// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// Default accounting across interacting cases: a defaulting agent's backing is consumed one liable slice per
/// loan, the rest keeps backing its other open loans, and whatever is left is released once the last one
/// closes. Lenders must never lose principal while loans are fully stake-backed.
contract DefaultAccountingTest is Test {
    uint256 constant USDC = 1e6;
    uint256 constant DEPOSIT = 10_000 * USDC;
    uint256 constant RESERVE = 1_000 * USDC;

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address rootOp = makeAddr("rootOp");
    address midOp = makeAddr("midOp");
    address leafOp = makeAddr("leafOp");
    address otherOp = makeAddr("otherOp");

    uint256 ROOT;
    uint256 MID;
    uint256 LEAF;
    uint256 OTHER;

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);
        usdc.mint(lender, DEPOSIT);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(DEPOSIT, lender);
        vm.stopPrank();
        usdc.mint(owner, RESERVE);
        vm.startPrank(owner);
        usdc.approve(address(pool), type(uint256).max);
        pool.fundReserve(RESERVE);
        vm.stopPrank();
        vm.prank(rootOp);
        ROOT = reg.register("ipfs://root");
        vm.prank(midOp);
        MID = reg.register("ipfs://mid");
        vm.prank(leafOp);
        LEAF = reg.register("ipfs://leaf");
        vm.prank(otherOp);
        OTHER = reg.register("ipfs://other");
        address[4] memory ops = [rootOp, midOp, leafOp, otherOp];
        for (uint256 i = 0; i < ops.length; i++) {
            usdc.mint(ops[i], 5_000 * USDC);
            vm.prank(ops[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function _borrow(address op, uint256 agent, uint256 amt, uint64 term) internal returns (uint256 id) {
        vm.prank(op);
        id = pool.borrow(agent, amt, term, op);
    }

    function _lendersWhole() internal view {
        assertEq(pool.totalAssets(), DEPOSIT + pool.totalFeesEarned(), "lenders lost principal");
        assertEq(pool.totalBadDebt(), pool.totalReserveCovered(), "bad debt not fully covered");
    }

    function _drainReserve() internal {
        uint256 free = pool.reserve() - pool.totalEarned();
        vm.prank(owner);
        pool.withdrawReserve(free, owner);
    }

    // ------------------------------------------------------------------ the review's counterexample, and neighbours

    /// Two loans on one delegation, both default, reserve gone: the root pays for both, lenders lose nothing.
    function test_twoDefaults_rootPaysBoth() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        _drainReserve();
        uint256 a = _borrow(midOp, MID, 50 * USDC, 1 days);
        uint256 b = _borrow(midOp, MID, 50 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a);
        // after the first default: 50 of the delegation consumed, 50 still backing loan b
        assertEq(pool.getAgent(MID).delegatedIn, 50 * USDC);
        assertEq(pool.getAgent(ROOT).delegatedOut, 50 * USDC);
        assertEq(pool.getAgent(ROOT).stake, 50 * USDC);
        pool.markDefault(b);
        assertEq(pool.getAgent(ROOT).stake, 0);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        assertEq(pool.getAgent(MID).delegatedIn, 0);
        _lendersWhole();
    }

    /// Partial: loans smaller than the delegation. Each default consumes its own slice; the leftover goes
    /// back to the root once the agent has nothing open.
    function test_partialDefaults_leftoverReturnsToRoot() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        _drainReserve();
        uint256 a = _borrow(midOp, MID, 30 * USDC, 1 days);
        uint256 b = _borrow(midOp, MID, 50 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a);
        assertEq(pool.getAgent(ROOT).delegatedOut, 70 * USDC);
        assertEq(pool.available(ROOT), 0, "root capacity stays locked while the agent has an open loan");
        pool.markDefault(b);
        // 80 slashed, the unused 20 of delegation released: the root has 20 stake and nothing delegated
        assertEq(pool.getAgent(ROOT).stake, 20 * USDC);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        assertEq(pool.available(ROOT), 20 * USDC);
        _lendersWhole();
    }

    /// Repayment after a default: the second loan is paid, the sponsor's remaining backing is released,
    /// and the dead agent earns nothing from it.
    function test_repayAfterDefault_releasesBacking_noGrowth() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        _drainReserve();
        uint256 a = _borrow(midOp, MID, 50 * USDC, 1 days);
        uint256 b = _borrow(midOp, MID, 50 * USDC, 7 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a);
        assertEq(pool.getAgent(ROOT).delegatedOut, 50 * USDC);
        vm.prank(midOp);
        pool.repay(b);
        CreditPool.Agent memory m = pool.getAgent(MID);
        assertTrue(m.defaulted);
        assertEq(m.activeLoans, 0);
        assertEq(m.delegatedIn, 0);
        assertEq(m.earned, 0);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0);
        assertEq(pool.getAgent(ROOT).stake, 50 * USDC);
        assertEq(pool.available(ROOT), 50 * USDC);
        assertEq(pool.score(MID), 0);
        _lendersWhole();
    }

    /// A sponsor cannot pull the backing out from under a dead agent's open loan.
    function test_unvouchDeadAgent_reverts() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        uint256 a = _borrow(midOp, MID, 50 * USDC, 1 days);
        _borrow(midOp, MID, 50 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a);
        vm.prank(rootOp);
        vm.expectRevert();
        pool.unvouch(ROOT, MID, 1);
        vm.prank(rootOp);
        vm.expectRevert();
        pool.withdrawStake(ROOT, 1, rootOp);
    }

    /// Two children on one root: one child's defaults never touch the other child's line.
    function test_multipleChildren_isolated() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, OTHER, 100 * USDC);
        _drainReserve();
        uint256 a = _borrow(midOp, MID, 50 * USDC, 1 days);
        uint256 b = _borrow(midOp, MID, 50 * USDC, 1 days);
        uint256 c = _borrow(otherOp, OTHER, 60 * USDC, 7 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a);
        pool.markDefault(b);
        assertEq(pool.getAgent(OTHER).delegatedIn, 100 * USDC);
        assertEq(pool.capacity(OTHER), 100 * USDC);
        assertEq(pool.getAgent(ROOT).delegatedOut, 100 * USDC);
        assertEq(pool.getAgent(ROOT).stake, 100 * USDC);
        vm.prank(otherOp);
        pool.repay(c);
        _lendersWhole();
    }

    /// A sub-sponsor backing a leaf from earned credit: each default becomes its own recourse loan for the
    /// liable slice; paying them keeps lenders whole, and the leftover delegation is released after.
    function test_subSponsor_recoursePerDefault() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        // MID earns 50 over two epochs
        uint256 r1 = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(r1);
        vm.warp(block.timestamp + 7 days);
        uint256 r2 = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(r2);
        assertEq(pool.getAgent(MID).earned, 50 * USDC);
        vm.prank(midOp);
        pool.vouch(MID, LEAF, 40 * USDC);
        uint256 a = _borrow(leafOp, LEAF, 15 * USDC, 1 days);
        uint256 b = _borrow(leafOp, LEAF, 15 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        uint256 loansBefore = pool.loanCount();
        pool.markDefault(a);
        pool.markDefault(b);
        assertEq(pool.loanCount(), loansBefore + 2, "one recourse loan per default");
        uint256 rA = loansBefore + 1;
        uint256 rB = loansBefore + 2;
        assertTrue(pool.getLoan(rA).isRecourse && pool.getLoan(rB).isRecourse);
        CreditPool.Agent memory m = pool.getAgent(MID);
        assertEq(m.principalOut, 30 * USDC, "sponsor owes both liable slices");
        assertEq(m.delegatedOut, 0, "unused 10 of the delegation released once the leaf had nothing open");
        assertEq(m.childrenDefaulted, 2);
        // MID pays its recourse
        vm.prank(midOp);
        pool.repay(rA);
        vm.prank(midOp);
        pool.repay(rB);
        assertEq(pool.getAgent(MID).recourseHonored, 2);
        _lendersWhole();
    }

    /// Sponsor already dead: nobody to charge, the reserve takes it, bad debt equals what the reserve paid.
    function test_deadSponsor_reserveCovers() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        uint256 r1 = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(r1);
        vm.warp(block.timestamp + 7 days);
        uint256 r2 = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(r2);
        vm.prank(midOp);
        pool.vouch(MID, LEAF, 40 * USDC);
        uint256 leafLoan = _borrow(leafOp, LEAF, 40 * USDC, 1 days);
        uint256 midLoan = _borrow(midOp, MID, 20 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(midLoan); // MID dies first
        assertTrue(pool.getAgent(MID).defaulted);
        pool.markDefault(leafLoan); // its child's loan has nobody left to charge
        assertEq(pool.totalBadDebt(), 40 * USDC);
        _lendersWhole();
    }

    /// A root defaulting on its own loans: stake is slashed loan by loan.
    function test_rootDefaults_perLoan() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 100 * USDC);
        _drainReserve();
        uint256 a = _borrow(rootOp, ROOT, 40 * USDC, 1 days);
        uint256 b = _borrow(rootOp, ROOT, 40 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a);
        assertEq(pool.getAgent(ROOT).stake, 60 * USDC);
        pool.markDefault(b);
        assertEq(pool.getAgent(ROOT).stake, 20 * USDC);
        _lendersWhole();
    }

    /// The reserve lock survives a first default: a dead agent's earned-backed open loan keeps its reserve
    /// coverage, so the owner cannot withdraw the reserve out from under it.
    function test_reserveLock_keepsCoveringOpenEarnedLoans() public {
        vm.prank(rootOp);
        pool.enrollRoot(ROOT, 200 * USDC);
        vm.prank(rootOp);
        pool.vouch(ROOT, MID, 100 * USDC);
        uint256 r1 = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(r1);
        vm.warp(block.timestamp + 7 days);
        uint256 r2 = _borrow(midOp, MID, 100 * USDC, 7 days);
        vm.warp(block.timestamp + 2 days);
        vm.prank(midOp);
        pool.repay(r2);
        assertEq(pool.getAgent(MID).earned, 50 * USDC);
        // capacity 150: 100 delegated + 50 earned. Borrow all of it as two loans.
        uint256 a = _borrow(midOp, MID, 100 * USDC, 1 days);
        uint256 b = _borrow(midOp, MID, 50 * USDC, 1 days);
        vm.warp(block.timestamp + 5 days);
        pool.markDefault(a); // fully covered by the delegation; earned credit still counts
        assertEq(pool.getAgent(MID).earned, 50 * USDC);
        assertEq(pool.totalEarned(), 50 * USDC);
        // the owner can drain the reserve only down to totalEarned
        uint256 free = pool.reserve() - pool.totalEarned();
        vm.prank(owner);
        vm.expectRevert();
        pool.withdrawReserve(free + 1, owner);
        vm.prank(owner);
        pool.withdrawReserve(free, owner);
        pool.markDefault(b); // 50 with no delegation left: the reserve covers it, earned credit retired
        assertEq(pool.getAgent(MID).earned, 0);
        assertEq(pool.totalEarned(), 0);
        assertEq(pool.reserve(), 0);
        _lendersWhole();
    }
}
