// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SeatVaultV3Base} from "../SeatVaultV3.t.sol";
import {MockPoolManager} from "../SeatSizer.t.sol";
import {SeatVaultV3} from "../../src/SeatVaultV3.sol";
import {SeatSizer} from "../../src/SeatSizer.sol";

/// Adversarial review of src/SeatSizer.sol. Base vault terms: seat 25,000 $PRIORS, line $5, burn 50%.
contract SeatSizerAuditTest is SeatVaultV3Base {
    bytes32 constant POOL_ID = keccak256("priors/usdg");
    uint256 constant E = 1e18;
    MockPoolManager pm;
    SeatSizer sizer;
    bytes32 slot;

    function setUp() public override {
        super.setUp();
        pm = new MockPoolManager();
        sizer = new SeatSizer(vault, pm, POOL_ID, owner, keeper, 6_000 * E, 2_000_000 * E);
        slot = sizer.priceSlot();
        vm.prank(owner);
        vault.transferOwnership(address(sizer));
        vm.prank(owner);
        sizer.acceptVaultOwnership();
    }

    function _sqrt(uint256 perUsdgX10) internal pure returns (uint160) {
        return uint160(Math.sqrt((perUsdgX10 * 1e11) << 192));
    }

    function _pokeAt(uint256 perUsdgX10, uint256 n, uint256 gap) internal {
        for (uint256 i = 0; i < n; i++) {
            pm.set(slot, _sqrt(perUsdgX10));
            vm.warp(vm.getBlockTimestamp() + gap);
            vm.prank(keeper);
            sizer.poke();
        }
    }

    function _size() internal view returns (uint256 s) {
        (s,,,,,) = vault.params();
    }

    /// burn at the median price, in hundredths of a line
    function _burnLinesX100() internal view returns (uint256) {
        (uint256 s,, uint256 burnBps,,,) = vault.params();
        uint256 t = sizer.targetFor(sizer.medianSqrtPrice());
        return s * burnBps * 5 * 100 / (t * 10_000);
    }

    /// M-1 (fixed): once the seat sits at the ceiling, a further $PRIORS collapse still pauses seats. resize() used
    /// to revert Unchanged before its pause check; it now pauses even when the size cannot move.
    function test_M1_atCeiling_aFurtherCollapsePauses() public {
        // $PRIORS falls: target 2.8M, over the 2M ceiling; 2M burns 1M = 1.79 lines -> raise to the ceiling, no pause
        _pokeAt(1_100_000, 48, 30 minutes);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 2_000_000 * E);
        assertFalse(vault.seatsPaused());
        // $PRIORS falls another 10x: target 28M, a 2M seat now burns 0.18 lines: the resize pauses seats
        _pokeAt(11_000_000, 48, 30 minutes);
        assertEq(sizer.targetFor(sizer.medianSqrtPrice()), 28_000_000 * E);
        assertLt(_burnLinesX100(), 150, "burn is under 1.5 lines");
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 2_000_000 * E);
        assertTrue(vault.seatsPaused(), "a collapse under the ceiling pauses seats");
        // and with nothing left to do, the next resize says so
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.Unchanged.selector, 2_000_000 * E));
        sizer.resize();
    }

    /// M-1 (fixed): if the Safe unpauses while the price is still collapsed, the keeper's next resize pauses again (the
    /// safe side); the Safe keeps seats open by raising the bounds, or by taking the vault back.
    function test_M1_afterSafeUnpause_theKeeperRepausesWhileStillCollapsed() public {
        _pokeAt(40_600_000, 48, 30 minutes);
        vm.prank(keeper);
        sizer.resize();
        assertTrue(vault.seatsPaused());
        vm.prank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.pauseSeats, (false)));
        _pokeAt(40_600_000, 48, 30 minutes);
        vm.prank(keeper);
        sizer.resize();
        assertTrue(vault.seatsPaused());
    }

    /// L-1 (fixed): a seat above the ceiling (the Safe raised it by hand) is still cut at most by half, and it counts
    /// as the day's cut, even when the target is a raise the ceiling clamps.
    function test_L1_seatAboveCeiling_aClampedRaiseIsAHalvingCut() public {
        SeatVaultV3.Params memory p = _params();
        p.seatSize = 10_000_000 * E; // the Safe's emergency raise
        vm.prank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.setParams, (p)));
        _pokeAt(11_000_000, 48, 30 minutes); // target 28M, clamped to the 2M ceiling: a cut of the 10M seat
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 5_000_000 * E, "halved, not cut 5x");
        assertEq(sizer.lastCutAt(), uint64(vm.getBlockTimestamp()), "counted as the day's cut");
        assertTrue(vault.seatsPaused(), "5M still burns under 1.5 lines at a 28M target");
    }

    function test_L1_seatAboveCeiling_theCutBranchHalvesAtMost() public {
        SeatVaultV3.Params memory p = _params();
        p.seatSize = 10_000_000 * E;
        vm.prank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.setParams, (p)));
        _pokeAt(1_100_000, 48, 30 minutes); // target 2.8M, ceiling 2M
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 5_000_000 * E, "10M -> 5M, not 2M");
    }

    /// Info (fixed): observations are at least 29 minutes apart, so the 24 a resize needs span over 11 hours.
    function test_minObsSpansOver11Hours() public {
        pm.set(slot, _sqrt(4060));
        vm.prank(keeper);
        sizer.poke();
        vm.warp(vm.getBlockTimestamp() + 28 minutes);
        vm.prank(keeper);
        vm.expectRevert();
        sizer.poke();
        uint256 t0 = vm.getBlockTimestamp() - 28 minutes;
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        vm.prank(keeper);
        sizer.poke();
        _pokeAt(4060, 22, 29 minutes);
        assertGe(vm.getBlockTimestamp() - t0, 11 hours);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 12_500 * E);
    }

    /// INFO: with burnBps under 3000 (the vault allows 2500), a seat at the 5-line target burns 1.25 lines < 1.5, so
    /// every resize that lands on the target pauses the vault.
    function test_poc_burnUnder30pct_everyResizeOnTargetPauses() public {
        SeatVaultV3.Params memory p = _params();
        p.burnBps = 2500;
        vm.prank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.setParams, (p)));
        _pokeAt(40_600, 48, 30 minutes); // target 110,000: a normal raise
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 110_000 * E);
        assertTrue(vault.seatsPaused());
    }

    /// Info (fixed): nobody can renounce: not the sizer's ownership, not the vault's through execute. A renounce would
    /// strand the vault (no unpause, retire, rescue or handback, ever).
    function test_renounceIsRefused_onTheSizerAndOnTheVault() public {
        vm.prank(owner);
        vm.expectRevert(SeatSizer.NoRenounce.selector);
        sizer.renounceOwnership();
        vm.prank(owner);
        vm.expectRevert(SeatSizer.NoRenounce.selector);
        sizer.execute(abi.encodeWithSignature("renounceOwnership()"));
        assertEq(sizer.owner(), owner);
        assertEq(vault.owner(), address(sizer));
    }

    /// Negative checks: what the keeper cannot do.
    function test_keeperCannotReachOwnerPaths() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        sizer.acceptVaultOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        sizer.transferOwnership(keeper);
        vm.expectRevert(SeatSizer.NoRenounce.selector); // refused to everyone, the Safe included
        sizer.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.acceptOwnership();
        vm.stopPrank();
    }

    /// A cut needs a strict majority of low-sqrt observations: 24 bad of 48 moves nothing (upper median).
    function test_cutNeeds25of48() public {
        _pokeAt(40_600, 24, 30 minutes); // 110,000 target (honest, cheap $PRIORS)
        _pokeAt(406, 24, 30 minutes); // 24 pumped
        assertEq(sizer.targetFor(sizer.medianSqrtPrice()), 110_000 * E);
    }

    /// targetFor holds for any sqrtPriceX96 at the vault's line (mulDiv is 512-bit; the unit loop terminates).
    function testFuzz_targetFor_neverReverts(uint160 sp) public view {
        sizer.targetFor(sp);
    }

    function test_targetFor_extremes() public view {
        assertEq(sizer.targetFor(1), 0);
        sizer.targetFor(type(uint160).max);
    }
}
