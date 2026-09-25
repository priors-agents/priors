// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SeatVaultV3Base} from "./SeatVaultV3.t.sol";
import {SeatVaultV3} from "../src/SeatVaultV3.sol";
import {SeatSizer, IExtsload} from "../src/SeatSizer.sol";

/// A PoolManager whose pool slot answers a price the test sets (sqrtPriceX96 in the low 160 bits, as slot0 packs it).
contract MockPoolManager is IExtsload {
    mapping(bytes32 => bytes32) public slots;

    function set(bytes32 slot, uint160 sqrtPriceX96) external {
        // slot0 packs sqrtPriceX96 (low 160 bits) with tick and fees above it: keep something in the high bits
        slots[slot] = bytes32((uint256(0xABCDEF) << 160) | uint256(sqrtPriceX96));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
}

/// SeatSizer: the vault's seat follows the $PRIORS price without a Safe signature, within bounds a keeper cannot leave,
/// and the Safe keeps every other owner power. Base terms: seat 25,000 $PRIORS, line $5, burn 50%.
contract SeatSizerTest is SeatVaultV3Base {
    bytes32 constant POOL_ID = keccak256("priors/usdg");
    uint256 constant E = 1e18;
    MockPoolManager pm;
    SeatSizer sizer;
    bytes32 slot;

    function setUp() public override {
        super.setUp();
        pm = new MockPoolManager();
        sizer = new SeatSizer(vault, pm, POOL_ID, owner, keeper, 5_000 * E, 2_000_000 * E);
        slot = sizer.priceSlot();
        vm.prank(owner);
        vault.transferOwnership(address(sizer));
        vm.prank(owner);
        sizer.acceptVaultOwnership();
    }

    /// sqrtPriceX96 for `perUsdg` whole $PRIORS per whole USDG (raw ratio perUsdg * 1e12).
    function _sqrt(uint256 perUsdgX10) internal pure returns (uint160) {
        return uint160(Math.sqrt((perUsdgX10 * 1e11) << 192));
    }

    function _pokeAt(uint256 perUsdgX10, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            pm.set(slot, _sqrt(perUsdgX10));
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            vm.prank(keeper);
            sizer.poke();
        }
    }

    function _size() internal view returns (uint256 s) {
        (s,,,,,) = vault.params();
    }

    function test_setUp_theSizerOwnsTheVault() public view {
        assertEq(vault.owner(), address(sizer));
        assertEq(sizer.owner(), owner);
        assertEq(slot, keccak256(abi.encode(POOL_ID, uint256(6))));
    }

    function test_target_matchesTheKeeperMath() public view {
        // 406 $PRIORS per USDG: 5 lines = $25 = 10,150 $PRIORS, rounded up to 2 significant digits = 11,000 (as
        // scripts/test-seat-price-guard.mjs pins for targetSeatSize)
        assertEq(sizer.targetFor(_sqrt(4060)), 11_000 * E);
        assertEq(sizer.targetFor(_sqrt(40_600)), 110_000 * E);
    }

    function test_poke_onlyKeeperOrSafe_andRateLimited() public {
        pm.set(slot, _sqrt(4060));
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.NotKeeper.selector, anyone));
        sizer.poke();
        vm.prank(keeper);
        sizer.poke();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.TooSoon.selector, uint64(vm.getBlockTimestamp() + 29 minutes)));
        sizer.poke();
        vm.warp(vm.getBlockTimestamp() + 29 minutes);
        vm.prank(owner);
        sizer.poke();
        assertEq(sizer.obsCount(), 2);
    }

    function test_poke_refusesAnUnreadablePrice() public {
        vm.prank(keeper);
        vm.expectRevert(SeatSizer.PriceUnreadable.selector);
        sizer.poke();
    }

    function test_resize_needs12HoursOfObservations() public {
        _pokeAt(4060, 23);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.NotEnoughObservations.selector, 23, 24));
        sizer.resize();
    }

    function test_resize_cutsFollowASustainedMove_atMost2xPerDay_noSafeSignature() public {
        // today's price, 12 h of it: target 11,000, but a cut may halve at most (25,000 -> 12,500)
        _pokeAt(4060, 24);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 12_500 * E);
        // one cut a day
        _pokeAt(406, 25); // $PRIORS 10x dearer for 12.5 h, over half the window: a further cut is due
        uint64 nextCut = sizer.lastCutAt() + 1 days;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.TooSoon.selector, nextCut));
        sizer.resize();
        // and a price back to today's is in band (12,500 is within [80%, 2x] of 11,000): nothing to do
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _pokeAt(4060, 48);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.InBand.selector, 12_500 * E, 11_000 * E));
        sizer.resize();
    }

    function test_resize_onlyTheLastDayCounts_aStaleWindowCannotResize() public {
        // a full day of observations at a high $PRIORS price, then the keeper goes quiet for 3 days
        _pokeAt(406, 48);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        // one fresh observation is not a median: the stale ones must not size the seat
        _pokeAt(4060, 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.NotEnoughObservations.selector, 1, 24));
        sizer.resize();
        // 12 h of fresh observations and it works again, on fresh prices only
        _pokeAt(4060, 23);
        assertEq(sizer.targetFor(sizer.medianSqrtPrice()), 11_000 * E);
    }

    function test_resize_aPumpShorterThanHalfTheWindowMovesNothing() public {
        // 25 honest observations, then 23 with $PRIORS 10x dearer (a pump held for 11.5 h): the median is honest
        _pokeAt(4060, 25);
        _pokeAt(406, 23);
        assertEq(sizer.targetFor(sizer.medianSqrtPrice()), 11_000 * E);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 12_500 * E); // the same as with no pump at all
    }

    function test_resize_neverUnderTheFloor_evenOnASustainedPump() public {
        // $PRIORS 100x dearer for days: target 110 $PRIORS; the seat halves once a day and stops at the floor
        uint256[3] memory want = [uint256(12_500), 6_250, 5_000];
        for (uint256 d = 0; d < 3; d++) {
            _pokeAt(41, 48);
            vm.prank(keeper);
            sizer.resize();
            assertEq(_size(), want[d] * E);
        }
        _pokeAt(41, 48);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.Unchanged.selector, 5_000 * E));
        sizer.resize();
    }

    function test_resize_raisesAtOnce_anyTime() public {
        // a cut today...
        _pokeAt(4060, 24);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 12_500 * E);
        // ...then $PRIORS falls 10x for more than half the window: the raise goes straight to the target, same day
        _pokeAt(40_600, 25);
        assertEq(sizer.targetFor(sizer.medianSqrtPrice()), 110_000 * E);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 110_000 * E);
        assertFalse(vault.seatsPaused());
    }

    function test_resize_theCeilingPausesSeatsWhenItLeavesTheBurnUnder1point5Lines() public {
        // $PRIORS 1000x cheaper: target 11M, over the 2M ceiling. A 2M seat would burn 1M = 0.45 line: seats pause.
        _pokeAt(40_600_000, 48);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 2_000_000 * E);
        assertTrue(vault.seatsPaused());
    }

    function test_resize_aCeilingThatStillLeaves1point5LinesDoesNotPause() public {
        // target 3M against the 2M ceiling: 2M burns 1M = 1.67 lines, above 1.5: no pause
        vm.prank(owner);
        sizer.setBounds(5_000 * E, 2_000_000 * E);
        _pokeAt(1_100_000, 48); // 110,000 $PRIORS per USDG: $25 = 2.75M -> 2.8M
        assertEq(sizer.targetFor(sizer.medianSqrtPrice()), 2_800_000 * E);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 2_000_000 * E);
        assertFalse(vault.seatsPaused());
    }

    function test_resize_changesOnlyTheSeatSize() public {
        (, uint256 line, uint256 burnBps, uint256 maxOpen, uint256 cap, uint64 len) = vault.params();
        _pokeAt(4060, 24);
        vm.prank(keeper);
        sizer.resize();
        (uint256 s2, uint256 line2, uint256 burn2, uint256 maxOpen2, uint256 cap2, uint64 len2) = vault.params();
        assertEq(s2, 12_500 * E);
        assertEq(line2, line);
        assertEq(burn2, burnBps);
        assertEq(maxOpen2, maxOpen);
        assertEq(cap2, cap);
        assertEq(len2, len);
        assertFalse(vault.seatsPaused());
    }

    function test_aRaiseStopsLoansOnSmallerSeats_aCutDoesNot() public {
        _offerAndAccept(staker, AGENT_PK, AGENT); // a 25,000 seat
        // a cut to 12,500: the 25,000 seat still borrows
        _pokeAt(4060, 24);
        vm.prank(keeper);
        sizer.resize();
        _borrow(agentOp, AGENT, 5 * USDC, 2 days);
        // a raise to 110,000 ($PRIORS 10x cheaper): the 25,000 seat can no longer borrow
        _pokeAt(40_600, 25);
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), 110_000 * E);
        assertFalse(vault.canBorrow(VAULT_ID, AGENT, 0, 0, 0, address(0), agentOp, address(0)));
    }

    function test_theKeeperHasNoOtherPower() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        sizer.execute(abi.encodeCall(SeatVaultV3.pauseSeats, (true)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        sizer.setBounds(1, 2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        sizer.setKeeper(keeper);
        vm.stopPrank();
        // and the vault's owner functions cannot be reached around the sizer
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.pauseSeats(true);
    }

    function test_theSafeKeepsEveryOwnerPower() public {
        vm.startPrank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.pauseSeats, (true)));
        assertTrue(vault.seatsPaused());
        sizer.execute(abi.encodeCall(SeatVaultV3.pauseSeats, (false)));
        sizer.execute(abi.encodeCall(SeatVaultV3.setGates, (3, 30 days)));
        assertEq(vault.minRepaid(), 3);
        sizer.execute(abi.encodeCall(SeatVaultV3.setGates, (0, 30 days))); // back to the test agent's (no history)
        SeatVaultV3.Params memory p = _params();
        p.seatSize = 7_000 * E;
        sizer.execute(abi.encodeCall(SeatVaultV3.setParams, (p)));
        assertEq(_size(), 7_000 * E);
        sizer.setKeeper(anyone);
        assertEq(sizer.keeper(), anyone);
        vm.stopPrank();
        // freeze a seat
        vm.prank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.setParams, (_params())));
        _offerAndAccept(staker, AGENT_PK, AGENT);
        vm.prank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV3.freezeSeat, (AGENT)));
        assertEq(uint8(_status(AGENT)), uint8(SeatVaultV3.Status.Closed));
        // a revert inside the vault surfaces as the vault's own error
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NoOpenSeat.selector, AGENT));
        sizer.execute(abi.encodeCall(SeatVaultV3.freezeSeat, (AGENT)));
        // and the Safe takes the vault back
        vm.prank(owner);
        sizer.execute(abi.encodeCall(vault.transferOwnership, (owner)));
        vm.prank(owner);
        vault.acceptOwnership();
        assertEq(vault.owner(), owner);
    }

    function test_bounds_mustBeSane() public {
        vm.startPrank(owner);
        vm.expectRevert(SeatSizer.BadBounds.selector);
        sizer.setBounds(0, 1);
        vm.expectRevert(SeatSizer.BadBounds.selector);
        sizer.setBounds(10, 9);
        vm.stopPrank();
    }
}
