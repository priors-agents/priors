// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TreasuryV4Base} from "./TreasurySponsorV4.t.sol";
import {InviteBond, ITreasuryRules} from "../src/InviteBond.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// GHSA-w9xg (Medium, 2026-10-04): on treasury v4 a bond follows its depositor while the line follows the agent, so a
/// buyer of a bonded agent can borrow and default on a line the seller's bond answers for. These tests pin that
/// residual as it stands on v4 (the borrow-time check is TreasurySponsorV5's), the reporter's path among them, and the
/// way out a seller has today: leave the line before selling, then take the bond back through the no-line release.
/// The invite bot no longer hands an unused invite to a later owner (since 2026-10-04).
/// Not a fix: the bond returned to the seller on a sale would let one owner sell to its own second wallet, borrow,
/// default and keep the bond (InviteBond's own rule: moving the agent between one's own wallets gains nothing).
contract InviteBondSaleTest is TreasuryV4Base {
    InviteBond bond;
    address safe = makeAddr("safe");
    uint256 constant BOND = 5e6;
    uint64 constant UNUSED = 4 days;

    function setUp() public override {
        super.setUp();
        bond =
            new InviteBond(pool, IERC8004Identity(address(reg)), ITreasuryRules(address(treasury)), safe, BOND, UNUSED);
        _funded();
        vm.prank(agentOp);
        usdc.approve(address(bond), type(uint256).max);
        vm.prank(agentOp2);
        usdc.approve(address(bond), type(uint256).max);
    }

    /// The seller bonds and opens its own first line with its own consent.
    function _bondedLine() internal {
        vm.prank(agentOp);
        bond.deposit(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(AGENT, TREASURY_ID, AGENT_PK);
        vm.prank(relayer);
        treasury.firstLine(AGENT, FAR, _invite(AGENT, FAR), c, sig);
        assertEq(_line(AGENT), 5 * USDC);
    }

    function _sell() internal {
        vm.prank(agentOp);
        reg.transferFrom(agentOp, agentOp2, AGENT);
        assertEq(reg.ownerOf(AGENT), agentOp2);
    }

    /// Path 1, no invite needed: the line was open before the sale; the buyer draws it and defaults.
    function test_v4Residual_openLineSold_buyerDefault_slashesTheSellersBond() public {
        _bondedLine();
        _sell();
        assertEq(bond.bonds(AGENT).depositor, agentOp, "the bond still names the seller");
        vm.prank(agentOp2);
        uint256 loan = pool.borrow(AGENT, 5 * USDC, 7 days, agentOp2, type(uint256).max);
        _default(loan);
        uint256 seller = usdc.balanceOf(agentOp);
        vm.prank(anyone);
        bond.slash(AGENT);
        assertEq(usdc.balanceOf(safe), BOND, "the seller's bond went to the beneficiary");
        assertEq(usdc.balanceOf(agentOp), seller);
    }

    /// Path 2, the reporter's: the seller's unused invite (it names only the agent) redeemed by the buyer.
    function test_v4Residual_unusedInviteSold_buyerRedeems_slashesTheSellersBond() public {
        vm.prank(agentOp);
        bond.deposit(AGENT);
        bytes memory inv = _invite(AGENT, FAR);
        _sell();
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(AGENT, TREASURY_ID, AGENT2_PK);
        vm.prank(relayer);
        treasury.firstLine(AGENT, FAR, inv, c, sig);
        vm.prank(agentOp2);
        uint256 loan = pool.borrow(AGENT, 5 * USDC, 7 days, agentOp2, type(uint256).max);
        _default(loan);
        vm.prank(anyone);
        bond.slash(AGENT);
        assertEq(usdc.balanceOf(safe), BOND);
    }

    /// The seller's way out: leave the line before the sale (no loan open), and the bond comes back by itself through
    /// the no-line release; the buyer has no line to draw.
    function test_sellerLeavesFirst_bondComesBack_buyerCannotBorrow() public {
        _bondedLine();
        vm.prank(agentOp);
        pool.leave(AGENT);
        _sell();
        vm.prank(agentOp2);
        vm.expectRevert();
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOp2, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + UNUSED + 1);
        uint256 seller = usdc.balanceOf(agentOp);
        vm.prank(anyone);
        bond.release(AGENT);
        assertEq(usdc.balanceOf(agentOp), seller + BOND, "the bond back to the seller");
    }

    /// The buyer's own deposit replaces the seller's bond at once, returning it (InviteBond.deposit).
    function test_buyerBonds_sellersBondReturned() public {
        _bondedLine();
        _sell();
        uint256 seller = usdc.balanceOf(agentOp);
        vm.prank(agentOp2);
        bond.deposit(AGENT);
        assertEq(usdc.balanceOf(agentOp), seller + BOND);
        assertEq(bond.bonds(AGENT).depositor, agentOp2);
    }
}
