// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {StockVaultBase} from "./StockVault.t.sol";

/// GHSA-qcrq-x8xg-25vg (hey-research-lab; SECURITY-v2 SV-21): `borrowRoom`'s notice says it answers 0 when a loan would
/// be refused, but it quoted room where every loan is refused. Cases 1 and 2 of the report, its own tests: each shows
/// the borrow reverting, then reads the view. Case 3 (a default marked on the owner's account, `OwnerDefaulted`) does
/// not fit the contract's size limit and stays with the readers (docs/proposals/stockvault-borrowroom.md).
contract StockVaultQcrqTest is StockVaultBase {
    /// canBorrow lends only to the owner who opened the position: once the agent changes hands every loan reverts.
    function test_borrowRoom_afterTheAgentChangesHands_isZero() public {
        _open(AGENT_PK, AGENT, SHARE / 2); // $300 of SPY, a $150 line
        vm.prank(agentOp);
        reg.transferFrom(agentOp, agentOp2, AGENT);

        // the mutating path: every loan is refused by the vault's own canBorrow
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(AGENT, 10 * USDC, 7 days, agentOp2, type(uint256).max);

        // the view
        assertEq(vault.borrowRoom(AGENT), 0, "borrowRoom quotes room the vault refuses");
    }

    /// A defaulted agent with another loan still open: its position stays open and not closing until the seizure, and
    /// the pool refuses every loan (AgentDefaulted).
    function test_borrowRoom_ofADefaultedAgent_isZero() public {
        _open(AGENT_PK, AGENT, SHARE / 2); // $150 line
        vm.prank(agentOp);
        uint256 first = pool.borrow(AGENT, 50 * USDC, 7 days, agentOp, type(uint256).max);
        vm.prank(agentOp);
        pool.borrow(AGENT, 50 * USDC, 30 days, agentOp, type(uint256).max);
        vm.warp(pool.getLoan(first).defaultableAt + 1);
        spyFeed.set(600e8, block.timestamp); // a fresh price, so the view is not zero for staleness
        _tape(address(spyFeed));
        pool.markDefault(first);
        assertTrue(pool.getAgent(AGENT).defaulted);

        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.AgentDefaulted.selector, AGENT));
        pool.borrow(AGENT, 10 * USDC, 7 days, agentOp, type(uint256).max);

        assertEq(vault.borrowRoom(AGENT), 0, "borrowRoom quotes room on a defaulted agent");
    }
}
