// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {SeatVaultV4} from "../src/SeatVaultV4.sol";
import {SeatVaultV4Base} from "./SeatVaultV4.t.sol";

/// What V4 adds to V3: a default's slash is split between the burn and the protocol stake (`keepBps`), the protocol
/// stake can never be taken out, it only backs agents through protocol seats, and those seats' fees go to the funder.
/// Review round 2 adds: eligibility bound to the owner the Safe vetted (R2-1), levers that reach open protocol seats
/// (R2-2), one roll for both weekly budgets (R2-3), and the owner's cap on loan terms (finding 8).
contract SeatVaultV4SplitTest is SeatVaultV4Base {
    function _keep(uint256 bps) internal {
        vm.prank(owner);
        vault.setKeep(bps);
    }

    function _setBurn(uint256 bps) internal {
        SeatVaultV4.Params memory p = _params();
        p.burnBps = bps;
        vm.prank(owner);
        vault.setParams(p);
    }

    /// staker seats AGENT, it borrows 5 and defaults
    function _seatAndDefault() internal returns (uint256 loanId) {
        _offerAndAccept(staker, AGENT_PK, AGENT);
        loanId = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        _default(loanId);
    }

    /// the owner's steps before any protocol seat: a fee recipient, a weekly budget, the eligible agents, then open
    function _openProtocol() internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT2;
        address[] memory owners = new address[](1);
        owners[0] = agentOp2;
        vm.startPrank(owner);
        vault.setProtocolFeesTo(sink);
        vault.setProtocolEpochCap(1000 * USDC);
        vault.setProtocolEligible(ids, owners, true);
        vault.openProtocolSeats(true);
        vm.stopPrank();
    }

    function _protocolSeat(uint256 pk, uint256 id) internal {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(vm.addr(pk));
        vault.seatFromProtocol(id, c, sig);
    }

    // ---- the split ----

    function test_default_keepSplitsTheSlash() public {
        _keep(5000);
        uint256 before = priors.balanceOf(staker);
        _seatAndDefault();
        // the staker loses burnBps (50%) of the seat whatever keepBps is; half of that is kept, half burnt
        assertEq(priors.balanceOf(staker), before - SEAT / 2, "the staker loses the slash, and only the slash");
        assertEq(vault.protocolTokens(), SEAT / 4, "half the slash kept");
        assertEq(vault.totalKept(), SEAT / 4);
        assertEq(vault.totalBurnt(), SEAT / 4, "half the slash burnt");
        assertEq(priors.balanceOf(address(vault)), SEAT / 4, "the vault holds exactly the protocol stake");
        assertEq(vault.tokensHeld(), 0);
    }

    function test_keepZero_burnsTheWholeSlash_asV3() public {
        _seatAndDefault();
        assertEq(vault.protocolTokens(), 0);
        assertEq(vault.totalBurnt(), SEAT / 2);
        assertEq(priors.balanceOf(address(vault)), 0);
    }

    function test_keepAll_burnsNothing() public {
        _keep(10_000);
        _seatAndDefault();
        assertEq(vault.totalBurnt(), 0);
        assertEq(vault.protocolTokens(), SEAT / 2);
    }

    function test_keep_doesNotChangeWhatTheStakerLoses() public {
        uint256 b0 = priors.balanceOf(staker);
        _keep(10_000);
        _seatAndDefault();
        assertEq(b0 - priors.balanceOf(staker), SEAT / 2, "burnBps is the staker's loss, keepBps only splits it");
    }

    // ---- the protocol stake cannot leave ----

    function test_protocolStake_outOfRescue() public {
        _keep(5000);
        _seatAndDefault();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.Protected.selector, address(priors)));
        vault.rescue(address(priors), owner);
        // only a stray transfer above the protocol stake can be rescued
        vm.prank(anyone);
        priors.transfer(address(vault), 1e18);
        vm.prank(owner);
        vault.rescue(address(priors), owner);
        assertEq(priors.balanceOf(owner), 1e18);
        assertEq(vault.protocolTokens(), SEAT / 4, "the protocol stake did not move");
        assertEq(priors.balanceOf(address(vault)), SEAT / 4);
    }

    // ---- protocol seats ----

    function test_protocolSeat_closedUntilOpened_andNeedsAWholeSeat() public {
        _keep(5000);
        _seatAndDefault(); // SEAT/4 kept: less than a seat
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(SeatVaultV4.ProtocolSeatsClosed.selector);
        vault.seatFromProtocol(AGENT2, c, sig);
        _openProtocol();
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NotEnoughProtocolTokens.selector, SEAT / 4, SEAT));
        vault.seatFromProtocol(AGENT2, c, sig);
    }

    function test_protocolSeat_onlyTheController() public {
        _openProtocol();
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NotController.selector, AGENT2, anyone));
        vault.seatFromProtocol(AGENT2, c, sig);
    }

    /// a whole seat kept (burn and keep at 100%), then AGENT2 borrows on it, repays, and the seat closes: the tokens
    /// come back to the protocol stake and the fee goes to the funder
    function test_protocolSeat_borrowRepayClose_tokensBack_feesToTheFunder() public {
        _setBurn(10_000);
        _keep(10_000);
        _seatAndDefault();
        assertEq(vault.protocolTokens(), SEAT);
        _openProtocol();

        _protocolSeat(AGENT2_PK, AGENT2);
        SeatVaultV4.Seat memory s = vault.getSeat(AGENT2);
        assertEq(s.staker, address(vault), "the vault is the protocol seat's staker");
        assertEq(uint8(s.status), uint8(SeatVaultV4.Status.Open));
        assertEq(vault.protocolTokens(), 0);
        assertEq(vault.tokensHeld(), SEAT);

        uint256 loanId = _borrow(agentOp2, AGENT2, 5 * USDC, 7 days);
        vm.warp(block.timestamp + 7 days);
        _repay(agentOp2, loanId);
        vault.poke(AGENT2);
        uint256 fees = vault.feesOwed(address(vault));
        assertGt(fees, 0, "the protocol seat earned the sponsor share");
        uint256 sink0 = usdc.balanceOf(sink);
        vm.prank(anyone);
        vault.claimProtocolFees();
        assertEq(usdc.balanceOf(sink) - sink0, fees, "to protocolFeesTo, the funder");

        vm.prank(agentOp2);
        vault.close(AGENT2);
        assertEq(uint8(vault.getSeat(AGENT2).status), uint8(SeatVaultV4.Status.Closed));
        assertEq(vault.protocolTokens(), SEAT, "every token back to the protocol stake");
        assertEq(vault.tokensHeld(), 0);
        assertEq(priors.balanceOf(address(vault)), SEAT);
    }

    function test_protocolSeat_default_isSlashedLikeAnySeat_nothingLeaves() public {
        _setBurn(10_000);
        _keep(10_000);
        _seatAndDefault();
        _openProtocol();
        _setBurn(5000);
        _keep(5000);
        _protocolSeat(AGENT2_PK, AGENT2);
        uint256 loanId = _borrow(agentOp2, AGENT2, 5 * USDC, 7 days);
        uint256 burnt0 = vault.totalBurnt();
        _default(loanId);
        // 50% slashed and, on a protocol seat, burnt in full (audit H-1: the stake shrinks); the other half comes back
        assertEq(vault.totalBurnt() - burnt0, SEAT / 2);
        assertEq(vault.protocolTokens(), SEAT / 2);
        assertEq(priors.balanceOf(address(vault)), SEAT / 2, "nothing left the vault but the burn");
    }

    function test_protocolSeat_turnedDownOffer_goesBackToTheProtocol() public {
        _setBurn(10_000);
        _keep(10_000);
        _seatAndDefault();
        _openProtocol();
        _protocolSeat(AGENT2_PK, AGENT2);
        // closing with no loan open: straight back
        vm.prank(owner);
        vault.freezeSeat(AGENT2);
        assertEq(vault.protocolTokens(), SEAT);
    }

    // ---- owner levers ----

    function test_ownerLevers_boundedAndOwnerOnly() public {
        vm.startPrank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setKeep(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.openProtocolSeats(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setProtocolFeesTo(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setProtocolEpochCap(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setProtocolEligible(new uint256[](0), new address[](0), true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        vault.setMaxLoanTerm(7 days);
        vm.stopPrank();
        vm.startPrank(owner);
        vm.expectRevert(SeatVaultV4.InvalidParams.selector);
        vault.setKeep(10_001);
        vm.expectRevert(SeatVaultV4.InvalidParams.selector);
        vault.setMaxLoanTerm(1 days - 1);
        vm.expectRevert(SeatVaultV4.InvalidParams.selector);
        vault.setMaxLoanTerm(366 days);
        vm.expectRevert(SeatVaultV4.InvalidParams.selector);
        vault.setProtocolFeesTo(address(0));
        vm.expectRevert(SeatVaultV4.InvalidParams.selector);
        vault.setProtocolFeesTo(address(vault));
        vault.setProtocolFeesTo(anyone);
        vm.stopPrank();
        assertEq(vault.protocolFeesTo(), anyone);
        assertEq(vault.keepBps(), 0, "V3 behaviour until the owner sets it");
        assertEq(vault.maxLoanTerm(), 0, "no term cap until the owner sets it, as V3");
        assertFalse(vault.protocolSeatsOpen());
    }

    // ---- review round 2 ----

    /// one whole seat of protocol stake (burn and keep at 100% for one default), then burn 50% and keep 50% again,
    /// and protocol seats open for AGENT2
    function _seedProtocol() internal {
        _setBurn(10_000);
        _keep(10_000);
        _seatAndDefault();
        _setBurn(5000);
        _keep(5000);
        _openProtocol();
        assertEq(vault.protocolTokens(), SEAT);
    }

    /// the Safe marks `id` for the owner that holds it now, or revokes it (no owners needed)
    function _eligible(uint256 id, bool on) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        address[] memory owners = new address[](on ? 1 : 0);
        if (on) owners[0] = reg.ownerOf(id);
        vm.prank(owner);
        vault.setProtocolEligible(ids, owners, on);
    }

    function _newAgent(uint256 pk) internal returns (uint256 id) {
        address o = vm.addr(pk);
        vm.startPrank(o);
        id = reg.register("x");
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        usdc.mint(o, 100 * USDC);
    }

    /// R2-1: marking an agent eligible binds the owner the Safe vetted, who must hold it then; revoking clears it.
    function test_R2_1_eligibilityBindsTheOwnerWhenMarked() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT2;
        address[] memory owners = new address[](1);
        owners[0] = agentOp2;
        vm.expectEmit(address(vault));
        emit SeatVaultV4.ProtocolEligible(AGENT2, agentOp2, true);
        vm.prank(owner);
        vault.setProtocolEligible(ids, owners, true);
        assertEq(vault.protocolEligibleOwner(AGENT2), agentOp2);
        assertTrue(vault.protocolEligible(AGENT2));
        assertFalse(vault.protocolEligible(AGENT), "never marked");
        vm.expectEmit(address(vault));
        emit SeatVaultV4.ProtocolEligible(AGENT2, address(0), false);
        vm.prank(owner);
        vault.setProtocolEligible(ids, new address[](0), false);
        assertEq(vault.protocolEligibleOwner(AGENT2), address(0));
        assertFalse(vault.protocolEligible(AGENT2));
    }

    /// R2-1: the Safe names the owner it vetted. If the id was sold while the Safe collected signatures, marking
    /// reverts instead of binding the buyer; a missing owner is refused too.
    function test_R2_1_marking_revertsIfTheVettedOwnerNoLongerHoldsIt() public {
        address buyer = makeAddr("buyer");
        vm.prank(agentOp2);
        reg.transferFrom(agentOp2, buyer, AGENT2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT2;
        address[] memory owners = new address[](1);
        owners[0] = agentOp2; // the owner the Safe vetted
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.OwnerChanged.selector, AGENT2, agentOp2, buyer));
        vault.setProtocolEligible(ids, owners, true);
        assertEq(vault.protocolEligibleOwner(AGENT2), address(0), "the buyer was not bound");

        vm.prank(owner);
        vm.expectRevert(SeatVaultV4.InvalidParams.selector);
        vault.setProtocolEligible(ids, new address[](0), true);
    }

    /// R2-1: the Safe vetted AGENT2's owner, not the id. Once the id changes hands the new holder cannot take a
    /// protocol seat; back in the vetted owner's hands, the agent can again; marking it anew binds the new holder.
    function test_R2_1_transferredEligibleId_cannotTakeAProtocolSeat() public {
        _seedProtocol();
        uint256 buyerPk = 0xBAD;
        address buyer = vm.addr(buyerPk);
        vm.prank(agentOp2);
        reg.transferFrom(agentOp2, buyer, AGENT2);
        assertFalse(vault.protocolEligible(AGENT2), "not eligible in the buyer's hands");
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, buyerPk);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NotEligible.selector, AGENT2));
        vault.seatFromProtocol(AGENT2, c, sig);
        assertEq(vault.protocolTokens(), SEAT, "the stake did not move");
        assertEq(vault.protocolLinedThisEpoch(), 0, "no protocol budget spent");

        // the Safe vets the buyer and marks the agent anew: now the buyer may
        _eligible(AGENT2, true);
        assertEq(vault.protocolEligibleOwner(AGENT2), buyer);
        _protocolSeat(buyerPk, AGENT2);
        assertEq(_seat(AGENT2).owner, buyer);
        vm.prank(buyer);
        vault.close(AGENT2);

        // handed back to the operator the Safe vetted first, it is not eligible: the mark follows the last vetting
        vm.prank(buyer);
        reg.transferFrom(buyer, agentOp2, AGENT2);
        assertFalse(vault.protocolEligible(AGENT2));
    }

    /// R2-2: revoking eligibility reaches the protocol seat already open: no new loan. Marked again (same owner),
    /// it lends again. Revoked with a loan open, repaying and closing still work.
    function test_R2_2_revokedEligibility_stopsLoansOnTheOpenProtocolSeat() public {
        _seedProtocol();
        _protocolSeat(AGENT2_PK, AGENT2);
        _eligible(AGENT2, false);
        assertFalse(vault.canBorrow(VAULT_ID, AGENT2, 5 * USDC, 7 days, 0, agentOp2, agentOp2, agentOp2));
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(AGENT2, 5 * USDC, 7 days, agentOp2, type(uint256).max);

        _eligible(AGENT2, true);
        uint256 l = _borrow(agentOp2, AGENT2, 5 * USDC, 7 days);
        _eligible(AGENT2, false);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _repay(agentOp2, l);
        vm.prank(agentOp2);
        vault.close(AGENT2);
        assertEq(uint8(_status(AGENT2)), uint8(SeatVaultV4.Status.Closed));
        assertEq(vault.protocolTokens(), SEAT, "every token back to the protocol stake");
    }

    /// R2-2: freezeSeat on a protocol seat also revokes the agent's eligibility, so it cannot re-seat at once.
    function test_R2_2_freezeSeat_protocolSeat_revokesEligibility() public {
        _seedProtocol();
        _protocolSeat(AGENT2_PK, AGENT2);
        vm.expectEmit(address(vault));
        emit SeatVaultV4.ProtocolEligible(AGENT2, address(0), false);
        vm.prank(owner);
        vault.freezeSeat(AGENT2);
        assertEq(uint8(_status(AGENT2)), uint8(SeatVaultV4.Status.Closed));
        assertEq(vault.protocolEligibleOwner(AGENT2), address(0));
        assertEq(vault.protocolTokens(), SEAT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NotEligible.selector, AGENT2));
        vault.seatFromProtocol(AGENT2, c, sig);
    }

    /// R2-2: freezeSeat revokes only the eligibility of the owner who took the protocol seat. The id moved and the
    /// Safe marked it for the new holder: freezing the old holder's seat leaves the new holder eligible.
    function test_R2_2_freezeSeat_oldProtocolSeat_keepsTheNewHoldersEligibility() public {
        _seedProtocol();
        _protocolSeat(AGENT2_PK, AGENT2);
        uint256 buyerPk = 0xB0B;
        address buyer = vm.addr(buyerPk);
        vm.prank(agentOp2);
        reg.transferFrom(agentOp2, buyer, AGENT2);
        _eligible(AGENT2, true);
        assertEq(vault.protocolEligibleOwner(AGENT2), buyer);

        vm.prank(owner);
        vault.freezeSeat(AGENT2);
        assertEq(uint8(_status(AGENT2)), uint8(SeatVaultV4.Status.Closed));
        assertEq(vault.protocolEligibleOwner(AGENT2), buyer, "the new holder is still eligible");
        assertTrue(vault.protocolEligible(AGENT2));
        _protocolSeat(buyerPk, AGENT2);
        assertEq(_seat(AGENT2).owner, buyer);
    }

    /// R2-2: freezing an ordinary seat leaves the agent's protocol eligibility alone.
    function test_R2_2_freezeSeat_ordinarySeat_keepsEligibility() public {
        _eligible(AGENT2, true);
        _offerAndAccept(staker2, AGENT2_PK, AGENT2);
        vm.prank(owner);
        vault.freezeSeat(AGENT2);
        assertEq(vault.protocolEligibleOwner(AGENT2), agentOp2);
        assertEq(priors.balanceOf(address(vault)), 0, "every token back to the staker");
    }

    /// Finding 8: the owner's cap on loan terms. Over the cap is refused, at or under it is allowed, on ordinary and
    /// protocol seats alike; 0 lifts it.
    function test_maxLoanTerm_refusesLongerTerms_allowsShorter() public {
        _seedProtocol(); // AGENT defaulted here; AGENT2 is eligible
        uint256 id3 = _newAgent(0xC3);
        _offerAndAccept(staker, 0xC3, id3);
        address op3 = vm.addr(0xC3);
        assertTrue(vault.canBorrow(VAULT_ID, id3, 5 * USDC, 30 days, 0, op3, op3, op3), "no cap by default");

        vm.expectEmit(address(vault));
        emit SeatVaultV4.MaxLoanTermUpdated(7 days);
        vm.prank(owner);
        vault.setMaxLoanTerm(7 days);
        assertFalse(vault.canBorrow(VAULT_ID, id3, 5 * USDC, 7 days + 1, 0, op3, op3, op3));
        vm.prank(op3);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(id3, 5 * USDC, 30 days, op3, type(uint256).max);
        uint256 l = _borrow(op3, id3, 5 * USDC, 7 days); // at the cap
        assertEq(pool.getLoan(l).dueAt, vm.getBlockTimestamp() + 7 days);
        _repay(op3, l);
        _repay(op3, _borrow(op3, id3, 5 * USDC, 1 days)); // under it

        // a protocol seat is capped the same way
        _protocolSeat(AGENT2_PK, AGENT2);
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(AGENT2, 5 * USDC, 8 days, agentOp2, type(uint256).max);
        _repay(agentOp2, _borrow(agentOp2, AGENT2, 5 * USDC, 7 days));

        // 0 lifts the cap
        vm.prank(owner);
        vault.setMaxLoanTerm(0);
        _borrow(op3, id3, 5 * USDC, 30 days);
    }

    /// R2-3: both weekly budgets roll together when a seat opens after the epoch ends. protocolEpochRoom reads the
    /// room now (a fresh epoch once the last one is over, before anything rolls it), capped by the vault's room.
    function test_R2_3_bothBudgetsRollTogether_andProtocolEpochRoom() public {
        _seedProtocol();
        vm.prank(owner);
        vault.setProtocolEpochCap(5 * USDC);
        assertEq(vault.protocolEpochRoom(), 5 * USDC);
        _protocolSeat(AGENT2_PK, AGENT2);
        assertEq(vault.protocolLinedThisEpoch(), 5 * USDC);
        assertEq(vault.protocolEpochRoom(), 0);

        vm.warp(vault.epochStart() + 7 days);
        assertEq(vault.protocolEpochRoom(), 5 * USDC, "the epoch is over: full room");
        assertEq(vault.epochRoom(), 50 * USDC);
        uint256 id3 = _newAgent(0xC3);
        _offerAndAccept(staker, 0xC3, id3); // an ordinary seat rolls both budgets
        assertEq(vault.epochStart(), vm.getBlockTimestamp());
        assertEq(vault.linedThisEpoch(), 5 * USDC);
        assertEq(vault.protocolLinedThisEpoch(), 0, "rolled with the vault's");
        // the protocol seat opened last epoch: its clean close refunds neither budget
        vm.prank(agentOp2);
        vault.close(AGENT2);
        assertEq(vault.linedThisEpoch(), 5 * USDC);
        assertEq(vault.protocolLinedThisEpoch(), 0);

        // the protocol room is capped by the vault's
        SeatVaultV4.Params memory p = _params();
        p.epochCap = 8 * USDC;
        vm.prank(owner);
        vault.setParams(p);
        assertEq(vault.epochRoom(), 3 * USDC);
        assertEq(vault.protocolEpochRoom(), 3 * USDC);
    }

    /// R2-3: a new epoch length starts a new epoch now that carries what the current one spent. Shortening frees no
    /// budget, a seat opened in the same block before the change is refunded from the budget it was charged to, and
    /// lengthening after an epoch is over does not bring its spend back.
    function test_R2_3_newEpochLength_startsAnEpochCarryingTheSpend() public {
        _seedProtocol();
        _protocolSeat(AGENT2_PK, AGENT2); // rolls: T0
        uint256 t0 = vault.epochStart();
        vm.warp(t0 + 3 days);
        uint256 id3 = _newAgent(0xC3);
        uint256 id4 = _newAgent(0xC4);
        _offerAndAccept(staker, 0xC3, id3);
        assertEq(vault.linedThisEpoch(), 10 * USDC);

        SeatVaultV4.Params memory p = _params();
        p.epochLength = 1 days; // the old epoch would have ended two days ago under this length
        vm.prank(owner);
        vault.setParams(p);
        assertEq(vault.epochStart(), vm.getBlockTimestamp(), "a new epoch starts now");
        assertEq(vault.epochRoom(), 40 * USDC, "carrying what was spent: shortening freed nothing");
        assertEq(vault.protocolLinedThisEpoch(), 5 * USDC);

        _offerAndAccept(staker, 0xC4, id4); // same block
        assertEq(vault.linedThisEpoch(), 15 * USDC);
        vm.prank(agentOp2);
        vault.close(AGENT2); // opened before the new epoch: no refund
        vm.prank(vm.addr(0xC3));
        vault.close(id3); // opened in this block, before the change: refunded from the carried budget
        assertEq(vault.linedThisEpoch(), 10 * USDC, "id4's open line is still counted");
        assertEq(vault.protocolLinedThisEpoch(), 5 * USDC);

        // over under the new length; lengthening now rolls first
        vm.warp(vm.getBlockTimestamp() + 1 days);
        p.epochLength = 7 days;
        vm.prank(owner);
        vault.setParams(p);
        assertEq(vault.epochStart(), vm.getBlockTimestamp());
        assertEq(vault.linedThisEpoch(), 0, "the ended epoch's spend does not come back");
        assertEq(vault.protocolLinedThisEpoch(), 0);
        assertEq(vault.epochRoom(), 50 * USDC);

        // the same length again is no change: the epoch runs on
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        vault.setParams(p);
        assertEq(vault.epochStart(), vm.getBlockTimestamp() - 1 days);
    }

    function test_claimProtocolFees_nothingOwed_reverts() public {
        vm.prank(owner);
        vault.setProtocolFeesTo(sink);
        vm.expectRevert(SeatVaultV4.ZeroAmount.selector);
        vault.claimProtocolFees();
    }
}
