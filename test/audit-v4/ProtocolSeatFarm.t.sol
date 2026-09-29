// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {SeatVaultV4} from "../../src/SeatVaultV4.sol";
import {SeatVaultV4Base} from "../SeatVaultV4.t.sol";

/// Audit V4 H-1 (fixed): a protocol seat puts no stake of the borrower's at risk, and the record gate alone could be
/// farmed on the attacker's own root for a few fee units. These tests were the proof; they now check the fix: only
/// agents the owner marked eligible take protocol seats, protocol lines have their own weekly budget, and a protocol
/// seat's own default burns its whole slash (the stake shrinks, never refills).
contract ProtocolSeatFarmTest is SeatVaultV4Base {
    address mallory = makeAddr("mallory"); // the attacker's main wallet: owns a throwaway root
    uint256 constant MIN_REPAID = 10;

    function _setBurnKeep(uint256 burnBps, uint256 keepBps) internal {
        SeatVaultV4.Params memory p = _params();
        p.burnBps = burnBps;
        vm.startPrank(owner);
        vault.setParams(p);
        vault.setKeep(keepBps);
        vm.stopPrank();
    }

    /// An honest staker's agent defaults with burn and keep at 100%: one whole seat of protocol stake.
    function _seedProtocolStake() internal {
        _setBurnKeep(10_000, 10_000);
        _offerAndAccept(staker, AGENT_PK, AGENT);
        uint256 loanId = _borrow(agentOp, AGENT, 5 * USDC, 7 days);
        _default(loanId);
        assertEq(vault.protocolTokens(), SEAT);
        vm.startPrank(owner);
        vault.setProtocolFeesTo(owner);
        vault.setProtocolEpochCap(1000 * USDC);
        vault.openProtocolSeats(true);
        vault.setGates(MIN_REPAID, 30 days);
        vm.stopPrank();
    }

    /// A fresh identity, owned by a fresh key, given MIN_REPAID repaid loans on the attacker's own root, then released.
    /// Returns the agent id and its owner's key.
    function _farmRecord(uint256 salt) internal returns (uint256 id, uint256 pk, address op) {
        pk = uint256(keccak256(abi.encode("farm", salt)));
        op = vm.addr(pk);
        vm.prank(op);
        id = reg.register("ipfs://farm");
        usdc.mint(op, 1 * USDC); // for the fees of the farmed loans
        vm.prank(op);
        usdc.approve(address(pool), type(uint256).max);

        vm.startPrank(mallory);
        uint256 root = reg.register("ipfs://mallory-root");
        usdc.approve(address(pool), type(uint256).max);
        pool.enrollRoot(root, 10 * USDC); // the pool's minimum stake, taken back below
        vm.stopPrank();
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consentFor(id, root, pk);
        vm.prank(mallory);
        pool.vouchWithConsent(root, id, 5 * USDC, 0, c, sig);
        for (uint256 i = 0; i < MIN_REPAID; i++) {
            uint256 l = _borrow(op, id, 5 * USDC, 1 days); // the pool's minimum loan and term
            _repay(op, l); // same block
        }
        vm.prank(op);
        pool.leave(id);
        vm.startPrank(mallory);
        pool.unlock(root, pool.rootShares(root), mallory);
        pool.claimSponsorFees(root, mallory);
        vm.stopPrank();
        assertEq(pool.getAgent(id).loansRepaid, MIN_REPAID);
        assertTrue(vault.seatable(id), "the farmed identity passes every gate");
    }

    function _eligible(uint256 id) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        address[] memory owners = new address[](1);
        owners[0] = reg.ownerOf(id); // the owner the Safe vetted
        vm.prank(owner);
        vault.setProtocolEligible(ids, owners, true);
    }

    /// The attack from the audit: a farmed identity passes every record gate, but cannot take a protocol seat.
    function test_farmedIdentity_cannotTakeAProtocolSeat() public {
        _seedProtocolStake();
        _setBurnKeep(6000, 5000);
        usdc.mint(mallory, 10 * USDC);
        (uint256 id, uint256 pk, address op) = _farmRecord(1);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NotEligible.selector, id));
        vault.seatFromProtocol(id, c, sig);
        assertEq(vault.protocolTokens(), SEAT, "the stake did not move");
    }

    /// Even an eligible agent that defaults costs the protocol stake: its slash is burnt in full, with keep at 100%.
    function test_protocolSeatDefault_burnsItsWholeSlash_theStakeShrinks() public {
        _seedProtocolStake();
        _setBurnKeep(6000, 10_000);
        usdc.mint(mallory, 10 * USDC);
        (uint256 id, uint256 pk, address op) = _farmRecord(2);
        _eligible(id);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(op);
        vault.seatFromProtocol(id, c, sig);
        _default(_borrow(op, id, 5 * USDC, 30 days));
        assertEq(vault.protocolTokens(), SEAT * 4 / 10, "60% of the seat slashed and burnt, nothing kept");
    }

    /// Protocol lines have their own weekly budget, inside the vault's.
    function test_protocolEpochCap_boundsProtocolLines() public {
        _seedProtocolStake();
        vm.prank(owner);
        vault.setProtocolEpochCap(0);
        usdc.mint(mallory, 10 * USDC);
        (uint256 id, uint256 pk, address op) = _farmRecord(3);
        _eligible(id);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(op);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.EpochCapReached.selector, 5 * USDC, 0));
        vault.seatFromProtocol(id, c, sig);
        vm.prank(owner);
        vault.setProtocolEpochCap(5 * USDC);
        vm.prank(op);
        vault.seatFromProtocol(id, c, sig);
        assertEq(vault.protocolLinedThisEpoch(), 5 * USDC);
    }
}
