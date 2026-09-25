// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {SeatVaultV3} from "../../src/SeatVaultV3.sol";
import {SeatVaultV3Base} from "../SeatVaultV3.t.sol";

/// Independent review of SeatVaultV3 (2026-09-23). Each `test_F*` PASSES by demonstrating the finding.
contract ReviewSeatVaultV3 is SeatVaultV3Base {
    /// F-3 (Low): an offer is bound to an agent id, not to the owner the staker trusted. The pool consent dies
    /// with an NFT sale; the staker's offer does not. The buyer accepts it with its own consent, draws the
    /// line and walks: the stranger's seat is burnt, the vault funder loses the line, the buyer risks nothing.
    function test_F3_offerOutlivesAnNFTSale_buyerBurnsTheStakersSeat() public {
        uint256 before = priors.balanceOf(staker);
        vm.prank(staker);
        vault.offer(AGENT); // the staker trusts agentOp

        uint256 buyerPk = 0xBAD;
        address buyer = vm.addr(buyerPk);
        vm.prank(agentOp);
        reg.transferFrom(agentOp, buyer, AGENT); // sale

        // Fixed 2026-09-24 (this demonstrated the finding before): the offer is bound to agentOp, so the buyer's
        // accept is refused and the staker keeps its whole seat.
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT, buyerPk);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.OwnerChanged.selector, AGENT, agentOp, buyer));
        vault.accept(AGENT, staker, c, sig);
        vm.prank(staker);
        vault.withdrawOffer(AGENT, staker);
        assertEq(priors.balanceOf(staker), before, "the staker's seat is whole");
        assertEq(usdc.balanceOf(buyer), 0, "the buyer takes nothing");
    }

    /// F-4 (Low): idle seats are permanent. Nobody but the squatter (staker or controller) can close a seat
    /// that never borrows, and the owner has no reclaim, so refundable tokens can hold every seat (and the
    /// vault's backing) forever. Bounded per epoch by epochCap, capped at MAX_OPEN_SEATS.
    function test_F4_idleSeatsFillTheVaultAndOnlyTheSquatterCanFreeThem() public {
        SeatVaultV3.Params memory p = _params();
        p.maxOpenSeats = 2;
        vm.prank(owner);
        vault.setParams(p);

        uint256 first;
        for (uint256 i = 0; i < 2; i++) {
            uint256 pk = 0x7000 + i;
            address a = vm.addr(pk);
            priors.mint(a, SEAT);
            vm.startPrank(a);
            priors.approve(address(vault), type(uint256).max);
            uint256 id = reg.register("squat");
            vm.stopPrank();
            (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
            vm.prank(a);
            vault.seat(id, c, sig);
            if (i == 0) first = id;
        }

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.NotStakerOrController.selector, first, owner));
        vault.close(first);

        vm.warp(block.timestamp + 365 days);
        vm.prank(staker);
        vault.offer(AGENT);
        (CreditPoolV2.Consent memory c2, bytes memory sig2) = _consent(AGENT, AGENT_PK);
        vm.prank(agentOp);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV3.TooManySeats.selector, 2, 2));
        vault.accept(AGENT, staker, c2, sig2);
    }
}
