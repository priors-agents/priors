// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// A sponsor is first-loss for what it vouched. These tests hold that to account at the one place it was
/// escapable: `unvouch` used to bound the release by the CHILD's `available`, which counts the child's own
/// earned credit — so once a child had earned headroom, the sponsor could detach its backing from a loan
/// the child had already drawn, and the default then fell on the reserve instead of on the stake.
///
/// An audit measured it at $100 taken from the reserve for $0.084 of fees, with a stake that was never
/// lost and got recycled. The rule that closes it is the one `markDefault` already uses to decide
/// liability: a default charges `min(principal, delegatedIn)` to the sponsor, so delegation is the primary
/// backing for drawn principal, and exactly that much of it must stay put until the loan closes.
contract SponsorLiabilityTest is Test {
    uint256 constant USD = 1e6;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address rootOp = makeAddr("rootOp");
    address midOp = makeAddr("midOp");
    address leafOp = makeAddr("leafOp");

    uint256 ROOT;
    uint256 MID;
    uint256 LEAF;

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);

        _fund(lender, 200_000 * USD);
        vm.prank(lender);
        pool.deposit(100_000 * USD, lender);

        _fund(owner, 10_000 * USD);
        vm.prank(owner);
        pool.fundReserve(1_000 * USD);

        vm.prank(rootOp);
        ROOT = reg.register("ipfs://root");
        vm.prank(midOp);
        MID = reg.register("ipfs://mid");
        vm.prank(leafOp);
        LEAF = reg.register("ipfs://leaf");

        _fund(rootOp, 10_000 * USD);
        _fund(midOp, 10_000 * USD);
        _fund(leafOp, 10_000 * USD);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// Give MID `earned` capacity the honest way: borrow, hold past minSeasoning, repay.
    function _farmEarned(uint256 principal) internal {
        vm.prank(midOp);
        pool.borrow(MID, principal, 7 days, midOp);
        uint256 id = pool.loanCount();
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(id);
    }

    /* The exploit window only opens once the child's own earned credit is at least as large as what it
       has drawn — below that, the pre-existing `_available` check already refuses the unvouch, which is
       why a single farming round proves nothing. `maxEarnPerEpoch` is $25 against a 7-day epoch, so
       reaching $50 of earned takes two epochs. Getting this wrong is how the first version of this test
       passed against the unfixed contract for the wrong reason. */
    function _farmEarnedAcrossTwoEpochs() internal {
        _farmEarned(50 * USD);
        vm.warp(block.timestamp + 8 days);
        _farmEarned(50 * USD);
        assertGe(pool.creditReport(MID).earned, 50 * USD, "not enough earned to open the window");
    }

    // ---------------------------------------------------------------- the fix

    /// The exploit, in its minimal form. Before the fix this call succeeded and the stake walked out
    /// from under a live loan; now the release is capped at the delegation that is not covering drawn
    /// principal, and asking for more reverts.
    function test_unvouchCannotReleaseDelegationBackingALiveLoan() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 60 * USD);
        pool.vouch(ROOT, MID, 60 * USD);
        vm.stopPrank();

        _farmEarnedAcrossTwoEpochs(); // MID's own earned credit now covers what it is about to draw

        vm.prank(midOp);
        pool.borrow(MID, 50 * USD, 7 days, midOp); // 50 of the 60 delegation is now underwriting a loan

        // Only the 10 that is not covering drawn principal may come back.
        uint256 releasable = 60 * USD - 50 * USD;
        vm.prank(rootOp);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.DelegationInUse.selector, MID, 60 * USD, releasable));
        pool.unvouch(ROOT, MID, 60 * USD);

        vm.prank(rootOp);
        pool.unvouch(ROOT, MID, releasable); // the free slice is still returnable
        assertEq(pool.creditReport(MID).delegatedIn, 50 * USD, "the backing for the live loan stayed");
    }

    /// The point of the fix is not the revert, it is who pays. The sponsor's stake must absorb the
    /// default, not the reserve.
    function test_theStakeAbsorbsTheDefaultRatherThanTheReserve() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 60 * USD);
        pool.vouch(ROOT, MID, 60 * USD);
        vm.stopPrank();

        _farmEarnedAcrossTwoEpochs();
        vm.prank(midOp);
        pool.borrow(MID, 50 * USD, 7 days, midOp);
        uint256 live = pool.loanCount();

        /* The sponsor tries to get out by every route it has, GREEDILY - it asks for the whole
           delegation, not the polite slice the fixed contract allows. That is what makes this test
           discriminate: against the unfixed contract the 60 succeeds, the stake walks, and the reserve
           pays; against the fixed one it reverts and only the free 10 comes back. A version of this
           test that asked for 10 passed against the bug. */
        vm.startPrank(rootOp);
        try pool.unvouch(ROOT, MID, 60 * USD) {}
            catch {
            pool.unvouch(ROOT, MID, 10 * USD);
        }
        uint256 free = pool.available(ROOT);
        if (free > 0) pool.withdrawStake(ROOT, free, rootOp);
        vm.stopPrank();

        uint256 reserveBefore = pool.reserve();
        uint256 stakeBefore = pool.creditReport(ROOT).stake;
        vm.warp(block.timestamp + 7 days + 3 days + 1);
        pool.markDefault(live);

        uint256 slashed = stakeBefore - pool.creditReport(ROOT).stake;
        assertEq(slashed, 50 * USD, "the stake should have paid the whole 50");
        assertEq(reserveBefore, pool.reserve(), "the reserve must not have been touched");
        assertEq(pool.totalBadDebt(), 0, "no bad debt: the sponsor covered it");
    }

    /// The recycling loop the audit measured at ~1190x: one stake, two cycles, the reserve emptied.
    /// With the fix the second cycle cannot start, because the stake never comes free.
    function test_theStakeCannotBeRecycledWhileItIsCommitted() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 60 * USD);
        pool.vouch(ROOT, MID, 60 * USD);
        vm.stopPrank();

        _farmEarnedAcrossTwoEpochs();
        vm.prank(midOp);
        pool.borrow(MID, 50 * USD, 7 days, midOp);

        // Greedy again: take back everything the contract will give, then try to walk with the stake.
        vm.startPrank(rootOp);
        try pool.unvouch(ROOT, MID, 60 * USD) {}
            catch {
            pool.unvouch(ROOT, MID, 10 * USD);
        }
        uint256 free = pool.available(ROOT);
        if (free > 0) pool.withdrawStake(ROOT, free, rootOp);
        vm.stopPrank();

        assertGe(pool.creditReport(ROOT).stake, 50 * USD, "50 of stake must remain against the live loan");
    }

    // ---------------------------------------------------------------- a dead root still owes

    /// `markDefault` used to read "sponsor is dead" as "sponsor has nothing". For a root that is false: its
    /// stake is cash still sitting in the contract, still earmarked to this very child. The loss went to
    /// the reserve, and past the reserve to the lenders, while the stake stayed frozen in `totalStake`
    /// forever - owned by nobody reachable.
    function test_aDeadRootsEarmarkedStakeIsSlashedForItsChild() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 200 * USD);
        pool.vouch(ROOT, MID, 100 * USD); // 100 earmarked for MID, 100 left for the root itself
        pool.borrow(ROOT, 100 * USD, 7 days, rootOp); // the root draws its own free half
        vm.stopPrank();
        uint256 rootLoan = pool.loanCount();

        vm.prank(midOp);
        pool.borrow(MID, 100 * USD, 7 days, midOp);
        uint256 midLoan = pool.loanCount();

        vm.warp(block.timestamp + 7 days + 3 days + 1);

        pool.markDefault(rootLoan); // the root dies on its own loan; 100 of stake survives, earmarked
        assertTrue(pool.creditReport(ROOT).defaulted);
        assertEq(pool.creditReport(ROOT).stake, 100 * USD, "half the stake should survive");

        uint256 reserveBefore = pool.reserve();
        uint256 lenderBefore = pool.convertToAssets(pool.shares(lender));

        pool.markDefault(midLoan); // and now the child it was backing

        assertEq(pool.creditReport(ROOT).stake, 0, "the surviving stake must have been slashed for the child");
        assertEq(pool.totalBadDebt(), 0, "the stake covered it, so there is no bad debt");
        assertEq(pool.reserve(), reserveBefore, "the reserve must not have paid");
        assertGe(pool.convertToAssets(pool.shares(lender)), lenderBefore, "lenders must not have lost");
    }

    /// The same cascade, with the reserve empty, is where it used to reach the lenders. This is the
    /// strongest statement of the fix: with nothing behind the reserve, the stake is the only thing
    /// standing between a dead root's child and a lender's principal.
    function test_withAnEmptyReserveTheDeadRootsStakeStillProtectsLenders() public {
        // drain the reserve down to nothing first. The amount is read BEFORE the prank: an inner call in
        // the argument list consumes it, and withdrawReserve then runs as this contract and reverts.
        uint256 all = pool.reserve();
        vm.prank(owner);
        pool.withdrawReserve(all, owner);
        assertEq(pool.reserve(), 0, "the reserve should be empty for this test to mean anything");

        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 200 * USD);
        pool.vouch(ROOT, MID, 100 * USD);
        pool.borrow(ROOT, 100 * USD, 7 days, rootOp);
        vm.stopPrank();
        uint256 rootLoan = pool.loanCount();

        vm.prank(midOp);
        pool.borrow(MID, 100 * USD, 7 days, midOp);
        uint256 midLoan = pool.loanCount();

        vm.warp(block.timestamp + 7 days + 3 days + 1);
        pool.markDefault(rootLoan);

        uint256 lenderBefore = pool.convertToAssets(pool.shares(lender));
        pool.markDefault(midLoan);

        assertEq(pool.totalBadDebt(), pool.totalReserveCovered(), "lenders never lose");
        assertEq(pool.convertToAssets(pool.shares(lender)), lenderBefore, "the lender's claim did not move");
        assertEq(pool.totalStake(), 0, "no stake left stranded in the books");
    }

    // ---------------------------------------------------------------- the honest path still works

    /// A sponsor whose child has drawn nothing gets all of it back. This is the case the treasury's own
    /// `reclaim()` uses — it gates on `activeLoans == 0` and then unvouches the full delegation, so if
    /// this breaks, the treasury's idle-line recovery breaks with it.
    function test_anUndrawnDelegationIsFullyReturnable() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 60 * USD);
        pool.vouch(ROOT, MID, 60 * USD);
        pool.unvouch(ROOT, MID, 60 * USD);
        vm.stopPrank();
        assertEq(pool.creditReport(MID).delegatedIn, 0, "an unused line did not come back");
        assertEq(pool.available(ROOT), 60 * USD, "the stake did not come free");
    }

    /// And once the loan is repaid, the rest follows.
    function test_repayingReleasesTheBackingAgain() public {
        vm.startPrank(rootOp);
        pool.enrollRoot(ROOT, 60 * USD);
        pool.vouch(ROOT, MID, 60 * USD);
        vm.stopPrank();

        _farmEarned(50 * USD);
        vm.prank(midOp);
        pool.borrow(MID, 50 * USD, 7 days, midOp);
        uint256 id = pool.loanCount();
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(id);

        vm.prank(rootOp);
        pool.unvouch(ROOT, MID, 60 * USD); // nothing drawn any more
        assertEq(pool.creditReport(MID).delegatedIn, 0);
    }
}
