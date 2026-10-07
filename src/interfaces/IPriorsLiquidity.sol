// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPriorsLiquidity
/// @notice Engine 3, protocol-owned liquidity as USDG-only ranges wholly below spot (docs/PRIORS-UNDERWRITING-SPEC.md,
///         2A.3; section 12, PL-*). No function decreases liquidity or moves USDG or $PRIORS out. SeatVaultV5 never
///         calls it; `run()` reads V5's `depthGuardOn()` and the SwapLimiter's views.
interface IPriorsLiquidity {
    /// @notice Permissionless: spends min(balance, allowance) (at least $5) on one USDG-only range below spot, never
    ///         swapping; refuses under the depth guard, a SeatSizer `lastObsAt` over 45 min, fewer than 24
    ///         observations or a snapshot over 2 h old; adds nothing when spot is at or under the range's top.
    function run() external;

    function totalUsdgAdded() external view returns (uint256);
    /// @notice USDG `run()` may spend now: accrues `maxPerRun` a day, capped at `maxPerRun`.
    function allowance() external view returns (uint256);
    function maxPerRun() external view returns (uint256);
    function offsetTicks() external view returns (uint24);
    function widthTicks() external view returns (uint24);
    function gap() external view returns (uint64);

    function timelock() external view returns (address);
    function swapLimiter() external view returns (address);
    function v5() external view returns (address);

    /// @notice Timelock only, within bounds that keep every range below spot (offset at least one tick spacing).
    function setLadder(uint24 offsetTicks, uint24 widthTicks) external;
    function setMaxPerRun(uint256 usdg) external;
    function setGap(uint64 gap) external;
    /// @notice Timelock only: tokens sent here by mistake; never USDG, $PRIORS or a position.
    function rescue(address token, address to) external;
}
