// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SeatVaultV3} from "../../src/SeatVaultV3.sol";
import {SeatVaultV3Base} from "../SeatVaultV3.t.sol";

/// X-3 launch mitigation (audit 2026-09-23): the vault is paused (`pauseSeats(true)`) from deployment until
/// `seatSize` is priced so that half a seat is worth well above `line`. Until then the self-seat loop of
/// `SeatVaultV3ExploitsTest.test_X3_selfSeatLoop_drainsEpochCapPerEpoch` must take nothing.
///
///   GREEN (mitigated):  forge test --match-path test/audit-v2/SeatVaultV3X3Mitigation.t.sol
///   RED (launch params, not paused):  X3_UNMITIGATED=true forge test --match-path test/audit-v2/SeatVaultV3X3Mitigation.t.sol
contract SeatVaultV3X3MitigationTest is SeatVaultV3Base {
    uint256 constant LSEAT = 1_000_000e18;

    function test_X3_pausedAtLaunch_selfSeatLoopTakesNothing() public {
        vm.startPrank(owner);
        vault.setParams(
            SeatVaultV3.Params({
                seatSize: LSEAT, line: 5 * USDC, burnBps: 5000, maxOpenSeats: 10, epochCap: 50 * USDC, epochLength: 7 days
            })
        );
        if (!vm.envOr("X3_UNMITIGATED", false)) vault.pauseSeats(true);
        vm.stopPrank();

        address loot = makeAddr("loot");
        uint256 backing0 = pool.backing(VAULT_ID);
        uint256[] memory loans = new uint256[](10);
        uint256 n;
        for (uint256 i = 0; i < 10; i++) {
            address a = vm.addr(0x6000 + i);
            priors.mint(a, LSEAT);
            vm.startPrank(a);
            priors.approve(address(vault), type(uint256).max);
            try vault.registerAndSeat("") returns (uint256 id) {
                loans[n++] = pool.borrow(id, 5 * USDC, 1 days, loot, type(uint256).max);
            } catch {}
            vm.stopPrank();
        }
        if (n > 0) {
            vm.warp(pool.getLoan(loans[0]).defaultableAt + 1);
            for (uint256 i = 0; i < n; i++) {
                vm.prank(keeper);
                pool.markDefault(loans[i]);
            }
        }

        assertEq(usdc.balanceOf(loot), 0, "the loop takes nothing while seats are paused");
        assertEq(pool.backing(VAULT_ID), backing0, "the funder's stake is untouched");
    }

    /// Pausing never traps a staker: a seat opened before the pause still closes with every token back.
    function test_X3_pauseLeavesExitsOpen() public {
        address a = vm.addr(0x7000);
        priors.mint(a, SEAT);
        vm.startPrank(a);
        priors.approve(address(vault), type(uint256).max);
        uint256 id = vault.registerAndSeat("");
        vm.stopPrank();

        vm.prank(owner);
        vault.pauseSeats(true);

        vm.prank(a);
        vault.close(id);
        assertEq(priors.balanceOf(a), SEAT, "every token back while paused");
    }
}
