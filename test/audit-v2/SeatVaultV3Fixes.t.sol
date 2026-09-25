// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {SeatVaultV3} from "../../src/SeatVaultV3.sol";
import {SeatVaultV3Base} from "../SeatVaultV3.t.sol";

/// Fixes for the three seat findings of the 2026-09-23 audit, at the launch numbers (1M $PRIORS seat, 5 USDG line,
/// burnBps 5000, 10 seats, 50 USDG per epoch) and the launch gates (minRepaid 3, idleAfter 30 days).
///
///   GREEN:  forge test --match-path test/audit-v2/SeatVaultV3Fixes.t.sol
///   RED (controlled mutation, gates off):  SEAT_GATES_OFF=true forge test --match-path test/audit-v2/SeatVaultV3Fixes.t.sol
///   X-1 has no switch: it is unconditional code; its RED is the old `test_X1_F3_*` exploit, which passed before.
contract SeatVaultV3FixesTest is SeatVaultV3Base {
    uint256 constant LSEAT = 1_000_000e18;
    uint256 constant MIN_REPAID = 3;
    uint64 constant IDLE = 30 days;

    function _launch() internal {
        vm.startPrank(owner);
        vault.setParams(
            SeatVaultV3.Params({
                seatSize: LSEAT, line: 5 * USDC, burnBps: 5000, maxOpenSeats: 10, epochCap: 50 * USDC, epochLength: 7 days
            })
        );
        if (!vm.envOr("SEAT_GATES_OFF", false)) vault.setGates(MIN_REPAID, IDLE);
        vm.stopPrank();
    }

    /// `n` loans borrowed and repaid under another backer: the history an honest agent brings to a seat.
    function _history(uint256 id, uint256 pk, uint256 n) internal {
        _handoff(id, pk, 10 * USDC);
        for (uint256 i = 0; i < n; i++) {
            _repay(vm.addr(pk), _borrow(vm.addr(pk), id, 5 * USDC, 1 days));
        }
    }

    // ------------------------------------------------------------------
    // X-3: a fresh identity cannot be seated, so the self-seat loop takes nothing even with seats open
    // ------------------------------------------------------------------

    function test_fix_X3_selfSeatLoopTakesNothingWithSeatsOpen() public {
        _launch();
        address loot = makeAddr("loot");
        uint256 backing0 = pool.backing(VAULT_ID);
        uint256[] memory loans = new uint256[](10);
        uint256 n;
        for (uint256 i = 0; i < 10; i++) {
            address a = vm.addr(0x6000 + i);
            priors.mint(a, LSEAT);
            vm.startPrank(a);
            priors.approve(address(vault), type(uint256).max);
            try vault.registerAndSeat("") returns (uint256 id) {
                loans[n++] = pool.borrow(id, 5 * USDC, 1 days, loot, type(uint256).max);
            } catch {}
            vm.stopPrank();
        }
        if (n > 0) {
            vm.warp(pool.getLoan(loans[0]).defaultableAt + 1);
            for (uint256 i = 0; i < n; i++) {
                vm.prank(keeper);
                pool.markDefault(loans[i]);
            }
        }
        assertFalse(vault.seatsPaused(), "seats are open: the gate alone must hold");
        assertEq(n, 0, "no fresh identity was seated");
        assertEq(usdc.balanceOf(loot), 0, "the loop takes nothing");
        assertEq(pool.backing(VAULT_ID), backing0, "the funder's stake is untouched");
    }

    function test_fix_X3_freshIdentityRefusedWithTheReason() public {
        _launch();
        vm.prank(staker);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotSeatable.selector, AGENT));
        vault.offer(AGENT);
        assertFalse(vault.seatable(AGENT));
    }

    /// The gate is a floor, not a wall: an agent that has repaid `minRepaid` loans is seated and borrows.
    function test_fix_X3_agentWithHistoryIsSeated() public {
        _launch();
        _history(AGENT, AGENT_PK, MIN_REPAID - 1);
        assertFalse(vault.seatable(AGENT), "one loan short");
        _repay(agentOp, _borrow(agentOp, AGENT, 5 * USDC, 1 days));
        assertTrue(vault.seatable(AGENT), "history met");

        priors.mint(staker, LSEAT);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        assertEq(pool.getAgent(AGENT).sponsor, VAULT_ID, "moved from its old backer to the vault");
        _repay(agentOp, _borrow(agentOp, AGENT, 5 * USDC, 1 days));
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Open));
    }

    // ------------------------------------------------------------------
    // X-1: an offer dies with an NFT sale
    // ------------------------------------------------------------------

    function test_fix_X1_saleKillsTheOffer_andTheStakerGetsEveryTokenBack() public {
        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.offer(AGENT); // the staker trusts agentOp

        uint256 buyerPk = 0xBAD;
        address buyer = vm.addr(buyerPk);
        vm.prank(agentOp);
        reg.transferFrom(agentOp, buyer, AGENT);

        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, buyerPk);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.OwnerChanged.selector, AGENT, agentOp, buyer));
        vault.accept(AGENT, staker, c, sig);

        // the buyer can turn it down (it controls the id now), and every token goes back
        vm.prank(buyer);
        vault.withdrawOffer(AGENT, staker);
        assertEq(priors.balanceOf(staker), before, "every token back");
        assertEq(vault.tokensHeld(), 0);
    }

    function test_fix_X1_theOwnerTheStakerTrustedCanStillAccept() public {
        vm.prank(staker);
        vault.offer(AGENT);
        _accept(AGENT_PK, AGENT, staker);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Open));
    }

    // ------------------------------------------------------------------
    // X-2: an idle seat can be closed by anyone after idleAfter
    // ------------------------------------------------------------------

    function _gatesIdleOnly() internal {
        vm.prank(owner);
        vault.setGates(0, vm.envOr("SEAT_GATES_OFF", false) ? 0 : IDLE);
    }

    function test_fix_X2_idleSeatExpires_everyTokenBack_slotAndBackingFreed() public {
        _gatesIdleOnly();
        SeatVaultV3.Params memory p = _params();
        p.maxOpenSeats = 1;
        vm.prank(owner);
        vault.setParams(p);
        uint256 before = priors.balanceOf(staker);
        _offerAndAccept(staker, AGENT_PK, AGENT);

        vm.warp(block.timestamp + IDLE - 1);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotIdle.selector, AGENT));
        vault.expire(AGENT);

        vm.warp(block.timestamp + 1);
        vm.prank(anyone);
        vault.expire(AGENT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Closed));
        assertEq(priors.balanceOf(staker), before, "every token back");
        assertEq(vault.openCount(), 0, "slot freed");
        assertEq(pool.getAgent(VAULT_ID).delegatedOut, 0, "backing freed");

        // the freed slot takes an honest seat
        _offerAndAccept(staker2, AGENT2_PK, AGENT2);
        assertEq(vault.openCount(), 1);
    }

    function test_fix_X2_aSeatInUseDoesNotExpire() public {
        _gatesIdleOnly();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.warp(block.timestamp + IDLE / 2);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days); // a borrow restarts the clock
        vm.warp(block.timestamp + IDLE / 2 + 1);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotIdle.selector, AGENT)); // loan open
        vault.expire(AGENT);
        _repay(agentOp, loan);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotIdle.selector, AGENT)); // idle for less than IDLE
        vault.expire(AGENT);
        vm.warp(block.timestamp + IDLE - 1); // the repayment restarted the clock too (Codex Low)
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotIdle.selector, AGENT));
        vault.expire(AGENT);
        vm.warp(block.timestamp + 1);
        vm.prank(anyone);
        vault.expire(AGENT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Closed));
    }

    /// Codex review 2026-09-24 (Low): a 30-day loan repaid on its due date left `lastBorrowAt + idleAfter` already
    /// elapsed, so a stranger could expire the seat of an agent that had just used it. The clock counts repayments.
    function test_fix_X2_aSeatIsNotIdleRightAfterALongLoanIsRepaid() public {
        _gatesIdleOnly();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 30 days);
        vm.warp(block.timestamp + 30 days);
        _repay(agentOp, loan);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotIdle.selector, AGENT));
        vault.expire(AGENT);
        vm.warp(block.timestamp + IDLE - 1);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotIdle.selector, AGENT));
        vault.expire(AGENT);
        vm.warp(block.timestamp + 1);
        vm.prank(anyone);
        vault.expire(AGENT);
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Closed));
    }

    function test_fix_X2_aDefaultedSeatIsSettledNotExpired() public {
        _gatesIdleOnly();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loan = _borrow(agentOp, AGENT, 5 * USDC, 1 days);
        _default(loan); // settles through onDefault
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Settled));
        vm.warp(block.timestamp + IDLE + 1);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NoOpenSeat.selector, AGENT));
        vault.expire(AGENT);
    }

    // ------------------------------------------------------------------
    // setGates
    // ------------------------------------------------------------------

    function test_fix_setGates_ownerOnlyAndBounded() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setGates(3, IDLE);
        vm.startPrank(owner);
        vm.expectRevert(SeatVaultV3.InvalidParams.selector);
        vault.setGates(3, 1 hours);
        vm.expectRevert(SeatVaultV3.InvalidParams.selector);
        vault.setGates(3, 366 days);
        vault.setGates(3, IDLE);
        vm.stopPrank();
        assertEq(vault.minRepaid(), 3);
        assertEq(vault.idleAfter(), IDLE);
    }
}
