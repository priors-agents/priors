// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev CreditPoolV2 as the IncomeRouter tests use it, with the pool's own layouts (test/autopay2/IPoolV2.sol, with the
///      backer's freeze and hook, and the guardian's pause). The tests deploy the pool from its artifact (deployCode)
///      and talk to it through this interface instead of importing src/CreditPoolV2.sol: an importer is compiled in
///      the pool's via-IR job (foundry.toml compilation_restrictions), and that job is already near the build
///      machine's memory.
interface IPoolV2 {
    enum LoanStatus {
        None,
        Active,
        Repaid,
        Defaulted
    }

    struct Agent {
        bool enrolled;
        bool isRoot;
        bool defaulted;
        bool frozen;
        bool importedFromV1;
        uint64 enrolledAt;
        uint64 lastBorrowAt;
        uint64 lastRepayAt;
        uint256 sponsor;
        uint256 delegatedIn;
        uint256 delegatedOut;
        uint256 principalOut;
        uint256 activeLoans;
        uint256 premiumBps;
        uint256 premiumCap;
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    struct Loan {
        uint256 agentId;
        uint256 sponsorId;
        uint256 principal;
        uint256 fee;
        uint256 sponsorCut;
        uint256 reserveCut;
        uint256 premium;
        address owner;
        uint64 issuedAt;
        uint64 dueAt;
        uint64 defaultableAt;
        uint64 minScoreTerm;
        uint64 closedAt;
        LoanStatus status;
    }

    struct Params {
        uint256 minLoan;
        uint256 maxLoan;
        uint64 minTerm;
        uint64 maxTerm;
        uint64 grace;
        uint64 minScoreTerm;
        uint256 feeBps;
        uint256 sponsorFeeBps;
        uint256 protocolFeeBps;
        uint256 minStake;
        uint256 maxUtilizationBps;
        uint256 keeperBounty;
    }

    struct Consent {
        uint256 agentId;
        uint256 sponsorId;
        address owner;
        uint256 maxPremiumBps;
        uint256 nonce;
        uint256 deadline;
    }

    event Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer);
    event HookFailed(uint256 indexed rootId, bytes4 selector);

    function usdg() external view returns (address);
    function registry() external view returns (address);
    function seed() external;
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256);
    function enrollRoot(uint256 rootId, uint256 assets) external;
    function setHook(uint256 rootId, address h) external;
    function hook(uint256 rootId) external view returns (address);
    function freeze(uint256 agentId, bool frozen_) external;
    function pause() external;
    function unpause() external;
    function pausedUntil() external view returns (uint64);
    function nonces(uint256 id) external view returns (uint256);
    function consentDigest(Consent calldata c) external view returns (bytes32);
    function vouchWithConsent(
        uint256 sponsorId,
        uint256 agentId,
        uint256 amount,
        uint256 premiumBps,
        Consent calldata c,
        bytes calldata sig
    ) external;
    function setDelegate(uint256 id, address delegate) external;
    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        returns (uint256 loanId);
    function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue) external;
    function markDefault(uint256 loanId) external;
    function getLoan(uint256 loanId) external view returns (Loan memory);
    function getAgent(uint256 id) external view returns (Agent memory);
    function loanCount() external view returns (uint256);
    function loansOf(uint256 id) external view returns (uint256[] memory);
    function getParams() external view returns (Params memory);
}
