// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {V5Math as M} from "../../src/v5/V5Math.sol";

/// @notice Fuzz tests of V5's pure math: value and its inverses, the line, the 512-bit comparisons, k, the splits,
///         the burn factors, the fee checkpoint and the fee headroom (X-ROUND, V5-P, 2.3, 2.6, 2.7).
/// forge-config: default.fuzz.runs = 5000
contract V5MathTest is Test {
    uint160 internal constant MIN_SQRT = 4_295_128_739;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    function _sqrt(uint256 s) internal pure returns (uint160) {
        return uint160(bound(s, MIN_SQRT, MAX_SQRT - 1));
    }

    // ---------------------------------------------------------------- value and its inverses

    /// @dev Over the realistic range (stakes up to 1e30 raw $PRIORS, any pool price).
    function testFuzz_tokensFor_coversValue(uint256 usdg, uint256 s) public pure {
        usdg = bound(usdg, 0, 1e18);
        uint160 sp = _sqrt(s);
        uint256 t = M.tokensFor(usdg, sp);
        vm.assume(t < 1e40);
        assertGe(M.value(t, sp), usdg, "tokensFor buys at least the value");
    }

    function testFuzz_tokensForDown_underValue(uint256 usdg, uint256 s) public pure {
        usdg = bound(usdg, 0, 1e18);
        uint160 sp = _sqrt(s);
        uint256 t = M.tokensForDown(usdg, sp);
        assertLe(M.value(t, sp), usdg, "the inverse rounded down never exceeds the value");
    }

    function testFuzz_value_monotone(uint256 a, uint256 b, uint256 s1, uint256 s2) public pure {
        a = bound(a, 0, 1e36);
        b = bound(b, a, 1e36);
        uint160 x = _sqrt(s1);
        uint160 y = uint160(bound(s2, x, MAX_SQRT - 1));
        assertLe(M.value(a, x), M.value(b, x), "more tokens are worth more");
        assertGe(M.value(a, x), M.value(a, y), "a higher sqrtPriceX96 (cheaper PRIORS) values less");
    }

    function testFuzz_value_zeroPrice(uint256 a) public pure {
        assertEq(M.value(a, 0), 0);
    }

    // ---------------------------------------------------------------- the line

    function testFuzz_line_bounds(uint256 a, uint256 s, uint256 ceil_, uint8 kSel) public pure {
        a = bound(a, 0, 1e36);
        uint160 sp = _sqrt(s);
        ceil_ = bound(ceil_, 0, 1e12);
        uint8 kx2 = [uint8(3), 4, 6][kSel % 3];
        uint256 l = M.line(a, sp, ceil_, kx2);
        uint256 raw = M.value(a, sp) * 2 / kx2;
        uint256 cap = raw < ceil_ ? raw : ceil_;
        assertEq(l % 5e6, 0, "a multiple of $5");
        assertLe(l, ceil_, "never above the tier's ceiling");
        assertLe(l * kx2, M.value(a, sp) * 2, "cover: k x line <= value of A");
        assertGt(l + 5e6, cap, "only the $5 floor is lost");
    }

    function testFuzz_line_wilderIsSmaller(uint256 a, uint256 s, uint256 ceil_) public pure {
        a = bound(a, 0, 1e36);
        uint160 sp = _sqrt(s);
        ceil_ = bound(ceil_, 0, 1e12);
        assertGe(M.line(a, sp, ceil_, 3), M.line(a, sp, ceil_, 4));
        assertGe(M.line(a, sp, ceil_, 4), M.line(a, sp, ceil_, 6));
    }

    function testFuzz_floor5(uint256 x) public pure {
        uint256 f = M.floor5(x);
        assertEq(f % 5e6, 0);
        assertLe(f, x);
        assertLt(x - f, 5e6);
    }

    // ---------------------------------------------------------------- 512-bit comparisons

    function testFuzz_sqLe_matches256(uint256 c1, uint256 a, uint256 c2, uint256 b) public pure {
        c1 = bound(c1, 0, type(uint32).max);
        c2 = bound(c2, 0, type(uint32).max);
        uint160 x = uint160(bound(a, 0, type(uint96).max));
        uint160 y = uint160(bound(b, 0, type(uint96).max));
        assertEq(M.sqLe(c1, x, c2, y), c1 * x * x <= c2 * y * y);
    }

    /// @dev Full-width: compare against the 512-bit identity (c·a² ≤ c·b² ⇔ a ≤ b for c > 0).
    function testFuzz_sqLe_fullWidth(uint256 c, uint256 a, uint256 b) public pure {
        c = bound(c, 1, type(uint64).max);
        uint160 x = uint160(a);
        uint160 y = uint160(b);
        assertEq(M.sqLe(c, x, c, y), x <= y);
    }

    function testFuzz_mul512(uint256 a, uint256 b) public pure {
        (uint256 hi, uint256 lo) = M.mul512(a, b);
        assertEq(lo, _lo(a, b));
        if (a < (1 << 128) && b < (1 << 128)) assertEq(hi, 0);
        if (b != 0) assertEq(hi, _hi(a, b));
    }

    function _lo(uint256 a, uint256 b) internal pure returns (uint256 r) {
        unchecked {
            r = a * b;
        }
    }

    function _hi(uint256 a, uint256 b) internal pure returns (uint256 r) {
        // schoolbook on 128-bit halves
        uint256 a1 = a >> 128;
        uint256 a0 = a & type(uint128).max;
        uint256 b1 = b >> 128;
        uint256 b0 = b & type(uint128).max;
        uint256 mid1 = a1 * b0;
        uint256 mid0 = a0 * b1;
        uint256 low = a0 * b0;
        uint256 carry = ((low >> 128) + (mid1 & type(uint128).max) + (mid0 & type(uint128).max)) >> 128;
        r = a1 * b1 + (mid1 >> 128) + (mid0 >> 128) + carry;
    }

    // ---------------------------------------------------------------- k

    /// @dev k_up classifies the range (max ÷ min)² exactly: ≤ 1.5 → 3, ≤ 2.5 → 4, else 6 (doubled k).
    function testFuzz_kUp_rational(uint256 a, uint256 b) public pure {
        uint160 lo = uint160(bound(a, 1, type(uint96).max));
        uint160 hi = uint160(bound(b, lo, uint256(lo) * 4));
        uint8 k = M.kUp(hi, lo);
        uint256 h2 = uint256(hi) * hi;
        uint256 l2 = uint256(lo) * lo;
        if (2 * h2 <= 3 * l2) assertEq(k, 3);
        else if (2 * h2 <= 5 * l2) assertEq(k, 4);
        else assertEq(k, 6);
    }

    function testFuzz_kDown_neverAboveUp(uint256 a, uint256 b) public pure {
        uint160 lo = uint160(bound(a, 1, type(uint96).max));
        uint160 hi = uint160(bound(b, lo, uint256(lo) * 4));
        assertGe(M.kDown(hi, lo), M.kUp(hi, lo), "stepping down needs a calmer range than stepping up");
    }

    function testFuzz_kBase_hysteresis(uint8 pSel, uint256 a, uint256 b) public pure {
        uint8 prev = [uint8(3), 4, 6][pSel % 3];
        uint160 lo = uint160(bound(a, 1, type(uint96).max));
        uint160 hi = uint160(bound(b, lo, uint256(lo) * 4));
        uint8 k = M.kBase(prev, hi, lo);
        uint8 up = M.kUp(hi, lo);
        uint8 down = M.kDown(hi, lo);
        assertGe(k, up, "never below k_up");
        assertTrue(k == 3 || k == 4 || k == 6);
        if (k < prev) assertEq(k, down < up ? up : down, "a step down only to k_down");
        if (prev <= up) assertEq(k, up, "rises at once");
    }

    function testFuzz_stepUp(uint256 n, uint256 p, uint256 mx, uint256 mn) public pure {
        uint160 newest = uint160(bound(n, 1, type(uint96).max));
        uint160 prevMax = uint160(bound(p, 1, type(uint96).max));
        uint160 lo = uint160(bound(mn, 1, type(uint96).max));
        uint160 hi = uint160(bound(mx, lo, type(uint96).max));
        bool expect = 50 * uint256(prevMax) * prevMax <= 49 * uint256(newest) * newest
            && 6 * uint256(lo) * lo <= 5 * uint256(hi) * hi;
        assertEq(M.stepUp(newest, prevMax, hi, lo), expect);
    }

    function test_kNext() public pure {
        assertEq(M.kNext(3), 4);
        assertEq(M.kNext(4), 6);
        assertEq(M.kNext(6), 6);
    }

    function testFuzz_priceBounds(uint256 a, uint256 b) public pure {
        uint160 x = uint160(bound(a, 1, type(uint96).max));
        uint160 m = uint160(bound(b, 1, type(uint96).max));
        uint256 x2 = uint256(x) * x;
        uint256 m2 = uint256(m) * m;
        assertEq(M.atOrUnder80(x, m), 5 * m2 <= 4 * x2);
        assertEq(M.atOrOver90(x, m), 9 * x2 <= 10 * m2);
        assertEq(M.meetsLeaveFloor(m, x), 9 * x2 <= 10 * m2);
    }

    function testFuzz_minMax(uint256 a, uint256 b) public pure {
        assertEq(M.max256(a, b), a > b ? a : b);
        assertEq(M.min256(a, b), a < b ? a : b);
        assertEq(M.max160(uint160(a), uint160(b)), uint160(a) > uint160(b) ? uint160(a) : uint160(b));
    }

    // ---------------------------------------------------------------- splits, burns, credits

    function testFuzz_split(uint256 fee) public pure {
        fee = bound(fee, 0, type(uint256).max / 7500);
        (uint256 book, uint256 buf) = M.split(fee);
        assertEq(book + buf, fee, "nothing lost");
        assertEq(book, fee * 3 / 4, "the book takes floor(75%)");
        assertGe(buf * 3, book, "the buffer never under 25% - rounding");
    }

    function testFuzz_burnFactors(uint256 units, bool owner) public pure {
        units = bound(units, 0, 1e40);
        uint256 rate = owner ? 7500 : 5000;
        uint256 b = M.burnOf(units, rate);
        uint256 r = M.remainderOf(units, rate);
        assertEq(b + r, units, "burn rounded up and remainder rounded down sum to the layer");
        assertGe(b * 10_000, units * rate, "never burns less than the rate");
        assertLt(b * 10_000, units * rate + 10_000, "at most one unit over");
    }

    /// @dev The fee checkpoint: crediting in steps never pays more than one credit over the whole span.
    function testFuzz_credit_checkpoint(uint256 units, uint256 i0, uint256 d1, uint256 d2) public pure {
        units = bound(units, 0, 1e40);
        i0 = bound(i0, 0, 1e60);
        d1 = bound(d1, 0, 1e60);
        d2 = bound(d2, 0, 1e60);
        uint256 i1 = i0 + d1;
        uint256 i2 = i1 + d2;
        uint256 whole = M.credit(units, i0, i2);
        uint256 parts = M.credit(units, i0, i1) + M.credit(units, i1, i2);
        assertLe(parts, whole, "stepwise credits never exceed the whole");
        assertLe(whole - parts, 1, "and lose at most one rounding");
        assertEq(M.credit(units, i2, i1), 0, "a stale index credits nothing");
    }

    /// @dev Many holders of one index: the credits sum to at most the fees that raised it.
    function testFuzz_credit_sumBounded(uint256 fee, uint256 u1, uint256 u2, uint256 u3) public pure {
        u1 = bound(u1, 1, 1e33);
        u2 = bound(u2, 0, 1e33);
        u3 = bound(u3, 0, 1e33);
        fee = bound(fee, 0, 1e18);
        uint256 div = u1 + u2 + u3;
        uint256 di = fee * 1e36 / div;
        uint256 sum = M.credit(u1, 0, di) + M.credit(u2, 0, di) + M.credit(u3, 0, di);
        assertLe(sum, fee);
    }

    // ---------------------------------------------------------------- fee headroom

    function testFuzz_maxVouch(uint256 free, uint256 dOut, uint256 cap) public pure {
        free = bound(free, 0, 1e15);
        dOut = bound(dOut, 0, 1e15);
        cap = bound(cap, 0, 200);
        uint256 m = M.maxVouch(free, dOut, cap);
        assertEq(m % 5e6, 0);
        if (m > 0) assertTrue(M.headroomOk(free, dOut, m, cap), "the max fits");
        assertFalse(M.headroomOk(free, dOut, m + 10e6, cap), "two steps more never fits");
        assertTrue(M.headroomOk(free, dOut, 0, cap) == (free >= M.feeRoom(dOut, cap)), "feeRoom is the need at 0");
    }

    function testFuzz_headroom_monotone(uint256 free, uint256 dOut, uint256 add, uint256 cap) public pure {
        free = bound(free, 0, 1e15);
        dOut = bound(dOut, 0, 1e15);
        add = bound(add, 1, 1e15);
        cap = bound(cap, 0, 200);
        if (M.headroomOk(free, dOut, add, cap)) assertTrue(M.headroomOk(free, dOut, add - 1, cap));
    }
}
