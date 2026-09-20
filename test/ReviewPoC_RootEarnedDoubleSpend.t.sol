// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// Was the security-review PoC for the root earned double-spend; now the regression guard for its fix.
///
/// THE DEFECT: a root sponsor may vouch out `stake + earned`. When the child defaulted, markDefault
/// clamped the root's liability to its `stake` and charged the shortfall to the reserve - but never
/// retired the root's `earned`. The same earned credit therefore backed a delegation that defaulted
/// AND remained the root's own borrowing capacity: the reserve paid for it twice, `reserve >=
/// totalEarned` broke, and lenders lost principal.
///
/// Note what was NOT wrong: `vouch()` letting a root delegate more than its `earned`. A root's stake is
/// real cash backing, so delegating stake + earned delegates real backing. The accounting on default was
/// incomplete, not the permission.
///
/// THE FIX (CreditPool.markDefault): whatever the root's stake cannot cover is written off against the
/// root's `earned`, keeping `totalEarned` in step so the reserve backs it exactly once.
///
/// These tests run the original attack move for move and assert it is now contained.
contract ReviewPoCRootEarnedDoubleSpend is Test {
    uint256 constant USD = 1e6;
    uint256 constant DEPOSIT = 150 * USD; // live poolLiquidity
    uint256 constant RESERVE = 25 * USD; // live reserve

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address attacker = makeAddr("attacker");

    uint256 ROOT;
    uint256 CHILD;

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

        // attacker's own capital: 10 USDG of root stake + small change for loan fees
        usdc.mint(attacker, 11 * USD);
        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        ROOT = reg.register("ipfs://attacker-root");
        CHILD = reg.register("ipfs://attacker-child");
        vm.stopPrank();
    }

    /// borrow `amt` for one day, hold exactly minSeasoning, repay -> grows `earned` by growthBps
    function _farm(uint256 amt) internal {
        vm.startPrank(attacker);
        uint256 id = pool.borrow(ROOT, amt, 1 days, attacker);
        vm.warp(block.timestamp + 1 days);
        pool.repay(id);
        vm.stopPrank();
    }

    /// The reserve is what backs earned credit. It must always cover every live unit of it.
    function _assertReserveCoversEarned(string memory when) internal view {
        assertGe(pool.reserve(), pool.totalEarned(), string.concat("INVARIANT reserve >= totalEarned broken ", when));
    }

    function test_rootEarnedIsRetiredWhenItsDelegationDefaults() public {
        vm.prank(attacker);
        pool.enrollRoot(ROOT, 10 * USD);

        _farm(10 * USD); // +5
        _farm(15 * USD); // +7.5
        _farm(22 * USD); // +11  (epoch room)
        _farm(33 * USD); // +1.5 (hits reserveRoom/epoch cap)

        CreditPool.Agent memory r = pool.getAgent(ROOT);
        assertEq(r.stake, 10 * USD, "stake");
        assertEq(r.earned, 25 * USD, "earned farmed to the reserve ceiling");
        assertEq(pool.available(ROOT), 35 * USD, "a root may borrow OR vouch stake + earned");
        _assertReserveCoversEarned("before the attack");

        // the original move: vouch the full capacity out, draw it, walk away
        vm.prank(attacker);
        pool.vouch(ROOT, CHILD, 35 * USD);
        vm.prank(attacker);
        uint256 childLoan = pool.borrow(CHILD, 35 * USD, 1 days, attacker);
        vm.warp(block.timestamp + 1 days + 3 days + 1); // term + grace
        pool.markDefault(childLoan);

        // THE FIX: the stake covered 10 of the 35; the remaining 25 stood on the root's earned
        // credit, so that earned is written off rather than left to be spent again.
        assertEq(pool.getAgent(ROOT).earned, 0, "the root's earned was retired with the delegation");
        assertEq(pool.totalEarned(), 0, "totalEarned follows");
        assertEq(pool.getAgent(ROOT).stake, 0, "stake was slashed");
        assertEq(pool.available(ROOT), 0, "nothing left to spend a second time");
        _assertReserveCoversEarned("after the default");

        // the second half of the double-spend is now impossible
        vm.prank(attacker);
        vm.expectRevert();
        pool.borrow(ROOT, 25 * USD, 1 days, attacker);

        // and the loss landed where it is supposed to: the first-loss reserve, not the lenders
        assertEq(pool.totalBadDebt(), 25 * USD, "the uncovered slice is bad debt");
        assertEq(pool.totalReserveCovered(), 25 * USD, "and the reserve covered all of it");
        assertGe(pool.convertToAssets(pool.shares(lender)), DEPOSIT, "INVARIANT lenders never lose principal broken");
    }

    /// `fundReserve` is permissionless, so an attacker can still raise the earned ceiling with their own
    /// money. That is by design - it is their money at risk first. What must not happen is lenders paying.
    function test_fundingTheReserveCannotBeTurnedIntoLenderLosses() public {
        uint256 TARGET_EARNED = 140 * USD;
        usdc.mint(attacker, 115 * USD + 10 * USD + 5 * USD);

        vm.startPrank(attacker);
        pool.fundReserve(115 * USD); // lifts the earned ceiling to 140
        pool.enrollRoot(ROOT, 10 * USD);
        vm.stopPrank();

        for (uint256 epoch = 0; epoch < 12 && pool.getAgent(ROOT).earned < TARGET_EARNED; epoch++) {
            for (uint256 k = 0; k < 4; k++) {
                uint256 before = pool.getAgent(ROOT).earned;
                if (before >= TARGET_EARNED) break;
                uint256 amt = pool.available(ROOT);
                if (amt > 50 * USD) amt = 50 * USD;
                if (amt < 5 * USD) break;
                _farm(amt);
                if (pool.getAgent(ROOT).earned == before) break; // epoch cap reached
            }
            vm.warp(block.timestamp + 7 days);
        }
        assertGe(pool.getAgent(ROOT).earned, TARGET_EARNED, "farmed");
        _assertReserveCoversEarned("after farming");

        uint256 line = pool.available(ROOT);
        vm.prank(attacker);
        pool.vouch(ROOT, CHILD, line);
        uint256 draw = line > pool.poolLiquidity() ? pool.poolLiquidity() : line;
        vm.prank(attacker);
        uint256 childLoan = pool.borrow(CHILD, draw, 1 days, attacker);
        vm.warp(block.timestamp + 4 days + 1);
        pool.markDefault(childLoan);

        _assertReserveCoversEarned("after the default at scale");
        assertGe(
            pool.convertToAssets(pool.shares(lender)), DEPOSIT, "INVARIANT lenders never lose principal broken at scale"
        );

        // whatever capacity survives is backed; draining it again must not reach the lender book
        uint256 second = pool.available(ROOT);
        if (second >= 5 * USD) {
            if (second > pool.poolLiquidity()) second = pool.poolLiquidity();
            vm.prank(attacker);
            uint256 rootLoan = pool.borrow(ROOT, second, 1 days, attacker);
            vm.warp(block.timestamp + 4 days + 1);
            pool.markDefault(rootLoan);
        }
        assertGe(pool.convertToAssets(pool.shares(lender)), DEPOSIT, "INVARIANT lenders never lose principal broken");
        _assertReserveCoversEarned("at the end");
    }
}
