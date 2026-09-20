// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// BETA MITIGATION — can the root-earned double-spend (ReviewPoC_RootEarnedDoubleSpend) be closed by an
/// owner-only parameter change, with no redeploy?
///
/// `isRoot = true` is assigned in exactly one place (CreditPool.sol:368, inside `enrollRoot`), and `enrollRoot`
/// refuses `stakeAmount < params.minStake`. The exploit needs a root that is not the treasury. So raising
/// `minStake` above any attacker's budget removes the only door into rootness — while `addStake` deliberately
/// does NOT re-check `minStake`, so the already-enrolled treasury can still be topped up by `sweep()`.
///
/// These tests hold that reasoning to account: the attack must fail, and everything beta needs must still work.
contract BetaMitigationMinStake is Test {
    uint256 constant USD = 1e6;
    uint256 constant DEPOSIT = 150 * USD; // live poolLiquidity
    uint256 constant RESERVE = 25 * USD; // live reserve
    uint256 constant TREASURY_STAKE = 25 * USD; // live treasury stake
    uint256 constant LOCKOUT = 1_000_000 * USD; // the mitigation: minStake nobody will post

    MockUSDC usdc;
    MockIdentityRegistry reg;
    CreditPool pool;

    address owner = makeAddr("owner");
    address lender = makeAddr("lender");
    address treasuryOp = makeAddr("treasuryOp");
    address attacker = makeAddr("attacker");
    address agentOp = makeAddr("agentOp");

    uint256 TREASURY;
    uint256 ATTACKER_ROOT;

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

        // the treasury enrols as a root BEFORE the lockout, exactly as it already has on mainnet
        usdc.mint(treasuryOp, 500 * USD);
        vm.startPrank(treasuryOp);
        usdc.approve(address(pool), type(uint256).max);
        TREASURY = reg.register("priors-treasury");
        pool.enrollRoot(TREASURY, TREASURY_STAKE);
        vm.stopPrank();

        usdc.mint(attacker, 1000 * USD);
        vm.startPrank(attacker);
        usdc.approve(address(pool), type(uint256).max);
        ATTACKER_ROOT = reg.register("ipfs://attacker-root");
        vm.stopPrank();
    }

    function _lockout() internal {
        CreditPool.Params memory p = pool.getParams();
        p.minStake = LOCKOUT;
        vm.prank(owner);
        pool.setParams(p);
    }

    /// The attack's first step is enrollRoot. After the lockout it cannot happen at any affordable price.
    function test_lockout_blocksTheOnlyDoorIntoRootness() public {
        _lockout();
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BelowMinStake.selector, 10 * USD, LOCKOUT));
        vm.prank(attacker);
        pool.enrollRoot(ATTACKER_ROOT, 10 * USD);

        // and not merely at the old price -- anything short of a million dollars is refused
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BelowMinStake.selector, 999_999 * USD, LOCKOUT));
        vm.prank(attacker);
        pool.enrollRoot(ATTACKER_ROOT, 999_999 * USD);
    }

    /// setParams does not bound minStake, so this must be provable rather than assumed: the lockout sticks.
    function test_lockout_isTheLiveValue() public {
        _lockout();
        assertEq(pool.getParams().minStake, LOCKOUT, "minStake");
    }

    /// The treasury is already enrolled, and addStake does not re-check minStake -- so sweep() keeps working
    /// and the operator can still grow the sponsor capacity that onboarding runs on.
    function test_lockout_treasuryCanStillBeToppedUp() public {
        _lockout();
        uint256 before = pool.getAgent(TREASURY).stake;
        vm.prank(treasuryOp);
        pool.addStake(TREASURY, 50 * USD);
        assertEq(pool.getAgent(TREASURY).stake, before + 50 * USD, "treasury stake grew after the lockout");
    }

    /// Everything the beta actually demonstrates still works: vouch a line, borrow, repay, earn.
    function test_lockout_normalAgentLifecycleStillWorks() public {
        _lockout();
        vm.prank(agentOp);
        uint256 agent = reg.register("https://priors.trade/agent");

        vm.prank(treasuryOp);
        pool.vouch(TREASURY, agent, 5 * USD);

        usdc.mint(agentOp, 1 * USD);
        vm.startPrank(agentOp);
        usdc.approve(address(pool), type(uint256).max);
        uint256 loan = pool.borrow(agent, 5 * USD, 7 days, agentOp);
        vm.warp(block.timestamp + 7 days);
        pool.repay(loan);
        vm.stopPrank();

        CreditPool.CreditReport memory r = pool.creditReport(agent);
        assertEq(r.loansRepaid, 1, "repaid");
        assertFalse(r.defaulted, "not defaulted");
        assertGt(r.score, 0, "scores");
    }

    /// The whole point: with the lockout in place the published PoC cannot be reproduced at all, because its
    /// first transaction reverts. This is the same sequence, asserted to die at step one.
    function test_lockout_defeatsThePublishedExploitSequence() public {
        _lockout();
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CreditPool.BelowMinStake.selector, 10 * USD, LOCKOUT));
        pool.enrollRoot(ATTACKER_ROOT, 10 * USD);
        vm.stopPrank();

        // no root => nothing to vouch from => the double-spend has no vehicle
        assertFalse(pool.getAgent(ATTACKER_ROOT).isRoot, "attacker is not a root");
        assertFalse(pool.getAgent(ATTACKER_ROOT).enrolled, "attacker is not enrolled");
    }

    /// Control: WITHOUT the lockout the same first step succeeds -- so the tests above are testing the
    /// mitigation, not some unrelated reason the attacker cannot enrol.
    function test_control_withoutLockoutTheAttackerBecomesARootFreely() public {
        vm.prank(attacker);
        pool.enrollRoot(ATTACKER_ROOT, 10 * USD);
        assertTrue(pool.getAgent(ATTACKER_ROOT).isRoot, "attacker IS a root without the lockout");
    }

    /// How many agents can the live treasury actually carry? A root may vouch only what it has free, so the
    /// binding constraint is its stake, not the 100 USDG epoch cap. At 25 USDG of stake and a 5 USDG first
    /// line that is 5 concurrent agents -- the number the beta plan has to be sized against.
    function test_capacity_treasuryStakeBoundsConcurrentAgents() public {
        _lockout();
        uint256 seated;
        for (uint256 i = 0; i < 12; i++) {
            vm.prank(agentOp);
            uint256 a = reg.register(string.concat("https://priors.trade/agent-", vm.toString(i)));
            if (pool.available(TREASURY) < 5 * USD) break;
            vm.prank(treasuryOp);
            pool.vouch(TREASURY, a, 5 * USD);
            seated++;
        }
        assertEq(seated, 5, "25 USDG of treasury stake seats exactly five 5 USDG lines");
        assertEq(pool.available(TREASURY), 0, "and then the treasury is out of room");
    }
}
