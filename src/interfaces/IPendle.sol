// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The few Pendle V2 reads the PT-USDG price feed and its deploy script make, as the contracts on Robinhood
///         Chain answer them (read on 2026-10-02: PT 0x6982…66ef, SY 0x8d31…C286, YT 0xF35E…f615, market 0xc2b8…5f4c).
interface IPPrincipalToken {
    function SY() external view returns (address);
    function YT() external view returns (address);
    function expiry() external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IStandardizedYield {
    /// @dev SY to its asset (USDG), 1e18 = 1:1.
    function exchangeRate() external view returns (uint256);
    function paused() external view returns (bool);
}

interface IPYieldToken {
    /// @dev The high-water mark of the SY's exchange rate (Pendle's PY index): a PT redeems for
    ///      exchangeRate / max(exchangeRate, pyIndexStored) of the asset.
    function pyIndexStored() external view returns (uint256);
}

interface IPMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256);
}
