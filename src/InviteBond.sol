// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CreditPoolV2} from "./CreditPoolV2.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";

/// Treasury v4's rules, as its public getter returns them (flat).
interface ITreasuryRules {
    function rules()
        external
        view
        returns (
            uint256 reserveBps,
            uint256 firstLine,
            uint256 secondLine,
            uint256 epochCap,
            uint64 epochLength,
            uint64 minSeasoning,
            uint256 minQualified,
            uint256 minScore,
            uint64 idleAfter
        );
}

/// @title InviteBond
/// @notice What an automatic invite costs. The invite bot signs a treasury v4 first line only for an agent whose
///         owner has locked `amount` USDG here. The bond goes back to the depositor once the agent has proven
///         itself, and to `beneficiary` if the agent defaults. With the bond equal to the first line, borrowing
///         a first line and walking away nets the borrower nothing.
///
///         Released (anyone may call, the USDG goes to the depositor) when the agent has not defaulted, has no
///         loan open, and either
///           - repaid, since the deposit, at least the treasury's `minQualified` qualified loans (the same bar the
///             treasury asks before it raises a line), or
///           - holds no line at all, `unusedAfter` seconds after the deposit (longer than any invite lives: an
///             owner the bot refused, or whose line was reclaimed, gets the bond back).
///         Releasing after one repayment would not do: bond, borrow and repay once, take the bond back, borrow
///         again and default is a net gain of one line.
///
///         Slashed (anyone may call, the USDG goes to `beneficiary`) once the pool has marked the agent defaulted.
///         A defaulted agent can never be released, and an agent past due still has its loan open, so the
///         depositor cannot take the bond back ahead of the mark.
///
///         No owner, no admin, no upgrade: every parameter is fixed at deploy. Changing the bond means deploying
///         a new InviteBond and pointing the bot at it; bonds already here keep their rules.
contract InviteBond is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Bond {
        address depositor;
        uint64 at;
        uint256 amount;
        uint256 qualifiedAt; // the agent's qualifiedRepaid when the bond was posted
    }

    CreditPoolV2 public immutable pool;
    IERC20 public immutable usdg;
    IERC8004Identity public immutable registry;
    ITreasuryRules public immutable treasury;
    address public immutable beneficiary;
    uint256 public immutable amount;
    uint64 public immutable unusedAfter;

    mapping(uint256 => Bond) internal _bonds;
    uint256[] internal _active;
    mapping(uint256 => uint256) internal _slot; // agentId => index in _active, plus one

    event Bonded(uint256 indexed agentId, address indexed depositor, uint256 amount);
    event Released(uint256 indexed agentId, address indexed depositor, uint256 amount);
    event Slashed(uint256 indexed agentId, address indexed beneficiary, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyBonded(uint256 agentId);
    error NotOwner(uint256 agentId);
    error AgentDefaulted(uint256 agentId);
    error NoBond(uint256 agentId);
    error NotReleasable(uint256 agentId);
    error NotDefaulted(uint256 agentId);

    constructor(
        CreditPoolV2 pool_,
        IERC8004Identity registry_,
        ITreasuryRules treasury_,
        address beneficiary_,
        uint256 amount_,
        uint64 unusedAfter_
    ) {
        if (
            address(pool_) == address(0) || address(registry_) == address(0) || address(treasury_) == address(0)
                || beneficiary_ == address(0)
        ) revert ZeroAddress();
        if (amount_ == 0 || unusedAfter_ == 0) revert ZeroAmount();
        pool = pool_;
        usdg = pool_.usdg();
        registry = registry_;
        treasury = treasury_;
        beneficiary = beneficiary_;
        amount = amount_;
        unusedAfter = unusedAfter_;
    }

    /// @notice Lock `amount` USDG behind agent `agentId`. Only the agent's owner, once per agent at a time, and
    ///         never for an agent that has defaulted. Needs `amount` of USDG approved to this contract.
    function deposit(uint256 agentId) external nonReentrant {
        if (_bonds[agentId].depositor != address(0)) revert AlreadyBonded(agentId);
        if (registry.ownerOf(agentId) != msg.sender) revert NotOwner(agentId);
        CreditPoolV2.Agent memory a = pool.getAgent(agentId);
        if (a.defaulted) revert AgentDefaulted(agentId);
        _bonds[agentId] =
            Bond({depositor: msg.sender, at: uint64(block.timestamp), amount: amount, qualifiedAt: a.qualifiedRepaid});
        _active.push(agentId);
        _slot[agentId] = _active.length;
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        emit Bonded(agentId, msg.sender, amount);
    }

    /// @notice Return the bond to its depositor, once `releasable` says so. Anyone may call.
    function release(uint256 agentId) external nonReentrant {
        Bond memory b = _bonds[agentId];
        if (b.depositor == address(0)) revert NoBond(agentId);
        if (!_releasable(agentId, b)) revert NotReleasable(agentId);
        _close(agentId);
        usdg.safeTransfer(b.depositor, b.amount);
        emit Released(agentId, b.depositor, b.amount);
    }

    /// @notice Send the bond of a defaulted agent to `beneficiary`. Anyone may call.
    function slash(uint256 agentId) external nonReentrant {
        Bond memory b = _bonds[agentId];
        if (b.depositor == address(0)) revert NoBond(agentId);
        if (!pool.getAgent(agentId).defaulted) revert NotDefaulted(agentId);
        _close(agentId);
        usdg.safeTransfer(beneficiary, b.amount);
        emit Slashed(agentId, beneficiary, b.amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function bonds(uint256 agentId) external view returns (Bond memory) {
        return _bonds[agentId];
    }

    function isBonded(uint256 agentId) external view returns (bool) {
        return _bonds[agentId].depositor != address(0);
    }

    function releasable(uint256 agentId) external view returns (bool) {
        Bond memory b = _bonds[agentId];
        return b.depositor != address(0) && _releasable(agentId, b);
    }

    function slashable(uint256 agentId) external view returns (bool) {
        return _bonds[agentId].depositor != address(0) && pool.getAgent(agentId).defaulted;
    }

    /// @notice When the no-line release opens for `agentId` (0 without a bond). It still needs no line and no loan.
    function unusedReleaseAt(uint256 agentId) external view returns (uint256) {
        Bond memory b = _bonds[agentId];
        return b.depositor == address(0) ? 0 : uint256(b.at) + unusedAfter;
    }

    /// @notice Qualified repayments since the deposit, and how many release the bond.
    function progress(uint256 agentId) external view returns (uint256 repaid, uint256 needed) {
        Bond memory b = _bonds[agentId];
        if (b.depositor == address(0)) return (0, _needed());
        return (pool.getAgent(agentId).qualifiedRepaid - b.qualifiedAt, _needed());
    }

    function activeCount() external view returns (uint256) {
        return _active.length;
    }

    /// @notice Agents with a bond, `count` of them from index `start` (order changes as bonds close).
    function activeIds(uint256 start, uint256 count) external view returns (uint256[] memory ids) {
        uint256 n = _active.length;
        if (start >= n) return new uint256[](0);
        uint256 end = start + count > n ? n : start + count;
        ids = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            ids[i - start] = _active[i];
        }
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _needed() internal view returns (uint256 n) {
        (,,,,,, n,,) = treasury.rules();
        if (n == 0) n = 1;
    }

    function _releasable(uint256 agentId, Bond memory b) internal view returns (bool) {
        CreditPoolV2.Agent memory a = pool.getAgent(agentId);
        if (a.defaulted || a.activeLoans != 0) return false;
        if (a.qualifiedRepaid >= b.qualifiedAt + _needed()) return true;
        return a.delegatedIn == 0 && block.timestamp >= uint256(b.at) + unusedAfter;
    }

    function _close(uint256 agentId) internal {
        delete _bonds[agentId];
        uint256 slot = _slot[agentId];
        uint256 last = _active[_active.length - 1];
        _active[slot - 1] = last;
        _slot[last] = slot;
        _active.pop();
        delete _slot[agentId];
    }
}
