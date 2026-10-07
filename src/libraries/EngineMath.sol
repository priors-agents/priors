// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolDepth} from "./PoolDepth.sol";

/// @title EngineMath
/// @notice The price and range arithmetic BuyAndBack and PriorsLiquidity share (docs/PRIORS-UNDERWRITING-SPEC.md 2A.5,
///         "Prices in sqrtPriceX96, stated once"). The pool's currency0 is USDG (6 decimals) and currency1 $PRIORS (18),
///         so sqrtPriceX96 = 2^96 x sqrt(raw $PRIORS per raw USDG): a higher sqrtPriceX96 is a cheaper $PRIORS, the min
///         of prices is the max of their sqrtPriceX96 values, and a price bound flips when written in sqrtPriceX96.
///
///         Every bound is an exact integer comparison of small constants times squared sqrtPriceX96 values, taken at
///         512 bits (a uint160 squared passes 256 bits), never through a fixed-point constant (2A.5).
library EngineMath {
    uint256 internal constant Q96 = 1 << 96;

    /// @notice Exactly c1 x a^2 <= c2 x b^2, at 512 bits, for a, b < 2^160 and c1, c2 < 2^64.
    function sqLe(uint256 c1, uint160 a, uint256 c2, uint160 b) internal pure returns (bool) {
        (uint256 ah, uint256 al) = _scaledSquare(c1, a);
        (uint256 bh, uint256 bl) = _scaledSquare(c2, b);
        return ah < bh || (ah == bh && al <= bl);
    }

    /// @notice USDG worth of `tokens` $PRIORS at `sqrtP`: tokens x 2^192 / sqrtP^2, each of the two steps rounded down
    ///         (SeatVaultV5's `value`, so a fill's payment matches the value V5 reports for it).
    function value(uint256 tokens, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(tokens, Q96, sqrtP), Q96, sqrtP);
    }

    /// @notice $PRIORS worth at most `usdg` at `sqrtP`: usdg x sqrtP^2 / 2^192, rounded down.
    function tokensForDown(uint256 usdg, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(usdg, sqrtP, Q96), sqrtP, Q96);
    }

    /// @notice The greatest tick whose sqrt price is at or under `sqrtP` (v4's getTickAtSqrtPrice), by binary search
    ///         over PoolDepth's TickMath; MIN_TICK for a price under the lowest. About 21 steps.
    function tickAt(uint160 sqrtP) internal pure returns (int24 lo) {
        lo = PoolDepth.MIN_TICK;
        int24 hi = PoolDepth.MAX_TICK;
        while (lo < hi) {
            // safe cast: the midpoint of two int24 values
            // forge-lint: disable-next-line(unsafe-typecast)
            int24 mid = int24((int256(lo) + int256(hi) + 1) / 2);
            if (PoolDepth.sqrtPriceAtTick(mid) <= sqrtP) lo = mid;
            else hi = mid - 1;
        }
    }

    /// @notice `t` rounded up to a multiple of `spacing` (away from spot, towards a cheaper $PRIORS).
    function ceilTo(int24 t, int24 spacing) internal pure returns (int24) {
        int24 r = t % spacing;
        if (r == 0) return t;
        return r > 0 ? t - r + spacing : t - r;
    }

    /// @dev c x x^2 at full precision, for x < 2^160 and c < 2^64 (the result is under 2^384).
    function _scaledSquare(uint256 c, uint160 x) private pure returns (uint256 hi, uint256 lo) {
        (uint256 h, uint256 l) = _mul512(x, x);
        (uint256 h2, uint256 l2) = _mul512(l, c);
        hi = h * c + h2;
        lo = l2;
    }

    /// @dev a x b as (hi, lo).
    function _mul512(uint256 a, uint256 b) private pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }
}
