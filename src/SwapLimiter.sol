// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GuardianPause} from "./GuardianPause.sol";
import {ISwapLimiter} from "./interfaces/ISwapLimiter.sol";
import {IExtsload, PoolDepth} from "./libraries/PoolDepth.sol";

/// @notice Arbitrum's system precompile at 0x64: the chain's own (L2) block number.
interface IArbSys {
    /// @notice The chain's own (L2) block number.
    function arbBlockNumber() external view returns (uint256);
}

/// @title SwapLimiter
/// @notice One limiter for every swap the protocol starts (docs/PRIORS-UNDERWRITING-SPEC.md 2A.5, section 8, section
///         12 SL-LIMITS). Each engine's cap is under the sandwich break-even on its own; stacked inside one attacker
///         transaction or one L2 block they are not, so every protocol swap calls `consume(usdg)` first:
///
///         - at most one protocol swap per L2 block, counted with `ArbSys(0x64).arbBlockNumber()` (on this Orbit chain
///           the EVM's `block.number` is the parent chain's, about one every 12 s; L2 blocks come every ~100 ms);
///         - a rolling hourly total at most the live cap, min(ceiling, 0.9 x D x (1/(1 - f) - 1)), with f the hook's
///           live fee (`hookFeeBps()` plus the creator tax, word 7 of `launches(poolId)`) and D the depth;
///         - D the smaller of min(L_live, L_snap) valued as one full-range position at the live price and the band
///           depth: the real USDG the pool pays out to a sale to 0.7 x spot and takes in from a buy to spot / 0.7,
///           recorded by `snapDepth()` and scaled to a full-range position;
///         - fail closed: the latest snapshot over 2 h old, the fee unreadable or above `expectedFeeBps` (400 bps),
///           ArbSys missing, or a zero price, and `consume` reverts.
///
///         Snapshots: 8 slots of 15 minutes, one per period (timestamp / 15 min, slot = period mod 8). Each keeps the
///         lowest L and band liquidities written in its period, and a write into a slot holding an older period starts
///         it fresh. The minima are taken over the slots whose period is one of the last 8, the current included, so
///         any number of extra snapshots can only lower them and every read is 8 slots. Band depths are stored as
///         full-range-equivalent liquidities (USDG x sqrtP / 2^96 / band factor): D at any price is then one product,
///         and the band term is valued at whatever price each form names (docs/PROTOCOL-BUILD.md, decision D3).
///
///         Who can do what: `consume` only BuyAndBack and SeatVaultV5, each set once through the timelock;
///         `snapDepth` the keeper (its helper) or the guardian Safe; the ceiling, `expectedFeeBps` and the keeper the
///         timelock; the guardian's pause stops `consume` only, never `snapDepth()` or a view, so a pause cannot turn
///         the depth guard on. No token ever passes through this contract.
contract SwapLimiter is ISwapLimiter, GuardianPause {
    using PoolDepth for PoolDepth.Pool;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    IArbSys public constant ARB_SYS = IArbSys(address(0x64));
    uint256 public constant BPS = 10_000;

    /// @notice A snapshot slot spans this long; 8 of them make the 2 h window.
    uint256 public constant SNAP_PERIOD = 15 minutes;
    uint256 public constant SNAP_SLOTS = 8;
    /// @notice Older than this, the latest snapshot fails every protocol swap closed.
    uint256 public constant MAX_SNAP_AGE = 2 hours;

    /// @notice The rolling window: 13 buckets of 5 minutes, the current one and the 12 before it, so the window always
    ///         covers the last hour (60 to 65 minutes of it).
    uint256 public constant BUCKET = 5 minutes;
    uint256 public constant BUCKETS = 13;

    /// @notice The depth guard's term values the fee clamped to this range (question 36).
    uint256 public constant GUARD_FEE_MIN_BPS = 200;
    uint256 public constant GUARD_FEE_MAX_BPS = 300;
    /// @notice `expectedFeeBps` is a ceiling under 100%, where the break-even formula ends.
    uint256 public constant MAX_EXPECTED_FEE_BPS = 9_999;

    /// @notice Gas given to each of the hook's two fee reads, and kept back to finish after them (2.2's pattern).
    uint256 public constant READ_GAS = 100_000;
    uint256 public constant READ_MARGIN = 5_000;

    /// @notice sqrt(0.7) scaled by 1e18, rounded up, and the two band factors rounded up: (1 - sqrt(0.7)) and
    ///         (sqrt(1/0.7) - 1). Rounded so every band end sits closer to spot and every depth rounds down.
    uint256 internal constant SQRT07_UP = 836660026534075548;
    uint256 internal constant DOWN_FACTOR_UP = 163339973465924453;
    uint256 internal constant UP_FACTOR_UP = 195228609334393640;
    uint256 internal constant E18 = 1e18;
    uint256 internal constant Q96 = 1 << 96;

    // ------------------------------------------------------------------
    // Immutables and storage
    // ------------------------------------------------------------------

    /// @notice The v4 PoolManager (read by extsload).
    IExtsload public immutable poolManager;
    /// @notice The $PRIORS/USDG pool's id.
    bytes32 public immutable poolId;
    /// @notice The pool's state slot in the PoolManager.
    bytes32 public immutable stateSlot;
    /// @notice The pool's tick spacing (200).
    int24 public immutable tickSpacing;
    /// @notice The Pons hook whose `hookFeeBps()` and `launches(poolId)` give f_live.
    address public immutable hook;

    /// @inheritdoc ISwapLimiter
    uint256 public ceiling;
    /// @inheritdoc ISwapLimiter
    uint256 public expectedFeeBps;
    /// @inheritdoc ISwapLimiter
    address public keeper;
    /// @inheritdoc ISwapLimiter
    address public buyAndBack;
    /// @inheritdoc ISwapLimiter
    address public v5;

    /// @notice 1 + the L2 block of the last consume (0: none yet).
    uint256 public lastSwapBlockPlusOne;
    /// @inheritdoc ISwapLimiter
    uint64 public lastSnapshotAt;

    struct Snap {
        uint64 period;
        uint128 liquidity;
        uint128 bandDown; // full-range-equivalent liquidity of the band below spot (what a sale to 0.7 x spot takes)
        uint128 bandUp; // full-range-equivalent liquidity of the band above spot (what a buy to spot / 0.7 pays)
    }

    Snap[8] internal _snaps;

    struct Bucket {
        uint64 index; // timestamp / BUCKET
        uint192 total;
    }

    Bucket[13] internal _buckets;

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotCaller(address caller);
    error NotKeeper(address caller);
    error AlreadySet();
    error BadAmount(uint256 usdg);
    error SwapInBlock(uint256 arbBlock);
    error FeeUnreadable();
    error FeeAboveCeiling(uint256 feeBps, uint256 ceilingBps);
    error StaleSnapshot(uint256 age);
    error PriceUnreadable();
    error OverCap(uint256 windowTotal, uint256 usdg, uint256 liveCap);
    error ReadStarved();
    error BadFeeBps(uint256 feeBps);

    /// @param poolManager_ the v4 PoolManager
    /// @param poolId_ the $PRIORS/USDG pool's id (USDG currency0)
    /// @param tickSpacing_ the pool's tick spacing
    /// @param hook_ the pool's hook (the fee reads)
    /// @param timelock_ the 48 h TimelockController
    /// @param guardian_ the Safe (pause, and `snapDepth`)
    /// @param keeper_ the keeper helper (may be predicted before it is deployed; the timelock can change it)
    /// @param ceiling_ the live cap's timelocked ceiling, raw USDG
    constructor(
        IExtsload poolManager_,
        bytes32 poolId_,
        int24 tickSpacing_,
        address hook_,
        address timelock_,
        address guardian_,
        address keeper_,
        uint256 ceiling_
    ) GuardianPause(guardian_, timelock_) {
        if (address(poolManager_) == address(0) || hook_ == address(0) || keeper_ == address(0)) {
            revert ZeroAddress();
        }
        if (tickSpacing_ <= 0) revert PriceUnreadable();
        poolManager = poolManager_;
        poolId = poolId_;
        stateSlot = PoolDepth.stateSlotOf(poolId_);
        tickSpacing = tickSpacing_;
        hook = hook_;
        keeper = keeper_;
        ceiling = ceiling_;
        expectedFeeBps = 400;
        emit KeeperSet(keeper_);
        emit CeilingSet(ceiling_);
        emit ExpectedFeeBpsSet(400);
    }

    // ------------------------------------------------------------------
    // Consume
    // ------------------------------------------------------------------

    /// @inheritdoc ISwapLimiter
    function consume(uint256 usdg) external whenNotPaused {
        // an unset caller is address(0), which never calls
        if (msg.sender != buyAndBack && msg.sender != v5) revert NotCaller(msg.sender);
        if (usdg == 0 || usdg > type(uint128).max) revert BadAmount(usdg);
        uint256 arbBlock = ARB_SYS.arbBlockNumber();
        if (lastSwapBlockPlusOne == arbBlock + 1) revert SwapInBlock(arbBlock);
        uint256 cap = _strictCap();
        uint256 used = _windowTotal();
        if (used + usdg > cap) revert OverCap(used, usdg, cap);

        lastSwapBlockPlusOne = arbBlock + 1;
        _record(usdg);
        emit Consumed(msg.sender, usdg, used + usdg, cap, arbBlock);
    }

    /// @dev The live cap, reverting with the reason on every fail-closed condition.
    function _strictCap() internal view returns (uint256) {
        (uint256 f, bool feeOk) = _feeLive();
        if (!feeOk) revert FeeUnreadable();
        if (f > expectedFeeBps) revert FeeAboveCeiling(f, expectedFeeBps);
        (uint128 lMin, uint256 age, bool snapOk) = _snapMin();
        if (!snapOk || age > MAX_SNAP_AGE) revert StaleSnapshot(age);
        PoolDepth.Pool memory p = _pool();
        (uint160 sqrtSpot,) = p.slot0();
        if (sqrtSpot == 0) revert PriceUnreadable();
        uint128 lLive = p.liquidity();
        return _cap(_value(lLive < lMin ? lLive : lMin, sqrtSpot), f);
    }

    // ------------------------------------------------------------------
    // Snapshots
    // ------------------------------------------------------------------

    /// @inheritdoc ISwapLimiter
    function snapDepth() external {
        if (msg.sender != keeper && msg.sender != _guardian) revert NotKeeper(msg.sender);
        PoolDepth.Pool memory p = _pool();
        (uint160 sqrtP, int24 tick) = p.slot0();
        if (sqrtP == 0) revert PriceUnreadable();
        uint128 l = p.liquidity();

        // a sale to 0.7 x spot: sqrtPriceX96 rises to sqrtP / sqrt(0.7) (rounded towards spot)
        uint256 endDown = Math.mulDiv(sqrtP, E18, SQRT07_UP);
        if (endDown > PoolDepth.MAX_SQRT_PRICE) endDown = PoolDepth.MAX_SQRT_PRICE;
        // safe cast: clamped to MAX_SQRT_PRICE just above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bandDown = p.amount0Up(sqrtP, tick, l, uint160(endDown));
        // a buy to spot / 0.7: sqrtPriceX96 falls to sqrtP x sqrt(0.7) (rounded towards spot)
        uint256 endUp = Math.mulDiv(sqrtP, SQRT07_UP, E18, Math.Rounding.Ceil);
        if (endUp < PoolDepth.MIN_SQRT_PRICE) endUp = PoolDepth.MIN_SQRT_PRICE;
        // safe cast: clamped to at least MIN_SQRT_PRICE above, and at most sqrtP
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 bandUp = p.amount0Down(sqrtP, tick, l, uint160(endUp));

        uint128 lDown = _toL(Math.mulDiv(Math.mulDiv(bandDown, sqrtP, Q96), E18, DOWN_FACTOR_UP));
        uint128 lUp = _toL(Math.mulDiv(Math.mulDiv(bandUp, sqrtP, Q96), E18, UP_FACTOR_UP));

        // safe cast: a timestamp / 900 fits 64 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 period = uint64(block.timestamp / SNAP_PERIOD);
        Snap storage s = _snaps[period % SNAP_SLOTS];
        if (s.period != period || lastSnapshotAt == 0) {
            s.period = period;
            s.liquidity = l;
            s.bandDown = lDown;
            s.bandUp = lUp;
        } else {
            if (l < s.liquidity) s.liquidity = l;
            if (lDown < s.bandDown) s.bandDown = lDown;
            if (lUp < s.bandUp) s.bandUp = lUp;
        }
        lastSnapshotAt = uint64(block.timestamp);
        emit DepthSnapped(period, l, bandDown, bandUp, sqrtP, msg.sender);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc ISwapLimiter
    function depthTerm(uint160 sqrtMedianX96, bool medianForm)
        external
        view
        returns (uint256 term, uint256 snapshotAge, bool ok)
    {
        uint128 lMin;
        (lMin, snapshotAge, ok) = _snapMin();
        (uint256 f, bool feeOk) = _feeLive();
        if (!ok || !feeOk || sqrtMedianX96 == 0) return (0, snapshotAge, false);
        uint160 sqrtRef = sqrtMedianX96;
        if (!medianForm) {
            // the live form: min(L_live, L_snap), valued at the lower of spot and the median (the larger
            // sqrtPriceX96), so a pump cannot raise it and a dump or a push out of a range lowers it at once
            PoolDepth.Pool memory p = _pool();
            (uint160 sqrtSpot,) = p.slot0();
            if (sqrtSpot == 0) return (0, snapshotAge, false);
            uint128 lLive = p.liquidity();
            if (lLive < lMin) lMin = lLive;
            if (sqrtSpot > sqrtRef) sqrtRef = sqrtSpot;
        }
        term = _term(_value(lMin, sqrtRef), _clampGuardFee(f));
    }

    /// @inheritdoc ISwapLimiter
    function liveCap() external view returns (uint256 cap, bool ok) {
        uint256 f;
        uint256 d;
        (d, f, ok) = _liveDepth();
        if (!ok || f > expectedFeeBps) return (0, false);
        cap = _cap(d, f);
    }

    /// @inheritdoc ISwapLimiter
    function liveDepth() external view returns (uint256 d, bool ok) {
        (d,, ok) = _liveDepth();
        if (!ok) d = 0;
    }

    /// @inheritdoc ISwapLimiter
    function hourRemaining() external view returns (uint256) {
        if (paused() || swappedThisBlock()) return 0;
        (uint256 d, uint256 f, bool ok) = _liveDepth();
        if (!ok || f > expectedFeeBps) return 0;
        uint256 cap = _cap(d, f);
        uint256 used = _windowTotal();
        return used >= cap ? 0 : cap - used;
    }

    /// @inheritdoc ISwapLimiter
    function swappedThisBlock() public view returns (bool) {
        (bool ok, bytes memory ret) = address(ARB_SYS).staticcall(abi.encodeCall(IArbSys.arbBlockNumber, ()));
        if (!ok || ret.length != 32) return true;
        return lastSwapBlockPlusOne == abi.decode(ret, (uint256)) + 1;
    }

    /// @inheritdoc ISwapLimiter
    function liveFeeBps() external view returns (uint256 feeBps, bool ok) {
        return _feeLive();
    }

    /// @inheritdoc ISwapLimiter
    function snapshot()
        external
        view
        returns (uint128 lSnap, uint128 lBandDown, uint128 lBandUp, uint256 age, bool ok)
    {
        // safe cast: a timestamp / 900 fits 64 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 cur = uint64(block.timestamp / SNAP_PERIOD);
        age = _age();
        lSnap = type(uint128).max;
        lBandDown = type(uint128).max;
        lBandUp = type(uint128).max;
        for (uint256 i; i < SNAP_SLOTS; ++i) {
            Snap memory s = _snaps[i];
            if (!_inWindow(s.period, cur)) continue;
            ok = true;
            if (s.liquidity < lSnap) lSnap = s.liquidity;
            if (s.bandDown < lBandDown) lBandDown = s.bandDown;
            if (s.bandUp < lBandUp) lBandUp = s.bandUp;
        }
        if (!ok) return (0, 0, 0, age, false);
    }

    /// @inheritdoc ISwapLimiter
    function windowTotal() external view returns (uint256) {
        return _windowTotal();
    }

    // ------------------------------------------------------------------
    // The timelock
    // ------------------------------------------------------------------

    /// @inheritdoc ISwapLimiter
    function timelock() public view override(ISwapLimiter, GuardianPause) returns (address) {
        return super.timelock();
    }

    /// @notice The live cap's ceiling. 0 stops every protocol swap for good until raised (section 8: the lasting stop
    ///         for a fault in a swap path).
    function setCeiling(uint256 ceiling_) external onlyTimelock {
        ceiling = ceiling_;
        emit CeilingSet(ceiling_);
    }

    /// @notice The fee ceiling above which every protocol swap reverts (400 bps at launch, question 13).
    function setExpectedFeeBps(uint256 feeBps) external onlyTimelock {
        if (feeBps > MAX_EXPECTED_FEE_BPS) revert BadFeeBps(feeBps);
        expectedFeeBps = feeBps;
        emit ExpectedFeeBpsSet(feeBps);
    }

    /// @notice The keeper allowed to `snapDepth` (the keeper helper).
    function setKeeper(address keeper_) external onlyTimelock {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice BuyAndBack's address, once.
    function setBuyAndBack(address buyAndBack_) external onlyTimelock {
        if (buyAndBack_ == address(0)) revert ZeroAddress();
        if (buyAndBack != address(0)) revert AlreadySet();
        buyAndBack = buyAndBack_;
        emit BuyAndBackSet(buyAndBack_);
    }

    /// @notice SeatVaultV5's address, once.
    function setV5(address v5_) external onlyTimelock {
        if (v5_ == address(0)) revert ZeroAddress();
        if (v5 != address(0)) revert AlreadySet();
        v5 = v5_;
        emit V5Set(v5_);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Where the pool's state lives in the PoolManager.
    function _pool() internal view returns (PoolDepth.Pool memory) {
        return PoolDepth.Pool(poolManager, stateSlot, tickSpacing);
    }

    /// @dev D at the live price with f_live, for the cap and the chunk sizes.
    function _liveDepth() internal view returns (uint256 d, uint256 f, bool ok) {
        (uint128 lMin, uint256 age, bool snapOk) = _snapMin();
        bool feeOk;
        (f, feeOk) = _feeLive();
        PoolDepth.Pool memory p = _pool();
        (uint160 sqrtSpot,) = p.slot0();
        if (!snapOk || !feeOk || age > MAX_SNAP_AGE || sqrtSpot == 0) return (0, f, false);
        uint128 lLive = p.liquidity();
        d = _value(lLive < lMin ? lLive : lMin, sqrtSpot);
        ok = true;
    }

    /// @dev The smallest of L_snap and the two band liquidities over the window, the latest snapshot's age, and
    ///      whether any slot is in the window.
    function _snapMin() internal view returns (uint128 lMin, uint256 age, bool ok) {
        // safe cast: a timestamp / 900 fits 64 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 cur = uint64(block.timestamp / SNAP_PERIOD);
        age = _age();
        lMin = type(uint128).max;
        for (uint256 i; i < SNAP_SLOTS; ++i) {
            Snap memory s = _snaps[i];
            if (!_inWindow(s.period, cur)) continue;
            ok = true;
            if (s.liquidity < lMin) lMin = s.liquidity;
            if (s.bandDown < lMin) lMin = s.bandDown;
            if (s.bandUp < lMin) lMin = s.bandUp;
        }
        if (!ok) lMin = 0;
    }

    /// @dev A slot counts when its period is one of the last SNAP_SLOTS, the current included, and was ever written.
    function _inWindow(uint64 period, uint64 cur) internal view returns (bool) {
        return lastSnapshotAt != 0 && period <= cur && period + SNAP_SLOTS > cur;
    }

    /// @dev Seconds since the latest snapshot; type(uint256).max before the first.
    function _age() internal view returns (uint256) {
        return lastSnapshotAt == 0 ? type(uint256).max : block.timestamp - lastSnapshotAt;
    }

    /// @dev Liquidity valued as one full-range position at `sqrtP`: L x 2^96 / sqrtP raw USDG, rounded down.
    function _value(uint128 l, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(l, Q96, sqrtP);
    }

    /// @dev 0.9 x D x f / (1 - f): the break-even victim size D x (1/(1 - f) - 1), times 0.9, rounded down.
    function _term(uint256 d, uint256 f) internal pure returns (uint256) {
        return Math.mulDiv(d, f * 9, (BPS - f) * 10);
    }

    /// @dev The live cap: min(ceiling, the depth term at `d` and `f`).
    function _cap(uint256 d, uint256 f) internal view returns (uint256) {
        uint256 t = _term(d, f);
        return t < ceiling ? t : ceiling;
    }

    /// @dev The depth guard's fee: f_live clamped to 200-300 bps (question 36).
    function _clampGuardFee(uint256 f) internal pure returns (uint256) {
        if (f < GUARD_FEE_MIN_BPS) return GUARD_FEE_MIN_BPS;
        if (f > GUARD_FEE_MAX_BPS) return GUARD_FEE_MAX_BPS;
        return f;
    }

    /// @dev A liquidity-equivalent, saturated at uint128 (only ever compared with real L).
    function _toL(uint256 x) internal pure returns (uint128) {
        // safe cast: checked against type(uint128).max on this line
        // forge-lint: disable-next-line(unsafe-typecast)
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }

    // ---- the rolling window ----

    /// @dev What was consumed in the current bucket and the 12 before it (60 to 65 minutes).
    function _windowTotal() internal view returns (uint256 total) {
        uint256 cur = block.timestamp / BUCKET;
        for (uint256 i; i < BUCKETS; ++i) {
            Bucket memory b = _buckets[i];
            if (b.index + BUCKETS > cur) total += b.total;
        }
    }

    /// @dev Add `usdg` to the current 5-minute bucket, restarting a bucket left from an older period.
    function _record(uint256 usdg) internal {
        uint256 cur = block.timestamp / BUCKET;
        Bucket storage b = _buckets[cur % BUCKETS];
        if (b.index != cur) {
            // safe cast: a timestamp / 300 fits 64 bits
            // forge-lint: disable-next-line(unsafe-typecast)
            b.index = uint64(cur);
            // safe cast: consume() caps usdg at type(uint128).max
            // forge-lint: disable-next-line(unsafe-typecast)
            b.total = uint192(usdg);
        } else {
            // safe cast: consume() caps usdg at type(uint128).max; the sum is checked
            // forge-lint: disable-next-line(unsafe-typecast)
            b.total += uint192(usdg);
        }
    }

    // ---- the hook's fee: 2.2's bounded reads ----

    /// @dev f_live = hookFeeBps() + launches(poolId) word 7. Each read is a staticcall with READ_GAS that copies one
    ///      word; a revert, a short reply or a word of 10,000 bps or more is a failed read. A caller that left less
    ///      than the budget reverts ReadStarved, so a failed read is always the hook's own fault.
    function _feeLive() internal view returns (uint256 f, bool ok) {
        (uint256 hookFee, bool ok1) = _readWord(abi.encodeWithSignature("hookFeeBps()"), 0);
        (uint256 tax, bool ok2) = _readWord(abi.encodeWithSignature("launches(bytes32)", poolId), 7);
        if (!ok1 || !ok2) return (0, false);
        f = hookFee + tax;
        if (f >= BPS) return (0, false);
        ok = true;
    }

    /// @dev One bounded read of the hook: word `word` of the reply to `data`, or ok false.
    function _readWord(bytes memory data, uint256 word) internal view returns (uint256 value, bool ok) {
        if (gasleft() < (READ_GAS * 64) / 63 + READ_MARGIN) revert ReadStarved();
        address target = hook;
        uint256 offset = word * 32;
        assembly ("memory-safe") {
            let success := staticcall(READ_GAS, target, add(data, 32), mload(data), 0, 0)
            if and(success, iszero(lt(returndatasize(), add(offset, 32)))) {
                let ptr := mload(0x40)
                returndatacopy(ptr, offset, 32)
                value := mload(ptr)
                ok := 1
            }
        }
        if (value >= BPS) return (0, false);
    }
}
