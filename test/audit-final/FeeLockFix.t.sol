// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {CreditPoolV2Base} from "../CreditPoolV2.t.sol";

/// The 2026-09-24 fix for final-audit N-1 (self-default was free): a borrow locks its fee out of the backer's free
/// backing, repay releases it, and a default burns the backer's shares worth principal + fee, so the unpaid fee
/// accrues to the remaining shares. RED on the pre-fix pool: `feeLocked` does not exist there (compile error), and
/// the audit PoC `test_N1_selfLoopStealsLenderYield_atZeroCost` passed (final audit, 2026-09-24).
contract FeeLockFixTest is CreditPoolV2Base {
    function setUp() public override {
        super.setUp();
        CreditPoolV2.Params memory p = _params();
        p.keeperBounty = 0; // launch value; keeps the reserve out of the accounting below
        vm.prank(owner);
        pool.setParams(p);
    }

    function _fee(uint256 principal, uint64 term) internal view returns (uint256 fee) {
        (fee,,,) = pool.quoteFee(AGENT, principal, term);
    }

    function test_borrow_locksTheFee_visibleInFreeBacking() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        uint256 freeBefore = pool.freeBacking(ROOT);
        uint256 l = _borrow(agentOwner, AGENT, 50 * USDC, 30 days);
        uint256 fee = pool.getLoan(l).fee;
        assertGt(fee, 0);
        assertEq(pool.feeLocked(ROOT), fee, "the loan's fee is locked on its backer");
        assertEq(pool.freeBacking(ROOT), freeBefore - fee, "and held out of the free backing");
        assertEq(pool.freeBacking(ROOT), pool.backing(ROOT) - pool.getAgent(ROOT).delegatedOut - fee);
    }

    function test_borrow_revertsWhenFreeBackingIsBelowTheFee() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC); // the whole stake vouched: free backing 0
        uint256 fee = _fee(50 * USDC, 30 days);
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientBacking.selector, ROOT, fee, 0));
        pool.borrow(AGENT, 50 * USDC, 30 days, agentOwner, type(uint256).max);

        vm.prank(rootOwner);
        pool.addStake(ROOT, fee - 1); // one unit short
        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientBacking.selector, ROOT, fee, fee - 1));
        pool.borrow(AGENT, 50 * USDC, 30 days, agentOwner, type(uint256).max);

        vm.prank(rootOwner);
        pool.addStake(ROOT, 1);
        _borrow(agentOwner, AGENT, 50 * USDC, 30 days); // exactly the fee fits
        assertEq(pool.freeBacking(ROOT), 0);
    }

    function test_repay_releasesTheLock() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 50 * USDC, 30 days);
        uint256 locked = pool.freeBacking(ROOT);
        vm.warp(block.timestamp + 30 days);
        _repay(agentOwner, l);
        assertEq(pool.feeLocked(ROOT), 0, "released");
        assertGe(pool.freeBacking(ROOT), locked + pool.getLoan(l).fee, "the fee is free backing again");
        // with the line withdrawn every share comes out: nothing stays locked
        vm.startPrank(rootOwner);
        pool.unvouch(ROOT, AGENT, 50 * USDC);
        pool.unlock(ROOT, pool.rootShares(ROOT), rootOwner);
        vm.stopPrank();
        assertEq(pool.rootShares(ROOT), 0);
    }

    /// The default burns shares worth principal + fee at the pre-default price. The principal left the pool as the
    /// loan; the fee's worth stays in it, so the remaining shares, lenders' included, gain exactly the fee.
    function test_default_burnsPrincipalPlusFee_remainingSharesGainTheFee() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 50 * USDC, 7 days);
        uint256 p = pool.getLoan(l).principal;
        uint256 fee = pool.getLoan(l).fee;
        uint256 ta = pool.totalAssets();
        uint256 ts = pool.totalShares();
        uint256 rootShares0 = pool.rootShares(ROOT);
        uint256 lenderValue = pool.convertToAssets(pool.shares(lender));

        _default(l);

        uint256 burnt = rootShares0 - pool.rootShares(ROOT);
        assertEq(burnt, ts - pool.totalShares(), "only the backer's shares are burnt");
        assertApproxEqAbs(burnt * ta / ts, p + fee, 1, "worth principal + fee at the pre-default price");
        assertEq(pool.feeLocked(ROOT), 0, "released");
        // remaining shares: worth (ts - burnt) * ta / ts before, totalAssets() after; the difference is the fee
        assertApproxEqAbs(pool.totalAssets(), (ts - burnt) * ta / ts + fee, 2, "remaining shares gain the fee");
        uint256 lenderGain = pool.convertToAssets(pool.shares(lender)) - lenderValue;
        assertApproxEqAbs(lenderGain, fee * pool.shares(lender) / pool.totalShares(), 2, "lenders' pro-rata cut");
        assertGt(lenderGain, 0);
    }

    function test_unlock_cannotTakeTheLockedFee() public {
        vm.prank(rootOwner);
        pool.addStake(ROOT, 1 * USDC); // 1 USDG of headroom
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC);
        _borrow(agentOwner, AGENT, 50 * USDC, 30 days);
        uint256 fee = pool.feeLocked(ROOT);
        assertGt(fee, 0);

        uint256 headroom = pool.convertToShares(1 * USDC); // everything above the line, fee included
        vm.prank(rootOwner);
        vm.expectPartialRevert(CreditPoolV2.InsufficientBacking.selector);
        pool.unlock(ROOT, headroom, rootOwner);

        uint256 free = pool.convertToShares(1 * USDC - fee) - 1; // the headroom less the locked fee
        vm.prank(rootOwner);
        pool.unlock(ROOT, free, rootOwner);
        assertGe(pool.backing(ROOT), 100 * USDC + fee, "the line and the locked fee stay staked");
    }

    function test_headroomForOneFee_oneLoanOpenNotTwo() public {
        uint256 fee = _fee(50 * USDC, 30 days);
        vm.prank(rootOwner);
        pool.addStake(ROOT, fee); // headroom for exactly one fee
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC); // the whole old stake vouched
        uint256 first = _borrow(agentOwner, AGENT, 50 * USDC, 30 days);

        vm.prank(agentOwner);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientBacking.selector, ROOT, fee, 0));
        pool.borrow(AGENT, 50 * USDC, 30 days, agentOwner, type(uint256).max);

        vm.warp(block.timestamp + 1 days);
        _repay(agentOwner, first); // releases the lock
        uint256 second = _borrow(agentOwner, AGENT, 50 * USDC, 30 days);
        assertEq(pool.feeLocked(ROOT), pool.getLoan(second).fee, "one loan's fee locked");
    }
}
