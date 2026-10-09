// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Base} from "./V5Base.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {IV5Errors} from "../../src/v5/V5Types.sol";

/// @dev Anyone's contract, as in docs/AUDIT-DEEP-GAS-INTEGRATION.md H-01's PoC: an honest `sync()` that warms every
///      slot `sync()` touches, then a `sync()` with a chosen gas budget, in one transaction.
contract SyncGriefer {
    function grief(SeatVaultV5 v, uint256 g) external returns (bool ok, bytes memory r) {
        v.sync();
        (ok, r) = address(v).call{gas: g}(abi.encodeWithSignature("sync()"));
    }
}

/// @dev V5's reads of the SwapLimiter inside a try (docs/V5-LAUNCH.md, open items: "The fee read starves at a bare gas
///      estimate"; docs/AUDIT-DEEP-GAS-INTEGRATION.md H-01, L-07). The mock limiter starves as the live one does: under
///      its read budget it reverts `ReadStarved()` cleanly and hands the gas back. Each test scans the gas a caller
///      gives the call, from where nothing can start to where everything is read: at no budget may the call succeed
///      having taken a starved read for the limiter's answer.
contract V5StarvedReadsTest is V5Base {
    uint256 internal constant FROM = 60_000;
    uint256 internal constant TO = 1_200_000;
    uint256 internal constant STEP = 1_000;

    SyncGriefer internal griefer;

    function _agentCount() internal pure override returns (uint256) {
        return 1;
    }

    function setUp() public override {
        super.setUp();
        griefer = new SyncGriefer();
    }

    /// @dev The griefer's starved `sync()` with `g` gas: whether it succeeded or reverted `ReadStarved`, and the price
    ///      cache left after it (the state is rolled back after).
    function _syncWith(uint256 g) internal returns (bool ok, bool starved, S.Price memory p) {
        uint256 snap = vm.snapshotState();
        bytes memory r;
        (ok, r) = griefer.grief(v5, g);
        starved = !ok && r.length == 4 && bytes4(r) == IV5Errors.ReadStarved.selector;
        p = lens.price();
        vm.revertToState(snap);
        vm.deleteStateSnapshot(snap);
    }

    /// @dev Anyone's starved `sync()` used to record `feeOk` false (kEff at least 2, no refresh-up until the next good
    ///      sync). Now it reverts `ReadStarved` below the fee read's budget and reads the fee above it.
    function test_starvedSync_cannotRecordFeeOkFalse() public {
        assertTrue(lens.price().feeOk, "honest state: the fee is read");
        uint256 refused;
        uint256 lowestOk;
        for (uint256 g = FROM; g <= TO; g += STEP) {
            (bool ok, bool starved, S.Price memory p) = _syncWith(g);
            assertFalse(
                ok && !p.feeOk, string.concat("a sync() that succeeded recorded feeOk false, at gas ", vm.toString(g))
            );
            if (starved) refused++;
            if (ok && lowestOk == 0) lowestOk = g;
        }
        assertGt(refused, 0, "under the budget sync() reverts ReadStarved");
        assertGt(lowestOk, 0, "over it sync() succeeds");
        emit log_named_uint("lowest gas at which sync() succeeds", lowestOk);
    }

    /// @dev The same scan for the depth read, which `sync()` would latch as the lasting depth guard (24 h of syncs to
    ///      lift; new loans, opens, backs, raises, placement and fills stopped).
    function test_starvedSync_cannotLatchTheDepthGuard() public {
        assertFalse(lens.depthGuardOn(), "honest state: the guard is off");
        for (uint256 g = FROM; g <= TO; g += STEP) {
            (bool ok,, S.Price memory p) = _syncWith(g);
            assertFalse(
                ok && p.depthOn,
                string.concat("a sync() that succeeded latched the depth guard, at gas ", vm.toString(g))
            );
        }
    }

    /// @dev The owner's `refresh` right after the open (the pages send both in one operation). Starved, it used to read
    ///      the depth guard as on and return having raised nothing, so the operation succeeded with the line unvouched
    ///      (docs/V5-LAUNCH.md, "V5 operations need a gas margin"). Now it raises the line or reverts. (It cannot reach
    ///      its lowering branch starved: the pool's `unvouch` calls V5's hook with 300,000 gas or reverts HookStarved.)
    function test_starvedRefresh_raisesOrReverts() public {
        uint256 id = agents[0];
        _open(id, 150_001 * T);
        uint256 line = lens.lineOf(id);
        assertEq(line, 50 * U);
        assertEq(pool.getAgent(id).delegatedIn, 0, "the open vouches nothing");
        uint256 refused;
        uint256 lowestOk;
        for (uint256 g = FROM; g <= TO; g += STEP) {
            uint256 snap = vm.snapshotState();
            vm.prank(_owner(id));
            (bool ok, bytes memory r) = address(v5).call{gas: g}(abi.encodeCall(v5.refresh, (id)));
            uint256 vouched = pool.getAgent(id).delegatedIn;
            vm.revertToState(snap);
            vm.deleteStateSnapshot(snap);
            assertFalse(
                ok && vouched != line,
                string.concat("a refresh that succeeded left the line unvouched, at gas ", vm.toString(g))
            );
            if (!ok && r.length == 4 && bytes4(r) == IV5Errors.ReadStarved.selector) refused++;
            if (ok && lowestOk == 0) lowestOk = g;
        }
        assertGt(refused, 0, "under the budgets refresh reverts ReadStarved");
        assertGt(lowestOk, 0, "over them it raises the line");
        emit log_named_uint("lowest gas at which the owner's refresh succeeds", lowestOk);
    }

    /// @dev With its budget given, a limiter whose views fail makes `sync()` revert and write nothing (4ff1f27, deep audit
    ///      H-01: any failure of the view reverts the call), so a failed read is never cached as a reading either way.
    function test_limiterFailingWithItsBudget_revertsAndWritesNothing() public {
        S.Price memory before = lens.price();
        limiter.setFeeReverts(true);
        limiter.setViewReverts(true);
        skip(1 minutes);
        vm.expectRevert(bytes("view down")); // the limiter's own failure, bubbled
        v5.sync();
        S.Price memory p = lens.price();
        assertEq(p.feeOk, before.feeOk, "the fee's reading is unchanged");
        assertEq(p.depthOn, before.depthOn, "the depth guard is unchanged");
    }
}
