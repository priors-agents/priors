// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBuyAndBack
/// @notice Engine 2 (docs/PRIORS-UNDERWRITING-SPEC.md, 2A.2; section 8's BuyAndBack row; section 12, BB-*). Built
///         separately; this is the surface SeatVaultV5 and the deploy checks are built against.
///
///         What V5 relies on, and nothing more:
///           - V5 never calls into BuyAndBack. It sends C's fees (USDG, `flush()`) and every return of C ($PRIORS:
///             `releaseFor`, `claimSettled`) as plain token transfers (review A-F2).
///           - BuyAndBack calls V5's `back(id, amount, false)` to place C (no 1,000 $PRIORS minimum, allowed while
///             `openBacking` is off, held by V5 to min(A/6 − C, A − B − C, A/8 a week) and to the placement rule),
///             `leave(id, amount, 1)` (mode 1 only), `fillExit` and `returnExit` (ISeatVaultV5Engine), and reads
///             `epochOf`, the points, the price cache and the guards through V5's views.
///           - V5 takes BuyAndBack's address at construction; BuyAndBack takes V5's once, through the timelock, and
///             refuses an address whose `buyAndBack()` is not itself or whose `timelock()` differs.
interface IBuyAndBack {
    /// @notice Permissionless (the keeper's 30-minute pass): internal fills of queued USDG exits first, then at most
    ///         one pool buy (2A.2 steps 1–10).
    function buy() external;

    /// @notice Permissionless: place this book's share of the epoch's allotment as C, through V5's `back`.
    function place(uint256 id) external;

    /// @notice Timelock only: burn part of the free balance (for example when V5 is retired).
    function burnFree(uint256 amount) external;

    /// @notice Timelock only, once: V5's address (2A.2).
    function setV5(address v5) external;

    /// @notice $PRIORS held and not placed behind a book.
    function freeBalance() external view returns (uint256);

    function v5() external view returns (address);
    function timelock() external view returns (address);
    function guardian() external view returns (address);
    function swapLimiter() external view returns (address);
}
