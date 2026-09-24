// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../../src/mocks/MockIdentityRegistry.sol";
import {MockPonsFeeEscrow} from "../../src/mocks/MockPonsFeeEscrow.sol";
import {IERC8004Identity} from "../../src/interfaces/IERC8004Identity.sol";
import {TreasuryV4Base} from "../TreasurySponsorV4.t.sol";

/// Final pre-mainnet audit, 2026-09-24: treasury v4 on a pool with a real v1 behind it (the importFromV1 path).
contract FinalAuditTreasuryImport is TreasuryV4Base {
    CreditPool v1;
    address v1Owner = makeAddr("v1-safe");
    uint256 v1Root;

    function setUp() public override {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        escrow = new MockPonsFeeEscrow();
        v1 = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), v1Owner);
        _deployPool(v1);
        _setUpTreasury();
        vm.startPrank(timelock);
        _setBountyZero(); // launch value
        vm.stopPrank();

        // a v1 history: 3 week-long 5 USDG loans, repaid, before the cutover
        usdc.mint(rootOp, 1_000 * USDC);
        vm.startPrank(rootOp);
        usdc.approve(address(v1), type(uint256).max);
        v1.deposit(500 * USDC, rootOp);
        v1Root = reg.register("v1-root");
        v1.enrollRoot(v1Root, 50 * USDC);
        v1.vouch(v1Root, AGENT, 10 * USDC);
        vm.stopPrank();
        vm.prank(agentOp);
        usdc.approve(address(v1), type(uint256).max);
        for (uint256 i; i < 3; i++) {
            vm.prank(agentOp);
            uint256 l = v1.borrow(AGENT, 5 * USDC, 7 days, agentOp);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            vm.prank(agentOp);
            v1.repay(l);
        }
        vm.prank(v1Owner);
        v1.pause(); // runbook 1.2
    }

    function _setBountyZero() internal {
        CreditPoolV2.Params memory p = pool.getParams();
        p.keeperBounty = 0;
        pool.setParams(p);
    }

    /// Info (T10 variant, not a larger bound): an imported v1 record with 3 qualified loans passes `raise` the
    /// moment `firstLine` lands, with no v2 loan and no seasoning on v2. Runbook §6 never calls `setSeeded`, and
    /// `seeded` only covers protocol-seeded records anyway. The loss per invite is the same `secondLine` as T10,
    /// and still bounded by `epochCap`.
    function test_N4_importedRecordRaisesImmediatelyAfterFirstLine() public {
        _funded();
        pool.importFromV1(AGENT);
        assertEq(pool.getAgent(AGENT).qualifiedRepaid, 3);
        _firstLine(AGENT, AGENT_PK);
        assertTrue(treasury.eligibleForRaise(AGENT), "eligible in the same block as the first line");
        treasury.raise(AGENT);
        assertEq(_line(AGENT), 50 * USDC);

        uint256 before = pool.backing(TREASURY_ID);
        uint256 loan = _borrow(agentOp, AGENT, 50 * USDC, 1 days);
        _default(loan);
        assertGe(before - pool.backing(TREASURY_ID), 50 * USDC - 1, "treasury stake loses the whole second line");
    }
}
