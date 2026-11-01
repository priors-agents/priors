// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BoardFeeSplitter
/// @notice The board's fee recipient: `feeTo` on AgentMarket and AgentMarketV2, and so AgentLease's, which reads V2's.
///         Every fee the board takes in USDG lands here and leaves by `split()` only, to two places: the engines (the
///         RevenueRouter, which splits whatever arrives between BuyAndBack and PriorsLiquidity) take `engineBps` of it,
///         and the treasury (treasury v5, which backs new agents' first lines) takes the rest
///         (docs/research/2026-10-28-board-token-mechanics/MECHANICS.md section 6.6). Anyone may call `split()`.
///
///         The split and the two addresses change only through a queue: the owner (the Safe) queues a change and
///         applies it 48 hours later, as the markets' own fee. Nothing else moves USDG: another token sent here by
///         mistake is sent on by the owner (`rescue`), never USDG. Not upgradeable.
contract BoardFeeSplitter is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice The wait between queueing a change of the settings and applying it.
    uint64 public constant DELAY = 48 hours;

    IERC20 public immutable usdg;

    /// @notice The RevenueRouter: the engines' side of each split.
    address public engines;
    /// @notice Treasury v5: the other side.
    address public treasury;
    /// @notice The engines' share of each split, in basis points; the treasury takes the rest.
    uint256 public engineBps;

    struct PendingSettings {
        address engines;
        address treasury;
        uint256 engineBps;
        uint64 readyAt;
    }

    /// @notice A queued change of the settings (`readyAt` 0: none).
    PendingSettings public pendingSettings;

    /// @notice USDG sent to each side, all splits together.
    uint256 public totalToEngines;
    uint256 public totalToTreasury;

    event Split(address indexed caller, uint256 toEngines, uint256 toTreasury);
    event SettingsQueued(address engines, address treasury, uint256 engineBps, uint64 readyAt);
    event SettingsApplied(address engines, address treasury, uint256 engineBps);
    event SettingsCancelled();
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error BadAddress(address account);
    error BadBps(uint256 engineBps);
    error NoPendingSettings();
    error SettingsNotReady(uint64 readyAt);
    error RescueUsdg();

    /// @param usdg_ USDG
    /// @param engines_ the RevenueRouter
    /// @param treasury_ treasury v5
    /// @param engineBps_ the engines' share, 0 to 10,000 (5,000: half and half, the owner's decision of 2026-10-29)
    /// @param owner_ the Safe
    constructor(IERC20 usdg_, address engines_, address treasury_, uint256 engineBps_, address owner_) Ownable(owner_) {
        if (address(usdg_) == address(0)) revert ZeroAddress();
        _checkSettings(engines_, treasury_, engineBps_);
        usdg = usdg_;
        engines = engines_;
        treasury = treasury_;
        engineBps = engineBps_;
        emit SettingsApplied(engines_, treasury_, engineBps_);
    }

    /// @notice Send the whole USDG balance on: `engineBps` of it to the engines, the rest to the treasury. Anyone may
    ///         call it; with nothing here it sends nothing.
    function split() external returns (uint256 toEngines, uint256 toTreasury) {
        uint256 balance = usdg.balanceOf(address(this));
        toEngines = (balance * engineBps) / BPS;
        toTreasury = balance - toEngines;
        if (toEngines > 0) usdg.safeTransfer(engines, toEngines);
        if (toTreasury > 0) usdg.safeTransfer(treasury, toTreasury);
        totalToEngines += toEngines;
        totalToTreasury += toTreasury;
        emit Split(msg.sender, toEngines, toTreasury);
    }

    /// @notice What `split()` would send to each side now.
    function splittable() external view returns (uint256 toEngines, uint256 toTreasury) {
        uint256 balance = usdg.balanceOf(address(this));
        toEngines = (balance * engineBps) / BPS;
        toTreasury = balance - toEngines;
    }

    /// @notice Queue new settings, applicable 48 hours from now. Replaces a change already queued, with a new 48 hours.
    function queueSettings(address engines_, address treasury_, uint256 engineBps_) external onlyOwner {
        _checkSettings(engines_, treasury_, engineBps_);
        // safe cast: a timestamp plus 48 h
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 readyAt = uint64(block.timestamp) + DELAY;
        pendingSettings =
            PendingSettings({engines: engines_, treasury: treasury_, engineBps: engineBps_, readyAt: readyAt});
        emit SettingsQueued(engines_, treasury_, engineBps_, readyAt);
    }

    /// @notice Apply the queued settings, once their 48 hours have passed.
    function applySettings() external onlyOwner {
        PendingSettings memory p = pendingSettings;
        if (p.readyAt == 0) revert NoPendingSettings();
        if (block.timestamp < p.readyAt) revert SettingsNotReady(p.readyAt);
        delete pendingSettings;
        engines = p.engines;
        treasury = p.treasury;
        engineBps = p.engineBps;
        emit SettingsApplied(p.engines, p.treasury, p.engineBps);
    }

    /// @notice Drop the queued settings.
    function cancelSettings() external onlyOwner {
        if (pendingSettings.readyAt == 0) revert NoPendingSettings();
        delete pendingSettings;
        emit SettingsCancelled();
    }

    /// @notice Send on another token sent here by mistake. Never USDG: USDG leaves by `split()` only.
    function rescue(IERC20 token, address to) external onlyOwner {
        if (address(token) == address(usdg)) revert RescueUsdg();
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(to, amount);
        emit Rescued(address(token), to, amount);
    }

    function _checkSettings(address engines_, address treasury_, uint256 engineBps_) internal view {
        if (engines_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (engines_ == address(this)) revert BadAddress(engines_);
        if (treasury_ == address(this)) revert BadAddress(treasury_);
        if (engineBps_ > BPS) revert BadBps(engineBps_);
    }
}
