// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPool} from "../src/CreditPool.sol";
import {TreasurySponsor} from "../src/TreasurySponsor.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";
import {TreasurySponsorTest} from "./TreasurySponsor.t.sol";

/// The two operational findings of the 2026-09-22 treasury v3 review, each reproduced and closed:
/// alternating reclaim() and raise() used to burn the epoch budget with the stake never at risk, and a
/// repeated sweep() used to carve the reserve share out of a stake share that was only waiting.
contract TreasuryV3AuditTest is TreasurySponsorTest {
    function _seatAndQualify() internal {
        _creatorFees(400 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(agentOp);
            uint256 loan = pool.borrow(AGENT, 5 * USDC, 7 days, agentOp);
            vm.warp(block.timestamp + 7 days);
            vm.prank(agentOp);
            pool.repay(loan);
        }
        assertTrue(treasury.eligibleForRaise(pool.creditReport(AGENT)));
    }

    function _idle() internal view returns (uint64 idleAfter) {
        (,,,,,,,, idleAfter) = treasury.rules();
    }

    /// A reclaimed seat is closed: raise() does not reopen it, so reclaim/raise cannot be alternated to
    /// spend the epoch's budget on a line nobody holds.
    function test_raise_doesNotReopenAReclaimedSeat() public {
        _seatAndQualify();
        treasury.reclaim(AGENT); // first look after the loans: refreshes the watermark
        vm.warp(block.timestamp + _idle());
        vm.prank(anyone);
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
        assertEq(pool.creditReport(AGENT).delegatedIn, 0);
        uint256 room = treasury.epochRoom();
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotEligible.selector, AGENT));
        treasury.raise(AGENT);
        assertEq(treasury.epochRoom(), room, "nothing spent");
        assertFalse(treasury.eligibleForRaise(pool.creditReport(AGENT)));
    }

    /// A raise is activity: the bigger line gets its own idleAfter before anyone can take it back.
    function test_raise_refreshesTheIdleWatermark() public {
        _seatAndQualify();
        treasury.reclaim(AGENT); // refresh after the loans
        vm.warp(block.timestamp + _idle() - 1 days);
        vm.prank(anyone);
        treasury.raise(AGENT);
        assertEq(pool.creditReport(AGENT).delegatedIn, 50 * USDC);
        uint256 at = block.timestamp + _idle();
        assertEq(treasury.reclaimableAt(AGENT), at);
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotIdle.selector, AGENT, at));
        treasury.reclaim(AGENT);
        vm.warp(at);
        assertEq(treasury.reclaim(AGENT), 50 * USDC);
    }

    /// Reopening a reclaimed seat is a person's fresh decision: a new invite works, the old signature
    /// does not, and the reopened line is the first line, not the raise.
    function test_firstLine_reopensAReclaimedSeatOnlyWithAFreshInvite() public {
        _creatorFees(200 * USDC);
        treasury.sweep();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.AlreadyLined.selector, AGENT));
        treasury.firstLine(AGENT, FAR, _sig(AGENT, FAR));
        vm.warp(block.timestamp + _idle());
        assertEq(treasury.reclaim(AGENT), 5 * USDC);
        // the same invite again: refused
        bytes memory old = _sig(AGENT, FAR);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.InviteUsed.selector, AGENT));
        treasury.firstLine(AGENT, FAR, old);
        // a fresh one: the seat reopens, the budget is charged the first line
        uint64 later = uint64(block.timestamp + 3 days);
        bytes memory fresh = _sig(AGENT, later);
        uint256 room = treasury.epochRoom();
        vm.prank(agentOp);
        treasury.firstLine(AGENT, later, fresh);
        assertEq(pool.creditReport(AGENT).delegatedIn, 5 * USDC);
        assertEq(treasury.epochRoom(), room - 5 * USDC);
        assertEq(treasury.reclaimableAt(AGENT), block.timestamp + _idle(), "a reopened seat starts a new idle clock");
        // still a controller-only call, still bound to the identity
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(TreasurySponsor.NotController.selector, AGENT, anyone));
        treasury.firstLine(AGENT, later, fresh);
    }

    /// The stake share that waits below the minimum stake is not split again on the next sweep.
    function test_sweep_keepsAWaitingStakeShareOutOfTheReserve() public {
        TreasurySponsor t = new TreasurySponsor(
            pool, IPonsFeeEscrow(address(escrow)), IPonsFactoryCreator(address(escrow)), owner, sink
        );
        vm.startPrank(owner);
        uint256 id = reg.register("priors-treasury-2");
        reg.safeTransferFrom(owner, address(t), id);
        t.adopt(id);
        vm.stopPrank();
        assertEq(pool.getParams().minStake, 10 * USDC);
        usdc.mint(address(t), 10 * USDC);
        uint256 reserve0 = pool.reserve();
        (uint256 toReserve, uint256 toStake) = t.sweep();
        assertEq(toReserve, 5 * USDC);
        assertEq(toStake, 0, "below the minimum: waits");
        assertEq(t.pendingStake(), 5 * USDC);
        for (uint256 i = 0; i < 25; i++) {
            vm.prank(anyone);
            (toReserve, toStake) = t.sweep();
            assertEq(toReserve, 0);
            assertEq(toStake, 0);
        }
        assertEq(pool.reserve(), reserve0 + 5 * USDC, "the reserve got its half once");
        assertEq(usdc.balanceOf(address(t)), 5 * USDC, "the stake half is still here");
        // more money arrives: only the new part is split, and the whole stake share enrolls
        usdc.mint(address(t), 10 * USDC);
        (toReserve, toStake) = t.sweep();
        assertEq(toReserve, 5 * USDC);
        assertEq(toStake, 10 * USDC);
        assertEq(t.pendingStake(), 0);
        assertEq(usdc.balanceOf(address(t)), 0);
        CreditPool.CreditReport memory r = pool.creditReport(id);
        assertTrue(r.enrolled && r.isRoot);
        assertEq(r.stake, 10 * USDC);
        assertEq(t.totalToReserve(), 10 * USDC);
        assertEq(t.totalStaked(), 10 * USDC);
    }
}
