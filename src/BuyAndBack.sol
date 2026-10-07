// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {GuardianPause} from "./GuardianPause.sol";
import {IBuyAndBack} from "./interfaces/IBuyAndBack.sol";
import {ISeatVaultV5Engine} from "./interfaces/ISeatVaultV5.sol";
import {ISeatSizerV4, IPriorsBurn} from "./interfaces/IV5Deps.sol";
import {ISwapLimiter} from "./interfaces/ISwapLimiter.sol";
import {IPoolManagerV4, IUnlockCallbackV4, PoolKeyV4, SwapParamsV4} from "./interfaces/IPoolManagerV4.sol";
import {EngineMath} from "./libraries/EngineMath.sol";

/// @notice The one V5 read BuyAndBack needs beyond ISeatVaultV5Engine: the book's latest generation, for `Placed`.
interface ISeatVaultV5Gen {
    /// @notice The agent's latest generation (0: never opened).
    function latestGen(uint256 id) external view returns (uint32);
}

/// @title BuyAndBack
/// @notice Engine 2: backing from revenue (docs/PRIORS-UNDERWRITING-SPEC.md 2A.2; section 8's BuyAndBack row; section 12
///         BB-TOK, BB-USDG, BB-EPOCH, BB-BUY, BB-FILL). Protocol revenue buys $PRIORS in small, price-bounded chunks,
///         and the tokens are posted as backing (C) behind books that repay, pro rata to their counted repayments,
///         through SeatVaultV5's `back`. C shares the fees those books pay and half of it burns if the book defaults;
///         it never raises a line. This contract does not sell, and it does not aim at any price: it buys only within
///         its bounds and skips otherwise.
///
///         Money in: USDG from the RevenueRouter and C's fees from V5's `flush()` (plain transfers; nothing calls in).
///         $PRIORS in: its own buys, internal fills of queued USDG exits, and C returned by V5 (plain transfers).
///         $PRIORS out, and nothing else: placement behind a book (V5's `back`), and `burnFree` (timelock). There is no
///         sell, transfer, approval to another spender, migration or rescue of $PRIORS (BB-TOK). USDG out, and nothing
///         else: to the PoolManager for exactly what a buy's swap consumed, and to a leaver for an internal fill
///         (BB-USDG).
///
///         `buy()` (anyone; the keeper's 30-minute pass), in 2A.2's order:
///         1. cooldown: at least `gap` (1 h) since the last call that filled or swapped;
///         2. day roll: dayBudget = max(balance / 7, $5), set by the first call of the UTC day that fills or swaps;
///         3. reads: V5's cached median, only while the SeatSizer `lastObsAt` stored with it is at most 45 min old, else
///            the whole call skips; spot from slot0 by extsload; the SeatSizer's last keeper observation; D from the
///            SwapLimiter (failing closed when its latest snapshot is over 2 h old);
///         4. internal fills of V5's exit queue first, at most min(V5's exit chunk, the day's budget left, balance) per
///            call, priced at min(spot, median, last observation), only while spot and the observation are both within
///            2% of the median and V5's `exitServiceOpen()` holds, each `fillExit` and its USDG payment one inner call;
///         5. no chasing, no crash buying: the swap step skips while spot > median x 1.02, under V5's spot guard or depth
///            guard;
///         6. chunk x = min(depth share of D, the day's budget left, balance, the limiter's hour left, `chunkMax`);
///            skip under $5 (the limiter's views are read first, so no refusal of the limiter undoes a fill);
///         7. price limit P_limit = spot x (1 + 2x/D) x (1 + tolerance), rounded down as a price;
///         8. one exact-input swap USDG -> $PRIORS on the PoolManager, settling only the USDG consumed;
///         9. internal floor: tokens >= x_paid / P_limit x (1 - f_live) x (1 - tolerance), rounded up, else revert;
///         10. `Bought(spent, got, sqrtBefore, sqrtAfter)`.
///         A call that neither fills nor swaps writes nothing.
///
///         `place(id)` (anyone, O(1)): the first call of V5's weekly epoch e snapshots allot_e = the free balance and
///         W_e = the global points of epochs e-4..e-1 (closed to new points); each book claims once an epoch
///         allot_e x its points in e-4..e-1 / W_e, cut to the room V5 reports (min(A/6 - C, A - B - C, A/8 a week)), to
///         what the epoch has left and to the free balance. The rest stays free for the next epoch.
///
///         Governance: the timelock (immutable) sets V5's address once and the buy bounds, and may `burnFree`; the
///         guardian (the Safe) can pause `buy()` and `place()` only, at most 14 days, never again within 14 days.
contract BuyAndBack is IBuyAndBack, IUnlockCallbackV4, GuardianPause, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Basis points in one.
    uint256 public constant BPS = 10_000;
    /// @notice No pool buy, and no fill turn, under $5.
    uint256 public constant MIN_CHUNK = 5e6;
    /// @notice Admin bound (2A.2): a pool buy's chunk is at most $1,000.
    uint256 public constant MAX_CHUNK = 1_000e6;
    /// @notice Admin bound (2A.2): the chunk's share of D is at most 1%.
    uint256 public constant MAX_DEPTH_SHARE_BPS = 100;
    /// @notice Admin bound (2A.2): the price tolerance is at most 100 bps.
    uint256 public constant MAX_TOLERANCE_BPS = 100;
    /// @notice Admin bound (2A.2): calls that fill or swap are at least 15 min apart.
    uint64 public constant MIN_GAP = 15 minutes;
    /// @notice Build bound: the gap is at most 7 days, so a setting cannot stop buying for good.
    uint64 public constant MAX_GAP = 7 days;
    /// @notice V5's cached median is used only while the SeatSizer `lastObsAt` stored with it is at most this old.
    uint64 public constant FRESH = 45 minutes;
    /// @notice The day's budget is the larger of balance / BUDGET_DIVISOR and MIN_CHUNK.
    uint256 public constant BUDGET_DIVISOR = 7;
    /// @notice V5's exit chunk (a constant rule of V5's) is the smaller of EXIT_CHUNK_MAX ($250) and
    ///         EXIT_CHUNK_BPS (0.35%) of D.
    uint256 public constant EXIT_CHUNK_MAX = 250e6;
    /// @notice See EXIT_CHUNK_MAX.
    uint256 public constant EXIT_CHUNK_BPS = 35;
    /// @notice At most this many exit-queue heads are tried in one call.
    uint256 public constant MAX_HEADS = 5;
    /// @notice Gas given to a leaver's USDG payment.
    uint256 public constant PAY_GAS = 150_000;
    /// @notice Gas kept back, beyond PAY_GAS x 64/63, to finish after the payment.
    uint256 public constant PAY_MARGIN = 10_000;
    /// @notice Gas given to the `isFrozen` read.
    uint256 public constant READ_GAS = 50_000;
    /// @notice Where a burn goes when the token's own `burn()` does not take it (SeatVaultV4's `_burn`).
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant Q96 = 1 << 96;

    /// @notice `Skipped` reason: under `gap` since the last call that filled or swapped.
    uint8 public constant SKIP_COOLDOWN = 1;
    /// @notice `Skipped` reason: V5's median cache unset or its `lastObsAt` over 45 min old.
    uint8 public constant SKIP_STALE_MEDIAN = 2;
    /// @notice `Skipped` reason: no depth (the limiter's latest snapshot over 2 h old, a failed fee read, D zero).
    uint8 public constant SKIP_NO_DEPTH = 3;
    /// @notice `Skipped` reason (swap step): spot above median x 1.02 as a price.
    uint8 public constant SKIP_CHASE = 4;
    /// @notice `Skipped` reason (swap step): V5's spot guard on.
    uint8 public constant SKIP_SPOT_GUARD = 5;
    /// @notice `Skipped` reason (swap step): V5's depth guard on.
    uint8 public constant SKIP_DEPTH_GUARD = 6;
    /// @notice `Skipped` reason (swap step): the chunk under $5 (the day's budget, the balance, or the limiter's hour,
    ///         which reads 0 whenever `consume()` would refuse).
    uint8 public constant SKIP_SMALL = 7;

    // ------------------------------------------------------------------
    // Immutables
    // ------------------------------------------------------------------

    /// @notice USDG (currency0), 6 decimals.
    IERC20 public immutable usdg;
    /// @notice $PRIORS (currency1), 18 decimals.
    IERC20 public immutable priors;
    /// @notice The Uniswap v4 PoolManager.
    IPoolManagerV4 public immutable poolManager;
    /// @dev The SwapLimiter: `consume` before every swap; D, the hour's budget and f_live as views.
    ISwapLimiter internal immutable _limiter;
    /// @notice SeatSizerV4: the keeper's last observation (`observation(obsCount() - 1)`).
    ISeatSizerV4 public immutable sizer;
    /// @notice The $PRIORS/USDG pool's id (keccak256 of its key).
    bytes32 public immutable poolId;
    /// @notice The pool's state slot in the PoolManager (slot0 at +0).
    bytes32 public immutable stateSlot;
    // the pool key, field by field (immutables cannot be structs)
    uint24 internal immutable _fee;
    int24 internal immutable _tickSpacing;
    address internal immutable _hooks;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    /// @inheritdoc IBuyAndBack
    address public v5;

    /// @notice Pool buys: the chunk's cap ($250 at launch).
    uint256 public chunkMax;
    /// @notice Pool buys: the chunk's share of D, in bps (35 at launch).
    uint256 public depthShareBps;
    /// @notice Pool buys: the price limit's and the floor's tolerance, in bps (50 at launch).
    uint256 public toleranceBps;
    /// @notice The gap between calls that filled or swapped (1 h at launch).
    uint64 public gap;

    /// @notice The last call that filled or swapped.
    uint64 public lastActionAt;
    /// @notice The UTC day (timestamp / 1 day) `dayBudget` and `spentToday` belong to.
    uint64 public budgetDay;
    /// @notice That day's budget: the larger of balance / 7 and $5, set by its first call that filled or swapped.
    uint256 public dayBudget;
    /// @notice What that day's fills and buys spent.
    uint256 public spentToday;

    /// @notice The epoch whose allotment is open, plus one (0: none yet).
    uint256 public epochPlusOne;
    /// @notice The open epoch's allotment: the free balance at its first `place()`.
    uint256 public allot;
    /// @notice The open epoch's W_e: the global points of its four closed epochs at that first call.
    uint256 public epochPoints;
    /// @notice The shares the open epoch's claims took (never above `allot`).
    uint256 public epochClaimed;
    /// @notice A book's last claimed epoch, plus one.
    mapping(uint256 id => uint256) public claimedPlusOne;

    /// @notice USDG spent in pool buys (section 8's `protocolUsdgSpent`).
    uint256 public totalUsdgSpent;
    /// @notice $PRIORS bought in the pool (section 8's `protocolBought`).
    uint256 public totalBought;
    /// @notice USDG paid to leavers by internal fills.
    uint256 public totalFillUsdg;
    /// @notice $PRIORS received by internal fills.
    uint256 public totalFilled;
    /// @notice $PRIORS placed behind books as C (section 8's `protocolPlaced`).
    uint256 public totalPlaced;
    /// @notice $PRIORS burned by `burnFree`.
    uint256 public totalBurnedFree;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    /// @notice A pool buy: USDG spent, $PRIORS received, and the price before and after (sqrtPriceX96).
    event Bought(uint256 spent, uint256 got, uint160 sqrtBefore, uint160 sqrtAfter);
    /// @notice C placed behind book `id` (its generation `gen`) in epoch `epoch`.
    event Placed(uint256 indexed id, uint32 gen, uint256 epoch, uint256 tokens);
    /// @notice Epoch `epoch` opened: its allotment and its points W_e.
    event EpochOpened(uint256 indexed epoch, uint256 allot, uint256 points);
    /// @notice Free balance burned by the timelock.
    event FreeBurned(uint256 tokens);
    /// @notice An internal fill: `tokens` from V5's exit queue entry, `usdg` paid to its holder.
    event Filled(uint256 indexed entryId, address indexed holder, uint256 tokens, uint256 usdg);
    /// @notice A fill whose USDG payment failed: V5 returned the entry (as $PRIORS, or to the tail).
    event FillReturned(uint256 indexed entryId);
    /// @notice A `buy()` that did nothing, or whose swap step did not run, and why (the SKIP_ constants).
    event Skipped(uint8 reason);
    /// @notice V5's address, set once.
    event V5Set(address indexed v5);
    /// @notice The pool-buy bounds changed (timelock).
    event BuyParamsSet(uint256 chunkMax, uint256 depthShareBps, uint256 toleranceBps, uint64 gap);

    /// @notice V5's address is already set (it is set once).
    error AlreadySet();
    /// @notice The V5 named does not name this BuyAndBack, this timelock and this limiter.
    error WrongV5();
    /// @notice V5's address is not set yet (Stage 1).
    error V5NotSet();
    /// @notice A setting outside its bounds, or a constructor argument that does not fit.
    error BadParams();
    /// @notice `burnFree` of zero or of more than the free balance.
    error BadAmount(uint256 amount);
    /// @notice `unlockCallback` from anyone but the PoolManager.
    error NotPoolManager();
    /// @notice `fillOne` from anyone but this contract.
    error NotSelf();
    /// @notice The swap's deltas were not USDG in (at most the chunk) and $PRIORS out.
    error BadDelta();
    /// @notice The swap gave fewer $PRIORS than the internal floor.
    error BelowFloor(uint256 got, uint256 floor);
    /// @notice V5 reported a fill it did not deliver exactly, or above `maxTokens`.
    error BadFill(uint256 taken);
    /// @notice The leaver's USDG payment failed (the fill is undone; V5 returns the entry).
    error PayFailed();
    /// @notice The caller left less gas than the payment's budget.
    error PayStarved();
    /// @notice The fill's inner call failed starved of gas by the caller (EIP-150).
    error FillStarved();
    /// @notice The book already claimed in this epoch.
    error AlreadyPlaced(uint256 id, uint256 epoch);
    /// @notice The book fails V5's placement rule.
    error NotEligible(uint256 id);
    /// @notice The book has no points in the four closed epochs.
    error NoPoints(uint256 id);
    /// @notice The claim comes to nothing (no share, no room, or no free balance).
    error NothingToPlace(uint256 id);
    /// @notice V5's `back` did not pull exactly the tokens placed, or left an allowance.
    error BadPlacement(uint256 id);

    /// @notice Constructor arguments.
    struct Init {
        IERC20 usdg;
        IERC20 priors;
        IPoolManagerV4 poolManager;
        PoolKeyV4 poolKey;
        ISwapLimiter swapLimiter;
        ISeatSizerV4 sizer;
        address timelock;
        address guardian;
    }

    /// @param i the tokens, the PoolManager and the pool's key (USDG currency0, $PRIORS currency1), the SwapLimiter,
    ///          SeatSizerV4, the 48 h timelock and the guardian Safe
    constructor(Init memory i) GuardianPause(i.guardian, i.timelock) {
        if (
            address(i.usdg) == address(0) || address(i.priors) == address(0) || address(i.poolManager) == address(0)
                || address(i.swapLimiter) == address(0) || address(i.sizer) == address(0)
        ) revert ZeroAddress();
        if (i.poolKey.currency0 != address(i.usdg) || i.poolKey.currency1 != address(i.priors)) revert BadParams();
        if (i.swapLimiter.timelock() != i.timelock) revert BadParams();
        usdg = i.usdg;
        priors = i.priors;
        poolManager = i.poolManager;
        _limiter = i.swapLimiter;
        sizer = i.sizer;
        poolId = keccak256(abi.encode(i.poolKey));
        stateSlot = keccak256(abi.encode(poolId, uint256(6)));
        _fee = i.poolKey.fee;
        _tickSpacing = i.poolKey.tickSpacing;
        _hooks = i.poolKey.hooks;
        _setParams(250e6, 35, 50, 1 hours);
    }

    // ------------------------------------------------------------------
    // buy()
    // ------------------------------------------------------------------

    /// @dev One call's reads, kept in memory.
    struct Ctx {
        ISeatVaultV5Engine v;
        uint160 median;
        uint160 spot;
        uint160 obs;
        uint256 d;
        uint256 left; // min(the day's budget left, balance)
    }

    /// @inheritdoc IBuyAndBack
    function buy() external nonReentrant whenNotPaused {
        Ctx memory c = Ctx({v: _v5(), median: 0, spot: 0, obs: 0, d: 0, left: 0});
        uint64 last = lastActionAt;
        if (last != 0 && block.timestamp < uint256(last) + gap) return _skip(SKIP_COOLDOWN);
        uint64 obsAt;
        (c.median, obsAt,,) = c.v.priceCache();
        if (c.median == 0 || block.timestamp > uint256(obsAt) + FRESH) return _skip(SKIP_STALE_MEDIAN);
        bool dOk;
        (c.d, dOk) = _limiter.liveDepth();
        if (!dOk || c.d == 0) return _skip(SKIP_NO_DEPTH);
        c.spot = _spot();
        c.obs = _lastObservation();

        // the day's budget, rolled in memory: written only if this call fills or swaps
        uint256 bal = usdg.balanceOf(address(this));
        uint64 today = uint64(block.timestamp / 1 days);
        uint256 budget = dayBudget;
        uint256 spent = spentToday;
        if (today != budgetDay) {
            budget = Math.max(bal / BUDGET_DIVISOR, MIN_CHUNK);
            spent = 0;
        }
        c.left = Math.min(budget - spent, bal);

        uint256 filled = _fills(c);
        c.left -= filled;
        (uint256 paid, uint8 why) = _swapStep(c);
        if (filled == 0 && paid == 0) return _skip(why);
        if (paid == 0) emit Skipped(why);

        lastActionAt = uint64(block.timestamp);
        budgetDay = today;
        dayBudget = budget;
        spentToday = spent + filled + paid;
    }

    /// @dev Step 4: internal fills of V5's exit queue, before any swap. Returns the USDG paid to leavers.
    function _fills(Ctx memory c) internal returns (uint256 paidTotal) {
        // the fill band: spot and the last observation both within 2% of the median, 98 s^2 <= 100 m^2 <= 102 s^2
        if (!_inBand(c.spot, c.median) || !_inBand(c.obs, c.median)) return 0;
        if (!c.v.exitServiceOpen() || _frozen()) return 0;
        uint256 budget = Math.min(_exitChunk(c.d), c.left);
        // min(spot, median, last observation) as a price is the largest sqrtPriceX96
        uint160 sqrtFill = c.spot;
        if (c.median > sqrtFill) sqrtFill = c.median;
        if (c.obs > sqrtFill) sqrtFill = c.obs;
        for (uint256 i; i < MAX_HEADS; ++i) {
            uint256 room = budget - paidTotal;
            if (room < MIN_CHUNK) break;
            (uint256 entryId,,,,) = c.v.exitHead();
            if (entryId == 0) break;
            uint256 maxTokens = EngineMath.tokensForDown(room, sqrtFill);
            uint256 g = gasleft();
            try this.fillOne(entryId, maxTokens, sqrtFill) returns (uint256 taken, uint256 pay, address holder) {
                if (taken != 0) {
                    paidTotal += pay;
                    totalFilled += taken;
                    totalFillUsdg += pay;
                    emit Filled(entryId, holder, taken, pay);
                }
            } catch (bytes memory err) {
                // EIP-150: an inner call starved by its caller leaves under 1/64 of what it was given
                if (gasleft() < g / 63) revert FillStarved();
                // safe cast: the first four bytes of a reply of exactly four, the error's selector
                // forge-lint: disable-next-line(unsafe-typecast)
                if (err.length != 4 || bytes4(err) != PayFailed.selector) _bubble(err);
                // the leaver's USDG payment failed: V5 pays the entry's rest as $PRIORS, or moves it to the tail
                c.v.returnExit(entryId);
                emit FillReturned(entryId);
            }
        }
    }

    /// @notice One internal fill and its USDG payment, as one call (`buy()`'s try/catch). Only this contract calls it.
    ///         V5 sends `taken` $PRIORS (at most `maxTokens`); the holder is paid floor(taken x the fill price) in USDG.
    ///         A failed payment reverts `PayFailed`, which undoes the fill.
    /// @return taken $PRIORS received from V5 (0: the head was not filled)
    /// @return pay USDG paid to the holder
    /// @return holder the entry's holder
    function fillOne(uint256 entryId, uint256 maxTokens, uint160 sqrtFill)
        external
        returns (uint256 taken, uint256 pay, address holder)
    {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 before = priors.balanceOf(address(this));
        (taken, holder) = ISeatVaultV5Engine(v5).fillExit(entryId, maxTokens, sqrtFill);
        if (taken == 0) return (0, 0, holder);
        if (taken > maxTokens || priors.balanceOf(address(this)) != before + taken) revert BadFill(taken);
        pay = EngineMath.value(taken, sqrtFill);
        if (!_pay(holder, pay)) revert PayFailed();
    }

    /// @dev Steps 5 to 10: the pool buy. Returns the USDG it spent (0 when it skipped) and, when it skipped, why.
    function _swapStep(Ctx memory c) internal returns (uint256 paid, uint8 why) {
        uint160 sqrtBefore = _spot();
        // no chasing: skip while spot > median x 1.02, exactly 100 m^2 > 102 s^2
        if (!EngineMath.sqLe(100, c.median, 102, sqrtBefore)) return (0, SKIP_CHASE);
        if (c.v.spotGuardOn()) return (0, SKIP_SPOT_GUARD);
        if (c.v.depthGuard()) return (0, SKIP_DEPTH_GUARD);
        // the limiter's views first: hourRemaining() is 0 whenever consume() would refuse any amount
        uint256 x =
            Math.min(Math.min((c.d * depthShareBps) / BPS, c.left), Math.min(_limiter.hourRemaining(), chunkMax));
        if (x < MIN_CHUNK) return (0, SKIP_SMALL);
        // f_live in the same transaction; a failed read reads 0 here, the stricter floor (consume() refuses it anyway)
        (uint256 f,) = _limiter.liveFeeBps();
        uint160 sqrtLimit = priceLimit(sqrtBefore, x, c.d, toleranceBps);
        _limiter.consume(x);
        uint256 got;
        (paid, got) = abi.decode(poolManager.unlock(abi.encode(x, sqrtLimit)), (uint256, uint256));
        uint256 floor = minOut(paid, sqrtLimit, f, toleranceBps);
        if (got < floor) revert BelowFloor(got, floor);
        totalUsdgSpent += paid;
        totalBought += got;
        emit Bought(paid, got, sqrtBefore, _spot());
    }

    /// @inheritdoc IUnlockCallbackV4
    /// @dev The swap: USDG (currency0) in, exact input `x`, never past `sqrtLimit`; settles only the USDG the swap
    ///      consumed and takes every $PRIORS it gave (the V4SwapOnce pattern, src/tools/V4SwapOnce.sol).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 x, uint160 sqrtLimit) = abi.decode(data, (uint256, uint160));
        // safe cast: x is at most MAX_CHUNK
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountIn = -int256(x);
        int256 delta = poolManager.swap(
            _key(), SwapParamsV4({zeroForOne: true, amountSpecified: amountIn, sqrtPriceLimitX96: sqrtLimit}), ""
        );
        // safe casts: a BalanceDelta packs currency0's int128 in the upper half and currency1's in the lower
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 d0 = int128(delta >> 128);
        // forge-lint: disable-next-line(unsafe-typecast)
        int128 d1 = int128(delta);
        // safe casts: -d0 is converted only once d0 < 0, and d1 only once d1 >= 0
        // forge-lint: disable-next-line(unsafe-typecast)
        if (d0 >= 0 || d1 < 0 || uint256(uint128(-d0)) > x) revert BadDelta();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 paid = uint256(uint128(-d0));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 got = uint256(uint128(d1));
        poolManager.sync(address(usdg));
        usdg.safeTransfer(address(poolManager), paid);
        poolManager.settle();
        if (got != 0) poolManager.take(address(priors), address(this), got);
        return abi.encode(paid, got);
    }

    // ------------------------------------------------------------------
    // place()
    // ------------------------------------------------------------------

    /// @inheritdoc IBuyAndBack
    function place(uint256 id) external nonReentrant whenNotPaused {
        ISeatVaultV5Engine v = _v5();
        uint256 e = v.epochOf(block.timestamp);
        uint256 a = allot;
        uint256 w = epochPoints;
        uint256 claimed = epochClaimed;
        if (epochPlusOne != e + 1) {
            // the first call in e: the allotment is the free balance, W_e the global points of e-4..e-1
            a = priors.balanceOf(address(this));
            w = 0;
            for (uint256 j = 1; j <= 4 && j <= e; ++j) {
                w += v.globalPoints(e - j);
            }
            claimed = 0;
            epochPlusOne = e + 1;
            allot = a;
            epochPoints = w;
            emit EpochOpened(e, a, w);
        }
        if (claimedPlusOne[id] == e + 1) revert AlreadyPlaced(id, e);
        (uint256 room, bool eligible) = v.placeRoom(id);
        if (!eligible) revert NotEligible(id);
        uint256 pts = 0;
        for (uint256 j = 1; j <= 4 && j <= e; ++j) {
            pts += v.bookPoints(id, e - j);
        }
        if (pts == 0) revert NoPoints(id);
        // allot_e x points / W_e, rounded down; a book's points never exceed W_e (closed epochs only lose points), and
        // the shares are also held to what the epoch has left
        uint256 share = w == 0 ? 0 : Math.mulDiv(a, Math.min(pts, w), w);
        share = Math.min(share, a - claimed);
        uint256 tokens = Math.min(Math.min(share, room), priors.balanceOf(address(this)));
        if (tokens == 0) revert NothingToPlace(id);
        claimedPlusOne[id] = e + 1;
        epochClaimed = claimed + share;
        totalPlaced += tokens;

        uint256 before = priors.balanceOf(address(this));
        priors.forceApprove(address(v), tokens);
        v.back(id, tokens, false);
        if (before - priors.balanceOf(address(this)) != tokens || priors.allowance(address(this), address(v)) != 0) {
            revert BadPlacement(id);
        }
        emit Placed(id, ISeatVaultV5Gen(address(v)).latestGen(id), e, tokens);
    }

    // ------------------------------------------------------------------
    // The timelock
    // ------------------------------------------------------------------

    /// @inheritdoc IBuyAndBack
    /// @dev Refuses an address whose `buyAndBack()` is not this contract or whose `timelock()` or `swapLimiter()`
    ///      differ: a check against a mistake, not a hostile Safe (2A.2).
    function setV5(address v5_) external onlyTimelock {
        if (v5_ == address(0)) revert ZeroAddress();
        if (v5 != address(0)) revert AlreadySet();
        ISeatVaultV5Engine v = ISeatVaultV5Engine(v5_);
        if (v.buyAndBack() != address(this) || v.timelock() != _timelock || v.swapLimiter() != address(_limiter)) {
            revert WrongV5();
        }
        v5 = v5_;
        emit V5Set(v5_);
    }

    /// @inheritdoc IBuyAndBack
    /// @dev Burns through $PRIORS' `burn()`, sending what it does not take to 0x...dEaD (SeatVaultV4's `_burn`).
    function burnFree(uint256 amount) external onlyTimelock nonReentrant {
        uint256 before = priors.balanceOf(address(this));
        if (amount == 0 || amount > before) revert BadAmount(amount);
        totalBurnedFree += amount;
        try IPriorsBurn(address(priors)).burn(amount) {} catch {}
        uint256 gone = before - priors.balanceOf(address(this));
        if (gone < amount) priors.safeTransfer(DEAD, amount - gone);
        emit FreeBurned(amount);
    }

    /// @notice The pool-buy bounds (timelock): `chunkMax_` $5 to $1,000, `depthShareBps_` 1 to 100 (0.35% at launch),
    ///         `toleranceBps_` 0 to 100 (50 at launch), `gap_` 15 min to 7 days (1 h at launch). Fills keep V5's exit
    ///         chunk whatever these are.
    function setBuyParams(uint256 chunkMax_, uint256 depthShareBps_, uint256 toleranceBps_, uint64 gap_)
        external
        onlyTimelock
    {
        _setParams(chunkMax_, depthShareBps_, toleranceBps_, gap_);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IBuyAndBack
    function freeBalance() external view returns (uint256) {
        return priors.balanceOf(address(this));
    }

    /// @inheritdoc IBuyAndBack
    function swapLimiter() external view returns (address) {
        return address(_limiter);
    }

    /// @inheritdoc IBuyAndBack
    function timelock() public view override(IBuyAndBack, GuardianPause) returns (address) {
        return super.timelock();
    }

    /// @inheritdoc IBuyAndBack
    function guardian() public view override(IBuyAndBack, GuardianPause) returns (address) {
        return super.guardian();
    }

    /// @notice The pool's key.
    function poolKey() external view returns (PoolKeyV4 memory) {
        return _key();
    }

    /// @notice 2A.2 step 7: the price limit spot x (1 + 2x/D) x (1 + tolerance) in USDG per $PRIORS, rounded down as
    ///         a price, so up as a sqrtPriceX96 (a lower bound the swap cannot pass):
    ///         sqrtLimit = ceil(sqrtSpot x sqrt(D x 10,000 / ((D + 2x) x (10,000 + tol)))).
    function priceLimit(uint160 sqrtSpot, uint256 x, uint256 d, uint256 tolBps) public pure returns (uint160) {
        uint256 ratioQ128 = Math.mulDiv(d * BPS, 1 << 128, (d + 2 * x) * (BPS + tolBps), Math.Rounding.Ceil);
        uint256 rootQ64 = Math.sqrt(ratioQ128, Math.Rounding.Ceil);
        // safe cast: rootQ64 <= 2^64, so the result is at most sqrtSpot
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(Math.mulDiv(sqrtSpot, rootQ64, 1 << 64, Math.Rounding.Ceil));
    }

    /// @notice 2A.2 step 9: the internal floor, paid / P_limit x (1 - f) x (1 - tolerance) $PRIORS, rounded up.
    function minOut(uint256 paid, uint160 sqrtLimit, uint256 feeBps, uint256 tolBps) public pure returns (uint256) {
        uint256 t = Math.mulDiv(paid, sqrtLimit, Q96, Math.Rounding.Ceil);
        t = Math.mulDiv(t, sqrtLimit, Q96, Math.Rounding.Ceil);
        return Math.mulDiv(t, (BPS - feeBps) * (BPS - tolBps), BPS * BPS, Math.Rounding.Ceil);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev V5, or a revert while it is unset.
    function _v5() internal view returns (ISeatVaultV5Engine) {
        address a = v5;
        if (a == address(0)) revert V5NotSet();
        return ISeatVaultV5Engine(a);
    }

    /// @dev The pool's key from its immutables.
    function _key() internal view returns (PoolKeyV4 memory) {
        return PoolKeyV4({
            currency0: address(usdg), currency1: address(priors), fee: _fee, tickSpacing: _tickSpacing, hooks: _hooks
        });
    }

    /// @dev A call that does nothing: one event, no state.
    function _skip(uint8 why) internal {
        emit Skipped(why);
    }

    /// @dev Live spot, slot0's price by extsload.
    function _spot() internal view returns (uint160) {
        // safe cast: v4 packs slot0's price in the low 160 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(uint256(poolManager.extsload(stateSlot)));
    }

    /// @dev The SeatSizer's latest keeper observation, 0 if none.
    function _lastObservation() internal view returns (uint160) {
        uint256 n = sizer.obsCount();
        return n == 0 ? 0 : sizer.observation(n - 1);
    }

    /// @dev Within 2% of the median as a price: 98 x s^2 <= 100 x m^2 <= 102 x s^2 (2A.5's fill band).
    function _inBand(uint160 s, uint160 m) internal pure returns (bool) {
        return EngineMath.sqLe(98, s, 100, m) && EngineMath.sqLe(100, m, 102, s);
    }

    /// @dev V5's exit chunk: the smaller of $250 and 0.35% of D.
    function _exitChunk(uint256 d) internal pure returns (uint256) {
        return Math.min(EXIT_CHUNK_MAX, (d * EXIT_CHUNK_BPS) / BPS);
    }

    /// @dev Whether USDG's issuer reports this contract frozen; a read that fails counts as frozen (fills skip).
    ///      A caller that starves the read only skips this call's fills, which then wait in the queue.
    function _frozen() internal view returns (bool frozen) {
        bytes memory data = abi.encodeWithSignature("isFrozen(address)", address(this));
        address token = address(usdg);
        frozen = true;
        assembly ("memory-safe") {
            let ok := staticcall(READ_GAS, token, add(data, 32), mload(data), 0, 0)
            if and(ok, iszero(lt(returndatasize(), 32))) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, 32)
                frozen := iszero(iszero(mload(ptr)))
            }
        }
    }

    /// @dev `usdg.transfer(to, amount)` with PAY_GAS: true only for a call that succeeded and returned a true word
    ///      (USDG returns a bool; a reply of anything else counts as a failed payment, which returns the entry as
    ///      $PRIORS). Copies at most 32 bytes. A caller that left less than the budget reverts PayStarved, so a failed
    ///      payment is always the token's.
    function _pay(address to, uint256 amount) internal returns (bool ok) {
        if (gasleft() < (PAY_GAS * 64) / 63 + PAY_MARGIN) revert PayStarved();
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        address token = address(usdg);
        assembly ("memory-safe") {
            let success := call(PAY_GAS, token, 0, add(data, 32), mload(data), 0, 0)
            if and(success, iszero(lt(returndatasize(), 32))) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, 32)
                ok := eq(mload(ptr), 1)
            }
        }
    }

    /// @dev Re-raise a revert reason as it came.
    function _bubble(bytes memory err) internal pure {
        assembly ("memory-safe") {
            revert(add(err, 32), mload(err))
        }
    }

    /// @dev The pool-buy bounds, within MIN/MAX_CHUNK, 1..MAX_DEPTH_SHARE_BPS, 0..MAX_TOLERANCE_BPS, MIN/MAX_GAP.
    function _setParams(uint256 chunkMax_, uint256 depthShareBps_, uint256 toleranceBps_, uint64 gap_) internal {
        if (
            chunkMax_ < MIN_CHUNK || chunkMax_ > MAX_CHUNK || depthShareBps_ == 0
                || depthShareBps_ > MAX_DEPTH_SHARE_BPS || toleranceBps_ > MAX_TOLERANCE_BPS || gap_ < MIN_GAP
                || gap_ > MAX_GAP
        ) revert BadParams();
        chunkMax = chunkMax_;
        depthShareBps = depthShareBps_;
        toleranceBps = toleranceBps_;
        gap = gap_;
        emit BuyParamsSet(chunkMax_, depthShareBps_, toleranceBps_, gap_);
    }
}
