// AgentLease, the seam (the renting spec, P11, with the owner's answers of 2026-10-27, 2026-10-30 and 2026-10-31;
// docs/AGENT-LEASE.md): the calls, events and errors of the lease as the index, the gas gate, Go mode, the board, the
// MCP and the contract itself (src/AgentLease.sol, src/interfaces/IAgentLease.sol) all name them; the rent, the fee,
// the days paid and the refunds, exactly as the contract computes them; the words a lease or an offer shows; and the
// calls an account sends.
//
// A renter runs an agent on Priors for 1 to 90 days: it sells the agent's work and takes paid jobs under its name, paid
// to its own address. It never borrows on the agent's line, never becomes its wallet or its delegate, and never
// changes its file. The agent stays in its owner's wallet the whole time: the lease never moves it, so its record, its
// line and its Score v2 stay where they are, and the owner can sell it like any other agent.
//
// The renter pays the whole term into the contract at `rent`, and none of it goes to the owner or to the market's feeTo
// then: the fee is never taken from what `rent` or `extend` pays in. (A rent that closes a lease which ran out
// unclaimed pays that old lease out first, as `claim` would.) Each day is paid once it has ended (`claim`, anyone, at
// any time), less its own share of the fee: day k (0-based) carries F(k+1) - F(k), where F(n) is the market's rule on n
// days' rent at the lease's pin, the lower rate and the lower minimum of the offer's fee and the market's at the rent
// (leaseFee, pinOf). The fee is always read live from the market: no helper here assumes one. A payout splits the days
// at the market's last sale since the last payout: the holder at the last payout gets the days that ended by it, the
// owner now the rest. That is each day to whoever held the agent when it ended for one market sale since the last
// payout (a V2 buy or acceptBid, or a v1 sale), and only then: a plain transfer with no sale since gives every unpaid
// day to its receiver, and with two changes of hands between payouts the middle holder is paid nothing (its days go to
// the holder at the last payout when the later change is a market sale, to the owner now when it is a plain transfer).
// So every operation on Priors that changes hands claims before and after the change, in the same operation
// (handoverCalls). Owners collect their own rent. An end first pays the days that ended to their holders (the renter's
// own end of a sound lease, the day under way too; the owner's, whoever holds the agent then, sends that day back),
// then sends every day not paid back to the renter, in full, and never less than the `minRefund` its caller names:
// refundsOf, not leaseOf, gives that figure, and a renter that also holds the agent ends as the renter (refundsOf,
// earlyEnd). Anyone ends a broken agent's lease, and every end of it sends the day under way back, whoever ends: with
// an owner (a default), every ended day still goes to its holders; with none (burnt, or held by the lease), only the
// days that ended by a market sale since the last payout are paid (brokenEnd). `extend` adds days at the lease's own
// day price, up to the rented offer's longest term (extendQuote). A listing of the agent that stands on V2 or v1 bars
// `rent` and `extend`, whoever listed it: the owner's own refuses them, and one whose seller no longer holds the agent
// is cancelled first, which anyone may do (rentCalls, extendCalls). A day price of 0 is allowed for one named address:
// no USDG moves and no fee is taken.
//
//   offerRent(id, dayPrice, minDays, maxDays, renter, expiry)   the owner; renter zero: anyone; paused with rent
//   cancelOffer(id)                                             the offer's owner, or anyone once it can't be taken
//   rent(id, days, maxTotal, recordHash, uriHash)               the renter, after approve(lease, total) when total > 0
//   extend(id, days, maxTotal, recordHash, uriHash)             the renter, after approve(lease, total) when total > 0
//   claim(id)                                                   anyone: pays the days ended; 0 with nothing stored
//   endLease(id, minRefund)                                     the renter, the owner now, anyone once broken
//   withdraw(account)                                           anyone: sends `account` what USDG refused it
//   cancel(id), on V2 or v1                                     anyone, for a listing whose seller no longer holds
//                                                               the agent: before a rent or an extension
//
// test/vectors/agent-lease.json (scripts/lease-vectors.mjs) holds the selectors, topics, errors, quotes, schedules,
// sales, defaults, extensions and calls (a market's cancel before a rent or an extension included); the contract's
// forge tests read it back (test/AgentLeaseVectors.t.sol), and scripts/test-agent-lease.mjs holds this module to it.
//
// A lease's amounts and a refund are on chain because the chain carries them: nothing here words a past lease's price
// or who ended a lease.
import { ethers } from "ethers";
import { toId } from "./credit-profile.mjs";
import { usdgText } from "./work-types.mjs";

/* ---- the contract ---- */

/** The constructor: the ERC-8004 registry, USDG, pool v2, pool v1 (zero allowed), AgentMarketV2, AgentMarket v1 (V2's
 *  previous, zero allowed) and the guardian (the Safe: pause of offerRent, rent and extend only). */
export const LEASE_CONSTRUCTOR = "constructor(address registry, address usdg, address poolV2, address poolV1, address market, address previous, address guardian)";

const OFFER_TUPLE = "tuple(address owner, uint96 dayPrice, address renter, uint8 minDays, uint8 maxDays, uint64 expiry, uint64 soldAt, uint16 feeBps, uint96 minFee)";
const LEASE_TUPLE = "tuple(address renter, uint64 start, uint8 term, uint8 paidDays, uint8 maxDays, address holder, uint96 dayPrice, address owner, uint64 settledAt, uint16 feeBps, uint96 minFee)";
/** The fields of offerOf and leaseOf, in the structs' order (IAgentLease.Offer, IAgentLease.Lease). */
export const OFFER_FIELDS = Object.freeze(["owner", "dayPrice", "renter", "minDays", "maxDays", "expiry", "soldAt", "feeBps", "minFee"]);
export const LEASE_FIELDS = Object.freeze(["renter", "start", "term", "paidDays", "maxDays", "holder", "dayPrice", "owner", "settledAt", "feeBps", "minFee"]);

/** The calls and views. userOf and userExpires take EIP-4907's names and meaning (the renter and the end while the
 *  lease runs and the agent has an owner, else zero); the contract does not claim ERC-4907 and logs no UpdateUser
 *  (owner question F10). paused() is GuardianPause's. */
export const LEASE_FUNCTIONS = Object.freeze([
  "function offerRent(uint256 id, uint256 dayPrice, uint8 minDays, uint8 maxDays, address renter, uint64 expiry)",
  "function cancelOffer(uint256 id)",
  "function rent(uint256 id, uint256 days_, uint256 maxTotal, bytes32 recordHash, bytes32 uriHash) returns (uint64 until)",
  "function extend(uint256 id, uint256 days_, uint256 maxTotal, bytes32 recordHash, bytes32 uriHash) returns (uint64 until)",
  "function claim(uint256 id) returns (uint256 paid)",
  "function endLease(uint256 id, uint256 minRefund) returns (uint256 refund)",
  "function withdraw(address account) returns (uint256 amount)",
  "function userOf(uint256 id) view returns (address)",
  "function userExpires(uint256 id) view returns (uint256)",
  `function leaseOf(uint256 id) view returns (${LEASE_TUPLE})`,
  `function offerOf(uint256 id) view returns (${OFFER_TUPLE})`,
  "function quote(uint256 id, uint256 days_) view returns (uint256 total, uint256 fee)",
  "function claimable(uint256 id) view returns (uint256)",
  "function refundsOf(uint256 id) view returns (uint256 byRenter, uint256 byOwner)",
  "function owed(address account) view returns (uint256)",
  "function paused() view returns (bool)",
  "function market() view returns (address)",
  "function previous() view returns (address)",
  "function MAX_DAYS() view returns (uint256)",
  "function MIN_RENT() view returns (uint256)",
]);

/** The events (docs/AGENT-LEASE.md, "Lease events"), in the interface's order. Rented.fee is the fee the whole term
 *  carries, taken from its payouts: none of the rent moves on at `rent` (a rent that closes a lease which ran out
 *  unclaimed logs that lease's payout first, RentPaid and FeeTaken, then Rented). Extended moves a lease's end.
 *  RentPaid names who a payout went to, net of its days' fee; FeeTaken follows with that payout's fee and the market's
 *  feeTo it went to; RentHeld follows a payout USDG refused, which waits in owed. LeaseEnded is an early end, or the end
 *  of a broken agent's lease (also after its date): a sound lease that runs to its date logs nothing then. */
export const LEASE_EVENTS = Object.freeze([
  "event RentOffered(uint256 indexed agentId, address indexed owner, address indexed renter, uint256 dayPrice, uint8 minDays, uint8 maxDays, uint64 expiry)",
  "event RentOfferCancelled(uint256 indexed agentId, address indexed by)",
  "event Rented(uint256 indexed agentId, address indexed owner, address indexed renter, uint64 start, uint64 until, uint256 total, uint256 fee)",
  "event Extended(uint256 indexed agentId, address indexed owner, address indexed renter, uint64 until, uint256 total)",
  "event RentPaid(uint256 indexed agentId, address indexed to, uint256 amount)",
  "event FeeTaken(uint256 indexed agentId, address indexed to, uint256 amount)",
  "event LeaseEnded(uint256 indexed agentId, address indexed renter, address indexed by, uint256 refund)",
  "event RentHeld(address indexed to, uint256 amount)",
  "event Withdrawn(address indexed to, uint256 amount)",
]);

/** The errors: the lease's own, then the ones with the market's signatures (one error map serves both), then
 *  GuardianPause's IsPaused. */
export const LEASE_ERRORS = Object.freeze([
  "error NoOffer(uint256 id)",
  "error OfferExpired(uint256 id, uint64 expiry)",
  "error OfferGone(uint256 id)",
  "error Leased(uint256 id, uint64 until)",
  "error NotForYou(uint256 id)",
  "error SelfRent()",
  "error RenterIsWallet(uint256 id)",
  "error RenterControls(uint256 id)",
  "error Listed(uint256 id, address market)",
  "error BadDays()",
  "error DayBelowFee(uint256 dayPrice, uint256 fee)",
  "error NoLease(uint256 id)",
  "error CannotEnd(uint256 id, address caller)",
  "error NothingOwed(address account)",
  "error PayOutOfGas()",
  "error NotRenter(uint256 id, address caller)",
  "error ChangedHands(uint256 id)",
  "error RefundBelow(uint256 refund, uint256 minRefund)",
  "error RegistryFailed(uint256 id)",
  "error NotOwner(uint256 id, address seller)",
  "error Custodian(address account)",
  "error Refused(address account)",
  "error Marked(address account)",
  "error IsRoot(uint256 id, address pool)",
  "error AgentDefaulted(uint256 id, address pool)",
  "error RecordChanged(uint256 id)",
  "error UriChanged(uint256 id)",
  "error PriceTooLow(uint256 price)",
  "error PriceAbove(uint256 price, uint256 maxPrice)",
  "error BadExpiry(uint64 expiry)",
  "error CannotCancel(uint256 id, address caller)",
  "error IsPaused(uint64 until)",
]);

export const LEASE_ABI = Object.freeze([LEASE_CONSTRUCTOR, ...LEASE_FUNCTIONS, ...LEASE_EVENTS, ...LEASE_ERRORS]);
export const LEASE_IFACE = new ethers.Interface(LEASE_ABI);
/** Each event's topic0. */
export const LEASE_TOPICS = Object.freeze(Object.fromEntries(LEASE_EVENTS.map((e) => {
  const f = ethers.EventFragment.from(e);
  return [f.name, LEASE_IFACE.getEvent(f.name).topicHash];
})));

/** The market's own calls a lease's client reads and sends, on the lease's market() (V2) and previous() (v1), with the
 *  market's signatures (src/interfaces/IAgentMarket.sol, sdk/market-abi.mjs): listingOf(id), since a listing that
 *  stands on either bars rent and extend, whoever listed it; and cancel(id), which anyone may send for a listing whose
 *  seller no longer holds the agent (rentCalls and extendCalls send it first). Not the lease's: no lease call. */
export const LEASE_MARKET_FUNCTIONS = Object.freeze([
  "function listingOf(uint256 id) view returns (tuple(address seller, uint256 price, uint64 expiry, uint256 nonce, bytes32 uriHash, uint256 loansRepaid) listing)",
  "function cancel(uint256 id)",
]);
const MARKET_IFACE = new ethers.Interface(LEASE_MARKET_FUNCTIONS);

/** What each refusal means for the sheets (the kinds Go mode's and the board's words use). */
export const LEASE_ERROR_KINDS = Object.freeze({
  NoOffer: "noOffer", OfferExpired: "gone", OfferGone: "gone", Leased: "leased", NotForYou: "notForYou", SelfRent: "self",
  RenterIsWallet: "wallet", RenterControls: "controls", Listed: "listed", BadDays: "days", DayBelowFee: "low",
  NoLease: "noLease", CannotEnd: "notYours", NothingOwed: "nothingOwed", PayOutOfGas: "gas", NotRenter: "notYours",
  ChangedHands: "changedHands", RefundBelow: "refundBelow", RegistryFailed: "registry", NotOwner: "notYours",
  Custodian: "cantRent", Refused: "cantRent", Marked: "marked", IsRoot: "cantRent", AgentDefaulted: "cantRent",
  RecordChanged: "record", UriChanged: "record", PriceTooLow: "low", PriceAbove: "price", BadExpiry: "expiry",
  CannotCancel: "notYours", IsPaused: "paused",
});

/** The kind of a lease call's revert data ("0x..."), or null when it is none of the lease's errors. */
export function leaseRefusal(data) {
  if (typeof data !== "string" || !/^0x[0-9a-fA-F]{8}/.test(data)) return null;
  try {
    const e = LEASE_IFACE.parseError(data);
    return e ? { kind: LEASE_ERROR_KINDS[e.name], name: e.name } : null;
  } catch (_) { return null; }
}

/* ---- the rules and the money ---- */

const DAY = 86_400;
/** The contract's rules, and Go mode's cap on one lease, added days included (goMax, the gas gate's: 600 USDG). */
export const LEASE_RULES = Object.freeze({
  minRent: 5_000_000n, // 5 USDG in all at the offer's shortest term, as the market's MIN_PRICE
  maxDays: 90, // MAX_DAYS: a lease runs 1 to 90 days, added days included (the owner's answer of 2026-10-31)
  dayS: DAY,
  maxOfferS: 30 * DAY, // MAX_OFFER: an offer stands 30 days at most
  goMax: 600_000_000n,
});

const uint = (v, what) => toId(v, what);
function daysOf(v, what = "days") {
  if (!Number.isSafeInteger(v) || v < 1 || v > LEASE_RULES.maxDays) throw new Error(`${what} is a whole number from 1 to ${LEASE_RULES.maxDays}`);
  return v;
}
const refusal = (message, kind) => Object.assign(new Error(message), { kind });

/** The market's fee rule on `amount`: max(amount x feeBps / 10,000 rounded down, minFee). The fee is the market's
 *  feeBps and minFee read live (or a lease's pin): there is no default. */
export function feeOn(amount, { feeBps, minFee } = {}) {
  if (feeBps == null || minFee == null) throw new Error("the fee is read live from the market: pass feeBps and minFee");
  const a = uint(amount, "amount"), bps = uint(feeBps, "feeBps"), min = uint(minFee, "minFee");
  const pct = (a * bps) / 10_000n;
  return pct > min ? pct : min;
}

/** The fee pin a rent gives its lease, as the contract sets it: the lower rate and, on its own, the lower minimum of
 *  the offer's (offerOf's feeBps and minFee: the market's at the offer) and the market's now (read live).
 *  { feeBps, minFee } */
export function pinOf(offer, market) {
  if (!offer || !market) throw new Error("pinOf takes the offer (offerOf) and the market's fee now");
  const ob = uint(offer.feeBps, "the offer's feeBps"), mb = uint(market.feeBps, "the market's feeBps");
  const om = uint(offer.minFee, "the offer's minFee"), mm = uint(market.minFee, "the market's minFee");
  return { feeBps: Number(ob < mb ? ob : mb), minFee: om < mm ? om : mm };
}

/**
 * What `rent` takes, as the contract's quote, rent and payouts compute it: { total, fee, firstDay, held } in USDG
 * units. `total` is dayPrice x days, all paid into the lease (`held`); none of it goes to the owner or the fee then.
 * `fee` is F(days), the fee the whole term carries, taken from its payouts, at the lease's pin (pinOf: the offer's fee,
 * offerFeeBps and offerMinFee, default the market's; and the market's now, feeBps and minFee, read live); `firstDay`
 * what day 1 pays its owner when it ends: the day price less F(1). A free lease takes nothing.
 */
export function rentQuote({ dayPrice, days, feeBps, minFee, offerFeeBps = feeBps, offerMinFee = minFee }) {
  if (feeBps == null || minFee == null) throw new Error("rentQuote takes the market's fee now (feeBps, minFee), read live");
  const p = uint(dayPrice, "dayPrice"), d = daysOf(days);
  const total = p * BigInt(d);
  if (total === 0n) return { total: 0n, fee: 0n, firstDay: 0n, held: 0n };
  const pin = pinOf({ feeBps: offerFeeBps, minFee: offerMinFee }, { feeBps, minFee });
  const fee = feeOn(total, pin), f1 = feeOn(p, pin);
  if (fee >= p) throw new Error("the fee is not under a day's rent: no such offer can stand");
  return { total, fee, firstDay: p - f1, held: total };
}

/** Why `offerRent` would refuse these terms, leaving the fee aside: "days", "free" or "low" (offerProblem). */
function offerShape({ dayPrice, minDays, maxDays, renter }) {
  if (!Number.isSafeInteger(minDays) || !Number.isSafeInteger(maxDays) || minDays < 1 || minDays > maxDays || maxDays > LEASE_RULES.maxDays) return "days";
  const p = uint(dayPrice, "dayPrice");
  if (p === 0n) return renter ? null : "free";
  if (p * BigInt(minDays) < LEASE_RULES.minRent) return "low";
  return null;
}

/**
 * Why `offerRent` would refuse these terms, or null: "days" (1 <= minDays <= maxDays <= 90), "free" (a day price of 0
 * with no named renter), "low" (under 5 USDG in all at minDays), "fee" (a day not above the fee on the longest term at
 * the market's fee now: DayBelowFee). `feeBps` and `minFee` are the market's, read live; they have no default.
 */
export function offerProblem({ dayPrice, minDays, maxDays, renter = null, feeBps, minFee }) {
  if (feeBps == null || minFee == null) throw new Error("offerProblem takes the market's fee now (feeBps, minFee), read live");
  const shape = offerShape({ dayPrice, minDays, maxDays, renter });
  if (shape) return shape;
  const p = uint(dayPrice, "dayPrice");
  if (p !== 0n && p <= feeOn(p * BigInt(maxDays), { feeBps, minFee })) return "fee";
  return null;
}

/** A lease as leaseOf gives it ({ renter, start, term, paidDays, maxDays, holder, dayPrice, owner, settledAt, feeBps,
 *  minFee }), with numbers or bigints. Only renter, start and term are needed to show it; the money needs the rest. */
function leaseOf(l) {
  if (!l || l.renter == null) throw new Error("a lease is leaseOf's tuple");
  const term = Number(l.term);
  return {
    renter: String(l.renter),
    start: Number(l.start),
    term,
    paidDays: Number(l.paidDays ?? 0),
    maxDays: Number(l.maxDays ?? term),
    holder: l.holder == null ? null : String(l.holder),
    dayPrice: uint(l.dayPrice ?? 0, "dayPrice"),
    owner: l.owner == null ? null : String(l.owner),
    settledAt: Number(l.settledAt ?? l.start),
    feeBps: l.feeBps == null ? null : Number(l.feeBps),
    minFee: l.minFee == null ? null : uint(l.minFee, "minFee"),
  };
}
const none = (l) => BigInt(l.renter) === 0n;
const ZERO = ethers.ZeroAddress;
/** An address as a lower case key; null or undefined: the zero address (no owner). */
function key(a, what) {
  if (a == null) return ZERO;
  try { return ethers.getAddress(String(a)).toLowerCase(); } catch (_) { throw new Error(`${what} must be an address`); }
}

/** The lease's end: start + term days (seconds). */
export const untilOf = (lease) => { const l = leaseOf(lease); return l.start + l.term * DAY; };
/** True while the lease runs (nowS < its end). */
export const isActive = (lease, nowS) => { const l = leaseOf(lease); return !none(l) && nowS < untilOf(l); };
/** The days of the lease that have ended by `nowS`: day k (0-based) ends at start + (k+1) days; all of them from its
 *  date on. */
export function daysEnded(lease, nowS) {
  const l = leaseOf(lease);
  if (nowS < l.start) return 0;
  return Math.min(l.term, Math.floor((nowS - l.start) / DAY));
}

/**
 * F(k): the fee the first `k` days of a lease carry in all, at its pin (leaseOf's feeBps and minFee): max(k x dayPrice
 * x feeBps / 10,000 rounded down, minFee); 0 for no day and for a free lease. After a payout the fee taken on a lease in
 * all is F(paidDays), so day j (0-based) carries F(j+1) - F(j), however the payouts are grouped.
 */
export function leaseFee(lease, k) {
  const l = leaseOf(lease);
  if (!Number.isSafeInteger(k) || k < 0 || k > LEASE_RULES.maxDays) throw new Error(`k is a whole number of days from 0 to ${LEASE_RULES.maxDays}`);
  if (k === 0 || l.dayPrice === 0n) return 0n;
  if (l.feeBps == null || l.minFee == null) throw new Error("a lease's fee pin (feeBps, minFee) is leaseOf's: read it with the lease");
  return feeOn(BigInt(k) * l.dayPrice, { feeBps: l.feeBps, minFee: l.minFee });
}

/** The contract's _settle: days `paidDays` to `to` of `l`, split between the holder at the last payout and the owner
 *  now (zero: none), each part net of its days' share of the fee. */
function settle(l, { holder, ownerNow, soldAt = 0, settledAt }, to) {
  const from = l.paidDays;
  if (to <= from) return { toHolder: 0n, toOwner: 0n, fee: 0n, paidDays: from };
  const h = key(holder, "the holder"), o = key(ownerNow, "the owner now");
  let split = to;
  if (o !== h) { // a change of hands since the last payout, or no owner any more
    split = from;
    const sold = Number(soldAt);
    if (sold > Number(settledAt)) split = Math.min(Math.max(Math.floor((sold - l.start) / DAY), from), to);
  }
  const paidTo = o === ZERO ? split : to; // with no owner the days after the split are not paid
  const f0 = leaseFee(l, from), f1 = leaseFee(l, split), f2 = leaseFee(l, paidTo);
  return {
    toHolder: BigInt(split - from) * l.dayPrice - (f1 - f0),
    toOwner: BigInt(paidTo - split) * l.dayPrice - (f2 - f1),
    fee: f2 - f0,
    paidDays: paidTo,
  };
}

/** The holder, owner, last sale and last payout a split reads: `holder` defaults to the lease's (leaseOf's holder),
 *  `ownerNow` to the holder (no change of hands; null or zero: no owner), `settledAt` to the lease's. */
function splitAt(l, { holder, ownerNow, soldAt = 0, settledAt }, what) {
  const h = holder ?? l.holder;
  if (h == null) throw new Error(`${what} takes the lease's holder (leaseOf's holder)`);
  return { holder: h, ownerNow: ownerNow === undefined ? h : ownerNow, soldAt, settledAt: settledAt ?? l.settledAt };
}

/**
 * Who a claim at `nowS` pays, as the contract splits it: { toHolder, toOwner, fee, paidDays } in USDG units (paidDays
 * the lease's after the claim). The days ended and not paid are split at the market's last sale since the last payout:
 * `holder` (the lease's holder at its last payout, `settledAt`) gets the days that ended by it (`soldAt`, lastSoldAt
 * now; rounded down), `ownerNow` the rest; with a new owner and no sale since, the owner now gets them all. That is
 * each day to whoever held the agent when it ended for one market sale since the last payout (a V2 buy or acceptBid,
 * or a v1 sale), and only then: a plain transfer with no sale since gives every unpaid day to its receiver, and with
 * two changes of hands the middle holder is paid nothing (its days go to `holder` when the later change is a market
 * sale, to `ownerNow` when it is a plain transfer). With no owner now (null or zero: burnt, or held by the lease), only
 * the holder's days are paid. Each part is net of its days' own fee; `fee` is their sum, to the market's feeTo.
 */
export function claimSplit({ lease, holder, ownerNow, soldAt = 0, settledAt, nowS }) {
  const l = leaseOf(lease);
  if (none(l)) return { toHolder: 0n, toOwner: 0n, fee: 0n, paidDays: 0 };
  return settle(l, splitAt(l, { holder, ownerNow, soldAt, settledAt }, "claimSplit"), daysEnded(l, nowS));
}

/** What claim(id) pays out now, in all, net of the fee (the contract's claimable): the days ended and not paid, each
 *  less its own fee. Without `ownerNow` the lease's holder still holds the agent; with it (and `soldAt`) the days are
 *  split as claimSplit splits them. */
export function claimableOf(lease, nowS, { ownerNow, soldAt = 0 } = {}) {
  const l = leaseOf(lease);
  if (none(l)) return 0n;
  const holder = l.holder ?? (ownerNow === undefined ? "0x0000000000000000000000000000000000000001" : null); // one holder all along
  const s = claimSplit({ lease: l, holder, ownerNow, soldAt, nowS });
  return s.toHolder + s.toOwner;
}

/**
 * What an end at `nowS` sends back to the renter (the contract's refundsOf): { byRenter, byOwner } in USDG units. An
 * end first pays the days that ended, so this, not leaseOf's (term - paidDays) x dayPrice (what the lease holds), is
 * the refund. While a sound lease runs a day is under way: the renter's own end keeps it paid (byRenter, the days after
 * it), the owner's end sends it back too (byOwner); both are 0 once the lease is over. A renter that also holds the
 * agent ends as the renter: its figure is byRenter, so a client names minRefund as account == renter ? byRenter :
 * byOwner. On a broken agent (`broken`, with the split's `ownerNow` and `soldAt` as brokenEnd takes them) every end
 * sends the day under way back, whoever ends: both are brokenEnd's refund.
 */
export function refundsOf(lease, nowS, { broken = false, ...at } = {}) {
  const l = leaseOf(lease);
  if (none(l)) return { byRenter: 0n, byOwner: 0n };
  if (broken) { const r = brokenEnd({ lease: l, ...at, nowS }).refund; return { byRenter: r, byOwner: r }; }
  if (nowS >= untilOf(l)) return { byRenter: 0n, byOwner: 0n };
  const e = daysEnded(l, nowS);
  return { byRenter: BigInt(l.term - e - 1) * l.dayPrice, byOwner: BigInt(l.term - e) * l.dayPrice };
}

/**
 * What an early end of a sound lease does at `nowS` (the contract's endLease while it runs): { toHolder, toOwner, fee,
 * refund } in USDG units. `by` "renter": the days ended and the day under way go to their holders; "owner" (the agent's
 * owner now, a buyer or a bid's maker included): only the days ended. A renter that also holds the agent ends as the
 * renter ("renter"). The days are paid first, split as claimSplit splits them; then every day not paid goes back to
 * the renter in full. A broken agent's end is brokenEnd's, whoever ends.
 */
export function earlyEnd({ lease, by, holder, ownerNow, soldAt = 0, settledAt, nowS }) {
  const l = leaseOf(lease);
  if (none(l) || nowS >= untilOf(l)) throw refusal("only a running lease ends early", "noLease");
  if (by !== "renter" && by !== "owner") throw new Error('by is "renter" or "owner"');
  const at = splitAt(l, { holder, ownerNow, soldAt, settledAt }, "earlyEnd");
  if (key(at.ownerNow, "the owner now") === ZERO) throw new Error("an agent with no owner is broken: its end is brokenEnd's");
  const s = settle(l, at, daysEnded(l, nowS) + (by === "renter" ? 1 : 0));
  return { toHolder: s.toHolder, toOwner: s.toOwner, fee: s.fee, refund: BigInt(l.term - s.paidDays) * l.dayPrice };
}

/**
 * What the end of a broken agent's lease does at `nowS` (the contract's claim or endLease by anyone then, before the
 * lease's date or after): { toHolder, toOwner, fee, refund } in USDG units, the same whoever ends, the renter
 * included: the day under way always comes back. With an owner (`ownerNow`, by default the holder: the agent defaulted
 * on pool v2 or v1), every day ended goes to its holders as a claim pays it, and the day under way and the days not
 * begun go back to the renter. With none (`ownerNow` null or zero: burnt, or held by the lease), the holder at the last
 * payout gets the days that ended by a market sale since (`soldAt`), and every other day not paid goes back.
 */
export function brokenEnd({ lease, holder, ownerNow, soldAt = 0, settledAt, nowS }) {
  const l = leaseOf(lease);
  if (none(l)) return { toHolder: 0n, toOwner: 0n, fee: 0n, refund: 0n };
  const s = settle(l, splitAt(l, { holder, ownerNow, soldAt, settledAt }, "brokenEnd"), daysEnded(l, nowS));
  return { toHolder: s.toHolder, toOwner: s.toOwner, fee: s.fee, refund: BigInt(l.term - s.paidDays) * l.dayPrice };
}

/**
 * What extend(id, days) takes now, from leaseOf's lease: { total, until, room }. `total` is the lease's day price x
 * days, paid into the lease (no fee on top: the added days carry their share when they are paid out); `until` the
 * lease's new end; `room` the most days it can take now (the rented offer's maxDays less its term). Throws as extend
 * reverts: once the lease is over (kind "noLease"), and for days outside 1 to room (kind "max" past room, "days" for
 * fewer than 1). The chain also refuses an extension once the agent changed hands or sold since the rent
 * (ChangedHands), while a listing of it stands on V2 or v1, whoever listed it (extendCalls cancels one whose seller no
 * longer holds the agent first), and on rent's checks of the agent and both accounts.
 */
export function extendQuote({ lease, days, nowS }) {
  const l = leaseOf(lease);
  if (none(l) || nowS >= untilOf(l)) throw refusal("the lease is over: no day can be added", "noLease");
  const room = Math.max(l.maxDays - l.term, 0);
  if (!Number.isSafeInteger(days) || days < 1) throw refusal("days is a whole number, at least 1", "days");
  if (days > room) throw refusal(room ? `the lease can take ${room} more days at most` : "the lease is at its longest term", "max");
  return { total: BigInt(days) * l.dayPrice, until: l.start + (l.term + days) * DAY, room };
}

/* ---- the words (spec 13, with the owner's answers of 2026-10-30 and 2026-10-31) ---- */

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const dayText = (s) => { const d = new Date(Number(s) * 1000); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`; };
const shortAddr = (a) => `${a.slice(0, 6)}..${a.slice(-4)}`;
const noCents = (text) => text.replace(/\.00$/, "");

/**
 * The words of renting, one set for every surface (the board, Go mode and the MCP translate or show them). None names a
 * past lease's price or who ended a lease, and none says the owner vouches for the renter. `end` is the owner's End
 * lease (and anyone's on a broken agent); `endYou` the renter's on a sound agent, also when the renter holds the agent,
 * since it ends as the renter (account == renter); `endYouBroken` the renter's on a broken agent, whose every end sends
 * the current day back. Those three are for a lease that runs: a broken agent's lease ended after its date has no day
 * under way, and takes `endAfter` (the owner's or anyone's) and `endYouAfter` (the renter's). `errors.listed` is the
 * owner's own listing, which rentCalls and extendCalls refuse; the chain's Listed maps there too (a stale listing met
 * in a race, after the reads: read again, and the builders cancel it first).
 */
export const LEASE_WORDS = Object.freeze({
  labels: Object.freeze({ forRent: "For rent", rented: "Rented", dayPrice: "Day price", days: "Days", runYou: "Agents you run", rentedOut: "Rented out", past: "Past leases" }),
  buttons: Object.freeze({ rent: "Rent", rentOut: "Rent it out", cancel: "Cancel offer", extend: "Add days", end: "End lease", claim: "Collect rent", withdraw: "Withdraw" }),
  pill: "{price} USDG a day",
  runBy: "Run by {addr} until {date}",
  offer: "{price} USDG a day, for {min} to {max} days.",
  offerTo: "Offered to {addr}.",
  box: Object.freeze([
    "You sell its work and take paid jobs under its name. Clients pay your own address.",
    "You can't borrow on its line or change its file. Its record stays with the agent.",
    "You pay the whole lease now, and its owner is paid as each day ends. If you end it early, every day after the current one comes back to you in full. If its owner ends it, the current day comes back too.",
  ]),
  sheet: Object.freeze({
    total: "{total} USDG for {days} days of #{id}. It's yours to run until {date}. Each day goes to its owner when it ends, and the fee comes out of the owner's rent, never out of what comes back to you.",
    loans: "Its owner can still borrow on its line. If a loan isn't repaid, you or anyone can end the lease, and the current day and every day after it come back to you.",
    servers: "Its owner's own servers may keep running outside Priors.",
    sale: "If #{id} changes hands, the lease goes on until {date}, but no days can be added. Each change of hands on Priors collects the rent first, so each day goes to whoever held #{id} when it ended.",
    hidden: "If Priors stops showing your offers for #{id}, nothing is paid back. You can end the lease and get the days not begun.",
  }),
  sell: "It's rented until {date}. A buyer gets it with the lease and the rent of each day that ends after the sale. A sale here collects the rent due to you first.",
  rentOut: "Someone pays {price} USDG a day to sell #{id}'s work under its name. They can't borrow on its line or change its file. Each day's rent comes to you when the day ends, less the fee. You can end the lease early at no cost to you, and the renter then gets back the current day and the days after it.",
  end: "The lease ends now. The renter gets back {refund} USDG for {n} days, the current day included.",
  endYou: "The lease ends now. You get back {refund} USDG for the {n} days after the current one, and the current day goes to its owner.",
  endYouBroken: "The lease ends now. You get back {refund} USDG for {n} days, the current day included.",
  endAfter: "The lease ends now. The renter gets back {refund} USDG for {n} days.",
  endYouAfter: "The lease ends now. You get back {refund} USDG for {n} days.",
  errors: Object.freeze({
    leased: "This agent is rented until {date}. You can rent it after that.",
    notForYou: "This offer is for another address. Ask its owner for one.",
    gone: "This offer is closed. Its owner can make a new one.",
    listed: "This agent is listed for sale. You can rent it or add days if the listing is taken down or runs out.",
    self: "You hold this agent. Use Rent it out to set a price.",
    wallet: "This address is the agent's payment wallet. Rent from another address.",
    controls: "This address can borrow for this agent. Rent from another address.",
    marked: "This address has a defaulted loan on Priors, so it can't rent here. Use another address.",
    record: "Its record changed since you looked. Read it again, then rent.",
    price: "The price changed since you looked. Read the offer again, then rent.",
    short: "You have {cash} USDG. Add {short} more, then rent.",
    over: "Go mode rents up to 600 USDG a lease, added days included. Choose fewer days.",
    low: "A paid lease costs 5 USDG or more in all, and a day costs more than the fee. Raise the day price.",
    cantRent: "This agent can't be rented here. Choose another agent.",
    paused: "Renting is paused for now. Ending a lease still works.",
    changedHands: "This agent changed hands since you rented it, so no days can be added. Its new owner can offer it again once this lease ends.",
    max: "This lease can't run longer than its owner offers, {max} days in all. Add fewer days, or rent it again once it ends.",
    notRenter: "Only the address that rented this agent can add days. Use that address.",
    refundBelow: "A day ended while this was being sent, so less would come back than you saw. Read the lease again, then end it.",
    registry: "The agent registry didn't answer, so nothing moved. Try again in a moment.",
  }),
  bell: Object.freeze({
    rented: "#{id} is rented until {date}.",
    extended: "#{id}'s lease now runs until {date}.",
    ending: "Your lease on #{id} ends within a day, on {date}.",
    endedEarly: "Your lease on #{id} ended early. {refund} USDG came back to you.",
    collect: "{amount} USDG of rent to collect on #{id}.",
    defaulted: "#{id} defaulted, so you can end its lease. The current day and every day after it come back to you.",
  }),
});

const fill = (t, v) => t.replace(/\{(\w+)\}/g, (m, k) => (k in v ? String(v[k]) : m));

/** An address, checksummed or lower case, never zero; lower case. */
function addressOf(a, what) {
  let x;
  try { x = ethers.getAddress(a); } catch (_) { throw new Error(`${what} must be an address`); }
  if (x === ethers.ZeroAddress) throw new Error(`${what} must not be the zero address`);
  return x.toLowerCase();
}

/** A running lease as every surface shows it: { by, since, until, words: "Run by 0x12..ab until 30 Nov" }. No price.
 *  Null when there is none, or it is over at `nowS`. */
export function leaseView(item, { nowS = Math.floor(Date.now() / 1000) } = {}) {
  if (!item || item.renter == null || BigInt(item.renter) === 0n) return null;
  const l = leaseOf(item);
  if (!isActive(l, nowS)) return null;
  const by = addressOf(l.renter, "the renter"), until = untilOf(l);
  return { by, since: l.start, until, words: fill(LEASE_WORDS.runBy, { addr: shortAddr(by), date: dayText(until) }) };
}

/** A standing offer as the For rent box shows it: { dayPrice: "2.00", minDays, maxDays, for, until, pill, words }. Null
 *  for none. `for` is the named renter (lower case), or null for anyone. */
export function offerView(item) {
  if (!item || item.owner == null || BigInt(item.owner) === 0n) return null;
  const p = uint(item.dayPrice, "dayPrice"), min = daysOf(Number(item.minDays), "minDays"), max = daysOf(Number(item.maxDays), "maxDays");
  const forWho = item.renter && BigInt(item.renter) !== 0n ? addressOf(item.renter, "the renter") : null;
  const price = noCents(usdgText(p));
  const words = [fill(LEASE_WORDS.offer, { price, min, max })];
  if (forWho) words.push(fill(LEASE_WORDS.offerTo, { addr: shortAddr(forWho) }));
  return { dayPrice: usdgText(p), minDays: min, maxDays: max, for: forWho, until: Number(item.expiry), pill: fill(LEASE_WORDS.pill, { price }), words };
}

/* ---- the calls, for agents and scripts ---- */

const USDG_IFACE = new ethers.Interface(["function approve(address spender, uint256 amount) returns (bool)"]);
const bytes32Of = (v, what) => { if (!/^0x[0-9a-fA-F]{64}$/.test(String(v))) throw new Error(`${what} is a 32-byte hex value`); return String(v).toLowerCase(); };
const call = (to, fn, args) => ({ to, data: LEASE_IFACE.encodeFunctionData(fn, args) });

/** offerRent: the owner's offer. `renter` null for anyone; `dayPrice` 0 only with a renter. With the market's fee read
 *  live (`feeBps` and `minFee`) it also refuses a day not above the fee on the longest term. [{ to, data }] */
export function offerCalls({ lease, id, dayPrice, minDays, maxDays, renter = null, expiry, feeBps, minFee }) {
  const to = addressOf(lease, "the lease");
  const who = renter ? addressOf(renter, "the renter") : ethers.ZeroAddress;
  const terms = { dayPrice, minDays, maxDays, renter: renter ? who : null };
  const problem = feeBps == null && minFee == null ? offerShape(terms) : offerProblem({ ...terms, feeBps, minFee });
  if (problem) throw new Error(`the offer is refused: ${problem}`);
  return [call(to, "offerRent", [uint(id, "id"), uint(dayPrice, "dayPrice"), minDays, maxDays, who, uint(expiry, "expiry")])];
}

/** cancelOffer. [{ to, data }] */
export const cancelOfferCalls = ({ lease, id }) => [call(addressOf(lease, "the lease"), "cancelOffer", [uint(id, "id")])];

/** A market's listingOf(id) as read: { seller (lower case; zero for none), expiry }. */
function listingRead(l, what) {
  if (l == null || l.seller == null) throw new Error(`${what} is the market's listingOf(id), read just before (its seller the zero address for none)`);
  let seller;
  try { seller = ethers.getAddress(String(l.seller)).toLowerCase(); } catch (_) { throw new Error(`${what}'s seller must be an address`); }
  if (seller !== ZERO && l.expiry == null) throw new Error(`${what} takes listingOf's expiry`);
  return { seller, expiry: seller === ZERO ? 0 : Number(l.expiry) };
}

/** What a rent or an extension of agent `id` sends before its own calls, for the listings that would bar it (the
 *  contract's Listed): a market's cancel(id) for each listing not expired at `nowS` whose seller no longer holds the
 *  agent, V2's before v1's. One by the owner now refuses (kind "listed"). [{ to, data }, ...] */
function unlistCalls({ id, ownerNow, market, listing, previous, prevListing, nowS }) {
  const owner = addressOf(ownerNow, "ownerNow (the agent's owner now)");
  if (!Number.isSafeInteger(nowS) || nowS < 0) throw new Error("nowS is the time the listings were read, in seconds");
  if (previous === undefined) throw new Error("previous is the lease's previous() (the zero address for none)");
  const markets = [[addressOf(market, "the market"), listingRead(listing, "listing")]];
  const prev = key(previous, "previous");
  if (prev !== ZERO) markets.push([prev, listingRead(prevListing, "prevListing")]);
  const calls = [];
  for (const [m, l] of markets) {
    if (l.seller === ZERO || nowS >= l.expiry) continue; // none, or expired: it bars nothing
    if (l.seller === owner) throw refusal(`#${id} is listed by its owner on ${m}: no lease starts or grows while that listing stands`, "listed");
    calls.push({ to: m, data: MARKET_IFACE.encodeFunctionData("cancel", [id]) });
  }
  return calls;
}

/**
 * rent or extend, as the calls of one operation: first, for each listing of agent `id` that stands at `nowS` (not
 * expired) on the lease's market (V2) or its previous (v1) while its seller no longer holds the agent, that market's
 * cancel(id), which anyone may send (V2's before v1's); then USDG approve(lease, total) exactly (none when nothing is
 * paid); then the call with maxTotal = total and the pins read. Any listing that stands bars both calls, whoever listed
 * it (Listed): one by an earlier holder is buyable again once the agent goes back to it, and a buyer in flight would
 * meet a new or a longer lease. One by the owner now refuses here (kind "listed"): only the owner can take it down
 * before its expiry. The reads, just before: `ownerNow` (the registry's ownerOf(id)), `market` and `previous` (the
 * lease's market() and previous(), the zero address for none), `listing` and `prevListing` (listingOf(id) on each: its
 * seller, the zero address for none, and its expiry), and `nowS`, their time. A cancel that lands first (by its seller
 * or anyone) makes this one revert NoListing: read again, and the next operation goes without it.
 */
function paidCalls(fn, { lease, usdg, id, days, total, recordHash, uriHash, ownerNow, market, listing, previous, prevListing, nowS }) {
  const to = addressOf(lease, "the lease"), t = uint(total, "total"), i = uint(id, "id");
  const calls = unlistCalls({ id: i, ownerNow, market, listing, previous, prevListing, nowS });
  if (t > 0n) calls.push({ to: addressOf(usdg, "USDG"), data: USDG_IFACE.encodeFunctionData("approve", [to, t]) });
  calls.push(call(to, fn, [i, BigInt(daysOf(days)), t, bytes32Of(recordHash, "recordHash"), bytes32Of(uriHash, "uriHash")]));
  return calls;
}

/** rent: a stale listing's cancel first (paidCalls), USDG approve(lease, total) exactly, then rent with maxTotal =
 *  total and the pins read (no approval for a free lease). [{ to, data }, ...] */
export const rentCalls = (args) => paidCalls("rent", args);

/** extend: a stale listing's cancel first (paidCalls), USDG approve(lease, total) exactly (extendQuote's total), then
 *  extend with maxTotal = total and the pins read; the renter only (no approval for a free lease).
 *  [{ to, data }, ...] */
export const extendCalls = (args) => paidCalls("extend", args);

/** claim. [{ to, data }] */
export const claimCalls = ({ lease, id }) => [call(addressOf(lease, "the lease"), "claim", [uint(id, "id")])];

/**
 * What a change of hands of agent `id` sends around its own calls, in the same operation (the client rule,
 * docs/AGENT-LEASE.md): { before, after }. While a lease is stored (`leased`: leaseOf names a renter, running or ended
 * and not yet paid out), claim(id) before, so every day ended until now goes to whoever held the agent when it ended,
 * and claim(id) after, so the new holder is recorded at once and a later change of hands elsewhere can't take its
 * days (claim on an agent with nothing stored returns 0, so the second never fails). For a move outside the market
 * (`plain`), cancelOffer(id) before while an offer stands (`offered`), as a round trip by plain transfers would bring
 * it back. Go mode's Buy ([...before, approve, buy, ...after]), Accept and transfer, the board's wallet paths and
 * @priors/mcp's market_buy and market_accept wrap their own calls in these; Go mode's Sell sends `before` ahead of its
 * listing.
 */
export function handoverCalls({ lease, id, leased = false, offered = false, plain = false }) {
  const before = [], after = [];
  if (leased) before.push(...claimCalls({ lease, id }));
  if (plain && offered) before.push(...cancelOfferCalls({ lease, id }));
  if (leased) after.push(...claimCalls({ lease, id }));
  return { before, after };
}

/** endLease, with the least refund the caller takes (`minRefund`, refundsOf's figure read just before, never leaseOf's:
 *  account == renter ? byRenter : byOwner, since a renter that also holds the agent ends as the renter; 0 to take
 *  whatever it is). [{ to, data }] */
export const endCalls = ({ lease, id, minRefund }) => [call(addressOf(lease, "the lease"), "endLease", [uint(id, "id"), uint(minRefund, "minRefund")])];

/** withdraw: sends `account` what USDG refused it (owed); anyone may send it, and it pays that account only. [{ to, data }] */
export const withdrawCalls = ({ lease, account }) => [call(addressOf(lease, "the lease"), "withdraw", [addressOf(account, "the account")])];
