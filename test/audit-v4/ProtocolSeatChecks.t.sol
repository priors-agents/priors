// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditPoolV2} from "../../src/CreditPoolV2.sol";
import {SeatVaultV3} from "../../src/SeatVaultV3.sol";
import {SeatVaultV4} from "../../src/SeatVaultV4.sol";
import {SeatSizer, IExtsload} from "../../src/SeatSizer.sol";
import {SeatVaultV4Base} from "../SeatVaultV4.t.sol";

contract MockPM is IExtsload {
    mapping(bytes32 => bytes32) public slots;

    function set(bytes32 slot, uint160 p) external {
        slots[slot] = bytes32((uint256(0xABCDEF) << 160) | uint256(p));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
}

/// Audit checks on what V4 adds: the protocol seat levers, fee routing, the stake's reach, SeatSizer on V4, and
/// a fuzzed sequence that checks the $PRIORS and USDG accounting after every step.
contract ProtocolSeatChecksTest is SeatVaultV4Base {
    address funder = makeAddr("funder");

    function _seedWholeSeat() internal {
        SeatVaultV4.Params memory p = _params();
        p.burnBps = 10_000;
        vm.startPrank(owner);
        vault.setParams(p);
        vault.setKeep(10_000);
        vm.stopPrank();
        _offerAndAccept(staker, AGENT_PK, AGENT);
        _default(_borrow(agentOp, AGENT, 5 * USDC, 7 days));
        uint256[] memory ids = new uint256[](1);
        ids[0] = AGENT2;
        vm.startPrank(owner);
        vault.setParams(_params());
        vault.setKeep(5000);
        vault.setProtocolFeesTo(funder);
        vault.setProtocolEpochCap(1000 * USDC);
        vault.setProtocolEligible(ids, _owners(ids), true);
        vault.openProtocolSeats(true);
        vm.stopPrank();
        assertEq(vault.protocolTokens(), SEAT);
    }

    function _protocolSeat(uint256 pk, uint256 id) internal {
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pk);
        vm.prank(vm.addr(pk));
        vault.seatFromProtocol(id, c, sig);
    }

    /// Audit L-1 (fixed): closing protocol seats also stops new loans on the protocol seats already open.
    function test_closingProtocolSeats_stopsBorrowsOnOpenOnes() public {
        _seedWholeSeat();
        _protocolSeat(AGENT2_PK, AGENT2);
        vm.prank(owner);
        vault.openProtocolSeats(false);
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(CreditPoolV2.BorrowBlockedByBacker.selector, VAULT_ID));
        pool.borrow(AGENT2, 5 * USDC, 30 days, agentOp2, type(uint256).max);
    }

    /// Audit I-1 (fixed): no recipient for protocol fees until the owner names one, and protocol seats cannot open
    /// before.
    function test_protocolFeesTo_unsetUntilNamed_andSeatsWaitForIt() public {
        assertEq(vault.protocolFeesTo(), address(0));
        vm.prank(owner);
        vm.expectRevert(SeatVaultV4.NoProtocolFeesTo.selector);
        vault.openProtocolSeats(true);
        vm.expectRevert(SeatVaultV4.NoProtocolFeesTo.selector);
        vault.claimProtocolFees();
    }

    /// The protocol seat's fees survive skim and reach protocolFeesTo; the staker-side paths cannot touch them.
    function test_protocolFees_notSkimmed_notClaimableByOthers() public {
        _seedWholeSeat();
        vm.prank(owner);
        vault.setProtocolFeesTo(funder);
        _protocolSeat(AGENT2_PK, AGENT2);
        uint256 l = _borrow(agentOp2, AGENT2, 5 * USDC, 30 days);
        vm.warp(block.timestamp + 10 days);
        _repay(agentOp2, l);
        vault.skim();
        uint256 owed = vault.feesOwed(address(vault));
        assertGt(owed, 0);
        vm.prank(address(0xBEEF));
        vm.expectRevert(SeatVaultV4.ZeroAmount.selector);
        vault.claim(address(0xBEEF));
        vault.claimProtocolFees();
        assertEq(usdc.balanceOf(funder), owed);
        assertEq(vault.totalFeesOwed(), 0);
    }

    /// No leftover offer or stake move when the seat cannot open (bad consent), and the vault's offer/seat slot
    /// cannot be reached by accept / withdrawOffer.
    function test_failedProtocolSeat_leavesNothing_andVaultOfferUnreachable() public {
        _seedWholeSeat();
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(AGENT2, AGENT_PK); // wrong signer
        vm.prank(agentOp2);
        vm.expectRevert();
        vault.seatFromProtocol(AGENT2, c, sig);
        assertEq(vault.protocolTokens(), SEAT);
        assertEq(vault.offers(AGENT2, address(vault)), 0);
        assertEq(vault.tokensHeld(), 0);

        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NoOffer.selector, AGENT2, address(vault)));
        vault.withdrawOffer(AGENT2, address(vault));
        (c, sig) = _consent(AGENT2, AGENT2_PK);
        vm.prank(agentOp2);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.NoOffer.selector, AGENT2, address(vault)));
        vault.accept(AGENT2, address(vault), c, sig);

        _protocolSeat(AGENT2_PK, AGENT2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SeatVaultV4.Protected.selector, address(priors)));
        vault.rescue(address(priors), owner);
    }

    /// SeatSizer, typed against SeatVaultV3, drives a V4 unchanged (same Params ABI, same epoch length, so a resize
    /// never restarts the epoch), and the Safe reaches the V4 setters through execute.
    function test_seatSizer_drivesV4() public {
        MockPM pm = new MockPM();
        SeatSizer sizer =
            new SeatSizer(SeatVaultV3(address(vault)), pm, keccak256("p"), owner, keeper, 5_000e18, 2_000_000e18);
        vm.prank(owner);
        vault.transferOwnership(address(sizer));
        vm.prank(owner);
        sizer.acceptVaultOwnership();
        uint160 px = uint160(Math.sqrt((uint256(4060) * 1e11) << 192));
        for (uint256 i = 0; i < 24; i++) {
            pm.set(sizer.priceSlot(), px);
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            vm.prank(keeper);
            sizer.poke();
        }
        uint64 start = vault.epochStart();
        vm.prank(keeper);
        sizer.resize();
        (uint256 size,,,,,) = vault.params();
        assertEq(size, 12_500e18);
        assertEq(vault.epochStart(), start, "a resize keeps the epoch");
        vm.startPrank(owner);
        sizer.execute(abi.encodeCall(SeatVaultV4.setKeep, (5000)));
        sizer.execute(abi.encodeCall(SeatVaultV4.setProtocolFeesTo, (funder)));
        sizer.execute(abi.encodeCall(SeatVaultV4.openProtocolSeats, (true)));
        sizer.execute(abi.encodeCall(SeatVaultV4.setMaxLoanTerm, (7 days)));
        vm.stopPrank();
        assertEq(vault.keepBps(), 5000);
        assertTrue(vault.protocolSeatsOpen());
        assertEq(vault.maxLoanTerm(), 7 days, "the Safe reaches the term cap through execute");
    }

    // ---- fuzzed sequences: accounting after every step ----

    function _check() internal view {
        uint256 bal = priors.balanceOf(address(vault));
        assertGe(bal, vault.tokensHeld() + vault.protocolTokens(), "PRIORS: balance >= held + protocol");
        // every PRIORS the vault holds is accounted for (no stray transfers in this sequence)
        assertEq(bal, vault.tokensHeld() + vault.protocolTokens(), "PRIORS: exact");
        uint256 usd = usdc.balanceOf(address(vault)) + pool.sponsorFees(VAULT_ID);
        assertGe(usd, vault.totalFeesOwed(), "USDG: owed is covered");
    }

    function testFuzz_sequence(uint256 seed) public {
        _seedWholeSeat(); // AGENT is dead after this
        vm.prank(owner);
        vault.setKeep(bound(seed, 0, 10_000));
        uint256[4] memory pks = [AGENT2_PK, uint256(0xC1), uint256(0xC2), uint256(0xC3)];
        uint256[4] memory ids;
        ids[0] = AGENT2;
        for (uint256 i = 1; i < 4; i++) {
            address o = vm.addr(pks[i]);
            vm.startPrank(o);
            ids[i] = reg.register("x");
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();
            usdc.mint(o, 100 * USDC);
        }
        uint256[] memory el = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            el[i] = ids[i];
        }
        address[] memory vetted = _owners(el); // before the prank: reading the owners is a call too
        vm.prank(owner);
        vault.setProtocolEligible(el, vetted, true);
        uint256[] memory loansOf = new uint256[](4);
        for (uint256 step = 0; step < 60; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 k = seed % 4;
            uint256 id = ids[k];
            address op = vm.addr(pks[k]);
            uint256 action = (seed >> 8) % 11;
            if (action == 0) {
                vm.prank(staker);
                try vault.offer(id) {} catch {}
            } else if (action == 1) {
                (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pks[k]);
                vm.prank(op);
                try vault.accept(id, staker, c, sig) {} catch {}
            } else if (action == 2) {
                (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, pks[k]);
                vm.prank(op);
                try vault.seatFromProtocol(id, c, sig) {} catch {}
            } else if (action == 3) {
                vm.prank(op);
                try pool.borrow(id, 5 * USDC, 7 days, op, type(uint256).max) returns (uint256 l) {
                    loansOf[k] = l;
                } catch {}
            } else if (action == 4 && loansOf[k] != 0) {
                vm.prank(op);
                try pool.repay(loansOf[k], id, type(uint256).max) {} catch {}
            } else if (action == 5 && loansOf[k] != 0) {
                CreditPoolV2.Loan memory l = pool.getLoan(loansOf[k]);
                if (l.status == CreditPoolV2.LoanStatus.Active) {
                    vm.warp(l.defaultableAt + 1);
                    vm.prank(keeper);
                    try pool.markDefault(loansOf[k]) {} catch {}
                }
            } else if (action == 6) {
                vm.prank(op);
                try vault.close(id) {} catch {}
            } else if (action == 7) {
                vm.prank(owner);
                try vault.freezeSeat(id) {} catch {}
            } else if (action == 8) {
                try vault.skim() {} catch {}
                try vault.claimProtocolFees() {} catch {}
                vm.prank(staker);
                try vault.claim(staker) {} catch {}
            } else if (action == 9) {
                vm.prank(staker);
                try vault.withdrawOffer(id, staker) {} catch {}
                vm.prank(op);
                try vault.withdrawOffer(id, address(vault)) {} catch {}
            } else if (action == 10) {
                vm.prank(owner);
                try vault.rescue(address(priors), owner) {} catch {}
                try vault.settle(id, loansOf[k]) {} catch {}
                vm.warp(block.timestamp + 1 days);
            }
            _check();
        }
    }

    /// the owners the Safe vetted: whoever holds each id now
    function _owners(uint256[] memory ids) internal view returns (address[] memory owners) {
        owners = new address[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            owners[i] = reg.ownerOf(ids[i]);
        }
    }
}
