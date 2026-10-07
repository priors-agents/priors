// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISwapLimiter
/// @notice The one limiter every swap the protocol starts goes through first (docs/PRIORS-UNDERWRITING-SPEC.md 2A.5,
///         section 8's SwapLimiter row, section 12 SL-LIMITS): at most one protocol swap per L2 block, a rolling hourly
///         total under the live cap, and the depth views the depth guard reads (2.8).
///
///         Units: every USDG amount is raw (6 decimals); fees in bps; ages in seconds; every price is the
///         USDG (currency0) / $PRIORS (currency1) pool's sqrtPriceX96, so a higher value is a cheaper $PRIORS.
///
///         Definitions (2A.5):
///           f_live     = the hook's `hookFeeBps()` + the creator tax (word 7 of `launches(poolId)`), bounded reads;
///           D          = min(L, L_band) x 2^96 / sqrtPriceX96, rounded down, with L = min(L_live, L_snap) (live) or
///                        L_snap (median form), L_snap the lowest active liquidity of the last 2 h (8 slots of 15
///                        minutes, each the lowest written in its period), and L_band the band depth as a full-range
///                        liquidity: min(lowest bandDown / (1 - sqrt(0.7)), lowest bandUp / (sqrt(1/0.7) - 1)) x
///                        sqrtP_snap / 2^96 (docs/PROTOCOL-BUILD.md, D3);
///           live cap   = min(ceiling, 0.9 x D x (1/(1 - f_live) - 1)), rounded down;
///           depth term = 0.9 x D x (1/(1 - f) - 1) before the ceiling, f clamped to 200-300 bps (question 36).
///
///         Names follow the interface SeatVaultV5 is built against (its worktree's src/interfaces/ISwapLimiter.sol);
///         `snapshot`, `windowTotal`, `keeper`, `buyAndBack` and `v5` are additions.
interface ISwapLimiter {
    /// @notice A protocol swap of `usdg` was allowed by `caller`; `windowTotal` includes it.
    event Consumed(address indexed caller, uint256 usdg, uint256 windowTotal, uint256 liveCap, uint256 arbBlock);
    /// @notice A depth snapshot: the pool's active liquidity, and the real USDG a 30% move each way trades against.
    event DepthSnapped(
        uint64 indexed period, uint128 liquidity, uint256 bandDown, uint256 bandUp, uint160 sqrtPriceX96, address by
    );
    /// @notice The live cap's ceiling changed (timelock).
    event CeilingSet(uint256 ceiling);
    /// @notice The fee ceiling above which protocol swaps revert changed (timelock).
    event ExpectedFeeBpsSet(uint256 feeBps);
    /// @notice The keeper allowed to snapDepth changed (timelock).
    event KeeperSet(address indexed keeper);
    /// @notice BuyAndBack was named as a caller, once (timelock).
    event BuyAndBackSet(address indexed buyAndBack);
    /// @notice SeatVaultV5 was named as a caller, once (timelock).
    event V5Set(address indexed v5);

    /// @notice Account one protocol swap of `usdg` before it is sent. Callable only by BuyAndBack and SeatVaultV5,
    ///         each set once through the timelock. Reverts when: a protocol swap was already consumed in this L2 block
    ///         (`ArbSys(0x64).arbBlockNumber()`); the rolling hourly total would exceed the live cap; the latest
    ///         snapshot is over 2 h old; f_live is above `expectedFeeBps()`; a fee read fails; the limiter is paused.
    function consume(uint256 usdg) external;

    /// @notice Record the pool's active liquidity L and the band depths (`bandDown`, `bandUp`, walking the initialized
    ///         ticks over a 30% move each way) into the current 15-minute slot, keeping the lowest. The keeper helper
    ///         or the Safe only.
    function snapDepth() external;

    /// @notice The depth guard's reading (2.8). `medianForm` true: D from L_snap and the band depth valued at
    ///         `sqrtMedianX96` (no L_live, no spot), the only form `sync()` decides lasting state on. `medianForm`
    ///         false (the live form): D from min(L_live, L_snap) and the band depth, valued at the lower price of live
    ///         spot and `sqrtMedianX96` (the larger sqrtPriceX96). `term` is the depth term (f clamped to 200-300 bps);
    ///         `snapshotAge` is now minus the latest snapshot (type(uint256).max if none); `ok` is false when a hook
    ///         read fails, no snapshot is in the 2 h window, or a price is zero. Never reverts on the hook's reply; its
    ///         only revert is `ReadStarved`, when the caller left less gas than the reads' budget.
    function depthTerm(uint160 sqrtMedianX96, bool medianForm)
        external
        view
        returns (uint256 term, uint256 snapshotAge, bool ok);

    /// @notice D at the live price, for the chunks (0.35% of D) and the daily sell budget (1% of D). `ok` false when no
    ///         snapshot is in the window, the latest is over 2 h old, a fee read fails or the price is zero.
    function liveDepth() external view returns (uint256 depthUsdg, bool ok);

    /// @notice The live cap at f_live. `ok` false as for `liveDepth`, or when f_live is above `expectedFeeBps()`.
    function liveCap() external view returns (uint256 cap, bool ok);

    /// @notice f_live, by bounded reads. `ok` false when a read fails or the total is 10,000 bps or more.
    function liveFeeBps() external view returns (uint256 feeBps, bool ok);

    /// @notice What `consume` would accept now: the live cap less the rolling total, and 0 whenever `consume` would
    ///         refuse any amount (paused, a protocol swap already in this L2 block, the fee unreadable or above the
    ///         ceiling, a stale snapshot).
    function hourRemaining() external view returns (uint256);

    /// @notice True if a protocol swap was already consumed in the current L2 block (or ArbSys cannot be read).
    function swappedThisBlock() external view returns (bool);

    /// @notice When the latest snapshot was written (0: never).
    function lastSnapshotAt() external view returns (uint64);

    /// @notice The lowest liquidity and band liquidities of the window, the latest snapshot's age, and whether any
    ///         snapshot is in the window.
    function snapshot() external view returns (uint128 lSnap, uint128 lBandDown, uint128 lBandUp, uint256 age, bool ok);

    /// @notice The rolling total consumed in the current window (at least the last hour: 60 to 65 minutes).
    function windowTotal() external view returns (uint256);

    /// @notice The live cap's timelocked ceiling, raw USDG.
    function ceiling() external view returns (uint256);
    /// @notice The fee ceiling (400 bps at launch): above it every protocol swap reverts.
    function expectedFeeBps() external view returns (uint256);
    /// @notice The keeper helper, which may snapDepth.
    function keeper() external view returns (address);
    /// @notice BuyAndBack, a consume caller (zero until set).
    function buyAndBack() external view returns (address);
    /// @notice SeatVaultV5, a consume caller (zero until set).
    function v5() external view returns (address);
    /// @notice The 48 h timelock: every setting.
    function timelock() external view returns (address);

    /// @notice The live cap's ceiling (timelock). 0 stops every protocol swap until raised.
    function setCeiling(uint256 ceiling) external;
    /// @notice The fee ceiling (timelock), under 10,000 bps.
    function setExpectedFeeBps(uint256 bps) external;
    /// @notice BuyAndBack's address, once (timelock).
    function setBuyAndBack(address buyAndBack) external;
    /// @notice SeatVaultV5's address, once (timelock).
    function setV5(address v5) external;
}
