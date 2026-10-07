// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRevenueRouter
/// @notice Receives the protocol's USDG revenue and splits each arrival once between BuyAndBack (engine 2) and
///         PriorsLiquidity (engine 3) (docs/PRIORS-UNDERWRITING-SPEC.md 2A.4). Each engine's share is kept apart as
///         `owedBuy` and `owedLiq` until its transfer goes through, so a frozen engine's share waits for it and is
///         never split again.
interface IRevenueRouter {
    /// @notice USDG actually sent by one `distribute()`.
    event Distributed(uint256 toBuyAndBack, uint256 toLiquidity);
    /// @notice A new arrival split at `buyBps`.
    event Split(uint256 arrived, uint256 toBuy, uint256 toLiq, uint256 buyBps);
    /// @notice The split changed (timelock).
    event BuyBpsSet(uint256 buyBps);

    /// @notice Permissionless, at most once a day, from a balance of at least 20 USDG: split what arrived since the
    ///         last split, then send each engine its whole owed share; a failed transfer stays owed to that engine.
    function distribute() external;

    /// @notice USDG split to BuyAndBack and not yet sent.
    function owedBuy() external view returns (uint256);
    /// @notice USDG split to PriorsLiquidity and not yet sent.
    function owedLiq() external view returns (uint256);
    /// @notice BuyAndBack's share of each new arrival, in bps (2,000-8,000).
    function buyBps() external view returns (uint256);
    /// @notice When distribute() last ran.
    function lastDistributeAt() external view returns (uint64);
    /// @notice BuyAndBack (engine 2), immutable.
    function buyAndBack() external view returns (address);
    /// @notice PriorsLiquidity (engine 3), immutable.
    function liquidity() external view returns (address);
    /// @notice The 48 h timelock (`setBuyBps`), immutable.
    function timelock() external view returns (address);

    /// @notice Timelock only, within 2,000-8,000 bps.
    function setBuyBps(uint256 bps) external;
}
