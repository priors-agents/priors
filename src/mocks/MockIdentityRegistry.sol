// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Test/dev stand-in for the ERC-8004 Identity Registry. `register()` mints a new agentId to the caller.
contract MockIdentityRegistry is ERC721 {
    uint256 public nextId = 1;
    mapping(uint256 => string) public agentURI;

    event Registered(uint256 indexed agentId, address indexed owner, string agentURI);

    constructor() ERC721("ERC-8004 Agent (mock)", "AGENT") {}

    function register(string calldata uri) external returns (uint256 agentId) {
        agentId = nextId++;
        _mint(msg.sender, agentId);
        agentURI[agentId] = uri;
        emit Registered(agentId, msg.sender, uri);
    }

    function register() external returns (uint256 agentId) {
        agentId = nextId++;
        _mint(msg.sender, agentId);
        emit Registered(agentId, msg.sender, "");
    }

    function tokenURI(uint256 agentId) public view override returns (string memory) {
        _requireOwned(agentId);
        return agentURI[agentId];
    }
}
