// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IERC8004Identity
/// @notice Minimal view of the ERC-8004 Identity Registry. Agents are ERC-721 tokens; the token id is the agentId.
///         We only rely on `ownerOf` (who controls the agent) and `exists`-style semantics via revert-on-missing.
interface IERC8004Identity {
    function ownerOf(uint256 agentId) external view returns (address);
}
