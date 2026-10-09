// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors} from "../../src/v5/V5Types.sol";
import {V5Math as M} from "../../src/v5/V5Math.sol";

/// @dev Section 6's attack table, row by row, for the rows V5 owns: each attack shown blocked or unprofitable. Rows
///      already shown by a unit test are mapped in docs/V5-BUILD.md ("Attacks"); the rows here are the ones whose
///      cost-versus-profit needs its own scenario.
contract V5AttacksTest is V5Base {
    uint256 internal id;

    function _agentCount() internal pure override returns (uint256) {
        return 3;
    }

    function setUp() public override {
        super.setUp();
        id = agents[0];
        vm.prank(timelock);
        v5.setOpenBacking(true);
    }

    function _usd(uint256 tokens, uint256 pE18) internal pure returns (uint256) {
        return tokens * pE18 / 1e30;
    }

    function _burned() internal view returns (uint256 b) {
        (,,,,, b,) = lens.totals();
    }

    // ------------------------------------------------------------------
    // row 1: exit with other people's $PRIORS
    // ------------------------------------------------------------------

    /// @dev Backers add no line; a default burns 75% of A, and the owner's net on a fully drawn line is negative at
    ///      P; the backers' own stake burns at 50%, and nothing of theirs reaches the owner.
    function test_row1_othersBackingRaisesNoLine_defaultCostsTheOwner() public {
        _open(id, 150_001 * T);
        uint256 line0 = lens.lineOf(id);
        _back(backer1, id, 90_000 * T);
        _back(backer2, id, 50_000 * T);
        _skipFresh(2 days);
        v5.pokeFees(id);
        assertEq(lens.lineOf(id), line0, "B raises no line");
        uint256 l = _borrow(id, line0, 8 days);
        uint256 o0 = priors.balanceOf(_owner(id));
        uint256 b0 = _burned();
        S.Gen memory g = _gen(id);
        uint256 a = g.counted[C.OWNER];
        assertEq(g.counted[C.OTHERS], 140_000 * T);
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        v5.claimSettled(id, 1, _owner(id));
        uint256 ownerLost = a + g.counted[C.OWN] - (priors.balanceOf(_owner(id)) - o0);
        assertGt(_usd(ownerLost, P0), line0, "the owner burns more than it drew (k 3: 2.25 lines)");
        // the backers burn 50% of their own: 70,000 T, none of it to the owner
        assertEq(_burned() - b0, ownerLost + 70_000 * T);
    }

    // ------------------------------------------------------------------
    // row 2: wash repayments
    // ------------------------------------------------------------------

    /// @dev Short loans, small loans and loans repaid within 7 days never count toward promotion or points.
    function test_row2_washLoansNeverCount() public {
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 25 * U, 1 days); // too short a term
        uint256 b = _borrow(id, 20 * U, 8 days); // under 50% of ceiling[T1]
        _skipFresh(1 days);
        _repay(a);
        uint256 c = _borrow(id, 25 * U, 8 days); // repaid too soon
        _skipFresh(2 days);
        _repay(c);
        _skipFresh(5 days);
        _repay(b);
        v5.pokeFees(id);
        assertEq(_gen(id).countedAtTier, 0, "nothing counted");
        uint256 ep = lens.epochOf(block.timestamp);
        assertEq(lens.bookPoints(id, ep), 0, "no points");
        assertEq(lens.globalPoints(ep), 0);
        _skipFresh(10 days);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotPromotable.selector, 3));
        v5.promote(id);
    }

    // ------------------------------------------------------------------
    // row 3: back, then leave before a default
    // ------------------------------------------------------------------

    /// @dev Leaving stake stays burnable until released: a default before the release burns the leaver's 50%.
    function test_row3_leaveBeforeADefault_stillBurns() public {
        _open(id, 150_001 * T);
        _back(backer1, id, 20_000 * T);
        _skipFresh(1 days);
        uint256 l = _borrow(id, 50 * U, 8 days);
        vm.prank(backer1);
        v5.leave(id, 20_000 * T, 0);
        uint32 d = _today();
        // the release waits on the listed loan
        _skipFresh(7 days + 1);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.ReleaseNotReady.selector);
        v5.release(id, 1, d, 0, 0);
        _skipFresh(4 days);
        pool.markDefault(l);
        uint256 b0 = priors.balanceOf(backer1);
        vm.prank(backer1);
        v5.release(id, 1, d, 0, 0);
        assertEq(priors.balanceOf(backer1) - b0, 10_000 * T, "the leaver's half burned");
    }

    // ------------------------------------------------------------------
    // row 4: buy an aged agent
    // ------------------------------------------------------------------

    /// @dev A change of owner freezes the book: no borrow, no raise, backing moves to leaving, a default still burns
    ///      the original poster's A, and the buyer starts its own book at T1 after the reopen ban.
    function test_row4_buyAnAgedAgent_nothingToBuy() public {
        _open(id, 150_001 * T);
        _back(backer1, id, 20_000 * T);
        _skipFresh(1 days);
        uint256 l = _borrow(id, 40 * U, 8 days);
        address seller = _owner(id);
        uint256 buyerPk = 0xB0B;
        address buyer = vm.addr(buyerPk);
        _fundAccount(buyer);
        vm.prank(seller);
        reg.transferFrom(seller, buyer, id);
        v5.pokeFees(id);
        S.Gen memory g = _gen(id);
        assertTrue(g.ownerChanged);
        assertEq(g.counted[C.OTHERS], 0, "every backing position moved to leaving");
        assertFalse(v5.canBorrow(ROOT, id, 5 * U, 1 days, 1, buyer, buyer, buyer), "the buyer draws nothing");
        assertFalse(v5.canBorrow(ROOT, id, 5 * U, 1 days, 1, seller, seller, seller), "nor the seller");
        // the seller's default still burns its A
        uint256 b0 = _burned();
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        assertGe(_burned() - b0, M.burnOf(g.counted[C.OWNER], C.OWNER_BURN_BPS));
        // the buyer cannot open again before 30 days, and then only at T1
        pkOf[id] = buyerPk;
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 1)); // a defaulted agent never reopens
        v5.open(id, 150_001 * T, false, c, sig);
    }

    /// @dev The same without a default: the buyer's own book, after the ban, is T1.
    function test_row4_buyerStartsAtT1() public {
        _open(id, 150_001 * T);
        uint256 a = _borrow(id, 25 * U, 8 days);
        uint256 b = _borrow(id, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        _repay(b);
        uint256 c0 = _borrow(id, 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(c0);
        v5.promote(id);
        assertEq(_gen(id).tier, 2);
        address seller = _owner(id);
        uint256 buyerPk = 0xB0B;
        address buyer = vm.addr(buyerPk);
        _fundAccount(buyer);
        vm.prank(seller);
        reg.transferFrom(seller, buyer, id);
        vm.prank(anyone);
        v5.close(id, 1);
        _skipFresh(31 days);
        v5.finishClose(id, 1);
        pkOf[id] = buyerPk;
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(buyer);
        v5.open(id, 150_001 * T, false, c, sig);
        assertEq(_gen(id).tier, 1, "the new owner starts at T1");
    }

    // ------------------------------------------------------------------
    // row 5: fee skimming
    // ------------------------------------------------------------------

    /// @dev Stake backed just before a repayment earns none of its fee: it joins only inside a poke, after the split,
    ///      no sooner than 24 h after its deposit.
    function test_row5_feeSkimming_earnsNothing() public {
        _open(id, 150_001 * T);
        uint256 l = _borrow(id, 50 * U, 10 days);
        _skipFresh(10 days - 1 hours);
        _back(backer2, id, 140_000 * T); // a whale, an hour before the repayment
        _repay(l);
        v5.pokeFees(id);
        _skipFresh(1 days);
        v5.pokeFees(id);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint32[] memory gens = new uint32[](1);
        gens[0] = 1;
        vm.prank(backer2);
        assertEq(v5.collect(ids, gens), 0, "no share of a fee earned before it joined");
        uint256 o0 = usdg.balanceOf(_owner(id));
        vm.prank(_owner(id));
        uint256 paid = v5.collect(ids, gens);
        assertGt(paid, 0, "the owner's A earned it");
        assertEq(usdg.balanceOf(_owner(id)) - o0, paid);
    }

    // ------------------------------------------------------------------
    // row 6: crash window
    // ------------------------------------------------------------------

    /// @dev After a fall of spot, no line uses the old price: `canBorrow` values at live spot, the spot guard refuses
    ///      new stake under 0.80 × median, and `open` sizes at live spot.
    function test_row6_crashWindow_noStalePrice() public {
        _open(id, 150_001 * T);
        _setSpot(P0 / 5); // −80%, before any keeper pass
        assertFalse(v5.canBorrow(ROOT, id, 50 * U, 8 days, 1, _owner(id), _owner(id), _owner(id)), "line at spot");
        assertTrue(v5.canBorrow(ROOT, id, 5 * U, 8 days, 1, _owner(id), _owner(id), _owner(id)), "$5 at spot, k 3");
        uint256 other = agents[1];
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(other, ROOT, 0);
        vm.prank(_owner(other));
        vm.expectRevert(IV5Errors.SpotGuardOn.selector);
        v5.open(other, 150_001 * T, false, c, sig);
        vm.prank(backer1);
        vm.expectRevert(IV5Errors.SpotGuardOn.selector);
        v5.back(id, 10_000 * T, false);
    }

    // ------------------------------------------------------------------
    // row 7: pump the median
    // ------------------------------------------------------------------

    /// @dev P = min(spot, 24h median, week low): a pumped median, or spot and median pumped for a day, leave the
    ///      line at the week's low.
    function test_row7_pumpTheMedian_lineHeldAtTheWeekLow() public {
        _calmWeek();
        _open(id, 60_100 * T); // $60 at k 1.5: a $40 line
        assertEq(lens.lineOf(id), 40 * U);
        sizer.set(_sqrtFor(P0 * 2), _sqrtFor(P0 * 2));
        _skip(10 minutes);
        v5.sync();
        assertEq(lens.lineOf(id), 40 * U, "median 2x, spot not: P is spot");
        _setSpot(P0 * 2);
        assertEq(lens.lineOf(id), 40 * U, "spot and median 2x: the week low binds");
        assertFalse(v5.canBorrow(ROOT, id, 45 * U, 8 days, 1, _owner(id), _owner(id), _owner(id)));
    }

    // ------------------------------------------------------------------
    // row 8: push spot down (grief)
    // ------------------------------------------------------------------

    /// @dev A one-transaction dip sets no latch (only `sync()` writes it); a lower vouch never goes under the
    ///      principal out; the drawn loan and its repayment are untouched.
    function test_row8_pushSpotDown_griefOnly() public {
        _open(id, 150_001 * T);
        uint256 l = _borrow(id, 40 * U, 8 days);
        _setSpot(P0 * 85 / 100); // inside 0.80–0.90: no latch
        assertFalse(lens.spotGuardOn());
        vm.prank(backer1);
        v5.back(id, 10_000 * T, false); // not refused: over 0.80 × median
        _setSpot(P0 / 2);
        _skip(2 hours);
        vm.prank(anyone);
        v5.refresh(id);
        assertGe(pool.getAgent(id).delegatedIn, 40 * U, "never under the principal out");
        _setSpot(P0);
        _repay(l);
        assertEq(uint8(pool.getLoan(l).status), uint8(ICreditPoolV2.LoanStatus.Repaid));
    }

    // ------------------------------------------------------------------
    // row 11: self-backing across wallets
    // ------------------------------------------------------------------

    /// @dev The owner's second wallet backs as anyone does: no line, 50% burn, a share of fees only.
    function test_row11_selfBacking_noLine_halfBurn() public {
        _open(id, 150_001 * T);
        uint256 line0 = lens.lineOf(id);
        address wallet2 = makeAddr("ownersOtherWallet");
        _fundAccount(wallet2);
        _back(wallet2, id, 100_000 * T);
        _skipFresh(2 days);
        v5.pokeFees(id);
        assertEq(lens.lineOf(id), line0);
        assertEq(_gen(id).counted[C.OTHERS], 100_000 * T, "merged into B");
        uint256 l = _borrow(id, line0, 8 days);
        _skipFresh(11 days + 1);
        pool.markDefault(l);
        uint256 w0 = priors.balanceOf(wallet2);
        v5.claimSettled(id, 1, wallet2);
        assertEq(priors.balanceOf(wallet2) - w0, 50_000 * T);
    }

    // ------------------------------------------------------------------
    // row 22: squat the open room
    // ------------------------------------------------------------------

    /// @dev Opening books charges no room; the room is charged at a book's first borrow and never refunded.
    function test_row22_openRoomChargedAtFirstBorrow_neverRefunded() public {
        _open(agents[1], 150_001 * T);
        _open(agents[2], 150_001 * T);
        (, uint256 used0,,) = lens.rooms();
        assertEq(used0, 0, "opens charge nothing");
        _open(id, 150_001 * T);
        uint256 l = _borrow(id, 10 * U, 8 days);
        (, uint256 used1,,) = lens.rooms();
        assertEq(used1, 50 * U, "the line open approved, at the first borrow");
        // a second loan on the same book charges nothing more
        _borrow(id, 10 * U, 8 days);
        (, uint256 used2,,) = lens.rooms();
        assertEq(used2, used1);
        _repay(l);
        _repay(l + 1);
        vm.prank(_owner(id));
        v5.close(id, 0);
        (, uint256 used3,,) = lens.rooms();
        assertEq(used3, used1, "never refunded");
    }

    // ------------------------------------------------------------------
    // row 26: epoch over-allocation
    // ------------------------------------------------------------------

    /// @dev Points go into the epoch they are recorded in, only for counted loans, and are erased with the totals
    ///      when the book can no longer claim (here: a change of owner).
    function test_row26_pointsRecordedOnce_erasedWithTheTotals() public {
        _open(id, 150_001 * T);
        _open(agents[1], 150_001 * T);
        uint256 a = _borrow(id, 30 * U, 8 days);
        uint256 b = _borrow(agents[1], 30 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        _repay(b);
        v5.pokeFees(id);
        v5.pokeFees(agents[1]);
        uint256 ep = lens.epochOf(block.timestamp);
        uint256 pa = lens.bookPoints(id, ep);
        uint256 pb = lens.bookPoints(agents[1], ep);
        assertEq(pa, 30 * U * 8 days / 30 days);
        assertEq(lens.globalPoints(ep), pa + pb, "the total is the books' sum");
        v5.pokeFees(id);
        assertEq(lens.bookPoints(id, ep), pa, "each loan once");
        // a change of owner erases the book's points and lowers the total
        address o = _owner(id);
        vm.prank(o);
        reg.transferFrom(o, makeAddr("buyer"), id);
        v5.pokeFees(id);
        assertEq(lens.bookPoints(id, ep), 0);
        assertEq(lens.globalPoints(ep), pb);
        // five epochs later the slot belongs to a new epoch: the old one reads 0
        _skipFresh(35 days);
        assertEq(lens.globalPoints(ep + 5), 0);
    }
}
