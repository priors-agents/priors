// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICreditPoolV2} from "../interfaces/ICreditPoolV2.sol";
import {V5PoolKey} from "../interfaces/IV5Deps.sol";
import {Env, C} from "./V5Types.sol";
import {V5Storage as S} from "./V5Storage.sol";
import {V5Math as M} from "./V5Math.sol";
import {V5Core as K} from "./V5Core.sol";
import {V5Book} from "./V5Book.sol";
import {V5Exit} from "./V5Exit.sol";
import {V5View} from "./V5View.sol";

/// @title V5Lens
/// @notice Every read-only view of SeatVaultV5, served by V5's fallback, which DELEGATECALLs this linked library
///         (docs/V5-BUILD.md, "Size"). It holds view functions only: none of them can write V5's state, and a
///         selector this library does not have reverts. Selectors of value-typed library functions equal the
///         contract ABI's, so callers use ISeatVaultV5Lens (test/v5) or ISeatVaultV5Engine like any contract.
library V5Lens {
    struct Needed {
        uint256 minA; // the owner's minimum at the open, mulDivUp twice (2.3)
        uint256 fullLine; // A that opens the current ceiling at kEff
        uint256 capA; // 3 × the current ceiling at P: where deposits stop going into A
        uint160 sqrtP;
        uint8 k; // kEff, doubled
        uint8 kCached; // the cached k, doubled
        bool depthGuard;
        uint256 line; // the book's line now
        uint256 ownerA;
        uint256 ownBacking;
        uint256 roomB; // room left under B + C ≤ A
        uint256 lineIfAdded; // the owner's: the line once its pending stake and `tokens` more count
        uint256 weekAfter;
    }

    /// @notice `needed(id, tokens, asOwner)` (2A.1): what the owner's stake opens and what a top-up of `tokens` would
    ///         do, at the sqrtP and kEff `open` would use now. `minA` and the full line are value()'s inverse rounded
    ///         up, so a deposit of exactly `minA` passes `open`'s check.
    function needed(uint256 id, uint256 tokens, bool asOwner) external view returns (Needed memory n) {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        uint160 sp = K.spot(e);
        uint160 ob = K.lastObs(e);
        n.sqrtP = K.pFull(sp, ob);
        n.k = K.kEff(sp, ob, true);
        n.kCached = l.price.k;
        n.depthGuard = K.depthGuard(e);
        uint32 genNo = l.latest[id];
        S.Gen storage g = l.gens[id][genNo];
        uint8 tier = g.status == C.OPEN ? g.tier : 1;
        uint256 ceil_ = C.ceiling(tier);
        n.minA = M.tokensFor(C.MIN_LINE * n.k / 2, n.sqrtP);
        n.fullLine = M.tokensFor(ceil_ * n.k / 2, n.sqrtP);
        n.capA = M.tokensFor(3 * ceil_, n.sqrtP);
        if (g.status != C.OPEN || !K.cacheSet()) return n;
        _book(e, id, genNo, tokens, asOwner, n);
    }

    function _book(Env memory e, uint256 id, uint32 genNo, uint256 tokens, bool asOwner, Needed memory n) private view {
        S.Gen storage g = S.layout().gens[id][genNo];
        uint256 ceil_ = C.ceiling(g.tier);
        n.ownerA = g.counted[C.OWNER];
        n.ownBacking = S.layout().pos[id][genNo][C.OWN][g.owner].counted;
        uint256 used = V5Book.backingUsed(g);
        n.roomB = n.ownerA > used ? n.ownerA - used : 0;
        n.line = M.line(n.ownerA, n.sqrtP, ceil_, n.k);
        n.lineIfAdded = n.line;
        n.weekAfter = n.line;
        if (!asOwner) return;
        // A once it all counts: the counted stake, an earlier top-up still pending, and what this one adds (as `back`
        // splits it, up to capA), valued as `refresh` values A
        uint256 aNow = n.ownerA + g.pendingTok[C.OWNER];
        uint256 toA = aNow >= n.capA ? 0 : M.min256(tokens, n.capA - aNow);
        n.lineIfAdded = M.line(aNow + toA, n.sqrtP, ceil_, n.k);
        uint256 week = g.roomLine + stakeShareLeft(e, g);
        n.weekAfter = n.lineIfAdded < week ? n.lineIfAdded : M.floor5(week);
    }

    function stakeShareLeft(Env memory e, S.Gen storage g) internal view returns (uint256) {
        S.Layout storage l = S.layout();
        uint64 ep = K.epochNow(e) + 1;
        uint256 total = l.raiseRoom - l.raiseRoom * C.PROMO_SHARE_BPS / 10_000;
        uint256 used = l.roomEpoch == ep ? l.stakeUsed : 0;
        uint256 left = total > used ? total - used : 0;
        uint256 bookCap = l.raiseRoom * C.STAKE_BOOK_BPS / 10_000;
        uint256 bookUsed = g.stakeEpoch == ep ? g.stakeRaised : 0;
        uint256 bookLeft = bookCap > bookUsed ? bookCap - bookUsed : 0;
        return left < bookLeft ? left : bookLeft;
    }

    /// @notice `usdgPathOpen(usdgIn)` (2A.1): whether a user swap of `usdgIn` can run now, and if not why: 1 stale or
    ///         unset cache, 2 no readable cap or snapshot, 3 over the cap, 4 spot guard, 5 depth guard.
    function usdgPathOpen(uint256 usdgIn) external view returns (bool, uint8) {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        if (!K.cacheFresh()) return (false, 1);
        (uint256 cap, bool ok) = e.limiter.liveCap();
        if (!ok) return (false, 2);
        uint256 lim = l.maxSwapUsdg < cap ? l.maxSwapUsdg : cap;
        if (usdgIn > lim || K.txSwaps() + usdgIn > cap) return (false, 3);
        if (K.spotGuard(K.spot(e))) return (false, 4);
        if (K.depthGuard(e)) return (false, 5);
        return (true, 0);
    }

    /// @notice What a placement into the agent's latest generation may add now, and whether the book meets the
    ///         placement rule (2A.2): open, not changed hands, T2 or above, opted in, no late repayment in 28 days, the
    ///         late guard off, the agent not defaulted, every guard off.
    function placeRoom(uint256 id) external view returns (uint256 tokens, bool eligible) {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        uint32 genNo = l.latest[id];
        S.Gen storage g = l.gens[id][genNo];
        if (genNo == 0 || g.status != C.OPEN || g.ownerChanged || g.tier < 2 || g.optOut) return (0, false);
        if (g.lastLateAt != 0 && block.timestamp < uint256(g.lastLateAt) + C.LATE_BAN) return (0, false);
        if (K.paused() || l.tripped || K.depthGuard(e) || K.spotGuard(K.spot(e))) return (0, false);
        if (e.pool.getAgent(id).defaulted) return (0, false);
        for (uint256 i = 0; i < g.listLen; i++) {
            ICreditPoolV2.Loan memory ln = e.pool.getLoan(g.list[i]);
            if (ln.status == ICreditPoolV2.LoanStatus.Active ? block.timestamp > ln.dueAt : ln.closedAt > ln.dueAt) {
                return (0, false);
            }
        }
        uint256 a = g.counted[C.OWNER];
        uint256 used = V5Book.backingUsed(g);
        uint256 r1 = a > used ? a - used : 0;
        uint256 r2 = a / 6 > g.cLive ? a / 6 - g.cLive : 0;
        uint256 placed = g.placeEpoch == K.epochNow(e) + 1 ? g.placed : 0;
        uint256 r3 = a / 8 > placed ? a / 8 - placed : 0;
        return (M.min256(r1, M.min256(r2, r3)), true);
    }

    /// @notice The book's line now, at `canBorrow`'s valuation.
    function lineOf(uint256 id) external view returns (uint256) {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        uint32 genNo = l.latest[id];
        S.Gen storage g = l.gens[id][genNo];
        if (genNo == 0 || g.status != C.OPEN || !K.cacheSet()) return 0;
        uint160 sp = K.spot(e);
        uint160 ob = K.lastObs(e);
        return M.line(g.counted[C.OWNER], K.pFull(sp, ob), C.ceiling(g.tier), K.kEff(sp, ob, true));
    }

    function exitServiceOpen() external view returns (bool) {
        return V5Exit.serviceOpen(K.env());
    }

    function depthGuard() external view returns (bool) {
        return K.depthGuard(K.env());
    }

    function spotGuardOn() external view returns (bool) {
        return K.spotGuard(K.spot(K.env()));
    }

    function kEff() external view returns (uint8) {
        Env memory e = K.env();
        return K.kEff(K.spot(e), K.lastObs(e), true);
    }

    function keeper() external view returns (address) {
        return S.layout().keeper;
    }

    function epochOf(uint256 t) external view returns (uint256) {
        return K.epochOf(K.env(), t);
    }

    function paused() external view returns (bool) {
        return K.paused();
    }

    function breakerTripped() external view returns (bool) {
        return S.layout().tripped;
    }

    function depthGuardOn() external view returns (bool) {
        return S.layout().price.depthOn;
    }

    /// @notice (median, its SeatSizer `lastObsAt`, week low, last observation). Under the depth guard's lasting state
    ///         the median is capped (it only moves toward a lower P) while `obsAt` stays fresh; see ISeatVaultV5Engine.
    function priceCache()
        external
        view
        returns (uint160 sqrtMedian, uint64 obsAt, uint160 sqrtWeekLow, uint160 sqrtObservation)
    {
        S.Price storage p = S.layout().price;
        return (p.median, p.rawObsAt, p.ringMax, p.obs);
    }

    function price() external view returns (S.Price memory) {
        return S.layout().price;
    }

    function exitHead()
        external
        view
        returns (uint256 entryId, address holder, uint256 rest, uint160 sqrtPLeave, uint64 joinedAt)
    {
        S.Layout storage l = S.layout();
        entryId = l.qHead;
        if (entryId == 0) return (0, address(0), 0, 0, 0);
        S.Entry storage en = l.entries[uint64(entryId)];
        S.Rec storage r = l.recs[en.id][en.gen][en.layer][en.day][en.holder];
        return (entryId, en.holder, r.counted + r.uncounted, r.sqrtLeave, en.joinedAt);
    }

    function bookPoints(uint256 id, uint256 epoch) external view returns (uint256) {
        S.Layout storage l = S.layout();
        S.Gen storage g = l.gens[id][l.latest[id]];
        S.Slot storage s = g.points[epoch % 5];
        return g.pointsVoid || s.epoch != epoch ? 0 : s.points;
    }

    function globalPoints(uint256 epoch) external view returns (uint256) {
        S.Slot storage s = S.layout().globalPts[epoch % 5];
        return s.epoch == epoch ? s.points : 0;
    }

    function cReturned() external view returns (uint256) {
        return S.layout().cReturned;
    }

    function claimable(address holder) external view returns (uint256) {
        return S.layout().claimable[holder];
    }

    function latestGen(uint256 id) external view returns (uint32) {
        return S.layout().latest[id];
    }

    function getGen(uint256 id, uint32 gen) external view returns (S.Gen memory) {
        return S.layout().gens[id][gen];
    }

    function position(uint256 id, uint32 gen, uint8 layer, address holder) external view returns (S.Pos memory) {
        return S.layout().pos[id][gen][layer][holder];
    }

    function record(uint256 id, uint32 gen, uint8 layer, uint32 day, address holder)
        external
        view
        returns (S.Rec memory)
    {
        return S.layout().recs[id][gen][layer][day][holder];
    }

    function leavingBucket(uint256 id, uint32 gen, uint8 layer, uint32 day) external view returns (S.Leaving memory) {
        return S.layout().leaving[id][gen][layer][day];
    }

    function pendingBucket(uint256 id, uint32 gen, uint8 layer, uint32 day) external view returns (S.Pending memory) {
        return S.layout().pend[id][gen][layer][day];
    }

    function loanRecord(uint256 loanId) external view returns (S.LoanRec memory) {
        return S.layout().loans[loanId];
    }

    function entry(uint256 entryId) external view returns (S.Entry memory) {
        return S.layout().entries[uint64(entryId)];
    }

    /// @notice The money aggregates: holders' credits, the buffer, C's fees, the $PRIORS ledger, auto-add's carried
    ///         dust, $PRIORS burned and the defaults of V5's root recorded.
    function totals()
        external
        view
        returns (
            uint256 holdersOwed,
            uint256 bufferOwed,
            uint256 protocolFeesOwed,
            uint256 ledger,
            uint256 carry,
            uint256 burned,
            uint256 recordedDefaults
        )
    {
        S.Layout storage l = S.layout();
        return (l.holdersOwed, l.bufferOwed, l.protocolFeesOwed, l.ledger, l.carry, l.burned, l.recordedDefaults);
    }

    function settings()
        external
        view
        returns (
            bool openBacking,
            uint256 premiumCap,
            uint256 maxSwapUsdg,
            uint256 openRoom,
            uint256 raiseRoom,
            uint256 vouchCap,
            uint8 minDrawK,
            bool premiumCheck,
            uint64 pausedUntil
        )
    {
        S.Layout storage l = S.layout();
        return (
            l.openBacking,
            l.premiumCap,
            l.maxSwapUsdg,
            l.openRoom,
            l.raiseRoom,
            l.vouchCap,
            l.minDrawK,
            l.premiumCheck,
            l.pausedUntil
        );
    }

    function rooms()
        external
        view
        returns (uint64 epochPlusOne, uint256 openUsed, uint256 promoUsed, uint256 stakeUsed)
    {
        S.Layout storage l = S.layout();
        return (l.roomEpoch, l.openUsed, l.promoUsed, l.stakeUsed);
    }

    function delegateOf(uint256 id) external view returns (address who, uint64 at) {
        S.Delegate storage d = S.layout().delegates[id];
        return (d.who, d.at);
    }

    function targetPremiumBps(uint256 id) external view returns (uint256) {
        return S.layout().targetPremium[id];
    }

    function reopenAt(uint256 id) external view returns (uint64) {
        return S.layout().reopenAt[id];
    }

    function entryRule() external view returns (uint8 minEntryLoans, uint32 minEntryDays) {
        S.Layout storage l = S.layout();
        return (l.minEntryLoans, l.minEntryDays);
    }
}
