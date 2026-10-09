// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title V5Math
/// @notice SeatVaultV5's pure math: value at a sqrtPriceX96, the line, k's integer comparisons and every price bound of
///         2A.5, each exact. Prices are sqrtPriceX96 values of the $PRIORS/USDG pool (USDG currency0, 6 decimals;
///         $PRIORS currency1, 18 decimals): sqrtP² ÷ 2^192 is raw $PRIORS per raw USDG, so a higher sqrtPriceX96 is a
///         cheaper $PRIORS, and every "min of prices" is a max of sqrtPriceX96 values (2A.5, review B-F1).
///         Every rounding goes against whoever could profit from it (X-ROUND): stake valued down, its inverse up,
///         lines floored to $5, k's comparisons toward the wider range.
library V5Math {
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant LINE_STEP = 5e6;

    /// @notice USDG value of `tokens` $PRIORS at `sqrtP`, rounded down (two floors): tokens × 2^192 ÷ sqrtP².
    function value(uint256 tokens, uint160 sqrtP) internal pure returns (uint256) {
        if (sqrtP == 0) return 0;
        return Math.mulDiv(Math.mulDiv(tokens, Q96, sqrtP), Q96, sqrtP);
    }

    /// @notice $PRIORS whose value at `sqrtP` is at least `usdg`: each rounding up undoes one of `value`'s floors, so
    ///         value(tokensFor(N, s), s) ≥ N for every s (V5-P).
    function tokensFor(uint256 usdg, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(usdg, sqrtP, Q96, Math.Rounding.Ceil), sqrtP, Q96, Math.Rounding.Ceil);
    }

    /// @notice $PRIORS whose value at `sqrtP` is at most `usdg` (the inverse rounded down).
    function tokensForDown(uint256 usdg, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(usdg, sqrtP, Q96), sqrtP, Q96);
    }

    function floor5(uint256 x) internal pure returns (uint256) {
        return x - (x % LINE_STEP);
    }

    /// @notice floor to $5 of min(ceiling, value(a) ÷ k), with k doubled (`kx2` 3, 4 or 6).
    function line(uint256 aTokens, uint160 sqrtP, uint256 ceiling_, uint8 kx2) internal pure returns (uint256) {
        uint256 v = value(aTokens, sqrtP) * 2 / kx2;
        return floor5(v < ceiling_ ? v : ceiling_);
    }

    // ------------------------------------------------------------------
    // 512-bit comparisons of squared sqrtPriceX96 values
    // ------------------------------------------------------------------

    /// @dev The full 512-bit product of a and b.
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }

    /// @dev c × x² at full precision, for x < 2^160 and c < 2^64 (the result is under 2^384).
    function scaledSquare(uint256 c, uint160 x) internal pure returns (uint256 hi, uint256 lo) {
        (uint256 h, uint256 l) = mul512(x, x);
        (uint256 h2, uint256 l2) = mul512(l, c);
        hi = h * c + h2;
        lo = l2;
    }

    /// @notice Exactly c1 × a² ≤ c2 × b², at 512 bits (2A.5: "never in 256 bits").
    function sqLe(uint256 c1, uint160 a, uint256 c2, uint160 b) internal pure returns (bool) {
        (uint256 ah, uint256 al) = scaledSquare(c1, a);
        (uint256 bh, uint256 bl) = scaledSquare(c2, b);
        return ah < bh || (ah == bh && al <= bl);
    }

    // ------------------------------------------------------------------
    // k (2.3): range = (maxSqrt ÷ minSqrt)², the highest price over the lowest
    // ------------------------------------------------------------------

    /// @notice k stepping up at the thresholds: calm when 2·max² ≤ 3·min² (range ≤ 1.5), normal when 2·max² ≤ 5·min²
    ///         (≤ 2.5), wild otherwise. Inclusive thresholds; exact.
    function kUp(uint160 maxSqrt, uint160 minSqrt) internal pure returns (uint8) {
        if (sqLe(2, maxSqrt, 3, minSqrt)) return 3;
        if (sqLe(2, maxSqrt, 5, minSqrt)) return 4;
        return 6;
    }

    /// @notice k stepping down only 5% inside a threshold (question 35): calm at a range ≤ 1.425 (40·max² ≤ 57·min²),
    ///         normal at ≤ 2.375 (8·max² ≤ 19·min²).
    function kDown(uint160 maxSqrt, uint160 minSqrt) internal pure returns (uint8) {
        if (sqLe(40, maxSqrt, 57, minSqrt)) return 3;
        if (sqLe(8, maxSqrt, 19, minSqrt)) return 4;
        return 6;
    }

    /// @notice k_base = max(k_up(range), min(previous k_base, k_down(range))).
    function kBase(uint8 prev, uint160 maxSqrt, uint160 minSqrt) internal pure returns (uint8) {
        uint8 up = kUp(maxSqrt, minSqrt);
        uint8 down = kDown(maxSqrt, minSqrt);
        uint8 held = prev < down ? prev : down;
        return up > held ? up : held;
    }

    /// @notice The step-up (question 33): the newest entry at least 2% under the lowest of the other six
    ///         (49·newest² ≥ 50·prevMax²) and the range at least 1.2 (5·max² ≥ 6·min²).
    function stepUp(uint160 newest, uint160 prevMax, uint160 maxSqrt, uint160 minSqrt) internal pure returns (bool) {
        return sqLe(50, prevMax, 49, newest) && sqLe(6, minSqrt, 5, maxSqrt);
    }

    /// @notice One level higher, at most wild.
    function kNext(uint8 k) internal pure returns (uint8) {
        return k == 3 ? 4 : 6;
    }

    // ------------------------------------------------------------------
    // price bounds (2A.5's table), each exact
    // ------------------------------------------------------------------

    /// @notice Spot guard (refuse): price ≤ 0.80 × median, that is 5·median² ≤ 4·x².
    function atOrUnder80(uint160 x, uint160 median) internal pure returns (bool) {
        return sqLe(5, median, 4, x);
    }

    /// @notice Spot guard's latch off: price ≥ 0.90 × median, that is 10·median² ≥ 9·x².
    function atOrOver90(uint160 x, uint160 median) internal pure returns (bool) {
        return sqLe(9, x, 10, median);
    }

    /// @notice The leaver's floor: a price at `sqrtPrice` is at least 0.9 × the P recorded at the leave, that is
    ///         10·leave² ≥ 9·price².
    function meetsLeaveFloor(uint160 sqrtLeave, uint160 sqrtPrice) internal pure returns (bool) {
        return sqLe(9, sqrtPrice, 10, sqrtLeave);
    }

    function max160(uint160 a, uint160 b) internal pure returns (uint160) {
        return a > b ? a : b;
    }

    function min256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // ------------------------------------------------------------------
    // money splits
    // ------------------------------------------------------------------

    /// @notice The fee split (2.7): the book's part floor(fee × 7500 ÷ 10000), the buffer the rest.
    function split(uint256 fee) internal pure returns (uint256 book, uint256 buffer) {
        book = fee * 7500 / 10_000;
        buffer = fee - book;
    }

    /// @notice A layer's burn, rounded up (2.6). `units` is a $PRIORS amount, far under 2^200, so the product fits.
    function burnOf(uint256 units, uint256 rateBps) internal pure returns (uint256) {
        return (units * rateBps + 9_999) / 10_000;
    }

    /// @notice What `units` of a settled layer pay, rounded down.
    function remainderOf(uint256 units, uint256 rateBps) internal pure returns (uint256) {
        return units * (10_000 - rateBps) / 10_000;
    }

    /// @notice A credit: units × (to − from) ÷ 1e36, rounded down.
    function credit(uint256 units, uint256 fromIndex, uint256 toIndex) internal pure returns (uint256) {
        if (toIndex <= fromIndex || units == 0) return 0;
        return Math.mulDiv(units, toIndex - fromIndex, 1e36);
    }

    /// @notice The fee headroom (2.3): after vouching `add` more, free backing still covers ceil((delegatedOut + add)
    ///         × (200 + premium cap) × 10 days ÷ (10,000 × 30 days)), the fee of every vouched line drawn for 10 days.
    function headroomOk(uint256 free, uint256 delegatedOut, uint256 add, uint256 premiumCap)
        internal
        pure
        returns (bool)
    {
        if (add > free) return false;
        uint256 need = Math.mulDiv(delegatedOut + add, 200 + premiumCap, 30_000, Math.Rounding.Ceil);
        return free - add >= need;
    }

    /// @notice The fee of every vouched line drawn in full for 10 days at the steward's fee ceiling plus V5's premium
    ///         cap: ceil(delegatedOut × (200 + cap) ÷ 30,000), which `retire` leaves in free backing.
    function feeRoom(uint256 delegatedOut, uint256 premiumCap) internal pure returns (uint256) {
        return Math.mulDiv(delegatedOut, 200 + premiumCap, 30_000, Math.Rounding.Ceil);
    }

    /// @notice The largest `add` that `headroomOk` admits, floored to $5 (it may be one step short of the exact
    ///         maximum, never over it).
    function maxVouch(uint256 free, uint256 delegatedOut, uint256 premiumCap) internal pure returns (uint256) {
        uint256 q = 200 + premiumCap;
        uint256 num = free * 30_000;
        uint256 sub = delegatedOut * q + 29_999;
        if (num <= sub) return 0;
        return floor5((num - sub) / (30_000 + q));
    }
}
