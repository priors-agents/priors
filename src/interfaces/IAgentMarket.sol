// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICreditPoolV2} from "./ICreditPoolV2.sol";

/// @title IAgentMarket
/// @notice AgentMarket (src/AgentMarket.sol) as the listings index, Go mode and the MCP call it. Its calls and
///         events are the ones sdk/market-abi.mjs fixes (docs/research/2026-10-23-hub-status/HUB-V1-SPEC.md 4.1); a
///         change here is a change to that seam first.
interface IAgentMarket {
    /// @notice A standing listing. `seller` is zero for none. `nonce` is the agent's listing count at `list`;
    ///         `uriHash` (keccak256 of the token URI) and `loansRepaid` (the pool's) are the pins taken then.
    struct Listing {
        address seller;
        uint256 price;
        uint64 expiry;
        uint256 nonce;
        bytes32 uriHash;
        uint256 loansRepaid;
    }

    event Listed(
        uint256 indexed agentId, address indexed seller, uint256 price, uint64 expiry, bytes32 uriHash, uint256 nonce
    );
    event Cancelled(uint256 indexed agentId, address indexed by, uint256 nonce);
    event Sold(
        uint256 indexed agentId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 fee,
        bytes32 recordHash,
        uint256 nonce
    );
    event FeeQueued(uint256 bps, uint256 minFee, address feeTo, uint64 readyAt);
    event FeeApplied(uint256 bps, uint256 minFee, address feeTo);
    event FeeCancelled();
    event RefusedSet(address indexed account, bool refused);
    event FollowsLineSet(uint256 indexed root, bool follows);

    /// @notice List agent `id` at `price` USDG units until `expiry`. The caller owns it and approved the market for
    ///         this one agent.
    function list(uint256 id, uint256 price, uint64 expiry) external;
    /// @notice Drop the listing of `id`: the seller, or anyone once the owner changed or the listing expired.
    function cancel(uint256 id) external;
    /// @notice Buy agent `id`, paying the listed price from the caller's USDG, with the pins the caller read.
    function buy(uint256 id, uint256 maxPrice, uint256 nonce, bytes32 uriHash, bytes32 recordHash) external;
    /// @notice keccak256(abi.encode(id, loansRepaid, volumeRepaid, qualifiedRepaid, defaulted, sponsor, delegatedIn))
    ///         from pool v2, now: the record and the line the buyer gets.
    function recordHash(uint256 id) external view returns (bytes32);
    /// @notice The standing listing of `id` (seller zero for none).
    function listingOf(uint256 id) external view returns (Listing memory listing);

    function queueFee(uint256 bps, uint256 minFee, address feeTo) external;
    function applyFee() external;
    function cancelFee() external;
    function setRefused(address account, bool refused) external;
    /// @notice Whether lines sponsored by root `root` follow their agents to a buyer (the treasury's). The timelock only.
    function setFollowsLine(uint256 root, bool follows) external;

    function feeBps() external view returns (uint256);
    function minFee() external view returns (uint256);
    function feeTo() external view returns (address);
    function pendingFee() external view returns (uint256 bps, uint256 minFee, address feeTo, uint64 readyAt);
    function lastSoldAt(uint256 id) external view returns (uint64);
    function refused(address account) external view returns (bool);
    function followsLine(uint256 root) external view returns (bool);
}

/// @notice The ERC-8004 identity registry, the parts the market uses: an ERC-721 with a token URI.
interface IMarketRegistry {
    function ownerOf(uint256 id) external view returns (address);
    function getApproved(uint256 id) external view returns (address);
    function tokenURI(uint256 id) external view returns (string memory);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @notice CreditPoolV2 (src/CreditPoolV2.sol) as the market reads it: the agent (its struct from ICreditPoolV2,
///         field for field), the marks that follow an owner (`ownerDefaults`, :185) and the custodians (`custodian`,
///         :186). Read through an interface so the market stays out of the pool's via-IR build.
interface IMarketPoolV2 {
    function getAgent(uint256 id) external view returns (ICreditPoolV2.Agent memory);
    function ownerDefaults(address owner) external view returns (uint256);
    function custodian(address who) external view returns (bool);
}

/// @notice CreditPool v1 (src/CreditPool.sol, retired) as the market reads it. `Agent` is v1's struct, field for field.
interface IMarketPoolV1 {
    struct Agent {
        bool enrolled;
        bool isRoot;
        bool defaulted;
        uint64 enrolledAt;
        uint256 sponsor;
        uint256 delegatedIn;
        uint256 delegatedOut;
        uint256 earned;
        uint256 stake;
        uint256 principalOut;
        uint256 activeLoans;
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint64 epochStart;
        uint256 earnedThisEpoch;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    function getAgent(uint256 id) external view returns (Agent memory);
}

/// @notice InviteBond v1 (src/InviteBond.sol): `bonds(id)` with v1's struct (:160).
interface IMarketInviteBond {
    struct Bond {
        address depositor;
        uint64 at;
        uint256 amount;
        uint256 qualifiedAt;
    }

    function bonds(uint256 id) external view returns (Bond memory);
}

/// @notice InviteBondV2 (src/InviteBondV2.sol): `bonds(id)` with V2's struct (:170).
interface IMarketInviteBondV2 {
    struct Bond {
        address depositor;
        uint64 at;
        uint256 amount;
    }

    function bonds(uint256 id) external view returns (Bond memory);
}
