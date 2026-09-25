// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SeatVaultV3} from "../src/SeatVaultV3.sol";
import {SeatSizer, IExtsload} from "../src/SeatSizer.sol";

/// SeatSizer against the live Robinhood Chain state: the real SeatVaultV3 (its 10 treasury seats), the real Safe and
/// the real Uniswap V4 PoolManager. The price moves by writing the pool's slot0 in the PoolManager's storage (sqrtPrice
/// in the low 160 bits, the rest kept), so the sizer reads it exactly the way it would on mainnet.
///
///   FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/SeatSizerFork.t.sol -vv
///
/// Skipped when FORK_RPC is unset.
contract SeatSizerForkTest is Test {
    SeatVaultV3 constant VAULT = SeatVaultV3(0x59D155C42A9263fA7596867b992bB3e84dF680a9);
    address constant SAFE = 0x20c6816B2419616238772591965E6E9AbE493fD5;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    bytes32 constant POOL_ID = 0xff7b3bd2db34d9ed8160e6dedf1d448777abaa1fa6fc8a31144930a1a656fd92;
    uint256 constant E = 1e18;
    address keeper = makeAddr("keeper");
    SeatSizer sizer;
    bytes32 slot;
    bool live;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        live = true;
        sizer = new SeatSizer(VAULT, IExtsload(PM), POOL_ID, SAFE, keeper, 6_000 * E, 2_000_000 * E);
        slot = sizer.priceSlot();
        vm.prank(SAFE);
        VAULT.transferOwnership(address(sizer));
        vm.prank(SAFE);
        sizer.acceptVaultOwnership();
    }

    function _setPrice(uint160 sqrtP) internal {
        uint256 word = uint256(vm.load(PM, slot));
        vm.store(PM, slot, bytes32((word >> 160 << 160) | uint256(sqrtP)));
    }

    function _pokes(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            vm.warp(vm.getBlockTimestamp() + 30 minutes);
            vm.prank(keeper);
            sizer.poke();
        }
    }

    function _size() internal view returns (uint256 s) {
        (s,,,,,) = VAULT.params();
    }

    function test_fork_theSeatFollowsTheLivePriceWithNoSafeSignature() public {
        if (!live) return;
        uint160 spot = uint160(uint256(IExtsload(PM).extsload(slot)));
        assertGt(spot, 0, "the live pool price reads through extsload");
        uint256 start = _size();
        emit log_named_decimal_uint("seatSize today", start, 18);
        emit log_named_decimal_uint("target at today's spot", sizer.targetFor(spot), 18);

        // 12 h at today's price: in band, nothing to do
        _pokes(24);
        vm.prank(keeper);
        vm.expectRevert();
        sizer.resize();

        // $PRIORS falls 16x (sqrtPrice x4) and stays there for over half a day: the seat follows at once
        _setPrice(spot * 4);
        _pokes(25);
        uint256 t = sizer.targetFor(sizer.medianSqrtPrice());
        vm.prank(keeper);
        sizer.resize();
        assertEq(_size(), t, "a raise goes to the target");
        assertGt(_size(), start * 10, "about 16x bigger");
        assertFalse(VAULT.seatsPaused());
        // the treasury's seats (12,000 each) are now under the size: no new loan on them until they are redone
        uint256[] memory open = VAULT.openSeats();
        assertEq(open.length, 10);
        SeatVaultV3.Seat memory s0 = VAULT.getSeat(open[0]);
        assertFalse(VAULT.canBorrow(VAULT.agentId(), open[0], 0, 0, 0, address(0), s0.owner, address(0)));

        // the price comes back: the seat is cut, at most halved and once a day, until it is back in band (within
        // [80%, 2x] of the target; the band then holds it, so there is no resize on every small move)
        _setPrice(spot);
        uint256 prev = _size();
        uint256 cuts;
        for (uint256 d = 0; d < 10; d++) {
            _pokes(48);
            vm.prank(keeper);
            try sizer.resize() {
                uint256 n = _size();
                assertLt(n, prev, "a cut");
                assertGe(n * 2, prev, "at most halved");
                prev = n;
                cuts++;
            } catch {
                break;
            }
        }
        uint256 tt = sizer.targetFor(spot);
        assertGt(cuts, 0);
        assertLe(_size(), tt * 2, "back in band (upper)");
        assertGe(_size() * 10, tt * 8, "back in band (lower)");
        emit log_named_decimal_uint("seatSize after the round trip", _size(), 18);
    }

    function test_fork_theSafeKeepsItsPowers_andTakesTheVaultBack() public {
        if (!live) return;
        uint256[] memory open = VAULT.openSeats();
        vm.startPrank(SAFE);
        sizer.execute(abi.encodeCall(SeatVaultV3.pauseSeats, (true)));
        assertTrue(VAULT.seatsPaused());
        sizer.execute(abi.encodeCall(SeatVaultV3.pauseSeats, (false)));
        sizer.execute(abi.encodeCall(SeatVaultV3.setGates, (3, 30 days)));
        sizer.execute(abi.encodeCall(SeatVaultV3.freezeSeat, (open[0])));
        assertTrue(VAULT.getSeat(open[0]).closing || VAULT.getSeat(open[0]).status == SeatVaultV3.Status.Closed);
        sizer.execute(abi.encodeCall(VAULT.transferOwnership, (SAFE)));
        VAULT.acceptOwnership();
        vm.stopPrank();
        assertEq(VAULT.owner(), SAFE);
    }

    function test_fork_aStrangerCannotPokeOrResize() public {
        if (!live) return;
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.NotKeeper.selector, stranger));
        sizer.poke();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SeatSizer.NotKeeper.selector, stranger));
        sizer.resize();
    }
}
