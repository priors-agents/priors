// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {IPermit2V5} from "../../src/interfaces/IV5Deps.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C, IV5Errors, IV5Events} from "../../src/v5/V5Types.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";

/// @dev `sync()`: the ring, k (fail-safe, hysteresis, step-up), the spot latch and the depth guard's lasting state;
///      the circuit breaker; the timelock's and the guardian's powers and the access matrix (2.3, 2.8, section 8).
contract V5GuardsTest is V5Base {
    function _agentCount() internal pure override returns (uint256) {
        return 7;
    }

    // ------------------------------------------------------------------
    // sync and k
    // ------------------------------------------------------------------

    function test_sync_needsAFreshObservation() public {
        _skip(46 minutes);
        vm.expectRevert(IV5Errors.StaleSizer.selector);
        v5.sync();
        sizer.set(_sqrtFor(P0), _sqrtFor(P0));
        sizer.setTooFew(true);
        vm.expectRevert(bytes("NotEnoughObservations"));
        v5.sync();
    }

    function test_k_failSafe_thenCalm_thenStepUp_thenNormal() public {
        assertEq(lens.price().k, C.K_WILD, "under 7 observed days");
        _calmWeek();
        assertEq(lens.price().k, C.K_CALM);
        // a day at 0.6 of the rest: range 1.67 is normal, and the day undercuts the rest: one level more
        _skip(1 days);
        _keeperPass(P0 * 60 / 100);
        assertEq(lens.price().kBase, C.K_NORMAL);
        assertEq(lens.price().k, C.K_WILD);
        // the next day at the same low: no undercut, the range's own k
        _skip(1 days);
        _keeperPass(P0 * 60 / 100);
        assertEq(lens.price().k, C.K_NORMAL);
    }

    function test_k_hysteresis_downOnlyInsideTheThreshold() public {
        // the low day first, then six days high: range 2.6, wild
        _skip(1 days);
        _keeperPass(P0 * 10 / 26);
        for (uint256 i = 0; i < 6; i++) {
            _skip(1 days);
            _keeperPass(P0);
        }
        assertEq(lens.price().kBase, C.K_WILD);
        // the low day leaves; the new day makes the range 2.4: inside 2.5 but over 2.375, k_base stays wild
        _skip(1 days);
        _keeperPass(P0 * 10 / 24);
        assertEq(lens.price().kBase, C.K_WILD, "down only 5% inside the threshold");
    }

    function test_k_stepUp_onASteadyDecline() public {
        _calmWeek();
        uint256 p = P0;
        uint8[] memory ks = new uint8[](6);
        for (uint256 i = 0; i < 6; i++) {
            p = p * 935 / 1000;
            _skip(1 days);
            _keeperPass(p);
            ks[i] = lens.price().k;
        }
        assertEq(ks[0], C.K_CALM, "range 1.07: no step");
        assertEq(ks[1], C.K_CALM, "range 1.14: under 1.2");
        assertEq(ks[2], C.K_NORMAL, "range 1.22 and a 6.5% undercut: one level up");
    }

    function test_k_gapInSyncs_readsWild() public {
        _calmWeek();
        _skip(2 days);
        _keeperPass(P0);
        assertEq(lens.price().k, C.K_WILD, "a day with no sync() is unobserved");
    }

    function test_depthGuard_lastingState_capsTheCacheAndHoldsK() public {
        _calmWeek();
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        v5.sync();
        assertTrue(lens.depthGuardOn());
        S.Price memory p = lens.price();
        // a higher median under the guard does not lift the cache
        _skip(30 minutes);
        _keeperPass(P0 * 2);
        assertEq(lens.price().median, p.median);
        assertEq(lens.price().k, C.K_WILD, "a day synced under the guard is unobserved");
        // clears only after 24 h of syncs reading it off
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);
        _skipFresh(30 minutes);
        assertTrue(lens.depthGuardOn());
        _skipFresh(1 days);
        assertFalse(lens.depthGuardOn());
        // a reading on in between restarts the clock
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        v5.sync();
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);
        _skipFresh(1 hours);
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        v5.sync();
        assertTrue(lens.depthGuardOn());
    }

    function test_depthGuard_noMergeIntoA_whileOn() public {
        uint256 id = agents[0];
        _open(id, 75_001 * T);
        _back(_owner(id), id, 20_000 * T);
        limiter.setDepthTerm(5_000e6, 100e6, 60, true);
        v5.sync();
        _skipFresh(2 days);
        v5.pokeFees(id);
        assertEq(_gen(id).pendingTok[C.OWNER], 20_000 * T, "A waits");
        limiter.setDepthTerm(5_000e6, 5_000e6, 60, true);
        _skipFresh(1 hours);
        _skipFresh(1 days);
        assertFalse(lens.depthGuardOn());
        v5.pokeFees(id);
        assertEq(_gen(id).pendingTok[C.OWNER], 0, "merged once off");
    }

    function test_fee_aboveTheCeiling_kAtLeast2_viewOkFalse() public {
        _calmWeek();
        limiter.setFee(300, false);
        v5.sync();
        assertEq(lens.kEff(), C.K_NORMAL);
        assertFalse(lens.price().feeOk);
    }

    // ------------------------------------------------------------------
    // circuit breaker
    // ------------------------------------------------------------------

    function test_breaker_tripsAt250_clearKeepsOldDefaultsOut() public {
        _calmWeek();
        uint256[] memory ls = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            _open(agents[i], 100_000 * T);
            ls[i] = _borrow(agents[i], 50 * U, 1 days);
        }
        _skipFresh(4 days + 1);
        for (uint256 i = 0; i < 4; i++) {
            pool.markDefault(ls[i]);
        }
        v5.sync();
        assertFalse(lens.breakerTripped(), "$200");
        pool.markDefault(ls[4]);
        vm.expectEmit(false, false, false, true, address(v5));
        emit IV5Events.BreakerTripped(250 * U, 250 * U);
        v5.sync();
        assertTrue(lens.breakerTripped());
        // new books and backing pause; settle and exits do not
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(agents[6], ROOT, 0);
        vm.prank(_owner(agents[6]));
        vm.expectRevert(IV5Errors.BreakerOn.selector);
        v5.open(agents[6], 100_000 * T, false, c, sig);
        v5.claimSettled(agents[0], 1, _owner(agents[0]));
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotGuardian.selector);
        v5.clear();
        vm.prank(guardian);
        v5.clear();
        assertFalse(lens.breakerTripped());
        v5.sync();
        assertFalse(lens.breakerTripped(), "defaults before the clear never re-trip it");
        // a later default is counted (and $50 does not trip)
        pool.markDefault(ls[5]);
        v5.sync();
        assertFalse(lens.breakerTripped());
    }

    // ------------------------------------------------------------------
    // the guardian
    // ------------------------------------------------------------------

    function test_pause_14days_cooldown_neverBlocksExits() public {
        uint256 id = agents[0];
        _open(id, 100_000 * T);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotGuardian.selector);
        v5.pause();
        vm.prank(guardian);
        v5.pause();
        assertTrue(lens.paused());
        vm.prank(guardian);
        vm.expectRevert(IV5Errors.PauseCooldown.selector);
        v5.pause();
        // exits run: close, finishClose
        vm.prank(_owner(id));
        v5.close(id, 1);
        _skipFresh(8 days);
        v5.finishClose(id, 1);
        _skipFresh(6 days);
        assertFalse(lens.paused(), "14 days at most");
        vm.prank(guardian);
        vm.expectRevert(IV5Errors.PauseCooldown.selector);
        v5.pause();
        _skipFresh(14 days);
        vm.prank(guardian);
        v5.pause();
        vm.prank(guardian);
        v5.unpause();
        vm.prank(guardian);
        vm.expectRevert(IV5Errors.Paused.selector);
        v5.unpause();
    }

    function test_stopKeeper_andSetKeeper() public {
        vm.prank(guardian);
        v5.stopKeeper();
        assertEq(lens.keeper(), address(0));
        vm.prank(keeper);
        vm.expectRevert(IV5Errors.NotKeeper.selector);
        v5.releaseFor(1, 1);
        vm.prank(anyone);
        vm.expectRevert(IV5Errors.NotTimelock.selector);
        v5.setKeeper(anyone);
        vm.prank(timelock);
        v5.setKeeper(keeper);
        assertEq(lens.keeper(), keeper);
    }

    // ------------------------------------------------------------------
    // the timelock's settings and their bounds
    // ------------------------------------------------------------------

    function test_settings_bounds_andAccess() public {
        vm.startPrank(timelock);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setPremiumCap(201);
        v5.setPremiumCap(200);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setPremium(1, 201);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setMaxSwapUsdg(0);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setMaxSwapUsdg(1_900 * U + 1);
        v5.setMaxSwapUsdg(1_000 * U);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setRooms(5_001 * U, 500 * U);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setRooms(500 * U, 5_001 * U);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        v5.setMinDrawK(5);
        v5.setMinDrawK(C.K_NORMAL);
        v5.setVouchCap(2_000 * U);
        v5.setOpenBacking(false);
        v5.setPremiumCheck(false);
        vm.stopPrank();
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(v5.setPremiumCap, (0));
        calls[1] = abi.encodeCall(v5.setPremium, (1, 0));
        calls[2] = abi.encodeCall(v5.setMaxSwapUsdg, (1));
        calls[3] = abi.encodeCall(v5.setRooms, (1, 1));
        calls[4] = abi.encodeCall(v5.setMinDrawK, (3));
        calls[5] = abi.encodeCall(v5.setVouchCap, (1));
        calls[6] = abi.encodeCall(v5.setOpenBacking, (true));
        calls[7] = abi.encodeCall(v5.setPremiumCheck, (true));
        calls[8] = abi.encodeCall(v5.retire, (1));
        calls[9] = abi.encodeCall(v5.setEntryRule, (0, 0));
        address[3] memory who = [guardian, keeper, anyone];
        for (uint256 i = 0; i < calls.length; i++) {
            for (uint256 j = 0; j < who.length; j++) {
                vm.prank(who[j]);
                (bool ok, bytes memory r) = address(v5).call(calls[i]);
                assertFalse(ok);
                assertEq(bytes4(r), IV5Errors.NotTimelock.selector);
            }
        }
        bytes[] memory gcalls = new bytes[](4);
        gcalls[0] = abi.encodeCall(v5.pause, ());
        gcalls[1] = abi.encodeCall(v5.unpause, ());
        gcalls[2] = abi.encodeCall(v5.clear, ());
        gcalls[3] = abi.encodeCall(v5.stopKeeper, ());
        address[3] memory gwho = [timelock, keeper, anyone];
        for (uint256 i = 0; i < gcalls.length; i++) {
            for (uint256 j = 0; j < gwho.length; j++) {
                vm.prank(gwho[j]);
                (bool ok, bytes memory r) = address(v5).call(gcalls[i]);
                assertFalse(ok);
                assertEq(bytes4(r), IV5Errors.NotGuardian.selector);
            }
        }
        // BuyAndBack only, keeper only, self only
        vm.expectRevert(IV5Errors.NotBuyAndBack.selector);
        v5.returnExit(1);
        vm.expectRevert(IV5Errors.NotKeeper.selector);
        v5.sellLeg(1, 1, anyone, 1);
    }

    function test_retire_toRetireTo_withinTheFeeHeadroom() public {
        uint256 id = agents[0];
        _open(id, 100_000 * T);
        vm.prank(_owner(id));
        v5.refresh(id); // $30 vouched
        uint256 free = pool.freeBacking(ROOT);
        uint256 shares = pool.convertToShares(free);
        vm.prank(timelock);
        vm.expectRevert(IV5Errors.NoFeeRoom.selector);
        v5.retire(shares);
        uint256 sh = pool.convertToShares(free - 1 * U);
        vm.prank(timelock);
        uint256 got = v5.retire(sh);
        assertGt(got, 0);
        assertEq(usdg.balanceOf(retireTo), got);
    }

    function test_fund_anyone_andRootChecks() public {
        vm.prank(funder);
        v5.fund(10 * U);
        vm.prank(funder);
        vm.expectRevert(IV5Errors.ZeroAmount.selector);
        v5.fund(0);
    }

    function test_fund_firstCallNeedsTheRoot() public {
        // a second V5 whose root identity it does not hold yet
        uint256 root2 = reg.register("root2");
        SeatVaultV5 v = _deployV5(root2);
        usdg.mint(address(this), 20 * U);
        usdg.approve(address(v), type(uint256).max);
        vm.expectRevert(IV5Errors.RootNotReady.selector);
        v.fund(10 * U);
        reg.safeTransferFrom(address(this), address(v), root2);
        v.fund(10 * U);
        assertEq(pool.hook(root2), address(v));
    }

    function test_constructor_validates() public {
        SeatVaultV5.Init memory i = _init(ROOT);
        i.epoch0 = EPOCH0 + 1 days; // a Tuesday
        vm.expectRevert(IV5Errors.BadSetting.selector);
        new SeatVaultV5(i);
        i = _init(ROOT);
        i.poolKey.currency0 = address(priors);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        new SeatVaultV5(i);
        i = _init(0);
        vm.expectRevert(IV5Errors.BadSetting.selector);
        new SeatVaultV5(i);
    }

    // ------------------------------------------------------------------
    // one transaction from an outside wallet
    // ------------------------------------------------------------------

    function test_permit2Pull_andMulticall() public {
        uint256 id = agents[0];
        _open(id, 100_000 * T);
        vm.prank(timelock);
        v5.setOpenBacking(true);
        address w = makeAddr("wallet");
        priors.mint(w, 10_000 * T);
        vm.prank(w);
        priors.approve(address(permit2), type(uint256).max);
        IPermit2V5.PermitSingle memory p = IPermit2V5.PermitSingle(
            IPermit2V5.PermitDetails(address(priors), uint160(10_000 * T), 0, 0), address(v5), block.timestamp
        );
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(v5.permit2Allow, (p, ""));
        calls[1] = abi.encodeCall(v5.permitUsdg, (0, 0, 0, bytes32(0), bytes32(0))); // fails quietly
        calls[2] = abi.encodeCall(v5.back, (id, 10_000 * T, false));
        vm.prank(w);
        v5.multicall(calls);
        assertEq(_gen(id).pendingTok[C.OTHERS], 10_000 * T);
    }

    function test_unknownSelectorReverts_andNoReentry() public {
        (bool ok,) = address(v5).call(abi.encodeWithSignature("nothing()"));
        assertFalse(ok);
        // a hostile hook calling back into V5 during a zap: one lock
        uint256 id = agents[0];
        swapper.setReenter(address(v5), abi.encodeCall(v5.flush, ()));
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        vm.expectRevert(IV5Errors.Reentrancy.selector);
        v5.openWithUsdg(id, 0, 200 * U, 1, block.timestamp + 300, false, c, sig);
    }

    // ------------------------------------------------------------------

    function _init(uint256 root) internal view returns (SeatVaultV5.Init memory i) {
        i = _baseInit();
        i.rootId = root;
    }

    function _deployV5(uint256 root) internal returns (SeatVaultV5) {
        return new SeatVaultV5(_init(root));
    }
}
