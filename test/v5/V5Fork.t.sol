// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {ISwapLimiter} from "../../src/interfaces/ISwapLimiter.sol";
import {ISeatSizerV4, IV4SwapOnce, IPermit2V5, IExtsloadV5, V5PoolKey} from "../../src/interfaces/IV5Deps.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {V5Lens} from "../../src/v5/V5Lens.sol";
import {C, IV5Errors} from "../../src/v5/V5Types.sol";
import {IPoolT} from "./V5Base.sol";
import {IV5Lens} from "./IV5Lens.sol";
import {MockLimiter} from "./V5Mocks.sol";

interface IForkRegistry {
    function register(string calldata uri) external returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

interface IForkSizer is ISeatSizerV4 {
    function keeper() external view returns (address);
    function poke() external;
}

/// @dev An owner that signs by ERC-1271: installed with `vm.etch` at a live agent's owner address, so the fork can
///      give that owner's consent (the pool's `validSig` falls back to 1271 when ECDSA does not recover the owner).
contract Accept1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}

/// @title SeatVaultV5 rehearsal against LIVE Robinhood Chain state (spec 12.2, "Fork rehearsals").
/// @notice Runs only when FORK_RPC is set; everything happens inside the local fork, nothing is broadcast:
///           anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8545 &
///           FORK_RPC=http://127.0.0.1:8545 forge test --match-path test/v5/V5Fork.t.sol -vv
///         It deploys V5 on the fork against the live pool v2, USDG, $PRIORS, the ERC-8004 registry, SeatSizerV4, the
///         PoolManager's slot0 of the $PRIORS pool, V4SwapOnce and Permit2 (the SwapLimiter is not deployed yet: a
///         mock with its surface stands in), gives it a root of its own, and runs the migration handoff of a live
///         agent sponsored by TreasurySponsorV4's root (6228), the entry read through `qualifiedRepaid`, a back, loans,
///         a promotion, a default with its burn, and an owner change. The live SeatSizerV4 is poked by its own keeper
///         (pranked) as time moves, so V5's `sync()` reads real observations of the live pool's price.
contract V5ForkTest is Test {
    IPoolT constant POOL = IPoolT(0x281210097f0de7A8FB6F87310AF0f089c9C8DE21);
    IForkRegistry constant REG = IForkRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    IERC20 constant PRIORS = IERC20(0xeDBf91223639800BCd5756815CAf908Df3b890bE);
    IForkSizer constant SIZER = IForkSizer(0x97C4e594D458f8BBE961d5384Bbd8a9Cc2D18777);
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant SWAP_ONCE = 0x7Cd4E04E433E69e588728c86A3832753B5F846d4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SAFE = 0x20c6816B2419616238772591965E6E9AbE493fD5;
    address constant TIMELOCK = 0x5d984C274035F81BB327d532897a902C5125F87c;
    uint256 constant TREASURY_ROOT = 6228;
    uint256 constant V4_ROOT = 6466;
    uint256 constant U = 1e6;
    uint256 constant T = 1e18;

    // agents moved to root 6228 on the live pool (SponsorChanged logs, blocks 70,000,000 to 79,477,975)
    uint256[18] internal candidates = [
        uint256(7627),
        7624,
        7622,
        7619,
        7616,
        6579,
        6577,
        6574,
        6526,
        6565,
        6459,
        6563,
        6458,
        6522,
        6516,
        6463,
        6448,
        6434
    ];

    bool forked;
    SeatVaultV5 v5;
    IV5Lens lens;
    MockLimiter limiter;
    uint256 root;
    address bb = makeAddr("buyAndBack");
    address keeper = makeAddr("v5Keeper");
    address backer = makeAddr("backer");
    address funder = makeAddr("funder");

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        forked = true;
        assertEq(block.chainid, 4663, "Robinhood Chain");
        assertEq(POOL.usdg(), address(USDG));
        assertEq(POOL.registry(), address(REG));

        limiter = new MockLimiter();
        root = REG.register("ipfs://v5-fork-root");
        SeatVaultV5.Init memory i;
        i.pool = POOL;
        i.priors = PRIORS;
        i.permit2 = IPermit2V5(PERMIT2);
        i.swapper = IV4SwapOnce(SWAP_ONCE);
        i.swapLimiter = ISwapLimiter(address(limiter));
        i.poolKey = V5PoolKey(address(USDG), address(PRIORS), 0, 200, HOOK);
        i.poolManager = IExtsloadV5(PM);
        i.buyAndBack = bb;
        i.sizer = SIZER;
        i.rootId = root;
        i.guardian = SAFE;
        i.timelock = TIMELOCK;
        i.retireTo = SAFE;
        i.keeper = keeper;
        i.epoch0 = (block.timestamp / 1 days - ((block.timestamp / 1 days + 3) % 7)) * 1 days; // this week's Monday
        i.maxSwapUsdg = 1_900 * U;
        i.openRoom = 500 * U;
        i.raiseRoom = 500 * U;
        i.vouchCap = 1_000 * U;
        v5 = new SeatVaultV5(i);
        lens = IV5Lens(address(v5));
        REG.transferFrom(address(this), address(v5), root);
        // V4's free root stake would arrive this way (spec 7, Stage 1): anyone funds V5's root
        deal(address(USDG), funder, 1_100 * U);
        vm.startPrank(funder);
        USDG.approve(address(v5), type(uint256).max);
        v5.fund(1_100 * U);
        vm.stopPrank();
        assertTrue(POOL.getAgent(root).isRoot);
        _keeperDay();
        console2.log("fork block", block.number);
    }

    // ------------------------------------------------------------------
    // time and the live keeper
    // ------------------------------------------------------------------

    /// @dev One day of the live SeatSizerV4's keeper passes (every 30 minutes) at the live pool's price, then V5's
    ///      `sync()`.
    function _keeperDay() internal {
        address k = SIZER.keeper();
        for (uint256 j = 0; j < 48; j++) {
            vm.warp(block.timestamp + 30 minutes);
            vm.prank(k);
            SIZER.poke();
        }
        v5.sync();
    }

    function _keeperHalfHours(uint256 n) internal {
        address k = SIZER.keeper();
        for (uint256 j = 0; j < n; j++) {
            vm.warp(block.timestamp + 30 minutes);
            vm.prank(k);
            SIZER.poke();
        }
        v5.sync();
    }

    function _days(uint256 n) internal {
        for (uint256 j = 0; j < n; j++) {
            _keeperDay();
        }
    }

    // ------------------------------------------------------------------
    // agents
    // ------------------------------------------------------------------

    /// @dev The first live agent under root 6228 with no loan open, never defaulted, whose owner has no default.
    function _liveAgent() internal view returns (uint256 id) {
        for (uint256 j = 0; j < candidates.length; j++) {
            ICreditPoolV2.Agent memory a = POOL.getAgent(candidates[j]);
            if (a.sponsor != TREASURY_ROOT || a.activeLoans != 0 || a.defaulted || a.isRoot) continue;
            if (POOL.ownerDefaults(REG.ownerOf(candidates[j])) != 0) continue;
            return candidates[j];
        }
    }

    /// @dev The live owner gives its consent by ERC-1271 (its code replaced with `Accept1271` on the fork).
    function _consentOf(uint256 id) internal returns (ICreditPoolV2.Consent memory c, bytes memory sig) {
        address o = REG.ownerOf(id);
        vm.etch(o, address(new Accept1271()).code);
        c = ICreditPoolV2.Consent({
            agentId: id,
            sponsorId: root,
            owner: o,
            maxPremiumBps: 0,
            nonce: POOL.nonces(id),
            deadline: block.timestamp + 1 hours
        });
        sig = hex"00";
    }

    function _fund(address who) internal {
        deal(address(PRIORS), who, 5_000_000 * T);
        deal(address(USDG), who, USDG.balanceOf(who) + 1_000 * U);
        vm.startPrank(who);
        PRIORS.approve(address(v5), type(uint256).max);
        USDG.approve(address(POOL), type(uint256).max);
        vm.stopPrank();
    }

    function _stakeFor(uint256 id) internal view returns (uint256) {
        V5Lens.Needed memory n = lens.needed(id, 0, true);
        uint256 t = n.fullLine + n.fullLine / 50;
        return t < n.capA ? t : n.capA;
    }

    function _borrow(uint256 id, uint256 amount, uint64 term) internal returns (uint256 loanId) {
        address o = REG.ownerOf(id);
        vm.prank(o);
        v5.refresh(id);
        vm.prank(o);
        loanId = POOL.borrow(id, amount, term, o, type(uint256).max);
    }

    function _repay(uint256 loanId) internal {
        ICreditPoolV2.Loan memory l = POOL.getLoan(loanId);
        deal(address(USDG), l.owner, USDG.balanceOf(l.owner) + l.principal + l.fee);
        vm.prank(l.owner);
        USDG.approve(address(POOL), type(uint256).max);
        vm.prank(l.owner);
        POOL.repay(loanId, l.agentId, type(uint256).max);
    }

    // ------------------------------------------------------------------
    // the rehearsal
    // ------------------------------------------------------------------

    /// @dev The migration handoff of a live agent from TreasurySponsorV4's root: the entry rule read through the
    ///      pool's `qualifiedRepaid` and `enrolledAt`; then the owner's open moves the sponsorship to V5's root in the
    ///      same transaction, and the line opens on the owner's stake at live P.
    function test_fork_handoff_back_loans_promote_default() public onFork {
        uint256 id = _liveAgent();
        assertGt(id, 0, "a live agent under root 6228 with no loan open");
        _handoff(id);
        _backAndClimb(id);
        _defaultAndBurn(id);
    }

    function _handoff(uint256 id) internal {
        address o = REG.ownerOf(id);
        _fund(o);
        ICreditPoolV2.Agent memory a0 = POOL.getAgent(id);
        console2.log("agent", id, "qualifiedRepaid", a0.qualifiedRepaid);
        // the spec's entry rule (3 loans held 7 days, 14 days since enrolment), read from the live record
        vm.prank(TIMELOCK);
        v5.setEntryRule(3, 14);
        uint256 stake = _stakeFor(id);
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consentOf(id);
        if (a0.qualifiedRepaid < 3) {
            vm.prank(o);
            vm.expectRevert(abi.encodeWithSelector(IV5Errors.NotEligible.selector, 3));
            v5.open(id, stake, false, c, sig);
            // the owner's addition: stake-only entry at T1 (the default rule)
            vm.prank(TIMELOCK);
            v5.setEntryRule(0, 0);
        }
        vm.prank(o);
        v5.open(id, stake, false, c, sig);
        assertEq(POOL.getAgent(id).sponsor, root, "the handoff: V5's root sponsors it now");
        S.Gen memory g = lens.getGen(id, 1);
        assertEq(g.tier, 1);
        assertGe(g.openLine, 25 * U);
        console2.log("open line", g.openLine, "A", g.counted[C.OWNER]);
    }

    /// @dev A backer; three counted loans at T1 ($25, 8 days, repaid after 7) and 14 days at the tier: T2; the
    ///      backer's share of the live fees.
    function _backAndClimb(uint256 id) internal {
        _fund(backer);
        vm.prank(TIMELOCK);
        v5.setOpenBacking(true);
        uint256 b = lens.getGen(id, 1).counted[C.OWNER] / 4;
        vm.prank(backer);
        v5.back(id, b, false);
        for (uint256 j = 0; j < 3; j++) {
            uint256 l = _borrow(id, 25 * U, 8 days);
            _days(7);
            _keeperHalfHours(2);
            _repay(l);
        }
        v5.pokeFees(id);
        assertEq(lens.getGen(id, 1).countedAtTier, 3);
        v5.promote(id);
        assertEq(lens.getGen(id, 1).tier, 2, "promoted on the live pool's loans");
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        uint32[] memory gens = new uint32[](1);
        gens[0] = 1;
        vm.prank(backer);
        uint256 paid = v5.collect(ids, gens);
        assertGt(paid, 0, "the backer's share of the live fees");
    }

    /// @dev A default: the hook settles and burns 75% of A and 50% of the backing, each rounded up; the remainders
    ///      come back at once; V5's balance still covers its ledger.
    function _defaultAndBurn(uint256 id) internal {
        S.Gen memory gb = lens.getGen(id, 1);
        (,,,,, uint256 burned0,) = lens.totals();
        uint256 l2 = _borrow(id, 25 * U, 8 days);
        _days(12);
        POOL.markDefault(l2);
        assertEq(lens.getGen(id, 1).status, C.SETTLED);
        (,,,,, uint256 burned1,) = lens.totals();
        uint256 expect = (gb.tokens[C.OWNER] * 7500 + 9999) / 10_000 + (gb.tokens[C.OTHERS] * 5000 + 9999) / 10_000
            + (gb.tokens[C.OWN] * 5000 + 9999) / 10_000;
        assertEq(burned1 - burned0, expect, "75% / 50%, rounded up");
        uint256 p0 = PRIORS.balanceOf(backer);
        v5.claimSettled(id, 1, backer);
        assertGt(PRIORS.balanceOf(backer), p0);
        (uint256 led, uint256 carry) = _ledger();
        assertGe(PRIORS.balanceOf(address(v5)), led + carry, "V5-TOK on the fork");
    }

    uint256 internal opk = uint256(keccak256("priors.v5.fork.owner"));

    /// @dev An agent of our own under another root of our own, with a $10 loan open.
    function _agentWithALoan() internal returns (uint256 id, uint256 l) {
        address o = vm.addr(opk);
        _fund(o);
        address otherRootOwner = makeAddr("otherRootOwner");
        deal(address(USDG), otherRootOwner, 500 * U);
        vm.startPrank(otherRootOwner);
        uint256 other = REG.register("ipfs://v5-fork-other-root");
        USDG.approve(address(POOL), type(uint256).max);
        POOL.enrollRoot(other, 300 * U);
        vm.stopPrank();
        vm.prank(o);
        id = REG.register("ipfs://v5-fork-agent");
        ICreditPoolV2.Consent memory c0 =
            ICreditPoolV2.Consent(id, other, o, 0, POOL.nonces(id), block.timestamp + 1 hours);
        bytes memory sig0 = _sign(c0);
        vm.prank(otherRootOwner);
        POOL.vouchWithConsent(other, id, 50 * U, 0, c0, sig0);
        vm.prank(o);
        l = POOL.borrow(id, 10 * U, 1 days, o, type(uint256).max);
    }

    function _sign(ICreditPoolV2.Consent memory c) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(opk, POOL.consentDigest(c));
        return abi.encodePacked(r, s, v);
    }

    /// @dev A handoff refused while a loan is open (src/CreditPoolV2.sol:601), and an owner change on a V5 book.
    function test_fork_handoffRefusedWithALoanOpen_andOwnerChange() public onFork {
        (uint256 id, uint256 l) = _agentWithALoan();
        address o = vm.addr(opk);
        ICreditPoolV2.Consent memory c =
            ICreditPoolV2.Consent(id, root, o, 0, POOL.nonces(id), block.timestamp + 1 hours);
        bytes memory sig = _sign(c);
        uint256 stake = _stakeFor(id);
        vm.prank(o);
        vm.expectRevert(IV5Errors.LoanOpen.selector);
        v5.open(id, stake, false, c, sig);
        // and the pool's own check, had V5 asked it (src/CreditPoolV2.sol:601)
        vm.prank(address(v5));
        vm.expectRevert(abi.encodeWithSignature("LoanOpen(uint256)", id));
        POOL.vouchWithConsent(root, id, 0, 0, c, sig);

        // repaid: the same handoff goes through (stake-only entry at T1)
        _repay(l);
        vm.prank(o);
        v5.open(id, stake, false, c, sig);
        assertEq(POOL.getAgent(id).sponsor, root);
        _borrow(id, 25 * U, 8 days);
        _sold(id, o);
    }

    /// @dev The agent is sold: V5 latches the change, refuses new loans, keeps A burnable.
    function _sold(uint256 id, address o) internal {
        address buyer = makeAddr("buyer");
        vm.prank(o);
        REG.transferFrom(o, buyer, id);
        v5.pokeFees(id);
        assertTrue(lens.getGen(id, 1).ownerChanged);
        assertFalse(v5.canBorrow(root, id, 5 * U, 1 days, 1, buyer, buyer, buyer));
        assertFalse(v5.canBorrow(root, id, 5 * U, 1 days, 1, o, o, o));
        assertGt(lens.getGen(id, 1).counted[C.OWNER], 0, "A stays until the book closes");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function _ledger() internal view returns (uint256 l, uint256 carry) {
        (,,, l, carry,,) = lens.totals();
    }
}
