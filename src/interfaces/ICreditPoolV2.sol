// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICreditPoolV2
/// @notice CreditPoolV2 (src/CreditPoolV2.sol, live at 0x2812…DE21) as SeatVaultV5 uses it, with the pool's own struct
///         layouts, field for field. Importing src/CreditPoolV2.sol instead would pull every importer into the pool's
///         via-IR compilation job (foundry.toml `compilation_restrictions`), which the build machine cannot afford.
interface ICreditPoolV2 {
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

    // roots and stake
    function enrollRoot(uint256 rootId, uint256 assets) external;
    function addStake(uint256 rootId, uint256 assets) external;
    function unlock(uint256 rootId, uint256 shares, address to) external returns (uint256 assets);
    function setHook(uint256 rootId, address h) external;
    function claimSponsorFees(uint256 sponsorId, address to) external returns (uint256 amount);
    function freeBacking(uint256 rootId) external view returns (uint256);
    function backing(uint256 rootId) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function rootShares(uint256 rootId) external view returns (uint256);

    // sponsorship
    function vouchWithConsent(
        uint256 sponsorId,
        uint256 agentId,
        uint256 amount,
        uint256 premiumBps,
        Consent calldata c,
        bytes calldata sig
    ) external;
    function vouch(uint256 sponsorId, uint256 agentId, uint256 amount) external;
    function unvouch(uint256 sponsorId, uint256 agentId, uint256 amount) external;
    function freeze(uint256 agentId, bool frozen) external;
    function setPremium(uint256 agentId, uint256 premiumBps) external;
    function consentDigest(Consent calldata c) external view returns (bytes32);
    function nonces(uint256 id) external view returns (uint256);

    // loans
    function markDefault(uint256 loanId) external;
    function importFromV1(uint256 agentId) external;
    function getAgent(uint256 id) external view returns (Agent memory);
    function getLoan(uint256 loanId) external view returns (Loan memory);
    function loanCount() external view returns (uint256);
    function getParams() external view returns (Params memory);

    // reads
    function feesFrom(uint256 sponsorId, uint256 agentId) external view returns (uint256);
    function sponsorFees(uint256 sponsorId) external view returns (uint256);
    function ownerDefaults(address owner) external view returns (uint256);
    function delegateOf(uint256 id) external view returns (address);
    function isController(uint256 id, address who) external view returns (bool);
    function pausedUntil() external view returns (uint64);
    function hook(uint256 rootId) external view returns (address);
    function usdg() external view returns (address);
    function registry() external view returns (address);
}

/// @notice The backer-hook interface CreditPoolV2 calls (src/CreditPoolV2.sol, `IBackerHook`), redeclared here for the
///         same reason as above. ABI-identical.
interface IBackerHookV2 {
    function canBorrow(
        uint256 rootId,
        uint256 agentId,
        uint256 amount,
        uint64 term,
        uint256 fee,
        address caller,
        address owner,
        address to
    ) external view returns (bool);
    function onBorrow(uint256 rootId, uint256 agentId, uint256 loanId) external;
    function onDefault(uint256 rootId, uint256 agentId, uint256 loanId, uint256 principal, bool lastLoan) external;
    function onRelease(uint256 rootId, uint256 agentId, uint256 amount, uint8 reason) external;
}
