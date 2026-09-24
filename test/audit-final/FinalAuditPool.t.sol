// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2, IBackerHook} from "../../src/CreditPoolV2.sol";
import {CreditPoolV2Base} from "../CreditPoolV2.t.sol";

/// Final pre-mainnet audit, 2026-09-24. Sources audited: CreditPoolV2 a613bb7c…, PoolV2Lib d8e3bd1f…,
/// TreasurySponsorV4 23632b36…, CreditLensV2 917d86f0… (unchanged since the 2026-09-23 exploit audit).
///
/// Launch parameters throughout: v1's params (5-500 USDG, 1-30 d, grace 3 d, 1%/30 d, 25% sponsor, 15% reserve,
/// minStake 10), maxUtilizationBps 9000, keeperBounty 0, and a keeper that marks every default the second it can.
///
/// `test_N*` PASS by demonstrating an exploit. `test_R*` PASS by demonstrating a refutation. `test_N*_fixed` PASS by
/// demonstrating that the exploit is closed by the 2026-09-24 fee lock (`CreditPoolV2.feeLocked`: a borrow holds its
/// fee out of the backer's free backing, and a default burns the backer's shares worth principal + fee).
contract FinalAuditPool is CreditPoolV2Base {
    uint256 constant ATK_PK = 0xA77AC;
    uint256 constant CAPITAL = 500e6; // the attacker's whole capital: one maxLoan
    address atk;
    uint256 atkRoot;
    uint256 atkAgent;
    uint256[] atkLoans;

    function setUp() public override {
        super.setUp();
        CreditPoolV2.Params memory p = _params();
        p.keeperBounty = 0; // launch value (runbook §0.1, DeployV2.s.sol:54)
        vm.prank(owner);
        pool.setParams(p);

        atk = vm.addr(ATK_PK);
        usdc.mint(atk, CAPITAL);
        vm.startPrank(atk);
        usdc.approve(address(pool), type(uint256).max);
        atkRoot = reg.register("atk-root");
        atkAgent = reg.register("atk-agent"); // same EOA owns the backer and the borrower
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // The loop: stake C, lend it to yourself, stake it again, ...
    // ------------------------------------------------------------------

    function _roomAfterStake(uint256 amt) internal view returns (bool) {
        uint256 ta = pool.totalAssets() + amt; // the stake lands first
        return (pool.totalPrincipalOut() + amt) * 10_000 <= pool.getParams().maxUtilizationBps * ta;
    }

    function _fee30(uint256 amount) internal view returns (uint256 fee) {
        (fee,,,) = pool.quoteFee(atkAgent, amount, 30 days);
    }

    /// The loop as the audit wrote it: stake C, vouch all of it, borrow it back. Since the fee lock the root has no
    /// free backing left for the fee, so the very first self-loan reverts.
    function _expectZeroHeadroomLoopReverts() internal {
        vm.prank(atk);
        pool.enrollRoot(atkRoot, CAPITAL);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(atkAgent, atkRoot, ATK_PK, 0);
        vm.prank(atk);
        pool.vouchWithConsent(atkRoot, atkAgent, CAPITAL, 0, c, sig);
        uint256 fee = _fee30(CAPITAL);
        vm.prank(atk);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.InsufficientBacking.selector, atkRoot, fee, 0));
        pool.borrow(atkAgent, CAPITAL, 30 days, atk, type(uint256).max);
    }

    /// The attacker's best adaptation to the fee lock: each round stakes what it holds, vouches and borrows that less
    /// its fee, so the fee always fits in its free backing. Returns the phantom backing (its own agent's principal).
    function _loop(uint256 maxRounds) internal returns (uint256 phantom) {
        vm.prank(atk);
        pool.enrollRoot(atkRoot, CAPITAL);
        uint256 amt = CAPITAL - _fee30(CAPITAL);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(atkAgent, atkRoot, ATK_PK, 0);
        vm.prank(atk);
        pool.vouchWithConsent(atkRoot, atkAgent, amt, 0, c, sig);
        vm.prank(atk);
        atkLoans.push(pool.borrow(atkAgent, amt, 30 days, atk, type(uint256).max));
        for (uint256 i = 1; i < maxRounds && _roomAfterStake(amt); i++) {
            uint256 staked = amt;
            amt = staked - _fee30(staked);
            vm.startPrank(atk);
            pool.addStake(atkRoot, staked);
            pool.vouch(atkRoot, atkAgent, amt);
            atkLoans.push(pool.borrow(atkAgent, amt, 30 days, atk, type(uint256).max));
            vm.stopPrank();
        }
        phantom = pool.getAgent(atkAgent).principalOut;
        assertEq(usdc.balanceOf(atk), amt, "the attacker holds its last self-loan");
    }

    /// Let every self-loan default, let the keeper mark them, then take the root's leftover shares out as cash.
    function _harvest() internal returns (uint256 atkBalance) {
        vm.warp(pool.getLoan(atkLoans[atkLoans.length - 1]).defaultableAt + 1);
        for (uint256 i; i < atkLoans.length; i++) {
            vm.prank(keeper);
            pool.markDefault(atkLoans[i]);
        }
        uint256 left = pool.rootShares(atkRoot);
        if (left > 0) {
            vm.prank(atk);
            pool.unlock(atkRoot, left, atk);
        }
        atkBalance = usdc.balanceOf(atk);
    }

    function _lenderValue() internal view returns (uint256) {
        return pool.convertToAssets(pool.shares(lender));
    }

    // ==================================================================
    // N-1 (High): lender yield theft. Self-default was free, so self-referential backing earned lender yield for
    //             nothing, levered up to the utilization cap from one maxLoan of capital.
    // ==================================================================

    /// Was an exploit before 2026-09-24 (final audit N-1 fee lock): lender yield 0.999 -> 0.124 USDG, attacker
    /// +1.05 USDG. Now the audit's loop reverts at its first borrow, and the adapted loop (fee headroom each round)
    /// pays more in burnt fees than it earns, so the attacker loses money and lenders earn at least their honest yield.
    function test_N1_selfLoopStealsLenderYield_atZeroCost_fixed() public {
        // honest business: two backers each lend 100 USDG to a third-party agent for 30 days
        _stakeFee(rootOwner, ROOT, AGENT, 100 * USDC, 30 days);
        _stakeFee(root2Owner, ROOT2, AGENT2, 100 * USDC, 30 days);
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC);
        _sponsor(ROOT2, root2Owner, AGENT2, AGENT2_PK, 100 * USDC);
        uint256 h1 = _borrow(agentOwner, AGENT, 100 * USDC, 30 days);
        uint256 h2 = _borrow(agent2Owner, AGENT2, 100 * USDC, 30 days);
        uint256 lenderStart = _lenderValue();
        uint256 t0 = block.timestamp;

        // control world: no attacker
        uint256 snap = vm.snapshotState();
        vm.warp(t0 + 30 days);
        _repay(agentOwner, h1);
        _repay(agent2Owner, h2);
        uint256 lenderYieldHonest = _lenderValue() - lenderStart;

        // the audit's loop: blocked at the first self-loan
        vm.revertToState(snap);
        snap = vm.snapshotState();
        _expectZeroHeadroomLoopReverts();

        // attack world: same honest business, plus the adapted loop
        vm.revertToState(snap);
        uint256 phantom = _loop(type(uint256).max);
        vm.warp(t0 + 30 days);
        _repay(agentOwner, h1);
        _repay(agent2Owner, h2);
        uint256 atkEnd = _harvest();
        uint256 lenderYieldAttacked = _lenderValue() - lenderStart;
        assertLt(atkEnd, CAPITAL, "the loop loses money");

        emit log_named_decimal_uint("phantom backing from 500 USDG of capital", phantom, 6);
        emit log_named_decimal_uint("lender yield, no attacker", lenderYieldHonest, 6);
        emit log_named_decimal_uint("lender yield, with attacker", lenderYieldAttacked, 6);
        emit log_named_decimal_uint("attacker loss", CAPITAL - atkEnd, 6);

        // the invariant: a self-default charges the whole unpaid fee to the remaining shares, which exceeds the
        // lender yield the phantom shares collected (report: net = rX[(0.85X + 0.6H)/(X+Y) - 1] < 0, H <= Y)
        assertGe(lenderYieldAttacked, lenderYieldHonest, "lenders earn at least their honest-world yield");
        assertGe(_lenderValue(), 1_000 * USDC, "principal itself is intact");
    }

    // ==================================================================
    // N-2 (Medium): the same loop, run to the cap, froze every honest borrow for maxTerm + grace (33 days), at
    //               zero cost, and could be restarted in the block the keeper marks the defaults.
    // ==================================================================

    function _honestRoom() internal view returns (uint256) {
        uint256 cap = pool.getParams().maxUtilizationBps * pool.totalAssets();
        uint256 out = 10_000 * pool.totalPrincipalOut();
        return cap > out ? (cap - out) / 10_000 : 0;
    }

    /// Close the last gap below the cap with smaller self-loans (>= minLoan), so not even minLoan fits. Each one
    /// stakes the loan plus its fee first, so the fee lock is covered.
    function _fillAs(address borrower, uint256 agent) internal {
        CreditPoolV2.Params memory p = pool.getParams();
        for (uint256 i; i < 10 && _honestRoom() >= p.minLoan; i++) {
            uint256 y = _honestRoom() * 11; // after staking y + fee, the cap allows about 10.99x the room
            if (y > p.maxLoan) y = p.maxLoan;
            vm.startPrank(atk);
            pool.addStake(atkRoot, y + _fee30(y));
            uint256 b = _honestRoom();
            if (b > y) b = y;
            pool.vouch(atkRoot, agent, b);
            vm.stopPrank();
            vm.prank(borrower);
            atkLoans.push(pool.borrow(agent, b, 30 days, atk, type(uint256).max));
        }
    }

    /// Was an exploit before 2026-09-24 (final audit N-1 fee lock); now the audit's loop reverts at its first
    /// borrow and honest borrowing goes on. The adapted loop can still pin a 9000 cap, but no longer for free: the
    /// burnt fees cost the attacker, and lenders gain them. (The deploy's maxUtilizationBps = 10_000 ends the
    /// freeze itself: test_N2_fullUtilizationCap_freezeIsImpossible.)
    function test_N2_selfLoopFreezesAllBorrowing_atZeroCost_fixed() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        uint256 snap = vm.snapshotState();
        _expectZeroHeadroomLoopReverts();
        _borrow(agentOwner, AGENT, 5 * USDC, 1 days); // the minimum loan still goes through

        vm.revertToState(snap);
        _loop(type(uint256).max);
        _fillAs(atk, atkAgent);
        vm.prank(agentOwner);
        vm.expectRevert(CreditPoolV2.UtilizationTooHigh.selector);
        pool.borrow(AGENT, 5 * USDC, 1 days, agentOwner, type(uint256).max);

        vm.warp(block.timestamp + 32 days);
        uint256 atkEnd = _harvest();
        emit log_named_decimal_uint("attacker's cost of one freeze", CAPITAL - atkEnd, 6);
        assertLt(atkEnd, CAPITAL, "the freeze is no longer free");
        assertGt(_lenderValue(), 1_000 * USDC, "lenders gain the burnt fees");
    }

    /// Was an exploit before 2026-09-24 (final audit N-1 fee lock); now the audit's loop never starts, and with fee
    /// headroom every freeze cycle burns fees again: honest borrowing resumes once the defaults are marked, and a
    /// restart starts from less capital than the one before.
    function test_N2_freezeRestartsRightAfterTheDefaults_fixed() public {
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 50 * USDC);
        uint256 snap = vm.snapshotState();
        _expectZeroHeadroomLoopReverts();
        vm.revertToState(snap);

        _loop(type(uint256).max);
        _fillAs(atk, atkAgent);
        uint256 afterOne = _harvest();
        assertGt(pool.ownerDefaults(atk), 0, "the first borrower address is marked");
        assertLt(afterOne, CAPITAL, "one cycle cost the attacker its burnt fees");
        uint256 honest = _borrow(agentOwner, AGENT, 5 * USDC, 1 days); // the window between cycles is open
        assertEq(pool.getLoan(honest).principal, 5 * USDC);
    }

    /// maxUtilizationBps = 10_000 ends the freeze: the loop never takes liquidity net (each stake adds at least what
    /// the borrow removes), so honest borrows always fit in cash. Before the fee lock it made N-1 unbounded instead;
    /// now the unbounded loop just burns more fees.
    function test_N2_fullUtilizationCap_freezeIsImpossible() public {
        CreditPoolV2.Params memory p = pool.getParams();
        p.maxUtilizationBps = 10_000;
        vm.prank(owner);
        pool.setParams(p);

        _stakeFee(rootOwner, ROOT, AGENT, 100 * USDC, 30 days);
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC);
        uint256 liqBefore = pool.poolLiquidity();
        _loop(40);
        // at 10_000 the cap's room is the cash itself, and every self-loan was preceded by a larger stake
        assertGe(pool.poolLiquidity(), liqBefore, "the loop takes no liquidity net");
        assertGe(_honestRoom(), liqBefore, "the cap leaves at least the pre-loop room");
        _borrow(agentOwner, AGENT, 100 * USDC, 30 days); // honest borrow still goes through
    }

    /// Was an exploit before 2026-09-24 (final audit N-1 fee lock): at 10_000 the loop was unbounded and still stole
    /// yield. Now the honest borrow still goes through and the unbounded loop loses money.
    function test_N2_mitigation_fullUtilizationCapEndsTheFreeze_butNotTheYieldTheft_fixed() public {
        CreditPoolV2.Params memory p = pool.getParams();
        p.maxUtilizationBps = 10_000;
        vm.prank(owner);
        pool.setParams(p);

        _stakeFee(rootOwner, ROOT, AGENT, 100 * USDC, 30 days);
        _sponsor(ROOT, rootOwner, AGENT, AGENT_PK, 100 * USDC);
        uint256 liqBefore = pool.poolLiquidity();
        uint256 phantom = _loop(40);
        assertGe(pool.poolLiquidity(), liqBefore, "the loop takes no liquidity net");

        uint256 h = _borrow(agentOwner, AGENT, 100 * USDC, 30 days); // honest borrow still goes through
        uint256 lenderStart = _lenderValue();
        vm.warp(block.timestamp + 30 days);
        _repay(agentOwner, h);
        uint256 atkEnd = _harvest();
        assertLt(atkEnd, CAPITAL, "yield theft is gone too");
        emit log_named_decimal_uint("phantom backing", phantom, 6);
        emit log_named_decimal_uint("attacker loss", CAPITAL - atkEnd, 6);
        emit log_named_decimal_uint("lender yield", _lenderValue() - lenderStart, 6);
    }

    // ==================================================================
    // Refutations
    // ==================================================================

    /// The loop never reaches lender principal: mid-loop every lender share comes out in full, and after the
    /// defaults the share price is not below where it started.
    function test_R_selfLoopCannotReachLenderPrincipal() public {
        uint256 priceBefore = _price();
        _loop(type(uint256).max);
        uint256 snap = vm.snapshotState();
        uint256 sh = pool.shares(lender);
        vm.warp(block.timestamp + 8 days); // past MIN_HOLD
        vm.prank(lender);
        uint256 out = pool.withdraw(sh, lender);
        assertEq(out, 1_000 * USDC, "full exit while the loop is open");
        vm.revertToState(snap);
        _harvest();
        assertGe(_price(), priceBefore, "price never falls");
        assertEq(pool.totalBadDebt(), 0);
        assertGe(usdc.balanceOf(address(pool)), pool.poolLiquidity() + pool.reserve() + pool.unclaimedSponsorFees());
    }

    /// Without the loop (k = 1) the attacker still gets lender yield on backing whose cash it holds, but only 1x its
    /// capital (less the locked fee), the same as depositing it. The leverage comes from the loop.
    function test_R_withoutTheLoop_noLeverage() public {
        uint256 phantom = _loop(1);
        assertLe(phantom, CAPITAL);
    }
}

/// Hook targeting (Info, handed to the SeatVaultV2 audit): any root can point its hook at ANY contract, including
/// another backer's hook, and the pool then calls it with `msg.sender == pool` and the attacker's `rootId`.
/// A hook that checks only `msg.sender == pool` and not `rootId` can be driven by strangers.
contract NaiveHook is IBackerHook {
    address public immutable pool;
    uint256 public mine; // the root this hook was written for
    uint256 public releasesSeen; // what a naive hook would act on

    constructor(address p) {
        pool = p;
    }

    function setMine(uint256 r) external {
        mine = r;
    }

    function canBorrow(uint256, uint256, uint256, uint64, uint256, address, address, address)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function onBorrow(uint256, uint256, uint256) external {}

    function onDefault(uint256, uint256, uint256, uint256, bool) external {}

    function onRelease(uint256, uint256, uint256, uint8) external {
        require(msg.sender == pool, "only pool"); // and no rootId check
        releasesSeen++;
    }
}

contract FinalAuditHookTargeting is CreditPoolV2Base {
    function test_N3_anyRootCanDriveAnotherBackersHook() public {
        NaiveHook h = new NaiveHook(address(pool));
        h.setMine(ROOT);
        vm.prank(rootOwner);
        pool.setHook(ROOT, address(h));

        // ROOT2 (a stranger) points its own hook at ROOT's hook contract: allowed, immediate while it backs nothing
        vm.prank(root2Owner);
        pool.setHook(ROOT2, address(h));
        _sponsor(ROOT2, root2Owner, AGENT2, AGENT2_PK, 10 * USDC);
        vm.prank(root2Owner);
        pool.unvouch(ROOT2, AGENT2, 10 * USDC);
        assertEq(h.releasesSeen(), 1, "the pool delivered ROOT2's release to ROOT's hook");
    }
}
