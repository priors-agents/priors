// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICreditPoolV2} from "../interfaces/ICreditPoolV2.sol";
import {Env, C, IV5Events, IV5Errors} from "./V5Types.sol";
import {V5Storage as S} from "./V5Storage.sol";
import {V5Math as M} from "./V5Math.sol";
import {V5Core as K} from "./V5Core.sol";
import {V5Pos} from "./V5Pos.sol";
import {V5Steps} from "./V5Steps.sol";

/// @title V5Book
/// @notice Engine 1's book calls (docs/PRIORS-UNDERWRITING-SPEC.md rev 5, 2.2–2.5, 2A.1): open (with $PRIORS, USDG or
///         both), back, leave, close, the idle close, `sync(id)`, and the bound owner's switches. A linked library: it
///         runs by DELEGATECALL in SeatVaultV5's context, under V5's one lock.
library V5Book {
    struct OpenArgs {
        uint256 id;
        uint256 priorsIn;
        uint256 usdgIn;
        uint256 minOut;
        uint256 deadline;
        bool autoAdd;
    }

    /// @dev An open's working values (kept in memory: the legacy pipeline's stack is small).
    struct OpenVals {
        address owner;
        uint32 prev;
        uint32 genNo;
        uint160 sp;
        uint160 ob;
        uint160 sqrtP;
        uint8 k;
        uint256 tokens;
        uint256 aPart;
        uint256 own;
        uint256 line;
    }

    /// @notice `open` / `openWithUsdg` (2.5): the owner opens its agent's book, one transaction. The T1 entry gate in
    ///         O(1), the guards, one open per owner address in 7 days, the 30-day reopen ban, the previous generation
    ///         closed with no loan open (poked first), $PRIORS pulled and any USDG remainder swapped in the same call
    ///         (A valued at live spot read before the swap), the line at kEff at least $25, the consent within V5's
    ///         premium cap, then the handoff. What the two opening paths post counts at once (question 3). The line is
    ///         recorded as the room-charged line and vouched by the owner's own `refresh` at the draw (question 40).
    function open(OpenArgs memory a, ICreditPoolV2.Consent memory c, bytes memory sig) external {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        if (!l.rootReady) revert IV5Errors.RootNotReady();
        if (!K.cacheSet()) revert IV5Errors.NoPrice();
        OpenVals memory v;
        v.sp = K.spot(e);
        v.ob = K.lastObs(e);
        K.requireAddGuards(e, v.sp);
        bool ok;
        (ok, v.owner) = K.ownerOf(e, a.id);
        if (!ok) revert IV5Errors.RegistryRead();
        if (v.owner != msg.sender) revert IV5Errors.NotOwner();
        if (c.maxPremiumBps > l.premiumCap || c.maxPremiumBps < l.targetPremium[a.id]) revert IV5Errors.PremiumCap();
        if (block.timestamp < l.reopenAt[a.id]) revert IV5Errors.ReopenBan();
        uint64 lo = l.lastOpenAt[v.owner];
        if (lo != 0 && block.timestamp < uint256(lo) + C.OPEN_GAP) revert IV5Errors.OpenTooSoon();
        v.prev = l.latest[a.id];
        if (v.prev != 0) {
            S.Gen storage gp = l.gens[a.id][v.prev];
            if (gp.status == C.OPEN) revert IV5Errors.BookOpen();
            V5Steps.firstSteps(e, a.id, false); // reconciles and pokes it: its fees are credited to it, never the new one
            if (gp.listLen != 0) revert IV5Errors.LoanOpen();
            // 2.2's order: the call's own checks after the first steps, whose reconciliation may trip the breaker
            // (deep audit D-02; the other guards cannot move in them)
            if (l.tripped) revert IV5Errors.BreakerOn();
        }
        _entry(e, a.id, v.owner);
        v.sqrtP = K.pFull(v.sp, v.ob);
        v.k = K.kEff(v.sp, v.ob, true);
        K.pull(e, e.priors, a.priorsIn);
        v.tokens = a.priorsIn + V5Pos.zap(e, a.usdgIn, a.minOut, a.deadline);
        if (v.tokens == 0) revert IV5Errors.ZeroAmount();
        uint256 capA = M.tokensFor(3 * C.ceiling(1), v.sqrtP);
        v.aPart = v.tokens < capA ? v.tokens : capA;
        v.own = v.tokens - v.aPart;
        if (v.own > v.aPart) revert IV5Errors.TooMuchStake(); // at most 6 × the ceiling at P in all (2.5)
        v.line = M.line(v.aPart, v.sqrtP, C.ceiling(1), v.k);
        if (v.line < C.MIN_LINE) revert IV5Errors.LineTooSmall(v.line);
        _newGen(e, a, v);
        // every price and balance read is done: the handoff (the old sponsor's onRelease runs inside it)
        e.pool.vouchWithConsent(e.root, a.id, 0, l.targetPremium[a.id], c, sig);
    }

    /// @dev The T1 entry gate, O(1) (2.4): never defaulted, an owner address with no default, no loan open, and the
    ///      timelocked entry rule: `minEntryLoans` repaid loans held 7 days and `minEntryDays` since enrolment (the
    ///      spec's 3 and 14 at most). The owner's addition sets both to 0: the owner's stake alone buys T1, never the
    ///      climb above it, which still needs V5's counted loans and time per tier.
    function _entry(Env memory e, uint256 id, address owner) private view {
        ICreditPoolV2.Agent memory ag = e.pool.getAgent(id);
        if (ag.activeLoans != 0) revert IV5Errors.LoanOpen();
        if (ag.defaulted) revert IV5Errors.NotEligible(1);
        if (ag.isRoot) revert IV5Errors.NotEligible(2);
        S.Layout storage l = S.layout();
        if (ag.qualifiedRepaid < l.minEntryLoans) revert IV5Errors.NotEligible(3);
        uint256 age = uint256(l.minEntryDays) * 1 days;
        if (age != 0 && (ag.enrolledAt == 0 || block.timestamp < uint256(ag.enrolledAt) + age)) {
            revert IV5Errors.NotEligible(4);
        }
        if (e.pool.ownerDefaults(owner) != 0) revert IV5Errors.NotEligible(5);
    }

    function _newGen(Env memory e, OpenArgs memory a, OpenVals memory v) private {
        S.Layout storage l = S.layout();
        v.genNo = v.prev + 1;
        l.latest[a.id] = v.genNo;
        S.Gen storage g = l.gens[a.id][v.genNo];
        g.owner = v.owner;
        g.openedAt = uint64(block.timestamp);
        g.status = C.OPEN;
        g.tier = 1;
        g.tierStep = 1;
        g.tierSince = uint64(block.timestamp);
        g.roomLine = v.line;
        g.openLine = v.line;
        V5Pos.depositCounted(a.id, v.genNo, C.OWNER, v.owner, v.aPart);
        l.pos[a.id][v.genNo][C.OWNER][v.owner].autoAdd = a.autoAdd;
        if (v.own != 0) {
            V5Pos.depositCounted(a.id, v.genNo, C.OWN, v.owner, v.own);
            l.pos[a.id][v.genNo][C.OWN][v.owner].autoAdd = a.autoAdd;
        }
        l.feeMark[a.id] = e.pool.feesFrom(e.root, a.id);
        _noteDelegate(e, a.id);
        l.lastOpenAt[v.owner] = uint64(block.timestamp);
        emit IV5Events.BookOpened(a.id, v.genNo, v.owner, v.aPart, v.line);
        emit IV5Events.Backed(a.id, v.genNo, v.owner, C.OWNER, v.aPart, a.usdgIn);
        if (v.own != 0) emit IV5Events.Backed(a.id, v.genNo, v.owner, C.OWN, v.own, 0);
    }

    /// @notice `back` / `backWithUsdg` (2.5), `a` read as (id, priorsIn, usdgIn, minOut, deadline, autoAdd): $PRIORS (and any USDG remainder swapped in the same call) behind an
    ///         open book, as pending stake (24 h warm-up, 2.7). The owner's top-ups go to A until value(A + A's pending)
    ///         reaches 3 × the ceiling at P, the rest to its own backing (question 31); others' backing needs
    ///         `openBacking` and the book's switch; BuyAndBack's placement of C is held to the placement rule and to
    ///         min(A/6 − C, A − B − C, A/8 a week) (question 23). B + C + x ≤ A for every addition, with B and C counted
    ///         plus pending plus leaving until `releasableAt`, A counted only.
    function back(OpenArgs memory a) external {
        Env memory e = K.env();
        K.Steps memory st = V5Steps.firstSteps(e, a.id, false);
        S.Gen storage g = S.layout().gens[a.id][st.genNo];
        if (!st.hasBook || g.status != C.OPEN) revert IV5Errors.BookNotOpen();
        if (!st.readOk) revert IV5Errors.RegistryRead();
        if (g.ownerChanged) revert IV5Errors.OwnerChangedLatch();
        uint160 sp = K.spot(e);
        K.requireAddGuards(e, sp);
        if (e.pool.getAgent(a.id).defaulted) revert IV5Errors.AgentDefaulted();
        if (K.lateGuard(g, st.ls)) revert IV5Errors.LateGuard();
        // the cache is set: the book's open needed it, and a zero median latches the spot guard (refused above)
        uint8 role = _role(e, g, msg.sender); // 0 owner, 1 other, 2 BuyAndBack
        uint160 sqrtP = K.pFull(sp, K.lastObs(e));
        K.pull(e, e.priors, a.priorsIn);
        uint256 tokens = a.priorsIn + V5Pos.zap(e, a.usdgIn, a.minOut, a.deadline);
        if (tokens == 0) revert IV5Errors.ZeroAmount();
        if (role != 2 && tokens < C.MIN_BACK) revert IV5Errors.TooSmall();
        if (role != 0) {
            _place(e, a.id, st.genNo, role, tokens, a.autoAdd);
            emit IV5Events.Backed(a.id, st.genNo, msg.sender, role == 1 ? C.OTHERS : C.OWN, tokens, a.usdgIn);
            return;
        }
        uint256 toA = _placeOwner(e, a.id, st.genNo, tokens, sqrtP, a.autoAdd);
        _ownerBacked(a.id, st.genNo, tokens - toA, toA, a.usdgIn);
    }

    /// @dev The owner's top-up: one `Backed` per layer credited (audit L-03), the call's USDG on the first, as `open`
    ///      reports its two layers.
    function _ownerBacked(uint256 id, uint32 genNo, uint256 toOwn, uint256 toA, uint256 usdgIn) private {
        if (toA != 0) emit IV5Events.Backed(id, genNo, msg.sender, C.OWNER, toA, usdgIn);
        if (toOwn != 0) emit IV5Events.Backed(id, genNo, msg.sender, C.OWN, toOwn, toA == 0 ? usdgIn : 0);
    }

    function _role(Env memory e, S.Gen storage g, address who) private view returns (uint8 role) {
        S.Layout storage l = S.layout();
        if (who == g.owner) return 0;
        if (who == e.buyAndBack) {
            if (g.tier < 2 || g.optOut) revert IV5Errors.NotEligible(6);
            if (g.lastLateAt != 0 && block.timestamp < uint256(g.lastLateAt) + C.LATE_BAN) {
                revert IV5Errors.NotEligible(7);
            }
            return 2;
        }
        if (!l.openBacking || g.othersOff) revert IV5Errors.BackingClosed();
        return 1;
    }

    /// @dev B and C as 2.2 counts them: counted plus pending plus leaving until `releasableAt` (a poke ran first, so
    ///      every bucket whose `releasableAt` has passed is retired and out of `leavingLive`).
    function backingUsed(S.Gen storage g) internal view returns (uint256) {
        return g.counted[1] + g.counted[2] + g.pendingTok[1] + g.pendingTok[2] + g.leavingLive[1] + g.leavingLive[2];
    }

    /// @dev Others' backing (role 1) or C (role 2).
    function _place(Env memory e, uint256 id, uint32 genNo, uint8 role, uint256 tokens, bool autoAdd) private {
        S.Gen storage g = S.layout().gens[id][genNo];
        uint256 a = g.counted[C.OWNER];
        uint256 used = backingUsed(g);
        if (role == 2) {
            if (used + tokens > a || 6 * (g.cLive + tokens) > a) revert IV5Errors.NoRoom();
            uint64 ep = K.epochNow(e) + 1;
            if (g.placeEpoch != ep) {
                g.placeEpoch = ep;
                g.placed = 0;
            }
            if (8 * (g.placed + tokens) > a) revert IV5Errors.NoRoom();
            g.placed += tokens;
            V5Pos.deposit(e, id, genNo, C.OWN, msg.sender, tokens);
        } else {
            if (used + tokens > a) revert IV5Errors.NoRoom();
            V5Pos.deposit(e, id, genNo, C.OTHERS, msg.sender, tokens);
            S.layout().pos[id][genNo][C.OTHERS][msg.sender].autoAdd = autoAdd;
        }
    }

    /// @dev The owner's top-up: into A until value(A + A's pending) reaches 3 × the ceiling at P, the rest into its
    ///      own backing within B + C ≤ A (question 31).
    ///      Returns what went into A.
    function _placeOwner(Env memory e, uint256 id, uint32 genNo, uint256 tokens, uint160 sqrtP, bool autoAdd)
        private
        returns (uint256 toA)
    {
        S.Gen storage g = S.layout().gens[id][genNo];
        uint256 a = g.counted[C.OWNER];
        uint256 capA = M.tokensFor(3 * C.ceiling(g.tier), sqrtP);
        uint256 aNow = a + g.pendingTok[C.OWNER];
        toA = aNow >= capA ? 0 : M.min256(tokens, capA - aNow);
        uint256 rest = tokens - toA;
        if (rest != 0 && backingUsed(g) + rest > a) revert IV5Errors.NoRoom();
        if (toA != 0) {
            V5Pos.deposit(e, id, genNo, C.OWNER, msg.sender, toA);
            S.layout().pos[id][genNo][C.OWNER][msg.sender].autoAdd = autoAdd;
        }
        if (rest != 0) {
            V5Pos.deposit(e, id, genNo, C.OWN, msg.sender, rest);
            S.layout().pos[id][genNo][C.OWN][msg.sender].autoAdd = autoAdd;
        }
    }

    /// @notice `leave` (2.5): at least 1,000 $PRIORS or the whole position, the whole position when less than 1,000
    ///         would stay; counted stake first, then pending stake (debiting the bucket it came from); into today's
    ///         leaving bucket, where it stays burnable until released. BuyAndBack's C leaves in mode 1 only.
    function leave(uint256 id, uint256 amount, uint8 mode) external {
        Env memory e = K.env();
        if (mode > 2) revert IV5Errors.BadSetting();
        K.Steps memory st = V5Steps.firstSteps(e, id, false);
        S.Gen storage g = S.layout().gens[id][st.genNo];
        if (!st.hasBook || g.status != C.OPEN) revert IV5Errors.BookNotOpen();
        uint8 layer = K.backLayer(e, g, msg.sender);
        if (msg.sender == e.buyAndBack && mode != 1) revert IV5Errors.BadSetting();
        if (g.layerEnd[layer] != 0) revert IV5Errors.NothingToLeave();
        (uint256 c, uint256 u) = _takeFrom(e, id, st.genNo, layer, amount);
        g.counted[layer] -= c;
        g.pendingTok[layer] -= u;
        g.leavingLive[layer] += c + u;
        uint32 d = _toRecord(e, id, st.genNo, layer, c, u, mode);
        emit IV5Events.LeaveQueued(id, st.genNo, msg.sender, c + u, mode, d);
    }

    /// @dev The amount a leave takes from the caller's position: counted first, then pending.
    function _takeFrom(Env memory e, uint256 id, uint32 genNo, uint8 layer, uint256 amount)
        private
        returns (uint256 c, uint256 u)
    {
        V5Pos.resolve(e, id, genNo, layer, msg.sender);
        S.Pos storage pp = S.layout().pos[id][genNo][layer][msg.sender];
        uint256 total = pp.counted + pp.a0 + pp.a1;
        if (total == 0) revert IV5Errors.NothingToLeave();
        if (amount >= total || total - amount < C.MIN_BACK) amount = total;
        if (amount < C.MIN_BACK && amount != total) revert IV5Errors.TooSmall();
        c = amount < pp.counted ? amount : pp.counted;
        u = amount - c;
        pp.counted -= c;
        if (u != 0) _takePending(id, genNo, layer, pp, u);
        pp.autoAdd = false;
    }

    struct Lv {
        uint256 id;
        uint32 genNo;
        uint8 layer;
        uint32 day;
        uint256 c;
        uint256 u;
        uint8 mode;
    }

    /// @dev The leave's part in today's leaving bucket and the caller's record there (its credit moved first).
    function _toRecord(Env memory e, uint256 id, uint32 genNo, uint8 layer, uint256 c, uint256 u, uint8 mode)
        private
        returns (uint32)
    {
        Lv memory v = Lv(id, genNo, layer, 0, c, u, mode);
        v.day = V5Pos.touchBucket(e, id, genNo, layer);
        S.Leaving storage b = S.layout().leaving[id][genNo][layer][v.day];
        b.counted += c;
        b.uncounted += u;
        _rec(e, v, b);
        return v.day;
    }

    function _rec(Env memory e, Lv memory v, S.Leaving storage b) private {
        S.Layout storage l = S.layout();
        uint256 idx = l.gens[v.id][v.genNo].index;
        S.Rec storage r = l.recs[v.id][v.genNo][v.layer][v.day][msg.sender];
        K.creditRec(e, r, b, msg.sender, idx);
        uint160 pl = K.pFull(K.spot(e), K.lastObs(e));
        if ((r.counted | r.uncounted) == 0 || pl < r.sqrtLeave) r.sqrtLeave = pl;
        r.counted += v.c;
        r.uncounted += v.u;
        r.creditedTo = idx;
        r.mode = v.mode;
        if (msg.sender == e.buyAndBack) l.cInBucket[v.id][v.genNo][v.day] += v.c + v.u;
    }

    /// @dev Take `u` of a position's pending stake, the older day first, debiting its buckets.
    ///      0 < u ≤ a0 + a1. The older slot is the one with a day when the other has none, else the earlier day; it is
    ///      never empty, and the newer one is reached only when the older did not cover `u`.
    function _takePending(uint256 id, uint32 genNo, uint8 layer, S.Pos storage pp, uint256 u) private {
        bool zeroFirst = pp.d1 == 0 || (pp.d0 != 0 && pp.d0 < pp.d1);
        u = _takeSlot(id, genNo, layer, pp, zeroFirst, u);
        if (u != 0) _takeSlot(id, genNo, layer, pp, !zeroFirst, u);
    }

    function _takeSlot(uint256 id, uint32 genNo, uint8 layer, S.Pos storage pp, bool slot0, uint256 u)
        private
        returns (uint256 rest)
    {
        uint256 have = slot0 ? pp.a0 : pp.a1;
        uint256 t = u < have ? u : have;
        uint32 d1 = slot0 ? pp.d0 : pp.d1;
        S.layout().pend[id][genNo][layer][d1 - 1].amount -= uint128(t);
        if (slot0) {
            pp.a0 = have - t;
            if (pp.a0 == 0) pp.d0 = 0;
        } else {
            pp.a1 = have - t;
            if (pp.a1 == 0) pp.d1 = 0;
        }
        rest = u - t;
    }

    /// @notice `close` (2.4, 2.5): the bound owner, or anyone once `ownerChanged` is set (then in mode 1). The line
    ///         freezes in the pool while V5's root sponsors the agent (our own onRelease is skipped: reconciled here);
    ///         every layer moves to leaving; A's closing record goes back to the address that posted it.
    function close(uint256 id, uint8 mode) external {
        Env memory e = K.env();
        if (mode > 2) revert IV5Errors.BadSetting();
        S.Layout storage l = S.layout();
        K.Steps memory st = V5Steps.firstSteps(e, id, false);
        S.Gen storage g = l.gens[id][st.genNo];
        if (!st.hasBook || g.status != C.OPEN) revert IV5Errors.BookNotOpen();
        bool byOwner = msg.sender == g.owner;
        if (!byOwner && !g.ownerChanged) revert IV5Errors.NotOwner();
        ICreditPoolV2.Agent memory ag = e.pool.getAgent(id);
        if (ag.defaulted) revert IV5Errors.AgentDefaulted(); // settle or sync(id) ends it
        if (ag.sponsor == e.root) e.pool.freeze(id, true);
        V5Pos.closeGen(e, id, st.genNo, byOwner ? mode : 1, byOwner, 1, false);
    }

    /// @notice `expire` (2.4): anyone, once the agent has no loan open and has not borrowed or repaid for 30 days
    ///         since the latest of the generation's opening and the pool's `lastBorrowAt` and `lastRepayAt`. Mode 1;
    ///         a book that never borrowed starts no reopen ban.
    function expire(uint256 id) external {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        K.Steps memory st = V5Steps.firstSteps(e, id, false);
        S.Gen storage g = l.gens[id][st.genNo];
        if (!st.hasBook || g.status != C.OPEN) revert IV5Errors.BookNotOpen();
        ICreditPoolV2.Agent memory ag = e.pool.getAgent(id);
        if (ag.defaulted) revert IV5Errors.AgentDefaulted();
        uint256 since = g.openedAt;
        if (ag.lastBorrowAt > since) since = ag.lastBorrowAt;
        if (ag.lastRepayAt > since) since = ag.lastRepayAt;
        if (ag.activeLoans != 0 || block.timestamp < since + C.IDLE_AFTER) revert IV5Errors.NotIdle();
        if (ag.sponsor == e.root) e.pool.freeze(id, true);
        V5Pos.closeGen(e, id, st.genNo, 1, false, 2, false);
    }

    /// @notice `sync(id)` (2.6): closes with no burn a book V5 no longer backs (the pool's sponsor is no longer V5's
    ///         root), once no loan of the generation is `Defaulted` and every default of V5's root is recorded. A
    ///         defaulted loan of the generation settles it instead (the first steps run the settle).
    function syncBook(uint256 id) external {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        K.Steps memory st = V5Steps.firstSteps(e, id, false);
        S.Gen storage g = l.gens[id][st.genNo];
        if (!st.hasBook || g.status == C.CLOSED || g.status == C.NONE) revert IV5Errors.BookNotOpen();
        if (g.status == C.SETTLED) return;
        ICreditPoolV2.Agent memory ag = e.pool.getAgent(id);
        if (ag.sponsor == e.root) revert IV5Errors.StillSponsored();
        if (K.defaultUnseen(e, ag)) revert IV5Errors.DefaultUnseen();
        V5Pos.closeGen(e, id, st.genNo, 1, false, 3, false);
    }

    function _noteDelegate(Env memory e, uint256 id) private {
        S.Delegate storage d = S.layout().delegates[id];
        address who = e.pool.delegateOf(id);
        if (who == d.who) return;
        d.who = who;
        d.at = uint64(block.timestamp);
        emit IV5Events.DelegateNoted(id, who);
    }
}
