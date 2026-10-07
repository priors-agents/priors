// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The piece of a Uniswap v4 PoolManager the limiter reads: raw storage.
interface IExtsload {
    /// @notice One word of the PoolManager's storage.
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title PoolDepth
/// @notice Reads a Uniswap v4 pool's state straight from the PoolManager's storage and measures its real depth over a
///         price band, walking its initialized ticks exactly as a v4 swap would cross them (LP fee 0, no hook delta).
///         Used by SwapLimiter's `snapDepth()` only (docs/PRIORS-UNDERWRITING-SPEC.md 2A.5, the band depth).
///
///         Storage layout (v4-core `PoolManager`): `pools` is the mapping at slot 6; a pool's `State` holds `slot0` at
///         +0 (sqrtPriceX96 in bits 0-159, tick in bits 160-183), `liquidity` at +3 (low 128 bits), `ticks` at +4
///         (mapping int24 => Info, whose first word is liquidityGross in its low 128 bits and liquidityNet in its high
///         128) and `tickBitmap` at +5 (mapping int16 => uint256). sim/spec-rev5/chain.mjs reads the same slots.
///
///         Every amount rounds down: a depth is only ever under-counted.
library PoolDepth {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    uint256 internal constant Q96 = 1 << 96;

    error TickOutOfRange(int24 tick);

    /// @notice A pool's view of the PoolManager: where its state lives.
    struct Pool {
        IExtsload manager;
        bytes32 stateSlot; // keccak256(abi.encode(poolId, 6))
        int24 tickSpacing;
    }

    /// @notice The state slot of `poolId` in a v4 PoolManager.
    function stateSlotOf(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, uint256(6)));
    }

    /// @notice slot0's price and tick.
    function slot0(Pool memory p) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        uint256 w = uint256(p.manager.extsload(p.stateSlot));
        // safe cast: v4 packs slot0's price in the low 160 bits
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(w);
        // safe cast: v4 packs slot0's int24 tick in bits 160-183
        // forge-lint: disable-next-line(unsafe-typecast)
        tick = int24(int256(w >> 160));
    }

    /// @notice The pool's active liquidity.
    function liquidity(Pool memory p) internal view returns (uint128) {
        return uint128(uint256(p.manager.extsload(bytes32(uint256(p.stateSlot) + 3))));
    }

    /// @notice USDG (currency0) the pool pays out to a sale that takes the price from `sqrtPriceX96` up to `sqrtEnd`
    ///         (a cheaper $PRIORS), crossing initialized ticks upward.
    function amount0Up(Pool memory p, uint160 sqrtPriceX96, int24 tick, uint128 liq, uint160 sqrtEnd)
        internal
        view
        returns (uint256 total)
    {
        uint160 cur = sqrtPriceX96;
        uint256 l = liq;
        while (cur < sqrtEnd) {
            (int24 next, bool initialized) = _nextUp(p, tick);
            if (next > MAX_TICK) next = MAX_TICK;
            uint160 sqrtNext = sqrtPriceAtTick(next);
            uint160 target = sqrtNext < sqrtEnd ? sqrtNext : sqrtEnd;
            total += amount0(cur, target, l);
            if (target == sqrtEnd || next == MAX_TICK) break;
            if (initialized) l = _addNet(l, _net(p, next));
            cur = sqrtNext;
            tick = next;
        }
    }

    /// @notice USDG (currency0) a buy must pay to take the price from `sqrtPriceX96` down to `sqrtEnd` (a dearer
    ///         $PRIORS), crossing initialized ticks downward.
    function amount0Down(Pool memory p, uint160 sqrtPriceX96, int24 tick, uint128 liq, uint160 sqrtEnd)
        internal
        view
        returns (uint256 total)
    {
        uint160 cur = sqrtPriceX96;
        uint256 l = liq;
        while (cur > sqrtEnd) {
            (int24 next, bool initialized) = _nextDown(p, tick);
            if (next < MIN_TICK) next = MIN_TICK;
            uint160 sqrtNext = sqrtPriceAtTick(next);
            uint160 target = sqrtNext > sqrtEnd ? sqrtNext : sqrtEnd;
            total += amount0(target, cur, l);
            if (target == sqrtEnd || next == MIN_TICK) break;
            if (initialized) l = _addNet(l, -int256(_net(p, next)));
            cur = sqrtNext;
            tick = next - 1;
        }
    }

    /// @notice currency0 held by liquidity `liq` between `sqrtA` <= `sqrtB` (v4 SqrtPriceMath.getAmount0Delta,
    ///         rounded down): liq * 2^96 * (sqrtB - sqrtA) / sqrtB / sqrtA.
    function amount0(uint160 sqrtA, uint160 sqrtB, uint256 liq) internal pure returns (uint256) {
        if (sqrtA >= sqrtB || liq == 0) return 0;
        return Math.mulDiv(liq << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    /// @notice sqrt(1.0001^tick) * 2^96 (v4-core TickMath.getSqrtPriceAtTick: the same constants and rounding).
    function sqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            // safe cast: abs of an int24 fits; checked against MAX_TICK next
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            // safe cast: MAX_TICK is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange(tick);
            uint256 price =
                absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) price = type(uint256).max / price;
            // round up to a Q64.96 (from Q128.128)
            sqrtPriceX96 = uint160((price >> 32) + (price % (1 << 32) == 0 ? 0 : 1));
        }
    }

    // ------------------------------------------------------------------
    // Ticks and the bitmap
    // ------------------------------------------------------------------

    /// @dev The next initialized tick strictly above `tick` within its bitmap word, or the word's last tick
    ///      (v4-core TickBitmap.nextInitializedTickWithinOneWord, lte = false).
    function _nextUp(Pool memory p, int24 tick) private view returns (int24 next, bool initialized) {
        int24 compressed = _compress(tick, p.tickSpacing) + 1;
        (int16 wordPos, uint8 bitPos) = _position(compressed);
        uint256 masked = _word(p, wordPos) & ~((uint256(1) << bitPos) - 1);
        initialized = masked != 0;
        int24 offset = initialized ? int24(uint24(_lsb(masked) - bitPos)) : int24(uint24(type(uint8).max - bitPos));
        next = (compressed + offset) * p.tickSpacing;
    }

    /// @dev The next initialized tick at or below `tick` within its bitmap word, or the word's first tick
    ///      (v4-core TickBitmap.nextInitializedTickWithinOneWord, lte = true).
    function _nextDown(Pool memory p, int24 tick) private view returns (int24 next, bool initialized) {
        int24 compressed = _compress(tick, p.tickSpacing);
        (int16 wordPos, uint8 bitPos) = _position(compressed);
        uint256 mask = (uint256(1) << bitPos) - 1 + (uint256(1) << bitPos);
        uint256 masked = _word(p, wordPos) & mask;
        initialized = masked != 0;
        int24 offset = initialized ? int24(uint24(bitPos - _msb(masked))) : int24(uint24(bitPos));
        next = (compressed - offset) * p.tickSpacing;
    }

    /// @dev A tick divided by the spacing, rounded towards negative infinity.
    function _compress(int24 tick, int24 spacing) private pure returns (int24 c) {
        c = tick / spacing;
        if (tick < 0 && tick % spacing != 0) c--; // round towards negative infinity
    }

    /// @dev The bitmap word and bit of a compressed tick.
    function _position(int24 compressed) private pure returns (int16 wordPos, uint8 bitPos) {
        // safe cast: an int24 compressed tick >> 8 fits int16
        // forge-lint: disable-next-line(unsafe-typecast)
        wordPos = int16(compressed >> 8);
        // safe cast: the low 8 bits of the compressed tick
        // forge-lint: disable-next-line(unsafe-typecast)
        bitPos = uint8(uint24(compressed) & 0xff);
    }

    /// @dev One word of the pool's tick bitmap.
    function _word(Pool memory p, int16 wordPos) private view returns (uint256) {
        bytes32 key = keccak256(abi.encode(wordPos, uint256(p.stateSlot) + 5));
        return uint256(p.manager.extsload(key));
    }

    /// @dev An initialized tick's liquidityNet.
    function _net(Pool memory p, int24 tick) private view returns (int128) {
        bytes32 key = keccak256(abi.encode(tick, uint256(p.stateSlot) + 4));
        return int128(int256(uint256(p.manager.extsload(key))) >> 128);
    }

    /// @dev Liquidity after crossing a tick; a negative result (impossible in a consistent pool) counts as zero, so
    ///      bad data can only lower a depth.
    function _addNet(uint256 l, int256 net) private pure returns (uint256) {
        // safe cast: log2 of a non-zero uint256 is under 256
        // forge-lint: disable-next-line(unsafe-typecast)
        if (net >= 0) return l + uint256(net);
        // safe cast: log2 of a non-zero uint256 is under 256
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 sub = uint256(-net);
        return sub >= l ? 0 : l - sub;
    }

    /// @dev The most significant set bit of a non-zero word.
    function _msb(uint256 x) private pure returns (uint8) {
        return uint8(Math.log2(x));
    }

    /// @dev The least significant set bit of a non-zero word.
    function _lsb(uint256 x) private pure returns (uint8) {
        unchecked {
            return uint8(Math.log2(x & (~x + 1)));
        }
    }
}
