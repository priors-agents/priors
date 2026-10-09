// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Env, C, IV5Events, IV5Errors} from "./V5Types.sol";
import {V5Storage as S} from "./V5Storage.sol";
import {V5Math as M} from "./V5Math.sol";
import {V5Core as K} from "./V5Core.sol";

/// @title V5Sync
/// @notice `sync()` (docs/PRIORS-UNDERWRITING-SPEC.md rev 5, 2.3, 2.8, 2A.1, 2A.6): the only writer of the price cache,
///         the week's ring, k, the spot guard's latch and the depth guard's lasting state, each from inputs no
///         transaction can move (the keeper's SeatSizer observations and the keeper's or the Safe's depth snapshots).
///         Permissionless; it needs a SeatSizer observation at most 45 min old. A linked library.
library V5Sync {
    struct Ring {
        uint160 maxS;
        uint160 minS;
        uint160 prevMax; // the largest sqrtPriceX96 of the other days in the window
        uint160 newest;
        bool allObserved;
    }

    function sync() external {
        Env memory e = K.env();
        S.Layout storage l = S.layout();
        S.Price storage p = l.price;
        uint64 obsAt = e.sizer.lastObsAt();
        if (block.timestamp > uint256(obsAt) + C.FRESH) revert IV5Errors.StaleSizer();
        uint160 med = e.sizer.medianSqrtPrice(); // reverts with fewer than 24 observations of the last 24 h
        uint160 ob = K.lastObs(e);
        p.rawMedian = med;
        p.rawObsAt = obsAt;
        p.obs = ob;
        bool guard = _depthGuard(e, p);
        // the cache P reads: under the guard it only moves toward a lower P
        p.median = guard && p.median != 0 ? M.max160(p.median, med) : med;
        Ring memory r = _ring(l, p, guard);
        p.ringMax = r.maxS;
        p.ringMin = r.minS;
        if (guard && r.maxS > p.guardLow) p.guardLow = r.maxS;
        _k(p, r, guard);
        _fee(e, p);
        _spotLatch(p, ob);
        K.breakerEval();
        emit IV5Events.Synced(p.median, p.ringMax, p.k);
    }

    /// @dev The depth guard's lasting state, decided on the median-valued form at the fresh SeatSizer median and the
    ///      snapshot's age: on at the first sync() that reads it on, off only after 24 h of syncs reading it off.
    function _depthGuard(Env memory e, S.Price storage p) private returns (bool) {
        bool form = K.depthForm(e, true);
        if (form) {
            p.guardOffSince = 0;
            if (!p.depthOn) {
                p.depthOn = true;
                p.guardLow = p.ringMax;
                emit IV5Events.GuardChanged(1, true);
            }
        } else if (p.depthOn) {
            if (p.guardOffSince == 0) {
                p.guardOffSince = uint64(block.timestamp);
            } else if (block.timestamp >= uint256(p.guardOffSince) + C.GUARD_RECOVERY) {
                p.depthOn = false;
                p.guardOffSince = 0;
                emit IV5Events.GuardChanged(1, false);
            }
        }
        return p.depthOn;
    }

    /// @dev Today's ring entry (the day's lowest cached median; under the guard at most the week low from when the
    ///      guard came on), days with no sync() inheriting the previous entry as unobserved, then the window's extremes.
    function _ring(S.Layout storage l, S.Price storage p, bool guard) private returns (Ring memory r) {
        uint32 d = K.today();
        uint32 d1 = d + 1;
        S.RingDay storage t = l.ring[d % 7];
        if (p.lastDay != d1) {
            if (p.lastDay != 0) {
                uint32 last = p.lastDay - 1;
                uint160 inherit = l.ring[last % 7].sqrt;
                uint32 from = last + 1;
                if (d > 7 && from < d - 6) from = d - 6;
                for (uint32 dd = from; dd < d; dd++) {
                    l.ring[dd % 7] = S.RingDay({day: dd + 1, sqrt: inherit, observed: false, guardSeen: false});
                }
            }
            l.ring[d % 7] = S.RingDay({day: d1, sqrt: p.median, observed: true, guardSeen: guard});
            p.lastDay = d1;
        } else {
            if (p.median > t.sqrt) t.sqrt = p.median;
            if (guard) t.guardSeen = true;
        }
        if (guard && p.guardLow > t.sqrt) t.sqrt = p.guardLow;
        r.newest = t.sqrt;
        r.minS = type(uint160).max;
        uint256 seen;
        r.allObserved = true;
        for (uint256 i = 0; i < 7; i++) {
            S.RingDay storage x = l.ring[i];
            if (x.day == 0 || uint256(x.day) + 6 < d1) continue; // empty, or older than the last 7 days
            seen++;
            if (!x.observed || x.guardSeen) r.allObserved = false;
            if (x.sqrt > r.maxS) r.maxS = x.sqrt;
            if (x.sqrt < r.minS) r.minS = x.sqrt;
            if (x.day != d1 && x.sqrt > r.prevMax) r.prevMax = x.sqrt;
        }
        if (seen < 7) r.allObserved = false;
    }

    /// @dev k_base with the hysteresis (never lowered under the guard); the fail-safe, then the step-up on top.
    function _k(S.Price storage p, Ring memory r, bool guard) private {
        uint8 prev = p.kBase == 0 ? C.K_WILD : p.kBase;
        uint8 kb = M.kBase(prev, r.maxS, r.minS);
        if (guard && kb < p.kBase) kb = p.kBase;
        p.kBase = kb;
        uint8 k = kb;
        if (r.prevMax != 0 && M.stepUp(r.newest, r.prevMax, r.maxS, r.minS)) k = M.kNext(kb);
        if (!r.allObserved) k = C.K_WILD;
        if (k != p.k) emit IV5Events.KChanged(k, r.maxS, r.minS);
        p.k = k;
    }

    /// @dev The live fee, read with a fixed budget the call must leave whole: a starved sync() reverts and writes
    ///      nothing, so `feeOk` false only ever means the hook's own failed read (deep audit H-01, L-07).
    function _fee(Env memory e, S.Price storage p) private {
        K.fixedBudget(C.FEE_READ_GAS);
        (uint256 f, bool ok) = e.limiter.liveFeeBps{gas: C.FEE_READ_GAS}();
        p.feeOk = ok;
        p.feeBps = f > type(uint16).max ? type(uint16).max : uint16(f);
    }

    /// @dev The spot guard's latch, from the keeper's latest observation against the cached median: on at ≤ 0.80 ×
    ///      median, off at ≥ 0.90 × median (2A.1).
    function _spotLatch(S.Price storage p, uint160 ob) private {
        if (!p.spotLatch && M.atOrUnder80(ob, p.median)) {
            p.spotLatch = true;
            emit IV5Events.GuardChanged(2, true);
        } else if (p.spotLatch && M.atOrOver90(ob, p.median)) {
            p.spotLatch = false;
            emit IV5Events.GuardChanged(2, false);
        }
    }
}
