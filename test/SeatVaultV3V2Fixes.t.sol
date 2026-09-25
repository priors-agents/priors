// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {SeatVaultV3} from "../src/SeatVaultV3.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {SeatVaultV3Base} from "./SeatVaultV3.t.sol";

/// Audit finding V-2 (second-opinion audit of SeatVaultV2, 2026-09-24): "the owner's levers and the agent's ownership do
/// not reach open seats". These are its three proofs of concept replayed against SeatVaultV3, where each one now fails.
/// Numbers are the LIVE ones read on chain 4663:
///   vault  seatSize 1M PRIORS, line 5 USDG, burnBps 5000, maxOpenSeats 10, epochCap 50 USDG / 7 d,
///          minRepaid 3, idleAfter 30 d, backing ~16 USDG
///   pool   minLoan 5, maxLoan 500, minTerm 1 d, maxTerm 30 d, grace 3 d, feeBps 100, sponsor 2500, protocol 1500,
///          minStake 10, maxUtilizationBps 10000, keeperBounty 0
abstract contract LiveSeatBase is SeatVaultV3Base {
    uint256 constant LSEAT = 1_000_000e18;
    uint256 constant LIVE_BACKING = 16 * USDC;

    function _live() internal {
        CreditPoolV2.Params memory pp = _poolParams();
        pp.maxUtilizationBps = 10_000;
        pp.keeperBounty = 0;
        vm.prank(timelock);
        pool.setParams(pp);

        vm.startPrank(owner);
        vault.setParams(
            SeatVaultV3.Params({
                seatSize: LSEAT, line: 5 * USDC, burnBps: 5000, maxOpenSeats: 10, epochCap: 50 * USDC, epochLength: 7 days
            })
        );
        vault.setGates(3, 30 days);
        // the funder's live stake is ~16 USDG: retire the rest of the base suite's 100
        uint256 keep = pool.convertToShares(LIVE_BACKING) + 1;
        vault.retire(pool.rootShares(VAULT_ID) - keep, owner);
        vm.stopPrank();
        assertApproxEqAbs(pool.backing(VAULT_ID), LIVE_BACKING, 2);
    }

    /// Honest history: `n` loans under ROOT (the base suite's other backer).
    function _history(uint256 id, uint256 pk, uint256 n) internal {
        _handoff(id, pk, 10 * USDC);
        for (uint256 i = 0; i < n; i++) {
            _repay(vm.addr(pk), _borrow(vm.addr(pk), id, 5 * USDC, 1 days));
        }
    }

    /// The farm: a fresh owner registers its own root and agent, stakes the pool's minStake behind the root,
    /// vouches the agent, and borrows/repays three 1-day minimum loans, all in the same block. Then it unlocks.
    function _farm(uint256 pk) internal returns (uint256 agent, uint256 root, uint256 feesPaid) {
        address a = vm.addr(pk);
        usdc.mint(a, 10 * USDC + 1 * USDC); // minStake + fee headroom (the borrowed principal repays itself)
        vm.startPrank(a);
        usdc.approve(address(pool), type(uint256).max);
        root = reg.register("farm-root");
        agent = reg.register("farm-agent");
        pool.enrollRoot(root, 10 * USDC);
        vm.stopPrank();
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(agent, root, pk);
        vm.prank(a);
        pool.vouchWithConsent(root, agent, 5 * USDC, 0, c, sig);
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(a);
            uint256 l = pool.borrow(agent, 5 * USDC, 1 days, a, type(uint256).max);
            feesPaid += pool.getLoan(l).fee;
            pool.repay(l, agent, type(uint256).max);
            vm.stopPrank();
        }
    }

    function _unlockAll(uint256 pk, uint256 root) internal {
        address a = vm.addr(pk);
        vm.startPrank(a);
        if (pool.sponsorFees(root) > 0) pool.claimSponsorFees(root, a);
        pool.unlock(root, pool.rootShares(root), a);
        vm.stopPrank();
    }

    function _selfSeat(uint256 pk, uint256 id) internal {
        address a = vm.addr(pk);
        priors.mint(a, LSEAT);
        vm.prank(a);
        priors.approve(address(vault), type(uint256).max);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(a);
        vault.seat(id, c, sig);
    }
}

contract SeatVaultV3V2FixesTest is LiveSeatBase {
    function setUp() public override {
        super.setUp();
        _live();
    }

    /// The team's answer to a PRIORS price collapse is `setParams` (bigger seat) and `pauseSeats`. Neither touches
    /// a seat already open: its line and burn are fixed at opening, `canBorrow` ignores the pause, the owner has
    /// no close/freeze, and `retire` cannot pull a vouched line. A farmed seat opened before the crash is a
    /// standing option to default at the crashed price.
    function test_F2_pauseAndRepriceDoNotReachAnOpenSeat() public {
        uint256 pk = 0xFA16;
        address atk = vm.addr(pk);
        (uint256 agent, uint256 root,) = _farm(pk);
        _selfSeat(pk, agent);
        _unlockAll(pk, root);

        // "the price collapsed": the Safe pulls every lever it has
        vm.startPrank(owner);
        vault.pauseSeats(true);
        SeatVaultV3.Params memory p;
        (p.seatSize, p.line, p.burnBps, p.maxOpenSeats, p.epochCap, p.epochLength) = vault.params();
        p.seatSize = 100 * LSEAT;
        p.burnBps = 10_000;
        vault.setParams(p);
        vault.setGates(1000, 1 days);
        uint256 all = pool.rootShares(VAULT_ID);
        vm.expectRevert(); // InsufficientBacking: the line is vouched
        vault.retire(all, owner);
        vm.stopPrank();

        // V3: the levers reach the open seat. No new loan while paused...
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        vm.prank(atk);
        pool.borrow(agent, 5 * USDC, 1 days, atk, type(uint256).max);
        // ...nor after the pause is lifted, because the seat no longer meets the repriced terms
        vm.prank(owner);
        vault.pauseSeats(false);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        vm.prank(atk);
        pool.borrow(agent, 5 * USDC, 1 days, atk, type(uint256).max);
        // and the Safe can close it outright: every token back, nothing burnt, the line released
        vm.prank(owner);
        vault.freezeSeat(agent);
        assertEq(uint8(vault.getSeat(agent).status), uint8(SeatVaultV3.Status.Closed));
        assertEq(priors.balanceOf(atk), LSEAT, "every token back to the staker");
    }

    function test_F3_openSeatSurvivesSale_buyerDrawsAndDefaults_sellerUnmarked() public {
        _history(AGENT, AGENT_PK, 3);
        priors.mint(staker, LSEAT);
        uint256 s0 = priors.balanceOf(staker);
        vm.prank(staker);
        vault.offer(AGENT); // the staker trusts agentOp
        _accept(AGENT_PK, AGENT, staker);

        address buyer = vm.addr(0xB17E);
        vm.prank(agentOp);
        reg.transferFrom(agentOp, buyer, AGENT); // sold (or handed to a burner), line and seat attached

        // V3: the seat is bound to the owner who accepted it; the buyer cannot draw on it
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        vm.prank(buyer);
        pool.borrow(AGENT, 5 * USDC, 1 days, buyer, type(uint256).max);
        // and anyone may close it now: every token back to the staker, nothing burnt
        vm.prank(anyone);
        vault.close(AGENT);
        assertEq(uint8(vault.getSeat(AGENT).status), uint8(SeatVaultV3.Status.Closed));
        assertEq(priors.balanceOf(staker), s0, "the staker gets its whole seat back");
        assertEq(usdc.balanceOf(buyer), 0, "the buyer took nothing");
        // while the seller still owns it, a stranger cannot close someone else's seat
        assertEq(pool.ownerDefaults(buyer), 0);
    }

    /// V3: while the agent is still with the owner who accepted, only the staker or the controller may close.
    function test_F3_V3_strangerCannotCloseWhileOwnerUnchanged() public {
        _history(AGENT, AGENT_PK, 3);
        priors.mint(staker, LSEAT);
        vm.prank(staker);
        vault.offer(AGENT);
        _accept(AGENT_PK, AGENT, staker);
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotStakerOrController.selector, AGENT, anyone));
        vault.close(AGENT);
        vm.prank(anyone);
        vm.expectRevert();
        vault.freezeSeat(AGENT); // the owner's lever only
    }

    /// V3: the same squat, and the owner ends it. `freezeSeat` closes each non-idle squatting seat (every token
    /// back, nothing burnt), and the honest, seasoned agent then gets its seat.
    function test_F4_V3_ownerEvictsTheSquat() public {
        uint256[3] memory ids;
        uint256[3] memory pks = [uint256(0x5B1), 0x5B2, 0x5B3];
        for (uint256 i = 0; i < 3; i++) {
            (uint256 id, uint256 root,) = _farm(pks[i]);
            ids[i] = id;
            _selfSeat(pks[i], id);
            _unlockAll(pks[i], root);
        }
        _history(AGENT, AGENT_PK, 3);
        priors.mint(staker, LSEAT);
        vm.prank(staker);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vm.expectRevert(); // InsufficientBacking: the squat holds every backed slot
        vault.accept(AGENT, staker, c, sig);

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(owner);
            vault.freezeSeat(ids[i]);
            assertEq(uint8(vault.getSeat(ids[i]).status), uint8(SeatVaultV3.Status.Closed));
            assertEq(priors.balanceOf(vm.addr(pks[i])), LSEAT, "evicted, every token back, nothing burnt");
        }
        (c, sig) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vault.accept(AGENT, staker, c, sig);
        assertEq(uint8(vault.getSeat(AGENT).status), uint8(SeatVaultV3.Status.Open), "the honest agent is seated");
    }
}
