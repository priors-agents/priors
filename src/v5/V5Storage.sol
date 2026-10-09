// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title V5Storage
/// @notice SeatVaultV5's whole state, at one ERC-7201 namespaced slot, so V5 and its linked libraries (which run by
///         DELEGATECALL in V5's context) share one layout. Amounts of $PRIORS in a generation are kept "in its layer's
///         burn-factor units": before a settle a unit is a token; after it a unit pays floor(units × (1 − rate)).
library V5Storage {
    /// @dev keccak256(abi.encode(uint256(keccak256("priors.seatvault.v5")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xcdde73c5677481b13a9fd0c58a089a0307b78e5c27d24daeaaa5854a73c18400;

    /// @dev A pending bucket: new stake of one layer and UTC day, merging into the layer's counted total at the first
    ///      poke at least 24 h after its latest deposit (2.7).
    struct Pending {
        uint128 amount;
        uint64 lastDeposit;
        bool merged;
        bool dead; // its layer moved to leaving before it merged: it never merges
        uint256 mergeIndex;
    }

    /// @dev A leaving bucket: one layer and UTC day of leaves (2.5).
    struct Leaving {
        bool exists;
        bool retired;
        uint64 latestLeave;
        uint64 releasableAt; // stored once, by the first poke after the bucket's day ended whose loan rule holds
        uint256 loanCount; // pool.loanCount() at the latest leave
        uint256 counted; // in the fee divisor until retired
        uint256 uncounted; // stake that left while pending: burns, never earns
        uint256 retireIndex;
    }

    /// @dev A holder's live position in one layer of one generation.
    struct Pos {
        uint256 counted;
        uint256 checkpoint; // fee index the counted shares are credited to
        uint256 a0; // pending amounts, each on its own bucket's clock (2.7)
        uint256 a1;
        uint32 d0; // their UTC days, + 1 (0: empty)
        uint32 d1;
        bool autoAdd;
    }

    /// @dev A holder's leaving record in one bucket (2.2). In the exit queue it is the entry itself (mode 2).
    struct Rec {
        uint256 counted;
        uint256 uncounted;
        uint256 creditedTo;
        uint160 sqrtLeave; // the stricter (lower-sqrt, higher-price) P of the leaves it holds
        uint8 mode; // 0 hold, 1 return $PRIORS, 2 return USDG
        uint64 entry; // its exit-queue entry id, 0 if not queued
    }

    struct Entry {
        uint256 id;
        uint32 gen;
        uint8 layer;
        uint32 day;
        address holder;
        uint64 joinedAt;
        uint64 prev;
        uint64 next;
    }

    /// @dev What V5 records of a loan its root sponsors.
    struct LoanRec {
        uint32 gen;
        uint8 tier;
        uint32 tierStep;
        bool seen;
        bool viaHook; // recorded by onBorrow (only such a loan can count)
        bool counted;
        bool breakerSeen;
        bool lateDone;
    }

    struct Slot {
        uint64 epoch;
        uint192 points;
    }

    struct DayBucket {
        uint32 day;
        uint224 amount;
    }

    struct RingDay {
        uint32 day; // UTC day + 1 (0: empty)
        uint160 sqrt; // the day's lowest cached median (the highest sqrtPriceX96)
        bool observed; // at least one sync() that day
        bool guardSeen; // a sync() that day ran with the depth guard on
    }

    struct Delegate {
        address who;
        uint64 at;
    }

    /// @dev The price cache `sync()` writes (2.3, 2.8).
    struct Price {
        uint160 rawMedian; // the SeatSizer median the last sync() read
        uint64 rawObsAt; // the SeatSizer lastObsAt stored with it: the cache's clock
        uint160 median; // the capped median P reads (under the depth guard it moves only toward a lower P)
        uint160 obs; // the keeper's last observation at the last sync()
        uint160 ringMax; // highest sqrtPriceX96 in the ring: the week low
        uint160 ringMin; // lowest sqrtPriceX96 in the ring: the week's high
        uint160 guardLow; // the week low when the depth guard came on
        uint32 lastDay; // UTC day of the last sync(), + 1
        uint8 kBase; // the one stored k (doubled), hysteresis only
        uint8 k; // cached k (doubled): fail-safe, then kBase or its step-up
        uint16 feeBps;
        bool feeOk;
        bool spotLatch;
        bool depthOn;
        uint64 guardOffSince;
    }

    struct Gen {
        // slot: identity
        address owner; // the bound owner: posted A
        uint64 openedAt;
        uint8 status;
        bool ownerChanged;
        bool optOut; // protocol backing off (question 11)
        bool othersOff; // others' backing off (question 22)
        // flags and tier
        bool pointsVoid; // a hook voided the points: they read 0, and the next first steps erase them from the totals
        bool openRoomCharged; // also: the book has borrowed
        bool closedByOwner;
        bool movePending; // closed inside a hook: its layers move to leaving at the next book call
        bool splitPending; // settled inside a hook: the fees owed before the default split at the next first steps
        uint64 movePendingAt; // ... as of this time, the close's (audit L-02)
        uint8 tier;
        uint8 countedAtTier;
        uint8 listLen;
        uint32 tierStep;
        uint64 tierSince;
        uint64 lastLateAt;
        uint64 closedMark;
        uint64 lastRaiseAt;
        uint64 promoEpoch;
        uint64 stakeEpoch; // epoch + 1 of stakeRaised
        uint64 placeEpoch; // epoch + 1 of placed
        uint160 movePendingSqrt; // P (`pDown()`) at a close inside a hook: the deferred move's `endSqrt` (deep audit D-05)
        uint256 roomLine; // the line some room has paid for
        uint256 openLine; // the line `open` approved (the open room's charge)
        uint256 promoCredit;
        uint256 stakeRaised;
        uint256 placed;
        uint256 index; // fee index, 1e36
        uint256 divisor; // counted tokens: live counted plus leaving counted not yet retired
        uint256 defaultProof;
        uint256 cLive; // C: counted + pending + leaving not yet retired
        uint256 cUnits; // C: every unit not yet paid out
        uint256[3] list; // C.LIST_CAP
        uint256[3] counted; // live counted per layer
        uint256[3] pendingTok; // unmerged, live pending per layer
        uint256[3] leavingLive; // leaving tokens per layer in buckets not yet retired
        uint256[3] tokens; // every unit of the layer in this generation not yet paid out
        uint64[3] layerEnd; // when the layer moved to leaving (0: live)
        uint160[3] endSqrt; // P at that move
        uint8[3] ownerEndMode; // the bound owner's record mode for that move
        uint32[2][3] liveDay; // unmerged pending bucket days per layer, + 1
        uint32[3] leaveHead; // next leaving bucket to store or retire, per layer
        Slot[5] points;
    }

    struct Layout {
        // settings (timelocked) and roles
        address keeper;
        bool openBacking;
        bool premiumCheck;
        uint8 minDrawK;
        uint64 premiumCheckFrom;
        uint256 premiumCap;
        uint256 maxSwapUsdg;
        uint256 openRoom;
        uint256 raiseRoom;
        uint256 vouchCap;
        uint8 minEntryLoans; // T1 entry's qualifiedRepaid (owner's addition: 0, stake-only entry, by default)
        uint32 minEntryDays; // T1 entry's days since pool enrolment (0 by default)
        // guardian
        uint64 pausedUntil;
        uint64 pauseEnd;
        // the root
        bool rootReady;
        uint256 childBase;
        uint256 recordedDefaults;
        // price and guards
        Price price;
        RingDay[7] ring;
        // circuit breaker
        DayBucket[30] defB;
        DayBucket[30] repB;
        bool tripped;
        uint64 clearedAt;
        // rooms
        uint64 roomEpoch; // + 1
        uint256 openUsed;
        uint256 promoUsed;
        uint256 stakeUsed;
        // fees
        uint256 holdersOwed;
        uint256 bufferOwed;
        uint256 protocolFeesOwed;
        // tokens
        uint256 ledger;
        uint256 carry;
        uint256 burned;
        uint256 cReturned;
        // exit queue
        uint64 qHead;
        uint64 qTail;
        uint64 nextEntry;
        uint32 sellDay; // + 1
        uint256 sellSpent;
        Slot[5] globalPts;
        mapping(address => uint256) claimable;
        mapping(uint256 => uint32) latest;
        mapping(uint256 => uint64) reopenAt;
        mapping(address => uint64) lastOpenAt;
        mapping(uint256 => Delegate) delegates;
        mapping(uint256 => uint256) targetPremium;
        mapping(uint256 => uint256) feeMark;
        mapping(uint256 => mapping(uint32 => Gen)) gens;
        mapping(uint256 => mapping(uint32 => mapping(uint8 => mapping(address => Pos)))) pos;
        mapping(uint256 => mapping(uint32 => mapping(uint8 => mapping(uint32 => Pending)))) pend;
        mapping(uint256 => mapping(uint32 => mapping(uint8 => mapping(uint32 => Leaving)))) leaving;
        mapping(uint256 => mapping(uint32 => mapping(uint8 => uint32[]))) leaveDays;
        mapping(uint256 => mapping(uint32 => mapping(uint8 => mapping(uint32 => mapping(address => Rec))))) recs;
        mapping(uint256 => mapping(uint32 => mapping(uint32 => uint256))) cInBucket;
        mapping(uint256 => LoanRec) loans;
        mapping(uint256 => Entry) entries;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }
}
