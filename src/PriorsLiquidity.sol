// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {GuardianPause} from "./GuardianPause.sol";
import {IPriorsLiquidity} from "./interfaces/IPriorsLiquidity.sol";
import {IBuyAndBack} from "./interfaces/IBuyAndBack.sol";
import {ISeatVaultV5Engine} from "./interfaces/ISeatVaultV5.sol";
import {ISeatSizerV4} from "./interfaces/IV5Deps.sol";
import {ISwapLimiter} from "./interfaces/ISwapLimiter.sol";
import {IPoolManagerV4, IUnlockCallbackV4, PoolKeyV4, ModifyLiquidityParamsV4} from "./interfaces/IPoolManagerV4.sol";
import {EngineMath} from "./libraries/EngineMath.sol";
import {PoolDepth} from "./libraries/PoolDepth.sol";

/// @title PriorsLiquidity
/// @notice Engine 3: protocol-owned liquidity (docs/PRIORS-UNDERWRITING-SPEC.md 2A.3; section 8's PriorsLiquidity row;
///         section 12 PL-NOOUT, PL-RANGE, PL-SPEND). Revenue goes into the $PRIORS/USDG pool as USDG-only ranges
///         wholly below spot, which Priors never takes out. Decided (question 9): no swap, no decrease, no withdraw.
///
///         What it is, honestly: depth under the price, where a fall and USDG exits land, and none at spot. Its USDG
///         becomes $PRIORS only as the price falls into a range, and a range the price rises back through sells back,
///         within it, only what it bought there. It earns nothing (the pool's LP fee is zero). Every USDG put in is
///         spent for good: it can never pay a default or a lender, and it is stranded if $PRIORS trading moves to
///         another pool (accepted, question 9).
///
///         `run()` (anyone; the keeper tries it every pass):
///         - at least `gap` (1 h) after the last run, and within an allowance that accrues `maxPerRun` ($500) a day,
///           capped at `maxPerRun`, debited only by what a run adds;
///         - a fresh SeatSizer median (its `lastObsAt` at most 45 min old, at least 24 observations), else revert;
///         - the depth guard off (2.8's one predicate: the SwapLimiter's median-valued and live forms at that median,
///           a snapshot under 2 h old, and, once V5 exists, V5's `depthGuardOn()`), else revert;
///         - spend s = min(balance, allowance), at least $5, else revert;
///         - spot at most 2% under the median as a price (a same-transaction dump cannot place a run under the fair
///           price), else revert;
///         - the range: its top at (1 - offset) x min(spot, median), its bottom (1 - offset - width) x the same, in
///           ticks: the reference tick plus `offsetTicks` and plus `offsetTicks + widthTicks`, both rounded up to the
///           pool's tick spacing (away from spot). currency0 is USDG, so a cheaper $PRIORS is a higher tick and the range
///           sits above the current tick, where a position holds only USDG;
///         - if `tickLower` is not above the current tick, it adds nothing and writes nothing;
///         - one `modifyLiquidity` with a positive delta, owned by this contract (salt 0), settling exactly the net
///           deltas it reads back from the PoolManager (a donation's fee credit is taken and kept: USDG for the next
///           run, $PRIORS for good); the callback reverts if the $PRIORS delta is negative.
///
///         No function decreases liquidity or moves USDG or $PRIORS out; `rescue` covers only other tokens. The timelock
///         (immutable) sets the ladder, `maxPerRun` and `gap` within bounds that keep every range below spot; the
///         guardian (the Safe) can pause `run()` only.
contract PriorsLiquidity is IPriorsLiquidity, IUnlockCallbackV4, GuardianPause, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice No run under $5.
    uint256 public constant MIN_SPEND = 5e6;
    /// @notice The SeatSizer median is used only while its `lastObsAt` is at most this old.
    uint64 public constant FRESH = 45 minutes;
    /// @notice The depth guard: a snapshot over 2 h old, or a depth term under $500, is the guard on (2.8).
    uint256 public constant MAX_SNAP_AGE = 2 hours;
    /// @notice See MAX_SNAP_AGE.
    uint256 public constant DEPTH_MIN = 500e6;
    /// @notice Runs at least 1 h and at most 7 days apart (2A.3).
    uint64 public constant MIN_GAP = 1 hours;
    /// @notice See MIN_GAP.
    uint64 public constant MAX_GAP = 7 days;
    /// @notice The ladder's bounds: offset and width at least one tick spacing; their sum at most 100,000 ticks (the
    ///         bottom then sits at 1.0001^-100,000, about 0.0045% of the reference).
    uint24 public constant MAX_LADDER_TICKS = 100_000;
    /// @notice `maxPerRun`'s bounds.
    uint256 public constant MIN_MAX_PER_RUN = 5e6;
    /// @notice See MIN_MAX_PER_RUN.
    uint256 public constant MAX_MAX_PER_RUN = 5_000e6;

    uint256 internal constant Q96 = 1 << 96;

    // ------------------------------------------------------------------
    // Immutables
    // ------------------------------------------------------------------

    /// @notice USDG (currency0), 6 decimals.
    IERC20 public immutable usdg;
    /// @notice $PRIORS (currency1), 18 decimals.
    IERC20 public immutable priors;
    /// @notice The Uniswap v4 PoolManager.
    IPoolManagerV4 public immutable poolManager;
    /// @notice The SwapLimiter, read for the depth guard's views only (engine 3 never swaps).
    ISwapLimiter internal immutable _limiter;
    /// @notice SeatSizerV4: the 24h median `run()` reads itself.
    ISeatSizerV4 public immutable sizer;
    /// @notice BuyAndBack, whose one-time V5 address is the V5 `run()` reads (no address of its own to set).
    IBuyAndBack public immutable buyAndBack;
    /// @notice The $PRIORS/USDG pool's id (keccak256 of its key).
    bytes32 public immutable poolId;
    /// @notice The pool's state slot in the PoolManager (slot0 at +0, positions at +6).
    bytes32 public immutable stateSlot;
    uint24 internal immutable _fee;
    /// @notice The pool's tick spacing (200).
    int24 public immutable tickSpacing;
    address internal immutable _hooks;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @inheritdoc IPriorsLiquidity
    uint24 public offsetTicks;
    /// @inheritdoc IPriorsLiquidity
    uint24 public widthTicks;
    /// @inheritdoc IPriorsLiquidity
    uint64 public gap;
    /// @inheritdoc IPriorsLiquidity
    uint256 public maxPerRun;
    /// @notice The last run that added.
    uint64 public lastRunAt;
    /// @notice When `allowanceStored` was written.
    uint64 public allowanceAt;
    /// @notice The allowance as of `allowanceAt`.
    uint256 public allowanceStored;
    /// @inheritdoc IPriorsLiquidity
    uint256 public totalUsdgAdded;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    /// @notice A run: USDG added to the range [tickLower, tickUpper) as liquidity `liquidity`.
    event Added(uint256 usdgIn, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 totalUsdgAdded);
    /// @notice A run that added nothing: the range's top was not above the current tick.
    event Skipped(int24 tickLower, int24 tick);
    /// @notice Credits a run took and keeps (a donation's fee credit).
    event Credited(uint256 usdg, uint256 priors);
    /// @notice The ladder changed (timelock).
    event LadderSet(uint24 offsetTicks, uint24 widthTicks);
    /// @notice `maxPerRun` changed (timelock).
    event MaxPerRunSet(uint256 maxPerRun);
    /// @notice The allowance carried over a change of `maxPerRun` (what had accrued, capped at the new value).
    event AllowanceCarried(uint256 allowance);
    /// @notice The gap between runs changed (timelock).
    event GapSet(uint64 gap);
    /// @notice Another token sent here by mistake, sent on (timelock).
    event Rescued(address indexed token, address indexed to, uint256 amount);

    /// @notice A run sooner than `gap` after the last.
    error TooSoon(uint64 next);
    /// @notice The SeatSizer's `lastObsAt` over 45 min old.
    error StaleMedian(uint64 lastObsAt);
    /// @notice The depth guard is on (2.8's one predicate).
    error DepthGuard();
    /// @notice Spot more than 2% under the median as a price (100 s^2 > 102 m^2 in sqrtPriceX96, USDG currency0).
    error SpotBelowMedian();
    /// @notice min(balance, allowance) under $5.
    error TooLittle(uint256 spend);
    /// @notice The spend buys no liquidity at this range's prices.
    error ZeroLiquidity();
    /// @notice `unlockCallback` from anyone but the PoolManager.
    error NotPoolManager();
    /// @notice The add's principal was not USDG alone, at most the spend.
    error BadDelta();
    /// @notice The net $PRIORS delta read back was negative: the add would take $PRIORS.
    error PriorsDelta(int256 delta);
    /// @notice A setting outside its bounds, or a constructor argument that does not fit.
    error BadParams();
    /// @notice `rescue` of USDG or $PRIORS.
    error NotRescuable(address token);

    /// @notice Constructor arguments.
    struct Init {
        IERC20 usdg;
        IERC20 priors;
        IPoolManagerV4 poolManager;
        PoolKeyV4 poolKey;
        ISwapLimiter swapLimiter;
        ISeatSizerV4 sizer;
        IBuyAndBack buyAndBack;
        address timelock;
        address guardian;
    }

    /// @param i the tokens, the PoolManager and the pool's key (USDG currency0, $PRIORS currency1), the SwapLimiter,
    ///          SeatSizerV4, BuyAndBack, the 48 h timelock and the guardian Safe
    constructor(Init memory i) GuardianPause(i.guardian, i.timelock) {
        if (
            address(i.usdg) == address(0) || address(i.priors) == address(0) || address(i.poolManager) == address(0)
                || address(i.swapLimiter) == address(0) || address(i.sizer) == address(0)
                || address(i.buyAndBack) == address(0)
        ) revert ZeroAddress();
        if (
            i.poolKey.currency0 != address(i.usdg) || i.poolKey.currency1 != address(i.priors)
                || i.poolKey.tickSpacing <= 0 || i.swapLimiter.timelock() != i.timelock
                || i.buyAndBack.timelock() != i.timelock || i.buyAndBack.swapLimiter() != address(i.swapLimiter)
        ) revert BadParams();
        usdg = i.usdg;
        priors = i.priors;
        poolManager = i.poolManager;
        _limiter = i.swapLimiter;
        sizer = i.sizer;
        buyAndBack = i.buyAndBack;
        poolId = keccak256(abi.encode(i.poolKey));
        stateSlot = keccak256(abi.encode(poolId, uint256(6)));
        _fee = i.poolKey.fee;
        tickSpacing = i.poolKey.tickSpacing;
        _hooks = i.poolKey.hooks;
        allowanceAt = uint64(block.timestamp);
        _setLadder(200, 12_000);
        _setMaxPerRun(500e6);
        _setGap(1 hours);
    }

    // ------------------------------------------------------------------
    // run()
    // ------------------------------------------------------------------

    /// @inheritdoc IPriorsLiquidity
    function run() external nonReentrant whenNotPaused {
        uint64 last = lastRunAt;
        if (last != 0 && block.timestamp < uint256(last) + gap) revert TooSoon(last + gap);
        uint64 obsAt = sizer.lastObsAt();
        if (block.timestamp > uint256(obsAt) + FRESH) revert StaleMedian(obsAt);
        // reverts NotEnoughObservations under 24 observations of the last day
        uint160 median = sizer.medianSqrtPrice();
        if (depthGuardOn(median)) revert DepthGuard();
        uint256 allowed = allowance();
        uint256 s = Math.min(usdg.balanceOf(address(this)), allowed);
        if (s < MIN_SPEND) revert TooLittle(s);

        (int24 tickLower, int24 tickUpper, int24 tick, uint160 sqrtSpot) = range(median);
        // spot more than 2% under the median (as a price), e.g. a dump in the same transaction: no run, so a run's USDG
        // is never placed under the fair price for good; a falling market waits for the median (deep audit EN-L1)
        if (!EngineMath.sqLe(100, sqrtSpot, 102, median)) revert SpotBelowMedian();
        if (tickLower <= tick) {
            emit Skipped(tickLower, tick);
            return;
        }
        uint160 sqrtA = PoolDepth.sqrtPriceAtTick(tickLower);
        uint160 sqrtB = PoolDepth.sqrtPriceAtTick(tickUpper);
        uint128 liq = liquidityFor(s, sqrtA, sqrtB);
        if (liq == 0) revert ZeroLiquidity();

        (uint256 usdgIn, int256 net0, int256 net1) =
            abi.decode(poolManager.unlock(abi.encode(tickLower, tickUpper, liq, s)), (uint256, int256, int256));
        // the allowance as of now, less what this run added
        allowanceStored = allowed - usdgIn;
        allowanceAt = uint64(block.timestamp);
        lastRunAt = uint64(block.timestamp);
        uint256 total = totalUsdgAdded + usdgIn;
        totalUsdgAdded = total;
        if (net0 > 0 || net1 > 0) {
            // safe casts: each is converted only where it is positive (net1 is never negative here)
            // forge-lint: disable-next-line(unsafe-typecast)
            emit Credited(net0 > 0 ? uint256(net0) : 0, uint256(net1));
        }
        emit Added(usdgIn, tickLower, tickUpper, liq, total);
    }

    /// @inheritdoc IUnlockCallbackV4
    /// @dev The add: a positive liquidity delta only. Its principal must be USDG alone and at most the run's spend;
    ///      the net deltas read back from the PoolManager (principal plus any fee credit) are settled and taken
    ///      exactly, and a negative $PRIORS delta reverts, so an add can never take $PRIORS.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (int24 tickLower, int24 tickUpper, uint128 liq, uint256 s) = abi.decode(data, (int24, int24, uint128, uint256));
        (int256 callerDelta, int256 fees) = poolManager.modifyLiquidity(
            _key(),
            ModifyLiquidityParamsV4({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liq)), salt: bytes32(0)
            }),
            ""
        );
        // the principal: the caller's delta less the fees it includes, per currency
        // safe casts: a BalanceDelta packs currency0's int128 in the upper half and currency1's in the lower
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 p0 = int256(int128(callerDelta >> 128)) - int256(int128(fees >> 128));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 p1 = int256(int128(callerDelta)) - int256(int128(fees));
        // safe cast: -p0 is evaluated only once p0 <= 0, and it is an int128 difference
        // forge-lint: disable-next-line(unsafe-typecast)
        if (p0 > 0 || p1 != 0 || uint256(-p0) > s) revert BadDelta();

        int256 net0 = _delta(address(usdg));
        int256 net1 = _delta(address(priors));
        if (net1 < 0) revert PriorsDelta(net1);
        if (net0 < 0) {
            poolManager.sync(address(usdg));
            // safe cast: net0 < 0 on this branch
            // forge-lint: disable-next-line(unsafe-typecast)
            usdg.safeTransfer(address(poolManager), uint256(-net0));
            poolManager.settle();
        } else if (net0 > 0) {
            // safe cast: net0 > 0 on this branch
            // forge-lint: disable-next-line(unsafe-typecast)
            poolManager.take(address(usdg), address(this), uint256(net0));
        }
        // safe cast: net1 > 0 where it is converted
        // forge-lint: disable-next-line(unsafe-typecast)
        if (net1 > 0) poolManager.take(address(priors), address(this), uint256(net1));
        // safe cast: p0 <= 0, checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return abi.encode(uint256(-p0), net0, net1);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IPriorsLiquidity
    function allowance() public view returns (uint256) {
        uint256 m = maxPerRun;
        uint256 accrued = allowanceStored + ((block.timestamp - allowanceAt) * m) / 1 days;
        return accrued < m ? accrued : m;
    }

    /// @notice 2.8's one predicate at `median` (the SeatSizer median `run()` reads): the SwapLimiter's median-valued
    ///         and live forms (a failed read, a snapshot over 2 h old or a term under $500 each reading on), and, once
    ///         BuyAndBack names V5, V5's lasting `depthGuardOn()`.
    function depthGuardOn(uint160 median) public view returns (bool) {
        (uint256 tM, uint256 ageM, bool okM) = _limiter.depthTerm(median, true);
        (uint256 tL,, bool okL) = _limiter.depthTerm(median, false);
        if (!okM || !okL || ageM > MAX_SNAP_AGE || tM < DEPTH_MIN || tL < DEPTH_MIN) return true;
        address v = buyAndBack.v5();
        return v != address(0) && ISeatVaultV5Engine(v).depthGuardOn();
    }

    /// @notice The range a run at `median` would add to, and the pool's current tick and price. The reference is
    ///         min(spot, median) as a price, the larger sqrtPriceX96; both ends are rounded up to the tick spacing.
    function range(uint160 median)
        public
        view
        returns (int24 tickLower, int24 tickUpper, int24 tick, uint160 sqrtSpot)
    {
        uint256 w = uint256(poolManager.extsload(stateSlot));
        // safe casts: v4 packs slot0's price in bits 0-159 and its int24 tick in bits 160-183
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtSpot = uint160(w);
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(int256(w >> 160));
        int24 ref = EngineMath.tickAt(sqrtSpot > median ? sqrtSpot : median);
        // safe casts: offset and width are each at most MAX_LADDER_TICKS (100,000), far inside int24
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 off = int24(offsetTicks);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 wid = int24(widthTicks);
        tickLower = EngineMath.ceilTo(ref + off, tickSpacing);
        tickUpper = EngineMath.ceilTo(ref + off + wid, tickSpacing);
    }

    /// @notice The most liquidity whose USDG-only add over [sqrtA, sqrtB) costs at most `usdgAmount`, as v4 rounds the
    ///         add's amount up: floor(floor(usdg x sqrtA / 2^96) x sqrtB / (sqrtB - sqrtA)).
    function liquidityFor(uint256 usdgAmount, uint160 sqrtA, uint160 sqrtB) public pure returns (uint128) {
        return SafeCast.toUint128(Math.mulDiv(Math.mulDiv(usdgAmount, sqrtA, Q96), sqrtB, sqrtB - sqrtA));
    }

    /// @notice This contract's liquidity in the position [tickLower, tickUpper), salt 0, read from the PoolManager.
    function liquidityOf(int24 tickLower, int24 tickUpper) external view returns (uint128) {
        // v4's Position.calculatePositionKey: keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt))
        bytes32 key = keccak256(abi.encodePacked(address(this), tickLower, tickUpper, bytes32(0)));
        bytes32 slot = keccak256(abi.encode(key, uint256(stateSlot) + 6));
        return uint128(uint256(poolManager.extsload(slot)));
    }

    /// @inheritdoc IPriorsLiquidity
    function v5() external view returns (address) {
        return buyAndBack.v5();
    }

    /// @inheritdoc IPriorsLiquidity
    function swapLimiter() external view returns (address) {
        return address(_limiter);
    }

    /// @inheritdoc IPriorsLiquidity
    function timelock() public view override(IPriorsLiquidity, GuardianPause) returns (address) {
        return super.timelock();
    }

    /// @notice The pool's key.
    function poolKey() external view returns (PoolKeyV4 memory) {
        return _key();
    }

    // ------------------------------------------------------------------
    // The timelock
    // ------------------------------------------------------------------

    /// @inheritdoc IPriorsLiquidity
    /// @dev `offsetTicks_` and `widthTicks_` each at least one tick spacing, their sum at most MAX_LADDER_TICKS: with
    ///      both ends rounded up, `tickLower` is then at least a spacing above the reference tick, which is at or above
    ///      the current tick, so every range is wholly below spot whatever the setting.
    function setLadder(uint24 offsetTicks_, uint24 widthTicks_) external onlyTimelock {
        _setLadder(offsetTicks_, widthTicks_);
    }

    /// @inheritdoc IPriorsLiquidity
    /// @dev $5 to $5,000 a day; the allowance accrued so far is kept, capped at the new value.
    function setMaxPerRun(uint256 usdg_) external onlyTimelock {
        uint256 a = allowance();
        _setMaxPerRun(usdg_);
        uint256 carried = a < usdg_ ? a : usdg_;
        allowanceStored = carried;
        allowanceAt = uint64(block.timestamp);
        emit AllowanceCarried(carried);
    }

    /// @inheritdoc IPriorsLiquidity
    /// @dev 1 h to 7 days.
    function setGap(uint64 gap_) external onlyTimelock {
        _setGap(gap_);
    }

    /// @inheritdoc IPriorsLiquidity
    /// @dev Never USDG or $PRIORS; the positions live in the PoolManager and no function here can touch them.
    function rescue(address token, address to) external onlyTimelock nonReentrant {
        if (token == address(usdg) || token == address(priors)) revert NotRescuable(token);
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev The pool's key from its immutables.
    function _key() internal view returns (PoolKeyV4 memory) {
        return PoolKeyV4({
            currency0: address(usdg), currency1: address(priors), fee: _fee, tickSpacing: tickSpacing, hooks: _hooks
        });
    }

    /// @dev This contract's open delta in `currency`, read from the PoolManager's transient storage (v4's
    ///      CurrencyDelta slot: keccak256(abi.encode(target, currency))).
    function _delta(address currency) internal view returns (int256) {
        return int256(uint256(poolManager.exttload(keccak256(abi.encode(address(this), currency)))));
    }

    /// @dev The ladder within its bounds (each at least one spacing, the sum at most MAX_LADDER_TICKS).
    function _setLadder(uint24 offsetTicks_, uint24 widthTicks_) internal {
        // safe cast: tickSpacing is positive (checked at construction) and at most 2^23
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 spacing = uint24(tickSpacing);
        if (
            offsetTicks_ < spacing || widthTicks_ < spacing
                || uint256(offsetTicks_) + uint256(widthTicks_) > MAX_LADDER_TICKS
        ) revert BadParams();
        offsetTicks = offsetTicks_;
        widthTicks = widthTicks_;
        emit LadderSet(offsetTicks_, widthTicks_);
    }

    /// @dev `maxPerRun` within MIN/MAX_MAX_PER_RUN.
    function _setMaxPerRun(uint256 m) internal {
        if (m < MIN_MAX_PER_RUN || m > MAX_MAX_PER_RUN) revert BadParams();
        maxPerRun = m;
        emit MaxPerRunSet(m);
    }

    /// @dev The gap within MIN/MAX_GAP.
    function _setGap(uint64 g) internal {
        if (g < MIN_GAP || g > MAX_GAP) revert BadParams();
        gap = g;
        emit GapSet(g);
    }
}
