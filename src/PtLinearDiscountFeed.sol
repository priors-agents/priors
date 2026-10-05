// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPPrincipalToken, IStandardizedYield, IPYieldToken} from "./interfaces/IPendle.sol";

/// @title PtLinearDiscountFeed
/// @notice A Chainlink-style price feed for a Pendle PT in its underlying (PT-USDG in USDG), for StockVault's
///         `setAsset` (docs/PRIORS-UNDERWRITING-SPEC.md 2.11; docs/PT-USDG.md). It answers what StockVault's IPriceFeed
///         reads (decimals, latestRoundData, getRoundData) from a ring of stored rounds, so StockVault's 14-day history
///         walk (`_feedHold`) finds the rounds it needs.
///
///         Each round's answer is computed here, from `block.timestamp`, when the round is stored:
///
///           linear  = 1 - timeLeft × perSecond                          (1e18 = par)
///           perSecond = rateBps / (10,000 × 365 days), rounded up once, at construction (the discount errs larger)
///           cap     = exchangeRate / pyIndexStored, when the SY's rate fell below Pendle's index (else par)
///           answer  = min(linear, cap)
///
///         `rateBps` and the PT are fixed at construction (the owner's 6%, above the market's implied ~3.45%). The
///         answer is never above par, is par from expiry on (the PT redeems 1:1), and rises with time: a later round
///         never answers less, unless the SY's own rate falls (what a PT holder would then lose at redemption).
///         Anyone may store a round (`push`), at most one per MIN_INTERVAL; it takes no input, so a pusher chooses
///         only when, never the price (invariant PT-PRICE, spec section 12).
///
///         It stops answering (every read reverts, and so does `push`) while the SY is paused, and for good once the
///         Safe calls `switchOff`. StockVault treats a feed that reverts as no price: no new line and no new loan
///         against the PT; repayments, closes and defaults never read the price and go on.
contract PtLinearDiscountFeed {
    uint256 internal constant PAR = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 public constant MAX_RATE_BPS = 2000; // 20% a year at most
    uint256 public constant MAX_TERM = 2 * 365 days; // with MAX_RATE_BPS, the discount is never over ~40% of par
    /// @notice The least time between two rounds. 50 minutes: the keeper's passes come every 30 minutes, so one round
    ///         lands about every hour; 14 days hold about 400 rounds, which StockVault's walk (1, 2, 4 … 4,096 rounds
    ///         back) passes at 512.
    uint256 public constant MIN_INTERVAL = 50 minutes;
    /// @notice Rounds kept: 1,024, about 42 days at one an hour. Older ones are overwritten and no longer readable.
    uint256 public constant RING = 1024;

    struct Round {
        uint64 answer; // at most PAR (1e18 < 2^64)
        uint64 updatedAt;
    }

    IPPrincipalToken public immutable pt;
    IStandardizedYield public immutable sy;
    IPYieldToken public immutable yt;
    uint256 public immutable expiry;
    uint256 public immutable rateBps;
    uint256 public immutable perSecond; // the discount per second of time left (1e18 = par), rounded up
    address public immutable safe; // the only key here: it can switch the feed off, once, and nothing else

    Round[RING] internal _rounds; // round id r lives at r % RING
    uint64 public latestRound; // 0 until the first push
    bool public off;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event SwitchedOff(address indexed by);

    error InvalidParams();
    error NotSafe(address caller);
    error SwitchedOffForGood();
    error SyPaused();
    error TooSoon(uint256 next);
    error NoRound(uint80 roundId);

    constructor(IPPrincipalToken pt_, uint256 rateBps_, address safe_) {
        if (safe_ == address(0) || rateBps_ == 0 || rateBps_ > MAX_RATE_BPS) revert InvalidParams();
        uint256 expiry_ = pt_.expiry();
        if (expiry_ > block.timestamp + MAX_TERM) revert InvalidParams();
        pt = pt_;
        sy = IStandardizedYield(pt_.SY());
        yt = IPYieldToken(pt_.YT());
        expiry = expiry_;
        rateBps = rateBps_;
        perSecond = (rateBps_ * PAR + BPS * YEAR - 1) / (BPS * YEAR);
        safe = safe_;
    }

    // ------------------------------------------------------------------
    // Rounds
    // ------------------------------------------------------------------

    /// @notice Store a round at today's price. Anyone, at most once per MIN_INTERVAL.
    function push() external returns (uint80 roundId) {
        _live();
        uint64 last = latestRound;
        if (last != 0) {
            uint256 next = uint256(_rounds[last % RING].updatedAt) + MIN_INTERVAL;
            if (block.timestamp < next) revert TooSoon(next);
        }
        uint256 p = price();
        roundId = last + 1;
        _rounds[roundId % RING] = Round(uint64(p), uint64(block.timestamp));
        latestRound = uint64(roundId);
        emit AnswerUpdated(int256(p), roundId, block.timestamp);
    }

    /// @notice The Safe's off switch, one way: every read and every push reverts from now on.
    function switchOff() external {
        if (msg.sender != safe) revert NotSafe(msg.sender);
        off = true;
        emit SwitchedOff(msg.sender);
    }

    // ------------------------------------------------------------------
    // Chainlink's reads (as StockVault's IPriceFeed has them)
    // ------------------------------------------------------------------

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external pure returns (string memory) {
        return "PT / underlying, linear discount to par";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return getRoundData(uint80(latestRound));
    }

    /// @notice A stored round; reverts NoRound for one never stored or already overwritten (more than RING back).
    function getRoundData(uint80 roundId)
        public
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _live();
        uint256 last = latestRound;
        if (roundId == 0 || roundId > last || last - roundId >= RING) revert NoRound(roundId);
        Round memory r = _rounds[roundId % RING];
        return (roundId, int256(uint256(r.answer)), r.updatedAt, r.updatedAt, roundId);
    }

    // ------------------------------------------------------------------
    // The price
    // ------------------------------------------------------------------

    /// @notice What a round stored now would answer (1e18 = par).
    function price() public view returns (uint256) {
        uint256 p = _linear(block.timestamp);
        uint256 cap = syCap();
        return cap < p ? cap : p;
    }

    /// @notice What one PT redeems for at the SY's rate now, per Pendle's index (1e18 = par): par while the SY's rate
    ///         stands at or above its high-water mark, less once it has fallen below it.
    function syCap() public view returns (uint256) {
        uint256 rate = sy.exchangeRate();
        uint256 index = yt.pyIndexStored();
        return rate >= index ? PAR : rate * PAR / index;
    }

    /// @notice When the next round may be stored (0: now, no round yet).
    function nextPushAt() external view returns (uint256) {
        uint64 last = latestRound;
        return last == 0 ? 0 : uint256(_rounds[last % RING].updatedAt) + MIN_INTERVAL;
    }

    /// @dev The linear discount at time `t`, with no division: plainly linear in `t`. The product cannot overflow:
    ///      `expiry - t` is under 2^64 (the constructor bounds `expiry` by its own block time plus MAX_TERM) and
    ///      `perSecond` under 2^33 (MAX_RATE_BPS), so it is computed unchecked. For `t` at or after construction the
    ///      discount is at most MAX_RATE_BPS over MAX_TERM, 40% of par and a rounding (under 1e9 wei), so the checked
    ///      subtraction never underflows.
    function _linear(uint256 t) internal view returns (uint256) {
        if (t >= expiry) return PAR;
        uint256 discount;
        unchecked {
            discount = (expiry - t) * perSecond;
        }
        return PAR - discount;
    }

    function _live() internal view {
        if (off) revert SwitchedOffForGood();
        if (sy.paused()) revert SyPaused();
    }
}
