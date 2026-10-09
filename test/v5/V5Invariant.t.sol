// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V5Base, IPoolT} from "./V5Base.sol";
import {IV5Lens} from "./IV5Lens.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C} from "../../src/v5/V5Types.sol";
import {V5Math as M} from "../../src/v5/V5Math.sol";
import {MockUSDG, MockPriors, MockRegistryV5, MockPoolManager, MockSizer} from "./V5Mocks.sol";

/// @dev Drives V5 with agents' owners, backers, BuyAndBack's placements, borrows, repayments, defaults, owner changes,
///      leaves, releases, closes, claims, pauses, price moves, keeper passes and time. Every action is bounded so most
///      succeed; one that reverts changes nothing (fail_on_revert is off). Ghosts record what the invariants compare.
contract V5Handler is Test {
    uint256 internal constant U = 1e6;
    uint256 internal constant T = 1e18;
    uint256 internal constant P0 = 1e15;

    SeatVaultV5 internal v5;
    IV5Lens internal lens;
    IPoolT internal pool;
    MockUSDG internal usdg;
    MockPriors internal priors;
    MockRegistryV5 internal reg;
    MockPoolManager internal pm;
    MockSizer internal sizer;
    bytes32 internal slot;
    uint256 internal root;
    address internal timelock;
    address internal guardian;
    address internal bb;

    uint256[] public ids;
    mapping(uint256 => uint256) public pkOf;
    address[] public backers;
    uint256[] public loans;

    struct Lv {
        uint256 id;
        uint32 gen;
        address holder;
        uint32 day;
    }

    Lv[] internal leaves;

    struct Bk {
        address who;
        uint256 id;
    }

    Bk[] internal backs;
    uint256 public priceE18 = P0;

    // ghosts
    uint256 public donated;
    uint256 public maxBurned;
    bool public burnedFell;
    bool public trippedClearedWithoutClear;
    bool public lastTripped;
    uint256 public calls;
    mapping(bytes32 => uint256) public count;
    mapping(bytes32 => uint256) public ok;
    bytes32 internal cur;
    bool internal constant DEBUG = false;

    struct Deps {
        SeatVaultV5 v5;
        IPoolT pool;
        MockUSDG usdg;
        MockPriors priors;
        MockRegistryV5 reg;
        MockPoolManager pm;
        MockSizer sizer;
        bytes32 slot;
        uint256 root;
        address timelock;
        address guardian;
        address bb;
    }

    constructor(Deps memory d, uint256[] memory ids_, uint256[] memory pks_, address[] memory backers_) {
        v5 = d.v5;
        lens = IV5Lens(address(d.v5));
        pool = d.pool;
        usdg = d.usdg;
        priors = d.priors;
        reg = d.reg;
        pm = d.pm;
        sizer = d.sizer;
        slot = d.slot;
        root = d.root;
        timelock = d.timelock;
        guardian = d.guardian;
        bb = d.bb;
        for (uint256 i = 0; i < ids_.length; i++) {
            ids.push(ids_[i]);
            pkOf[ids_[i]] = pks_[i];
        }
        backers = backers_;
    }

    modifier tick(bytes32 name) {
        calls++;
        count[name]++;
        cur = name;
        _;
        _ghosts();
    }

    function _ghosts() internal {
        (,,,,, uint256 b,) = lens.totals();
        if (b < maxBurned) burnedFell = true;
        maxBurned = b;
        bool t = lens.breakerTripped();
        lastTripped = t;
    }

    function idsLength() external view returns (uint256) {
        return ids.length;
    }

    function backersLength() external view returns (uint256) {
        return backers.length;
    }

    function _id(uint256 s) internal view returns (uint256) {
        return ids[s % ids.length];
    }

    function _owner(uint256 id) internal view returns (address) {
        return reg.ownerOf(id);
    }

    function _sqrtFor(uint256 pE18) internal pure returns (uint160) {
        return uint160(Math.sqrt(1e30 * (uint256(1) << 64) / pE18) * (uint256(1) << 64));
    }

    function _keeper() internal {
        uint160 s = _sqrtFor(priceE18);
        sizer.set(s, s);
        try v5.sync() {} catch {}
    }

    function _consent(uint256 id) internal view returns (ICreditPoolV2.Consent memory c, bytes memory sig) {
        c = ICreditPoolV2.Consent({
            agentId: id,
            sponsorId: root,
            owner: _owner(id),
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkOf[id], pool.consentDigest(c));
        sig = abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------ owners

    function open(uint256 who, uint256 amount) external tick("open") {
        uint256 id = _id(who);
        amount = bound(amount, 76_000, 280_000) * T;
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id);
        vm.prank(_owner(id));
        try v5.open(id, amount, false, c, sig) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function topUp(uint256 who, uint256 amount) external tick("topUp") {
        uint256 id = _id(who);
        amount = bound(amount, 1_000, 60_000) * T;
        vm.prank(_owner(id));
        try v5.back(id, amount, false) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function borrow(uint256 who, uint256 amount, uint256 term) external tick("borrow") {
        uint256 id = _id(who);
        _keeper();
        uint256 room = lens.lineOf(id);
        uint256 out = pool.getAgent(id).principalOut;
        room = room > out ? room - out : 0;
        if (room < 5 * U) return;
        amount = bound(amount, 5 * U, room);
        term = bound(term, 1, 10) * 1 days;
        address o = _owner(id);
        vm.prank(o);
        try v5.refresh(id) {} catch {}
        vm.prank(o);
        try pool.borrow(id, amount, uint64(term), o, type(uint256).max) returns (uint256 l) {
            loans.push(l);
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.logBytes(r);
        }
    }

    function repay(uint256 which) external tick("repay") {
        if (loans.length == 0) return;
        uint256 l = loans[which % loans.length];
        ICreditPoolV2.Loan memory ln = pool.getLoan(l);
        if (ln.status != ICreditPoolV2.LoanStatus.Active) return;
        usdg.mint(ln.owner, ln.principal + ln.fee);
        vm.prank(ln.owner);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(ln.owner);
        try pool.repay(l, ln.agentId, type(uint256).max) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function markDefault(uint256 which) external tick("default") {
        if (loans.length == 0 || which % 3 != 0) return;
        which /= 3;
        uint256 l = loans[which % loans.length];
        ICreditPoolV2.Loan memory ln = pool.getLoan(l);
        if (ln.status != ICreditPoolV2.LoanStatus.Active) return;
        uint256 at = uint256(ln.dueAt) + 3 days + 1;
        if (block.timestamp < at) {
            vm.warp(at);
            _keeper();
        }
        try pool.markDefault(l) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function promote(uint256 who) external tick("promote") {
        try v5.promote(_id(who)) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function close(uint256 who, uint8 mode) external tick("close") {
        if (mode % 8 != 0) return; // rare: a closed book stays closed 30 days
        uint256 id = _id(who);
        vm.prank(_owner(id));
        try v5.close(id, (mode / 8) % 3) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function finishClose(uint256 who) external tick("finishClose") {
        uint256 id = _id(who);
        uint32 g = lens.latestGen(id);
        if (g == 0) return;
        try v5.finishClose(id, g) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    /// @dev Rare: a sale of the agent to a new key.
    function changeOwner(uint256 who, uint256 pk) external tick("ownerChange") {
        if (count["ownerChange"] > 3) return;
        uint256 id = _id(who);
        pk = bound(pk, 1, 1e30);
        address to = vm.addr(pk);
        address from = _owner(id);
        if (to == from) return;
        vm.prank(from);
        reg.transferFrom(from, to, id);
        pkOf[id] = pk;
        priors.mint(to, 10_000_000 * T);
        vm.prank(to);
        priors.approve(address(v5), type(uint256).max);
    }

    // ------------------------------------------------------------------ backers and BuyAndBack

    function back(uint256 b, uint256 who, uint256 amount) external tick("back") {
        address a = backers[b % backers.length];
        amount = bound(amount, 1_000, 60_000) * T;
        vm.prank(a);
        try v5.back(_id(who), amount, false) {
            ok[cur]++;
            backs.push(Bk(a, _id(who)));
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function place(uint256 who, uint256 amount) external tick("place") {
        amount = bound(amount, 1_000, 15_000) * T;
        uint256 id = who % 2 == 0 ? ids[0] : _id(who); // the T2 book, mostly
        vm.prank(bb);
        try v5.back(id, amount, false) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function leave(uint256 which, uint256 amount, uint8 mode) external tick("leave") {
        if (backs.length == 0) return;
        Bk memory k = backs[which % backs.length];
        address a = k.who;
        uint256 id = k.id;
        uint32 g = lens.latestGen(id);
        if (g == 0) return;
        S.Pos memory p = lens.position(id, g, C.OTHERS, a);
        uint256 has = p.counted + p.a0 + p.a1;
        if (has == 0) return;
        amount = bound(amount, 1, has);
        vm.prank(a);
        try v5.leave(id, amount, mode % 3) {
            ok[cur]++;
            leaves.push(Lv(id, g, a, uint32(block.timestamp / 1 days)));
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function release(uint256 which) external tick("release") {
        if (leaves.length == 0) return;
        Lv memory x = leaves[which % leaves.length];
        vm.prank(x.holder);
        try v5.release(x.id, x.gen, x.day, 0, 0) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function claimSettled(uint256 b, uint256 who) external tick("claim") {
        uint256 id = _id(who);
        uint32 g = lens.latestGen(id);
        if (g == 0) return;
        address a = b % 3 == 0 ? _owner(id) : backers[b % backers.length];
        try v5.claimSettled(id, g, a) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function collect(uint256 b, uint256 who) external tick("collect") {
        address a = backers[b % backers.length];
        uint256[] memory xs = new uint256[](1);
        xs[0] = _id(who);
        uint32[] memory gs = new uint32[](1);
        gs[0] = lens.latestGen(xs[0]);
        vm.prank(a);
        try v5.collect(xs, gs) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function poke(uint256 who) external tick("poke") {
        try v5.pokeFees(_id(who)) {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function flush() external tick("flush") {
        try v5.flush() {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    // ------------------------------------------------------------------ the world

    function warp(uint256 secs) external tick("warp") {
        secs = bound(secs, 1 minutes, 3 days);
        vm.warp(block.timestamp + secs);
        _keeper();
    }

    function movePrice(uint256 bps, uint8 seed) external tick("price") {
        bool spotOnly = seed % 5 == 0;
        bps = bound(bps, 8_500, 11_500);
        priceE18 = priceE18 * bps / 10_000;
        if (priceE18 < P0 / 4) priceE18 = P0 / 4;
        if (priceE18 > P0 * 4) priceE18 = P0 * 4;
        pm.setSlot(slot, _sqrtFor(priceE18));
        if (!spotOnly) _keeper();
    }

    function pauseV5(uint8 seed) external tick("pause") {
        bool on = seed % 8 == 0;
        vm.prank(guardian);
        if (on) {
            try v5.pause() {
                ok[cur]++;
            } catch (bytes memory r) {
                if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
            }
        } else {
            try v5.unpause() {
                ok[cur]++;
            } catch (bytes memory r) {
                if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
            }
        }
    }

    function clearBreaker() external tick("clear") {
        vm.prank(guardian);
        try v5.clear() {
            ok[cur]++;
        } catch (bytes memory r) {
            if (DEBUG) console.log(string(abi.encodePacked(cur)), vm.toString(bytes4(r)));
        }
    }

    function donate(uint256 amount) external tick("donate") {
        amount = bound(amount, 1, 1_000 * T);
        priors.mint(address(this), amount);
        priors.transfer(address(v5), amount);
        donated += amount;
    }
}

/// @dev The invariant suite (spec 12.1, V5 rows; docs/V5-BUILD.md maps each invariant to the checks here and to the
///      unit tests).
contract V5InvariantTest is V5Base {
    V5Handler internal h;

    function _agentCount() internal pure override returns (uint256) {
        return 8;
    }

    function setUp() public override {
        super.setUp();
        vm.prank(timelock);
        v5.setOpenBacking(true);
        address[] memory bs = new address[](3);
        bs[0] = backer1;
        bs[1] = backer2;
        bs[2] = anyone;
        uint256[] memory ps = new uint256[](agents.length);
        for (uint256 i = 0; i < agents.length; i++) {
            ps[i] = pkOf[agents[i]];
        }
        V5Handler.Deps memory d;
        d.v5 = v5;
        d.pool = pool;
        d.usdg = usdg;
        d.priors = priors;
        d.reg = reg;
        d.pm = pm;
        d.sizer = sizer;
        d.slot = priceSlot;
        d.root = ROOT;
        d.timelock = timelock;
        d.guardian = guardian;
        d.bb = bb;
        h = new V5Handler(d, agents, ps, bs);
        priors.mint(bb, 10_000_000 * T);
        vm.prank(bb);
        priors.approve(address(v5), type(uint256).max);
        // two books open from the start
        _open(agents[0], 150_001 * T);
        _open(agents[1], 120_000 * T);
        _open(agents[2], 200_000 * T);
        _open(agents[3], 90_000 * T);
        // one book at T2, so BuyAndBack's placements have somewhere to go
        uint256 a = _borrow(agents[0], 25 * U, 8 days);
        uint256 b = _borrow(agents[0], 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(a);
        _repay(b);
        uint256 c = _borrow(agents[0], 25 * U, 8 days);
        _skipFresh(7 days + 1);
        _repay(c);
        v5.promote(agents[0]);
        _skipFresh(1 hours);
        targetContract(address(h));
    }

    // V5-TOK: $PRIORS conservation to the wei
    function invariant_tok_conservation() public view {
        (uint256 led, uint256 carry) = _ledger();
        assertEq(priors.balanceOf(address(v5)), led + carry + h.donated(), "balance = ledger + carry + donations");
    }

    // V5-USDG: what V5 owes in USDG is covered by its balance and the root's unclaimed fees
    function invariant_usdg_solvent() public view {
        assertTrue(_solvent(), "USDG owed covered");
    }

    // V5-BURN: burns only accumulate
    function invariant_burn_monotone() public view {
        assertFalse(h.burnedFell(), "the burned total never falls");
    }

    // V5-CAPS, V5-TIER, V5-LIST, V5-LINE (ceiling), V5-GEN on every agent's latest generation
    function invariant_books() public view {
        for (uint256 i = 0; i < agents.length; i++) {
            uint256 id = agents[i];
            uint32 gn = lens.latestGen(id);
            if (gn == 0) continue;
            S.Gen memory g = lens.getGen(id, gn);
            assertTrue(g.status >= C.OPEN && g.status <= C.SETTLED, "a status");
            assertTrue(g.tier >= 1 && g.tier <= 5, "a tier");
            assertLe(g.listLen, C.LIST_CAP, "the list cap");
            assertLe(g.openLine, C.ceiling(1), "open approves at most T1's line");
            assertGe(g.openLine, g.status == C.OPEN ? C.MIN_LINE : 0, "an open line of $25 at least");
            if (g.status == C.OPEN && !g.ownerChanged) _caps(g);
            uint256 line_ = lens.lineOf(id);
            assertLe(line_, C.ceiling(g.tier), "line under the ceiling");
            assertEq(line_ % C.LINE_STEP, 0, "line in $5 steps");
        }
    }

    function _caps(S.Gen memory g) internal pure {
        uint256 a = g.counted[C.OWNER];
        uint256 b = g.counted[C.OTHERS] + g.pendingTok[C.OTHERS] + g.leavingLive[C.OTHERS];
        uint256 own = g.counted[C.OWN] + g.pendingTok[C.OWN] + g.leavingLive[C.OWN];
        assertLe(b + own, a + g.pendingTok[C.OWNER], "B + C <= A");
        assertLe(g.cLive * 6, a + g.pendingTok[C.OWNER] + 6, "C <= A/6");
    }

    // V5-K: k and k_base take only 1.5, 2 or 3 and k is never under k_base
    function invariant_k() public view {
        S.Price memory p = lens.price();
        assertTrue(p.k == 0 || p.k == C.K_CALM || p.k == C.K_NORMAL || p.k == C.K_WILD);
        assertTrue(p.kBase == 0 || p.kBase == C.K_CALM || p.kBase == C.K_NORMAL || p.kBase == C.K_WILD);
        assertGe(p.k, p.kBase);
        uint8 ke = lens.kEff();
        assertTrue(ke == C.K_CALM || ke == C.K_NORMAL || ke == C.K_WILD);
    }

    // V5-P / V5-LINE: no line is above the line valued at live spot
    function invariant_lineNeverAboveSpot() public view {
        uint160 sp = uint160(uint256(pm.extsload(priceSlot)));
        for (uint256 i = 0; i < agents.length; i++) {
            uint256 id = agents[i];
            uint32 gn = lens.latestGen(id);
            if (gn == 0) continue;
            S.Gen memory g = lens.getGen(id, gn);
            if (g.status != C.OPEN) continue;
            uint256 atSpot = M.line(g.counted[C.OWNER], sp, C.ceiling(g.tier), lens.kEff());
            assertLe(lens.lineOf(id), atSpot, "P is never above spot");
        }
    }

    // V5-ROOMS: the week's rooms
    function invariant_rooms() public view {
        (, uint256 openUsed, uint256 promoUsed, uint256 stakeUsed) = lens.rooms();
        (,,, uint256 openRoom, uint256 raiseRoom,,,,) = lens.settings();
        assertLe(openUsed, openRoom + 8 * C.ceiling(1), "open room (recordLoan's T1 lines aside)");
        assertLe(promoUsed, raiseRoom * C.PROMO_SHARE_BPS / 10_000, "promotion share");
        assertLe(stakeUsed, raiseRoom - raiseRoom * C.PROMO_SHARE_BPS / 10_000, "stake share");
    }

    // BB-EPOCH / V5-ONCE: the epoch's total is at least every book's points (erasures only lower it)
    function invariant_points() public view {
        uint256 ep = lens.epochOf(block.timestamp);
        for (uint256 e = ep >= 4 ? ep - 4 : 0; e <= ep; e++) {
            uint256 sum;
            for (uint256 i = 0; i < agents.length; i++) {
                sum += lens.bookPoints(agents[i], e);
            }
            assertLe(sum, lens.globalPoints(e), "books' points within the total");
        }
    }

    // V5-BURN: no default of V5's root unrecorded beyond what the pool counts
    function invariant_defaultsRecorded() public view {
        (,,,,,, uint256 rec) = lens.totals();
        assertLe(rec, pool.getAgent(ROOT).childrenDefaulted, "recorded defaults never exceed the pool's");
    }

    // V5-FEEROOM: V5's root never vouches past its cap
    function invariant_vouchCap() public view {
        (,,,,, uint256 cap,,,) = lens.settings();
        assertLe(pool.getAgent(ROOT).delegatedOut, cap, "vouchCap");
    }

    function afterInvariant() public view {
        bytes32[17] memory names = [
            bytes32("open"),
            "topUp",
            "borrow",
            "repay",
            "default",
            "promote",
            "close",
            "finishClose",
            "back",
            "place",
            "leave",
            "release",
            "claim",
            "collect",
            "poke",
            "flush",
            "pause"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            console.log(string(abi.encodePacked(names[i])), h.count(names[i]), h.ok(names[i]));
        }
    }
}
