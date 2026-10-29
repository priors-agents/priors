// The market's planner for a wallet that signs its own transactions (the P7 spec, section 5): what an agent's own key
// reads, checks and sends to list, cancel, buy, bid on and accept a bid for an agent, on AgentMarket v1 or AgentMarketV2,
// one plain transaction at a time. @priors/mcp's market tools (packages/mcp/src/market-tools.mjs) run it; the package
// holds a byte-for-byte copy (scripts/test-packages.mjs fails on any drift). Pure: no network, no clock, no file.
//
//   1. kindReads(market): which market answers at the address, v1 or V2, at one block (marketKindOf). v1's bidSpender()
//      reverts with no data; V2's is CREATE(market, 1) (market-bids spenderOf), whose market() is the market. Its
//      registry and USDG must be the package's record's. A V2 with the builder share (the P5 spec, section 2) answers
//      MAX_BUILDER_BPS(); one without it reverts with no data, and every sale then pays no share. Its owner's switch,
//      buildersOn() (false until the Safe calls enableBuilders(), once, for good), is read with each agent's reads, at
//      the plan's block, never kept: while it is off no share can be set, and none is reported.
//   2. agentReads, accountReads, bidReads, then moreReads (the agent's sponsor's followsLine, the seller's and the
//      makers' accounts): one Multicall3 aggregate3 each, every call allowed to fail, all at one block. readsOut decodes
//      them into `c`, the object every plan reads; a read that failed is null, and a plan given null answers "unread",
//      never a guess.
//   3. sellPlan, buyPlan, cancelPlan, bidPlan, bidAnyPlan, cancelBidPlan, acceptPlan: the contract's rules in its order
//      (web/board-wallet-core.js sellState and buyPlan, web/board-wallet-bids-core.js, which a test holds this to), then
//      the steps, each one transaction: { steps, pins, ... } or { error: kind, ...vars }.
//   4. stepCalls(step, o): a step's { to, data }, from market-abi's MARKET_IFACE and market-bids' call builders.
//   5. MARKET_ERRORS and errorKindOf(revertData, role): a revert's kind; PLAN_WORDS and planWords(kind, vars): its words.
//
// What a sale leaves the seller is computed in netOf alone: price - fee - the builder's share, the share only where the
// market answers builderOf (P5), else price - fee. An open asking price and an open bid are worded; a price paid or taken
// is never worded after the fact.
import { ethers } from "ethers";
import { MARKET_IFACE, LISTING_RULES, feeOf } from "./market-abi.mjs";
import { BID_RULES, BID_WORDS, spenderOf, idsRootOf, listOf, inRoot, reserveCall, bidCall, bidAnyCall, cancelBidCall, acceptCall } from "./market-bids.mjs";

/* ---- small helpers ---- */

const ZERO = ethers.ZeroAddress, ZERO32 = ethers.ZeroHash;
const HEX32 = /^0x[0-9a-fA-F]{64}$/;
const DAY = 86400;
const lc = (a) => String(a).toLowerCase();
const isAddr = (a) => typeof a === "string" && /^0x[0-9a-fA-F]{40}$/.test(a) && BigInt(a) !== 0n;
const same = (a, b) => isAddr(a) && isAddr(b) && lc(a) === lc(b);
const big = (v) => (typeof v === "bigint" ? v : BigInt(v));
/** bytes32(id): a bid on one agent's target. */
const idWord = (id) => ethers.toBeHex(big(id), 32);
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
/** A UTC day as the words say it: "3 Nov". */
export const dayText = (s) => { const d = new Date(Number(s) * 1000); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`; };
/** USDG units as the words say them: "120", "1.20", "0.25". */
export function amountText(units) {
  const n = big(units), whole = n / 1_000_000n, frac = (n % 1_000_000n).toString().padStart(6, "0").replace(/0+$/, "");
  const w = String(whole).replace(/\B(?=([0-9]{3})+(?![0-9]))/g, ",");
  return frac ? `${w}.${frac.padEnd(2, "0")}` : w;
}

/* ---- the reads ---- */

/** Multicall3, at the same address on every chain (data-worker/registry.mjs). */
export const MULTICALL3 = "0xca11bde05977b3631167028862be2a173976ca11";
const MC3 = new ethers.Interface(["function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[] returnData)"]);

const LISTING = "tuple(address seller, uint256 price, uint64 expiry, uint256 nonce, bytes32 uriHash, uint256 loansRepaid)";
const BID = "tuple(address maker, uint64 expiry, uint16 left, bool any, uint96 price, uint96 minLine, uint64 minRepaid, bytes32 target, bytes32 uriHash)";
const AGENT_V2 = "tuple(bool enrolled, bool isRoot, bool defaulted, bool frozen, bool importedFromV1, uint64 enrolledAt, uint64 lastBorrowAt, uint64 lastRepayAt, uint256 sponsor, uint256 delegatedIn, uint256 delegatedOut, uint256 principalOut, uint256 activeLoans, uint256 premiumBps, uint256 premiumCap, uint256 loansRepaid, uint256 volumeRepaid, uint256 feesPaid, uint256 recourseHonored, uint256 childrenDefaulted, uint256 qualifiedRepaid, uint256 dollarSecondsRepaid)";
const AGENT_V1 = "tuple(bool enrolled, bool isRoot, bool defaulted, uint64 enrolledAt, uint256 sponsor, uint256 delegatedIn, uint256 delegatedOut, uint256 earned, uint256 stake, uint256 principalOut, uint256 activeLoans, uint256 loansRepaid, uint256 volumeRepaid, uint256 feesPaid, uint256 recourseHonored, uint256 childrenDefaulted, uint64 epochStart, uint256 earnedThisEpoch, uint256 qualifiedRepaid, uint256 dollarSecondsRepaid)";
/** Every view a plan reads, by the contract that answers it (src/AgentMarket.sol, src/AgentMarketV2.sol, BidSpender,
 *  the ERC-8004 registry, CreditPoolV2, CreditPool v1, InviteBond v1 and V2, USDG). Pool v1 and the two bonds answer
 *  their own structs under the same selectors, so each contract has its own Interface. */
export const READS = Object.freeze({
  market: new ethers.Interface([
    `function listingOf(uint256 id) view returns (${LISTING})`, "function feeBps() view returns (uint256)", "function minFee() view returns (uint256)",
    "function lastSoldAt(uint256 id) view returns (uint64)", "function refused(address account) view returns (bool)", "function followsLine(uint256 root) view returns (bool)",
    "function recordHash(uint256 id) view returns (bytes32)", "function paused() view returns (bool)", "function pausedUntil() view returns (uint64)",
    "function registry() view returns (address)", "function usdg() view returns (address)", "function poolV2() view returns (address)", "function poolV1() view returns (address)",
    "function inviteBond() view returns (address)", "function inviteBondV2() view returns (address)", "function bidSpender() view returns (address)", "function previous() view returns (address)",
    `function bidOf(uint256 bidId) view returns (${BID})`, "function bidTook(uint256 bidId, uint256 id) view returns (bool)", "function nextBidId() view returns (uint256)",
    // the builder share, on a V2 that has it (the P5 spec, 2.2 and 2.3)
    "function MAX_BUILDER_BPS() view returns (uint256)", "function builderOf(uint256 id) view returns (tuple(address to, uint16 bps))",
    "function saleSplit(uint256 id) view returns (uint256 fee, uint256 share, uint256 net)", "function buildersOn() view returns (bool)",
  ]),
  spender: new ethers.Interface(["function market() view returns (address)"]),
  registry: new ethers.Interface(["function ownerOf(uint256 tokenId) view returns (address)", "function getApproved(uint256 tokenId) view returns (address)", "function tokenURI(uint256 tokenId) view returns (string)"]),
  poolV2: new ethers.Interface([`function getAgent(uint256 id) view returns (${AGENT_V2})`, "function custodian(address account) view returns (bool)", "function ownerDefaults(address account) view returns (uint256)"]),
  poolV1: new ethers.Interface([`function getAgent(uint256 id) view returns (${AGENT_V1})`]),
  bondV1: new ethers.Interface(["function bonds(uint256 id) view returns (tuple(address depositor, uint64 at, uint256 amount, uint256 qualifiedAt))"]),
  bondV2: new ethers.Interface(["function bonds(uint256 id) view returns (tuple(address depositor, uint64 at, uint256 amount))", "function amount() view returns (uint256)"]),
  usdg: new ethers.Interface(["function balanceOf(address account) view returns (uint256)", "function allowance(address owner, address spender) view returns (uint256)"]),
});

/** One read: { key, to, data, as: [contract, fn] }. A read on a zero address is never made (that contract isn't on
 *  this chain): its key stays absent from `c`. */
function adder(out) {
  return (key, to, as, fn, args = []) => { if (isAddr(to)) out.push({ key, to: lc(to), data: READS[as].encodeFunctionData(fn, args), as: [as, fn] }); };
}
/** aggregate3's call for `reads`, each allowed to fail: { to, data }. */
export const aggregateCall = (reads) => ({ to: MULTICALL3, data: MC3.encodeFunctionData("aggregate3", [reads.map((r) => [r.to, true, r.data])]) });
/** aggregate3's answer: [{ ok, data }], in the reads' order. */
export function aggregateOut(hex) {
  const [rs] = MC3.decodeFunctionResult("aggregate3", hex);
  return rs.map(([ok, data]) => ({ ok: ok === true, data: lc(data) }));
}
/** A decoded value as plans read it: addresses lower case, a struct as an object, bigints as they are. */
function plain(v) {
  if (typeof v === "string") return /^0x[0-9a-fA-F]{40}$/.test(v) ? lc(v) : v;
  if (v instanceof ethers.Result) {
    let o = null;
    try { o = v.toObject(); } catch (_) { o = null; } // an unnamed value: a list
    return o ? Object.fromEntries(Object.entries(o).map(([k, x]) => [k, plain(x)])) : [...v].map(plain);
  }
  return v;
}
/**
 * The answers by key, decoded (`results`: aggregateOut's, in the reads' order): each value, or null for a read that
 * failed or can't be decoded. `c.failed[key]` says how one failed: "empty" (no data back: the function isn't there, as
 * v1's bidSpender() or a V2 without the builder share reverts with none, or no contract is at the address, which
 * Multicall3 answers as a success with no data), "reverted" (with data) or "bad" (no such answer).
 * Keys "bid:<id>", "took:<id>" and "<what>:<maker>" go into the maps c.bids (bidOf's, its maker zero for a bid that
 * doesn't stand; null unread; absent: not asked), c.took and c.makers.
 */
export function readsOut(reads, results, into = null) {
  const c = into || { failed: {}, bids: new Map(), took: new Map(), makers: new Map() };
  (reads || []).forEach((r, i) => {
    const x = results && results[i];
    let v = null;
    if (x && x.ok && (x.data === "0x" || x.data === "")) c.failed[r.key] = "empty";
    else if (x && x.ok) {
      try {
        const out = READS[r.as[0]].decodeFunctionResult(r.as[1], x.data);
        v = out.length === 1 ? plain(out[0]) : plain(out);
      } catch (_) { v = null; c.failed[r.key] = "bad"; }
    } else c.failed[r.key] = x && !x.ok ? (x.data === "0x" || x.data === "" ? "empty" : "reverted") : "bad";
    const at = r.key.indexOf(":");
    if (at < 0) { c[r.key] = v; return; }
    const kind = r.key.slice(0, at), k = r.key.slice(at + 1);
    if (kind === "bid") c.bids.set(k, v);
    else if (kind === "took") c.took.set(k, v === null ? null : v === true);
    else { if (!c.makers.has(k)) c.makers.set(k, {}); c.makers.get(k)[kind] = v; }
  });
  return c;
}

/** Which market answers at `market`, and its own addresses: the spender's market() is read in the same call, at the
 *  address V2's spender would have (spenderOf). */
export function kindReads(market) {
  const out = [], add = adder(out), m = lc(market);
  for (const k of ["bidSpender", "feeBps", "previous", "registry", "usdg", "poolV2", "poolV1", "inviteBond", "inviteBondV2", "MAX_BUILDER_BPS"]) add(k, m, "market", k);
  add("spenderMarket", spenderOf(m), "spender", "market");
  return out;
}
/**
 * The market `c` (kindReads' answers) shows, against the package's `record` ({ registry, usdg }): { kind: "v1" | "v2",
 * addr: { market, registry, usdg, poolV2, poolV1, inviteBond, inviteBondV2, spender (V2's), previous (V2's v1, or
 * null) }, shares (V2 with the builder share) }, or { error }: "unread" (a read failed: try again), "mismatch" (its
 * registry or USDG isn't the record's), "unknown" (neither v1's nor V2's answers).
 */
export function marketKindOf(c, { market, record }) {
  const f = c.failed || {}, z = (a) => (isAddr(a) ? lc(a) : null);
  if (c.registry == null || c.usdg == null || c.poolV2 == null) return { error: f.registry === "empty" || f.usdg === "empty" ? "unknown" : "unread" };
  if (!same(c.registry, record && record.registry) || !same(c.usdg, record && record.usdg)) return { error: "mismatch" };
  const addr = { market: lc(market), registry: lc(c.registry), usdg: lc(c.usdg), poolV2: z(c.poolV2), poolV1: z(c.poolV1), inviteBond: z(c.inviteBond), inviteBondV2: z(c.inviteBondV2), spender: null, previous: null };
  if (c.bidSpender == null && f.bidSpender === "empty") {
    if (c.feeBps == null) return { error: "unread" };
    return { kind: "v1", addr, shares: false };
  }
  if (c.bidSpender == null) return { error: f.bidSpender === "reverted" ? "unknown" : "unread" };
  const spender = spenderOf(market);
  if (!same(c.bidSpender, spender) || !same(c.spenderMarket, market)) return { error: "unknown" };
  let shares = null;
  if (c.MAX_BUILDER_BPS != null) shares = true;
  else if (f.MAX_BUILDER_BPS === "empty") shares = false;
  if (shares === null) return { error: "unread" };
  return { kind: "v2", addr: { ...addr, spender, previous: z(c.previous) }, shares };
}

/** What a sale reads of agent `id` (round one): its listing on the market and on `previous`, owner, approval, token
 *  URI, the market's record pin, both pools' records, both bonds and the bond's amount, its last sale, and its builder
 *  share where the market has one, with the owner's switch for shares (buildersOn) at the same block. */
export function agentReads({ addr, id, shares = false }) {
  const a = addr || {}, i = big(id), out = [], add = adder(out);
  add("listing", a.market, "market", "listingOf", [i]);
  add("prevListing", a.previous, "market", "listingOf", [i]);
  add("owner", a.registry, "registry", "ownerOf", [i]);
  add("approved", a.registry, "registry", "getApproved", [i]);
  add("uri", a.registry, "registry", "tokenURI", [i]);
  add("record", a.market, "market", "recordHash", [i]);
  add("agent", a.poolV2, "poolV2", "getAgent", [i]);
  add("agentV1", a.poolV1, "poolV1", "getAgent", [i]);
  add("bondV1", a.inviteBond, "bondV1", "bonds", [i]);
  add("bondV2", a.inviteBondV2, "bondV2", "bonds", [i]);
  add("bondAmount", a.inviteBondV2, "bondV2", "amount");
  add("soldAt", a.market, "market", "lastSoldAt", [i]);
  if (shares) { add("builder", a.market, "market", "builderOf", [i]); add("saleSplit", a.market, "market", "saleSplit", [i]); add("buildersOn", a.market, "market", "buildersOn"); }
  return out;
}
/** The wallet's own (`me`): its standing (the pool's custodian and marks, the market's refusal), the pause and the
 *  fee, its USDG and what it approved to the market, to InviteBondV2 and (V2) to the bids' spender; `self`, the agent
 *  the server acts for, adds that agent's pool record (its open loans). */
export function accountReads({ addr, me, self = null }) {
  const a = addr || {}, out = [], add = adder(out), w = lc(me);
  add("paused", a.market, "market", "paused");
  add("pausedUntil", a.market, "market", "pausedUntil");
  add("feeBps", a.market, "market", "feeBps");
  add("minFee", a.market, "market", "minFee");
  if (!isAddr(w)) return out;
  add("custodian", a.poolV2, "poolV2", "custodian", [w]);
  add("marked", a.poolV2, "poolV2", "ownerDefaults", [w]);
  add("refused", a.market, "market", "refused", [w]);
  add("cash", a.usdg, "usdg", "balanceOf", [w]);
  add("allowance", a.usdg, "usdg", "allowance", [w, a.market]);
  if (isAddr(a.inviteBondV2)) add("bondAllowance", a.usdg, "usdg", "allowance", [w, a.inviteBondV2]);
  if (isAddr(a.spender)) add("reserve", a.usdg, "usdg", "allowance", [w, a.spender]);
  if (self != null) add("selfAgent", a.poolV2, "poolV2", "getAgent", [big(self)]);
  return out;
}
/** Bids by id (bidOf), each read on chain whatever an index said of it. */
export function bidReads({ addr, bidIds = [] }) {
  const a = addr || {}, out = [], add = adder(out);
  for (const b of [...new Set(bidIds.map(String))]) add("bid:" + b, a.market, "market", "bidOf", [big(b)]);
  return out;
}
/**
 * Round two, at the same block, from round one's `c`: whether the market lets the agent's sponsor's line go with it;
 * the listing's seller's standing (a buy's checks of the seller); for agent `id`, each bid on an origin's take of it
 * (bidTook); and each maker's USDG, its reserve to the spender and its standing.
 */
export function moreReads(c, { addr, id = null }) {
  const a = addr || {}, out = [], add = adder(out), s = c && c.agent ? big(c.agent.sponsor) : 0n;
  if (s !== 0n) add("followed", a.market, "market", "followsLine", [s]);
  const l = c && c.listing;
  if (l && isAddr(l.seller)) {
    add("sellerCustodian", a.poolV2, "poolV2", "custodian", [l.seller]);
    add("sellerMarked", a.poolV2, "poolV2", "ownerDefaults", [l.seller]);
    add("sellerRefused", a.market, "market", "refused", [l.seller]);
  }
  const makers = new Set();
  for (const [k, b] of (c && c.bids) || new Map()) {
    if (!b || !isAddr(b.maker)) continue;
    makers.add(lc(b.maker));
    if (b.any && id != null) add("took:" + k, a.market, "market", "bidTook", [big(k), big(id)]);
  }
  for (const m of makers) {
    add("cash:" + m, a.usdg, "usdg", "balanceOf", [m]);
    if (isAddr(a.spender)) add("reserve:" + m, a.usdg, "usdg", "allowance", [m, a.spender]);
    add("refused:" + m, a.market, "market", "refused", [m]);
    add("custodian:" + m, a.poolV2, "poolV2", "custodian", [m]);
    add("marked:" + m, a.poolV2, "poolV2", "ownerDefaults", [m]);
  }
  return out;
}

/* ---- what a sale pays ---- */

/**
 * The fee on `price` and what the seller gets, after the builder's share (the P5 spec, 2.5): fee as the market's
 * (market-abi feeOf, with its feeBps and minFee), the share `builder.bps` of the price rounded down, never more than
 * what the fee leaves, none when no share is set (`builder` null or its `to` zero, as on v1 and on a V2 without
 * shares) or when the seller is the builder. { fee, share, net }.
 */
export function netOf(price, { feeBps = LISTING_RULES.feeBps, minFee = LISTING_RULES.minFee, builder = null, seller = null } = {}) {
  const p = big(price), { fee } = feeOf(p, { feeBps, minFee });
  let share = 0n;
  if (builder && isAddr(builder.to) && !same(builder.to, seller)) {
    share = (p * big(builder.bps)) / 10_000n;
    if (share > p - fee) share = p - fee;
  }
  return { fee, share, net: p - fee - share };
}
/** The fee settings a plan reads (the market's, read at the block). */
const feesOf = (c) => ({ feeBps: c.feeBps, minFee: c.minFee });

/* ---- the plans ---- */

const unread = (...v) => v.some((x) => x == null);
/** An unexpired listing (listingOf) of `who` at `now`, or null. */
function ownListing(l, who, now) {
  return l && same(l.seller, who) && Number(l.expiry) > Number(now) ? { seller: lc(l.seller), price: big(l.price), expiry: Number(l.expiry), nonce: big(l.nonce) } : null;
}
/** A listing's end: `now` plus `days` (1 to 30), or null. A plan's `expiry` given (the first plan's) wins: each later
 *  plan of the same call keeps it. */
function expiryOf({ days, expiry, now }) {
  if (expiry != null) return Number(expiry);
  if (!Number.isSafeInteger(days) || days < 1 || days > 30) return null;
  return Math.min(Number(now) + days * DAY, Number(now) + 30 * DAY - 300);
}
const holdUntil = (c) => { const s = Number(c.soldAt); return s === 0 ? 0 : s + LISTING_RULES.holdS; };
/** The registry's ownerOf reverted with data: no such agent (ERC721NonexistentToken), not a read that failed. */
const noAgent = (c) => c.owner == null && c.failed && c.failed.owner === "reverted";

/**
 * The sale's checks with `me` as the seller, in the contract's order (web/board-wallet-core.js sellState): { error }
 * ("unread", "notOwner", "account", "marked", "root", "loan", "defaulted", "line", "shortBond" with `bond`, `short` and
 * `cash`, "firstBond", "hold" with `until`, "paused" with `until`), or { bond (InviteBondV2's amount when the line lends
 * and has no V2 bond; else 0), bondApprove }.
 */
function saleChecks(c, { me, now }) {
  const t = Number(now);
  if (noAgent(c)) return { error: "notOwner", owner: null };
  if (unread(c.owner, c.listing, c.approved)) return { error: "unread" };
  if (!same(c.owner, me)) return { error: "notOwner", owner: isAddr(c.owner) ? lc(c.owner) : null };
  if (unread(c.custodian, c.refused, c.marked)) return { error: "unread" };
  if (c.custodian === true || c.refused === true) return { error: "account" };
  if (big(c.marked) !== 0n) return { error: "marked" };
  const a = c.agent;
  if (a == null) return { error: "unread" };
  if (a.isRoot) return { error: "root" };
  if (big(a.activeLoans) !== 0n) return { error: "loan" };
  if (a.defaulted) return { error: "defaulted" };
  const sponsor = big(a.sponsor), lent = big(a.delegatedIn);
  let bond = 0n, bondApprove = false;
  if (sponsor !== 0n || lent !== 0n) {
    if (sponsor !== 0n && c.followed == null) return { error: "unread" };
    if (sponsor === 0n || c.followed !== true) return { error: "line" };
    if (lent !== 0n) {
      if (c.bondV2 == null) return { error: "unread" };
      if (!isAddr(c.bondV2.depositor)) {
        if (unread(c.bondAmount, c.cash)) return { error: "unread" };
        bond = big(c.bondAmount);
        bondApprove = c.bondAllowance == null || big(c.bondAllowance) < bond;
        if (big(c.cash) < bond) return { error: "shortBond", bond, short: bond - big(c.cash), cash: big(c.cash) };
      }
    }
  }
  if (c.agentV1 !== undefined) {
    const o = c.agentV1;
    if (o == null) return { error: "unread" };
    if (o.isRoot) return { error: "root" };
    if (big(o.activeLoans) !== 0n) return { error: "loan" };
    if (o.defaulted) return { error: "defaulted" };
  }
  if (c.bondV1 !== undefined) {
    if (c.bondV1 == null) return { error: "unread" };
    if (isAddr(c.bondV1.depositor)) return { error: "firstBond" };
  }
  if (c.soldAt == null) return { error: "unread" };
  const until = holdUntil(c);
  if (until !== 0 && t < until) return { error: "hold", until };
  if (c.paused == null) return { error: "unread" };
  if (c.paused === true) return { error: "paused", until: c.pausedUntil == null ? null : Number(c.pausedUntil) };
  return { bond, bondApprove };
}
/** The builder share `c` read (null: none, or a market without shares), checked: a share the market answers with an
 *  address and at most 5% (MAX_BUILDER_BPS), else unread. While the owner's switch reads off (buildersOn false) no share
 *  can be set, so none is reported, whatever builderOf says; a V2 without the switch (buildersOn answers no data), or
 *  a switch read that failed, leaves it to builderOf. */
function builderIn(c, shares) {
  if (!shares || c.buildersOn === false) return { builder: null };
  if (c.builder == null) return { error: "unread" };
  const b = c.builder;
  if (!isAddr(b.to)) return { builder: null };
  if (big(b.bps) > 500n) return { error: "unread" };
  return { builder: { to: lc(b.to), bps: big(b.bps) } };
}

/**
 * Listing agent `id` from `me` (sellState with the terms): `price` (USDG units, 5 USDG or more), `days` (1 to 30) or
 * the first plan's `expiry`. { error } ("price", "days", then saleChecks'), or { steps, price, expiry, bond, fee, share,
 * net, mine (its own listing standing before), pins }. Steps, each one transaction, in order: "cancelOldPrev" (V2:
 * this wallet's own v1 listing of the agent, which an approval back to v1 would bring back), "cancelOld" (its own
 * listing here while the market isn't approved: approving brings it back at its old price), "bondApprove" and "bond"
 * (InviteBondV2's deposit, when the treasury line lends with no V2 bond), "approve" (the registry's, for this agent
 * only), "list".
 */
export function sellPlan(c, { addr, me, now, price, days, expiry = null, shares = false }) {
  c = c || {};
  const p = typeof price === "bigint" ? price : null;
  if (p == null || p < LISTING_RULES.minPrice) return { error: "price" };
  const e = expiryOf({ days, expiry, now });
  if (e == null || e <= Number(now) || e > Number(now) + 30 * DAY) return { error: "days" };
  const s = saleChecks(c, { me, now });
  if (s.error) return s;
  const bi = builderIn(c, shares);
  if (bi.error) return bi;
  if (unread(c.feeBps, c.minFee)) return { error: "unread" };
  const approved = same(c.approved, addr.market), mine = ownListing(c.listing, me, now);
  let prevMine = null;
  if (addr.previous) { if (c.prevListing == null) return { error: "unread" }; prevMine = ownListing(c.prevListing, me, now); }
  const steps = [...(prevMine ? ["cancelOldPrev"] : []), ...(mine && !approved ? ["cancelOld"] : []), ...(s.bond > 0n && s.bondApprove ? ["bondApprove"] : []),
    ...(s.bond > 0n ? ["bond"] : []), ...(approved ? [] : ["approve"]), "list"];
  const { fee, share, net } = netOf(p, { ...feesOf(c), builder: bi.builder, seller: me });
  return { steps, price: p, expiry: e, bond: s.bond, fee, share, net, mine, pins: { price: p, expiry: e } };
}

/** The listing of `c` a buyer could take at `now` by its own terms (its seller holds the agent, the market is approved
 *  for it, it hasn't ended): { seller, price, expiry, nonce }, or null. */
function liveListing(c, { addr, now }) {
  const l = c.listing;
  return l && isAddr(l.seller) && Number(l.expiry) > Number(now) && same(l.seller, c.owner) && same(c.approved, addr.market) ? { seller: lc(l.seller), price: big(l.price), expiry: Number(l.expiry), nonce: big(l.nonce) } : null;
}
/**
 * What stops any buyer from taking that listing, past the buyer's own checks, in the contract's order (the seller's
 * _checkAccount, then _checkSale and buy's pins): { error } ("unread", "sellerBlocked", "defaulted", "loan", "root",
 * "line", "firstBond", "hold" with `until`, "stale": the agent's file or its repaid loans changed after it was listed,
 * so no buy of that listing goes through until its seller lists again), or { follows, lent, uriHash } when nothing does.
 */
function takeChecks(c, { now }) {
  const a = c.agent, o = c.agentV1;
  if (unread(c.sellerCustodian, c.sellerRefused, c.sellerMarked)) return { error: "unread" };
  if (c.sellerCustodian === true || c.sellerRefused === true || big(c.sellerMarked) !== 0n) return { error: "sellerBlocked" };
  if (a == null || o === null) return { error: "unread" };
  if (a.defaulted || (o && o.defaulted)) return { error: "defaulted" };
  if (big(a.activeLoans) !== 0n || (o && big(o.activeLoans) !== 0n)) return { error: "loan" };
  if (a.isRoot || (o && o.isRoot)) return { error: "root" };
  const sponsor = big(a.sponsor), lent = big(a.delegatedIn);
  if (sponsor !== 0n && c.followed == null) return { error: "unread" };
  const follows = sponsor !== 0n && c.followed === true;
  if (sponsor !== 0n || lent !== 0n) {
    if (!follows) return { error: "line" };
    if (lent !== 0n && c.bondV2 == null) return { error: "unread" };
    if (lent !== 0n && !isAddr(c.bondV2.depositor)) return { error: "line" };
  }
  if (c.bondV1 === null || c.soldAt == null) return { error: "unread" };
  if (c.bondV1 && isAddr(c.bondV1.depositor)) return { error: "firstBond" };
  const until = holdUntil(c);
  if (until !== 0 && Number(now) < until) return { error: "hold", until };
  if (unread(c.uri, c.record) || !HEX32.test(String(c.record))) return { error: "unread" };
  const uriHash = lc(ethers.keccak256(ethers.toUtf8Bytes(c.uri)));
  if (uriHash !== lc(c.listing.uriHash) || big(a.loansRepaid) !== big(c.listing.loansRepaid)) return { error: "stale" };
  return { follows, lent, uriHash };
}
/**
 * Whether any buyer can take agent `id`'s listing on the market now (round one and two's reads of `c`): null when one
 * can, else why not: { error } "unread", "gone" (none stands that a buyer can take: none, ended, its seller no longer
 * holds the agent, or the market isn't approved for it), "paused" (`until`), or takeChecks'. market_agent's "For sale"
 * and a bid's "listed" read it, so neither sends the model to a buy that buyPlan refuses.
 */
export function listingBlock(c, { addr, now }) {
  c = c || {};
  if (noAgent(c)) return { error: "gone" };
  if (unread(c.listing, c.owner, c.approved)) return { error: "unread" };
  if (!liveListing(c, { addr, now })) return { error: "gone" };
  if (c.paused == null) return { error: "unread" };
  if (c.paused === true) return { error: "paused", until: c.pausedUntil == null ? null : Number(c.pausedUntil) };
  const k = takeChecks(c, { now });
  return k.error ? k : null;
}

/**
 * Buying agent `id` from `me` at `maxPrice` at most (web/board-wallet-core.js buyPlan, a price cap in place of the
 * listing first shown; `seen`, a later plan's: the first plan's { price, nonce }). { error } ("unread", "gone",
 * "relisted" with `price` (a nonce or price other than `seen`'s), "changed" with `price` (above `maxPrice`), "self",
 * "paused", "account", "marked", takeChecks' kinds, "record" with `n` and `m` (fewer repaid loans than `minRecord`),
 * "short" with `short` and `cash`), or { steps ("approveUsdg": exactly the price, while the USDG approved to the market
 * is short of it; "buy"), listing, follows (the treasury line comes with it), line, bond (what the buyer locks before it
 * borrows on it), fee, share, net (the seller's), pins: { price, nonce, uriHash (the token URI's bytes hashed here),
 * recordHash (the market's own, at the same block) } }.
 */
export function buyPlan(c, { addr, me, now, maxPrice, seen = null, minRecord = 0n, shares = false }) {
  c = c || {};
  if (noAgent(c)) return { error: "gone" };
  if (unread(c.listing, c.owner, c.approved)) return { error: "unread" };
  const listing = liveListing(c, { addr, now });
  if (!listing) return { error: "gone" };
  if (seen && (big(seen.nonce) !== listing.nonce || big(seen.price) !== listing.price)) return { error: "relisted", price: listing.price };
  if (listing.price > big(maxPrice)) return { error: "changed", price: listing.price };
  if (same(listing.seller, me)) return { error: "self" };
  if (c.paused == null) return { error: "unread" };
  if (c.paused === true) return { error: "paused", until: c.pausedUntil == null ? null : Number(c.pausedUntil) };
  if (unread(c.custodian, c.refused, c.marked)) return { error: "unread" };
  if (c.custodian === true || c.refused === true) return { error: "account" };
  if (big(c.marked) !== 0n) return { error: "marked" };
  const k = takeChecks(c, { now });
  if (k.error) return k;
  const a = c.agent, { follows, lent, uriHash } = k;
  if (big(a.loansRepaid) < big(minRecord)) return { error: "record", n: big(minRecord), m: big(a.loansRepaid) };
  const wants = follows && lent > 0n && !same(c.bondV2 && c.bondV2.depositor, me);
  if (wants && c.bondAmount == null) return { error: "unread" };
  if (unread(c.cash, c.allowance, c.feeBps, c.minFee)) return { error: "unread" };
  if (big(c.cash) < listing.price) return { error: "short", short: listing.price - big(c.cash), cash: big(c.cash) };
  const bi = builderIn(c, shares);
  if (bi.error) return bi;
  // what the seller gets: the market's own split when it answers one (the lower fee and share of list and now), else
  // the fee and the share now
  const split = shares && c.saleSplit ? { fee: big(c.saleSplit.fee), share: big(c.saleSplit.share), net: big(c.saleSplit.net) } : netOf(listing.price, { ...feesOf(c), builder: bi.builder, seller: listing.seller });
  return {
    steps: [...(big(c.allowance) < listing.price ? ["approveUsdg"] : []), "buy"], listing, follows, line: follows ? lent : 0n, bond: wants ? big(c.bondAmount) : 0n,
    fee: split.fee, share: split.share, net: split.net,
    pins: { price: listing.price, nonce: listing.nonce, uriHash, recordHash: lc(c.record) },
  };
}

/**
 * Cancelling the listings of agent `id` that `me` may cancel: its own on the market and on `previous` (V2's v1), and a
 * former owner's of an agent `me` now holds (`cancel` allows it once the owner changed, src/AgentMarket.sol:223).
 * { error: "unread" | "noListing" }, or { steps ("cancel", "cancelPrev"), listing, prevListing }. Never paused.
 */
export function cancelPlan(c, { addr, me }) {
  c = c || {};
  if (unread(c.listing, c.owner) || (addr.previous && c.prevListing == null)) return { error: "unread" };
  const may = (l) => l && isAddr(l.seller) && (same(l.seller, me) || (same(c.owner, me) && !same(l.seller, me)));
  const here = may(c.listing), there = addr.previous ? may(c.prevListing) : false;
  if (!here && !there) return { error: "noListing" };
  return { steps: [...(here ? ["cancel"] : []), ...(there ? ["cancelPrev"] : [])], listing: here ? c.listing : null, prevListing: there ? c.prevListing : null };
}

/** The reserve all of `me`'s open bids take together: price × left over `ids` (bidOf's in c.bids) that `me` made and
 *  that stand at `now`, but `except`, plus `extra`. null while one is unread. */
function reserveOf(c, { ids, me, now, except = [], extra = 0n }) {
  let sum = big(extra);
  for (const k of new Set(ids.map(String))) {
    if (except.includes(k)) continue;
    const b = c.bids.get(k);
    if (b === undefined) continue; // not asked
    if (b === null) return null; // asked, and the read failed
    if (same(b.maker, me) && Number(b.expiry) > Number(now)) sum += big(b.price) * big(b.left);
  }
  return sum;
}
/** The terms both bids check first, in the contract's order: the pause, the wallet's standing, the price, the days. */
function bidTerms(c, { me, now, price, days, expiry }) {
  if (unread(c.paused, c.custodian, c.refused, c.marked, c.cash, c.reserve, c.feeBps, c.minFee)) return { error: "unread" };
  if (c.paused === true) return { error: "paused", until: c.pausedUntil == null ? null : Number(c.pausedUntil) };
  if (c.custodian === true || c.refused === true) return { error: "account" };
  if (big(c.marked) !== 0n) return { error: "marked" };
  const p = typeof price === "bigint" ? price : null;
  if (p == null || p < BID_RULES.minPrice || p >= 2n ** 96n) return { error: "low" };
  const e = expiryOf({ days, expiry, now });
  if (e == null || e <= Number(now) || e > Number(now) + 30 * DAY) return { error: "days" };
  return { p, e, me };
}
/**
 * A bid on agent `id` from `me` (web/board-wallet-bids-core.js walletBidPlan, with this server's limits). `myBids`:
 * this wallet's bid ids (its record's and the index's), each read by bidOf in `c.bids`. { error } ("unread", "paused",
 * "account", "marked", "low", "days", "selfBid", "cantSell", "adapter", "record" (`n`, `m`), "listed" (`price`: a
 * listing at or below the bid that a buyer can take now, by buyPlan's rules: one held by a loan, a hold or a seller the
 * market stops doesn't count, as bid() takes the bid then), "short" (`short`, `cash`), "over" (`reserve`, `max`)), or
 * { steps ("approveReserve": the reserve set to exactly what all its open bids and this one take, when the allowance
 * is under it or above `maxReserve`; "bid"), reserve, price, expiry, uriHash (only as its file is now: the URI's bytes
 * hashed here, with `sameFile`), minRepaid, minLine, fee, share, net (what the owner gets now), pins }.
 */
export function bidPlan(c, { addr, me, id, now, price, days, expiry = null, sameFile = true, minRepaid = 0n, minLine = 0n, myBids = [], maxReserve, minRecord = 0n, adapters = [], shares = false }) {
  c = c || {};
  const t = bidTerms(c, { me, now, price, days, expiry });
  if (t.error) return t;
  const a = c.agent, o = c.agentV1;
  if (noAgent(c)) return { error: "cantSell" };
  if (c.owner == null || a == null || o === null || c.listing == null || c.approved == null || (sameFile && c.uri == null)) return { error: "unread" };
  if (!isAddr(c.owner)) return { error: "cantSell" };
  if (same(c.owner, me)) return { error: "selfBid" };
  if (adapters.some((x) => same(x, c.owner))) return { error: "adapter" };
  if (a.isRoot || a.defaulted || (o && (o.isRoot || o.defaulted))) return { error: "cantSell" };
  if (big(a.loansRepaid) < big(minRecord)) return { error: "record", n: big(minRecord), m: big(a.loansRepaid) };
  const l = liveListing(c, { addr, now });
  if (l && l.price <= t.p) {
    const k = takeChecks(c, { now });
    if (k.error === "unread") return k;
    if (!k.error) return { error: "listed", price: l.price };
  }
  if (big(c.cash) < t.p) return { error: "short", short: t.p - big(c.cash), cash: big(c.cash) };
  const reserve = reserveOf(c, { ids: myBids, me, now, extra: t.p });
  if (reserve == null) return { error: "unread" };
  if (reserve > big(maxReserve)) return { error: "over", reserve, max: big(maxReserve) };
  const bi = builderIn(c, shares);
  if (bi.error) return bi;
  const { fee, share, net } = netOf(t.p, { ...feesOf(c), builder: bi.builder, seller: c.owner });
  const uriHash = sameFile ? lc(ethers.keccak256(ethers.toUtf8Bytes(c.uri))) : ZERO32;
  const r = big(c.reserve), mr = big(minRepaid), ml = big(minLine);
  return { steps: [...(r < reserve || r > big(maxReserve) ? ["approveReserve"] : []), "bid"], reserve, price: t.p, expiry: t.e, uriHash, minRepaid: mr, minLine: ml, fee, share, net,
    pins: { id: big(id), price: t.p, expiry: t.e, uriHash, minRepaid: mr, minLine: ml } };
}
/**
 * A bid on up to `count` agents of an origin's list (`set`: /api/hub/origin-set's { root, ids }), `price` each: "badSet"
 * first (its ids don't make its root: the index's answer is refused), "count" (1 to 20, at most the list's size: `max`),
 * then bidPlan's terms, "short" (price × count), "over"; else { steps ("approveReserve", "bidAny"), reserve, price,
 * total, count, root, expiry, minRepaid, minLine, fee, net (what an owner gets now; no share is known before an agent
 * is), pins }.
 */
export function bidAnyPlan(c, { me, now, set, count, price, days, expiry = null, minRepaid = 0n, minLine = 0n, myBids = [], maxReserve }) {
  c = c || {};
  let root;
  try { root = set && Array.isArray(set.ids) && set.ids.length ? idsRootOf(set.ids) : null; } catch (_) { root = null; }
  if (!root || !HEX32.test(String(set.root)) || lc(set.root) !== root) return { error: "badSet" };
  const max = Math.min(BID_RULES.maxCount, listOf(set.ids).length);
  if (!Number.isSafeInteger(count) || count < 1 || count > max) return { error: "count", max };
  const t = bidTerms(c, { me, now, price, days, expiry });
  if (t.error) return t;
  const total = t.p * BigInt(count);
  if (big(c.cash) < total) return { error: "short", short: total - big(c.cash), cash: big(c.cash) };
  const reserve = reserveOf(c, { ids: myBids, me, now, extra: total });
  if (reserve == null) return { error: "unread" };
  if (reserve > big(maxReserve)) return { error: "over", reserve, max: big(maxReserve) };
  const { fee, net } = netOf(t.p, feesOf(c));
  const r = big(c.reserve), mr = big(minRepaid), ml = big(minLine);
  return { steps: [...(r < reserve || r > big(maxReserve) ? ["approveReserve"] : []), "bidAny"], reserve, price: t.p, total, count, root, expiry: t.e, minRepaid: mr, minLine: ml, fee, net,
    pins: { root, count, price: t.p, expiry: t.e, minRepaid: mr, minLine: ml } };
}
/**
 * Cancelling `bidIds` (at most 10) of `me`'s: { error } ("tooMany", "unread", "bidGone" with `bidId`: closed or never
 * made, "notMaker" with `bidId`), or { steps ("cancelBid:<id>" each, then "approveReserve" down to `reserveAfter` when
 * the allowance stands above it), reserveAfter (what its open bids in `myBids` still take) }. Never paused.
 */
export function cancelBidPlan(c, { me, now, bidIds, myBids = [] }) {
  c = c || {};
  const ids = [...new Set(bidIds.map(String))];
  if (ids.length > 10) return { error: "tooMany" };
  if (!ids.length) return { error: "bidGone", bidId: null };
  for (const k of ids) {
    const b = c.bids.get(k);
    if (b == null) return { error: "unread" };
    if (!isAddr(b.maker)) return { error: "bidGone", bidId: k };
    if (!same(b.maker, me)) return { error: "notMaker", bidId: k };
  }
  if (c.reserve == null) return { error: "unread" };
  const reserveAfter = reserveOf(c, { ids: [...myBids, ...ids], me, now, except: ids });
  if (reserveAfter == null) return { error: "unread" };
  return { steps: [...ids.map((k) => `cancelBid:${k}`), ...(big(c.reserve) > reserveAfter ? ["approveReserve"] : [])], reserveAfter, reserve: reserveAfter, pins: { bidIds: ids } };
}
/**
 * Accepting bid `bidId` for agent `id` held by `me` (web/board-wallet-bids-core.js walletAcceptPlan): the bid, its
 * target or list (`proof`, checked with inRoot, never trusted), the maker as a buyer, the sale's rules with `me` as the
 * seller, the maker's pins, the net. { error } ("unread", "gone", "notInBid", "taken", "selfAccept", "maker",
 * "unfunded", "paused", saleChecks' kinds, "repaid" (`n`, `m`), "lineBelow" (`line`), "card", "noNet" (`price`, `fee`:
 * the fee takes the whole price, which the contract allows only when the bid is at the minimum fee)), or { steps
 * ("cancelOldPrev", "cancelOld", "bondApprove", "bond", "approve", "accept", in acceptCalls' order), price, maker,
 * proof, fee, share, net (minNet: exact at the read block; a fee changes only after the market's 48 h, and a share only
 * lower), bond, pins }.
 */
export function acceptPlan(c, { addr, me, now, bidId, id, proof = [], shares = false }) {
  c = c || {};
  const key = String(bidId), b = c.bids.get(key);
  if (b == null) return { error: "unread" };
  if (!isAddr(b.maker) || Number(b.expiry) <= Number(now)) return { error: "gone" };
  if (!b.any ? lc(b.target) !== lc(idWord(id)) : !inRoot(b.target, String(id), proof)) return { error: "notInBid" };
  if (b.any) { const tk = c.took.get(key); if (tk == null) return { error: "unread" }; if (tk) return { error: "taken" }; }
  if (same(b.maker, me)) return { error: "selfAccept" };
  const mk = c.makers.get(lc(b.maker));
  if (!mk || unread(mk.refused, mk.custodian, mk.marked, mk.cash, mk.reserve)) return { error: "unread" };
  if (mk.refused === true || mk.custodian === true || big(mk.marked) !== 0n) return { error: "maker" };
  if (big(mk.cash) < big(b.price) || big(mk.reserve) < big(b.price)) return { error: "unfunded" };
  const s = saleChecks(c, { me, now });
  if (s.error) return s;
  const a = c.agent;
  if (c.uri == null || unread(c.feeBps, c.minFee)) return { error: "unread" };
  if (big(a.loansRepaid) < big(b.minRepaid)) return { error: "repaid", n: big(b.minRepaid), m: big(a.loansRepaid) };
  if (big(b.minLine) !== 0n && big(a.delegatedIn) < big(b.minLine)) return { error: "lineBelow", line: big(b.minLine) };
  if (BigInt(b.uriHash) !== 0n && lc(ethers.keccak256(ethers.toUtf8Bytes(c.uri))) !== lc(b.uriHash)) return { error: "card" };
  const bi = builderIn(c, shares);
  if (bi.error) return bi;
  const { fee, share, net } = netOf(big(b.price), { ...feesOf(c), builder: bi.builder, seller: me });
  if (net < 1n) return { error: "noNet", price: big(b.price), fee };
  const approved = same(c.approved, addr.market), mine = ownListing(c.listing, me, now);
  let prevMine = null;
  if (addr.previous) { if (c.prevListing == null) return { error: "unread" }; prevMine = ownListing(c.prevListing, me, now); }
  const steps = [...(prevMine ? ["cancelOldPrev"] : []), ...(mine && !approved ? ["cancelOld"] : []), ...(s.bond > 0n && s.bondApprove ? ["bondApprove"] : []),
    ...(s.bond > 0n ? ["bond"] : []), ...(approved ? [] : ["approve"]), "accept"];
  const pr = b.any ? proof.map(lc) : [];
  return { steps, price: big(b.price), maker: lc(b.maker), any: b.any === true, proof: pr, fee, share, net, bond: s.bond,
    pins: { bidId: key, id: big(id), price: big(b.price), maker: lc(b.maker), minNet: net } };
}

/* ---- the calls ---- */

const ERC20 = new ethers.Interface(["function approve(address spender, uint256 amount) returns (bool)"]);
const REGISTRY = new ethers.Interface(["function approve(address to, uint256 tokenId)"]);
const BOND_V2 = new ethers.Interface(["function deposit(uint256 agentId)"]);
const to_ = (a) => ethers.getAddress(a).toLowerCase();
/**
 * One step's transaction: { to, data }. `o`: { addr (marketKindOf's), id, now (the block's time, for the bids' terms),
 * and the plan's own: price, expiry, bond, pins, reserve, proof, net, root, count, uriHash, minRepaid, minLine }.
 */
export function stepCalls(step, o) {
  const a = o.addr, id = o.id == null ? null : big(o.id);
  const market = (fn, args) => ({ to: to_(a.market), data: MARKET_IFACE.encodeFunctionData(fn, args) });
  if (step === "cancelOld" || step === "cancel") return market("cancel", [id]);
  if (step === "cancelOldPrev" || step === "cancelPrev") return { to: to_(a.previous), data: MARKET_IFACE.encodeFunctionData("cancel", [id]) };
  if (step === "bondApprove") return { to: to_(a.usdg), data: ERC20.encodeFunctionData("approve", [to_(a.inviteBondV2), big(o.bond)]) };
  if (step === "bond") return { to: to_(a.inviteBondV2), data: BOND_V2.encodeFunctionData("deposit", [id]) };
  if (step === "approve") return { to: to_(a.registry), data: REGISTRY.encodeFunctionData("approve", [to_(a.market), id]) };
  if (step === "list") return market("list", [id, big(o.price), BigInt(o.expiry)]);
  if (step === "approveUsdg") return { to: to_(a.usdg), data: ERC20.encodeFunctionData("approve", [to_(a.market), big(o.pins.price)]) };
  if (step === "buy") return market("buy", [id, big(o.pins.price), big(o.pins.nonce), o.pins.uriHash, o.pins.recordHash]);
  if (step === "approveReserve") return reserveCall({ market: a.market, amount: big(o.reserve), usdg: a.usdg });
  if (step === "bid") return bidCall({ market: a.market, id, price: o.price, expiry: o.expiry, now: o.now, uriHash: o.uriHash, minRepaid: o.minRepaid, minLine: o.minLine });
  if (step === "bidAny") return bidAnyCall({ market: a.market, root: o.root, count: o.count, price: o.price, expiry: o.expiry, now: o.now, minRepaid: o.minRepaid, minLine: o.minLine });
  if (step.startsWith("cancelBid:")) return cancelBidCall({ market: a.market, bidId: step.slice("cancelBid:".length) });
  if (step === "accept") return acceptCall({ market: a.market, bidId: o.pins.bidId, id, proof: o.proof || [], minNet: o.pins.minNet });
  throw new Error(`no such step: ${step}`);
}
/** What a step's receipt must hold from the market: the event, by name, the final step of each tool ends with. */
export const STEP_EVENTS = Object.freeze({ list: "Listed", cancel: "Cancelled", cancelPrev: "Cancelled", buy: "Sold", bid: "BidMade", bidAny: "BidAnyMade", accept: "BidTaken" });

/* ---- the errors ---- */

/**
 * Every error a step can revert with, by signature, and its kind: AgentMarket's and AgentMarketV2's (src/AgentMarket.sol
 * 123-151, src/AgentMarketV2.sol 151-190, the builder share's of the P5 spec 2.8), the pause's (src/GuardianPause.sol
 * 27-32), BidSpender's (src/BidSpender.sol 22), USDG's two as deployed, the registry's approve from a wallet that doesn't
 * hold the agent, and InviteBondV2's deposit's. The board's ERR set (web/board-wallet-core.js) and the bids' (web/
 * board-wallet-bids-core.js), one table. "failed": nothing a plan checks; the step's own words.
 */
export const MARKET_ERRORS = Object.freeze({
  "NotOwner(uint256,address)": "notOwner", "NotApproved(uint256)": "notApproved", "IsRoot(uint256,address)": "root", "Custodian(address)": "account",
  "Refused(address)": "account", "Marked(address)": "marked", "LoanOpen(uint256,address)": "loan", "AgentDefaulted(uint256,address)": "defaulted",
  "HasLine(uint256)": "line", "Bonded(uint256,address)": "firstBond", "Unbonded(uint256)": "line", "BadRoot(uint256)": "failed",
  "OnHold(uint256,uint256)": "hold", "PriceTooLow(uint256)": "price", "BadExpiry(uint64)": "days", "NoListing(uint256)": "noListing",
  "ListingExpired(uint256,uint64)": "gone", "PriceAbove(uint256,uint256)": "changed", "SelfBuy()": "self", "NonceChanged(uint256,uint256)": "relisted",
  "UriChanged(uint256)": "stale", "LoansChanged(uint256)": "stale", "RecordChanged(uint256)": "recordMoved", "NotTransferred(uint256)": "failed",
  "CannotCancel(uint256,address)": "cannotCancel", "BadFee(uint256,uint256)": "failed", "BadFeeTo(address)": "failed", "NoPendingFee()": "failed",
  "FeeNotReady(uint64)": "failed",
  // V2's bids
  "NoBid(uint256)": "gone", "BidExpired(uint256,uint64)": "gone", "BadBid()": "failed", "NotMaker(uint256,address)": "notMaker", "NotFunded(uint256)": "short",
  "NotInBid(uint256,uint256)": "notInBid", "AlreadyTaken(uint256,uint256)": "taken", "RecordBelow(uint256,uint256)": "repaid", "LineBelow(uint256,uint256)": "lineBelow",
  "NetBelow(uint256,uint256)": "fee",
  // the builder share (the P5 spec, 2.8), once V2 has it: a seller or a buyer never sets one here (BuildersOff: setBuilder
  // before the owner turned shares on)
  "NotBuilder(uint256,address)": "failed", "BuilderTaken(uint256)": "failed", "AlreadySold(uint256)": "failed", "BadShare(uint256)": "failed", "BadBuilder(address)": "failed",
  "PayOutOfGas()": "failed", "BuildersOff()": "failed",
  // the pause
  "IsPaused(uint64)": "paused", "NotGuardian(address)": "failed", "NotTimelock(address)": "failed", "PauseRefused(uint64)": "failed", "BadPause(uint64)": "failed", "ZeroAddress()": "failed",
  // BidSpender: its pull is the market's alone
  "NotMarket(address)": "failed",
  // USDG as deployed, the registry, InviteBondV2's deposit
  "InsufficientAllowance()": "allowance", "InsufficientFunds()": "short", "ERC721InvalidApprover(address)": "notOwner", "ERC721NonexistentToken(uint256)": "cantSell",
  "NotOwner(uint256)": "notOwner", "AgentDefaulted(uint256)": "defaulted", "LoanOpen(uint256)": "loan", "NotTreasuryLine(uint256)": "line", "AlreadyBonded(uint256)": "failed",
});
const SELECTORS = new Map(Object.entries(MARKET_ERRORS).map(([sig, kind]) => [ethers.id(sig).slice(0, 10), { sig, kind }]));
/**
 * A revert's kind from its data ("0x" and the error's selector first; a message that quotes it works too): the known
 * selector found earliest, else "failed". `role` ("accept", "bid", "buy", "sell", "cancel", "cancelBid"): on an accept,
 * a pull that the maker's USDG refused is "unfunded" and UriChanged is the bid's file pin ("card"); SelfBuy is
 * "selfAccept" or "selfBid"; NoBid on a cancel of bids is "bidGone".
 */
export function errorKindOf(revertData, role = null) {
  const s = String(revertData || "").toLowerCase();
  let best = null, at = Infinity;
  for (const m of s.matchAll(/0x[0-9a-f]{8}/g)) {
    const hit = SELECTORS.get(m[0]);
    if (hit && m.index < at) { best = hit; at = m.index; }
  }
  if (!best) return { kind: "failed", sig: null };
  let kind = best.kind;
  if (role === "accept" && (kind === "allowance" || kind === "short")) kind = "unfunded";
  if (role === "accept" && best.sig === "UriChanged(uint256)") kind = "card";
  if (role === "cancelBid" && kind === "gone") kind = "bidGone";
  if (kind === "self" && role === "accept") kind = "selfAccept";
  if (kind === "self" && role === "bid") kind = "selfBid";
  if (kind === "price" && role === "bid") kind = "low";
  return { kind, sig: best.sig };
}

/* ---- the words ---- */

/**
 * The refusals by kind (the P7 spec, section 10.3), {placeholders} filled by planWords. Each says what is wrong, then
 * what to do; the tool adds "Nothing was signed or sent." A bid's and an accept's own kinds take BID_REFUSALS first.
 */
export const PLAN_WORDS = Object.freeze({
  // this server's settings
  sellOff: "This server doesn't sell agents. The user can allow it with PRIORS_MARKET_SELL.",
  sellNotListed: "This server doesn't sell #{id}. The user can add it to PRIORS_MARKET_SELL.",
  ownAgent: "#{id} is the agent this server acts for, and this server never sells it. Sell it from Go mode or the board.",
  floor: "{price} USDG is under this server's floor of {floor} USDG for one agent. Ask more, or the user can lower PRIORS_MARKET_MIN_SELL_USD.",
  floorNet: "This would leave this wallet {net} USDG after the fee{and}, under this server's floor of {floor} USDG for one agent. The user can lower PRIORS_MARKET_MIN_SELL_USD.",
  ceiling: "This could take {amount} USDG, above this server's limit of {max} USDG for one buy or bid. The user can raise PRIORS_MAX_MARKET_USD.",
  day: "This would bring today's buys and bids for agent #{self} and this wallet to {total} USDG, above {cap} USDG a day. {used} USDG was counted today, and the limit starts again at 00:00 UTC.",
  bidsOver: "Your open bids would take up to {reserve} USDG, above this server's limit of {max} USDG. Cancel a bid, then bid.",
  dupBid: "This wallet made bid #{bidId} on the same terms in the last 10 minutes, and it is still open. To bid again, cancel it with market_cancel_bid, then bid.",
  record: "#{id} has {m} repaid loan{s}. This server buys and bids only on agents with {n} or more.",
  // money
  keepBack: "Agent #{self} owes {owed} USDG on its open loans, due {due}. This would leave {left} USDG to repay them. Repay the loans, or add USDG.",
  short: "This wallet holds {cash} USDG. Add {short} USDG, then try again.",
  shortBond: "#{id}'s line needs a {bond} USDG bond before it can change hands, and this wallet holds {cash} USDG. Add {short} USDG, then try again.",
  noEth: "This wallet holds no ETH on Robinhood Chain for gas. Add a little ETH, then try again.",
  lowEth: "This wallet holds {have} ETH on Robinhood Chain, and these steps need up to {need} ETH for gas. Add ETH, then try again.",
  // the agent
  notOwner: "This wallet doesn't hold #{id}. Its owner is {owner}.",
  gone: "#{id} isn't for sale now. Its listing ended, or its seller no longer holds it or no longer lets the market move it.",
  changed: "#{id} asks {price} USDG now, above your {max}. Read it again, then buy.",
  relisted: "#{id}'s listing changed since it was read. It asks {price} USDG now. Read it again, then buy.",
  stale: "#{id}'s file or its record changed after it was listed, so this listing can't be bought. Its seller has to list it again.",
  recordMoved: "#{id}'s record changed since it was read. Read it again, then buy.",
  fileMoved: "#{id}'s file changed since it was read. Read it again, then bid.",
  sellerBlocked: "#{id}'s seller can't sell on the market now, so its listing can't be bought.",
  self: "This wallet listed #{id}. Use market_cancel to stop selling.",
  loan: "#{id} has a loan open. It can change hands once the loan is repaid.",
  line: "#{id}'s line can't go with it. Its owner leaves the line before a sale.",
  hold: "#{id} changed hands in the last 14 days. It can change hands again on {date}.",
  root: "#{id} backs other agents' lines. It can't be sold here.",
  defaulted: "#{id} has a default on the pool. It can't be sold here.",
  firstBond: "#{id} has a bond on the older InviteBond. It can't change hands here while that bond stands.",
  cantSell: "#{id} can't be sold here.",
  adapter: "#{id} can't be sold here. Its NFT's adapter holds it.",
  noListing: "This wallet has no listing of #{id} to cancel.",
  cannotCancel: "This listing of #{id} isn't this wallet's to cancel. Its seller still holds the agent.",
  notApproved: "The market isn't approved for #{id}. Nothing of it can move until it is.",
  price: "A listing asks 5 USDG or more. Raise the price, then list.",
  days: "A listing or a bid lasts 1 to 30 days. Pick a number of days in that range.",
  // the account and the market
  account: "This wallet can't buy or sell on the market.",
  marked: "This wallet has a default on the pool. It can't buy or sell on the market.",
  paused: "The market is paused{until}. Cancelling still works.",
  unknownMarket: "The market at {market} doesn't answer as the market this server knows. Update @priors/mcp.",
  unread: "The chain couldn't be read just now. Try again in a minute.",
  allowance: "The USDG approved for this step was short when it ran. Read it again, then try again.",
  failed: "The market refused this step ({why}). Read the agent again with market_agent.",
  // the bids, where a sale's word is wrong
  notMaker: "Bid #{bidId} isn't this wallet's. Only its maker can cancel it.",
  bidGone: "Bid #{bidId} isn't open now. It was cancelled, taken or ran out, or there is no such bid.",
  noNet: "This bid is {price} USDG and the market's fee is {fee} USDG, so it would leave this wallet nothing. It can't be accepted.",
  tooMany: "market_cancel_bid cancels at most 10 bids a call. Cancel the rest in another call.",
  count: "A bid on an origin takes 1 to {max} agents here. Pick a count in that range.",
  noBids: "This wallet has no open bid to cancel.",
  badSet: "Priors' hub answered a list whose ids don't make its root, so this server didn't use it. Try again later.",
  // the hub
  hubDown: "Priors' hub at {hub} didn't answer, so {what} can't be read. Try again later.",
  noSet: "Priors' hub has no list for {origin} now. Bid on one agent instead.",
});
/** A bid's and an accept's refusals: market-bids' BID_WORDS.errors as they are, but "over" (this server's own limit),
 *  the two that name Go mode's buttons, which this server doesn't have, "notInBid", said here without the list's day
 *  (an accept may not have read it), and "badSet", which says what the hub did (the tool adds that nothing was sent). */
export const BID_REFUSALS = Object.freeze({
  ...BID_WORDS.errors,
  over: PLAN_WORDS.bidsOver,
  selfBid: "This wallet holds #{id}. Use market_list to set a price.",
  selfAccept: "This is this wallet's own bid. Cancel it with market_cancel_bid.",
  notInBid: "This agent isn't in that bid's list. market_agent shows the bids it can take, with their proofs.",
  badSet: PLAN_WORDS.badSet,
});
const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
/** The words of kind `kind` for `role` ("bid" and "accept" read BID_REFUSALS first), {placeholders} filled from `vars`:
 *  bigints as USDG amounts ("1.20"), but ids (id, bidId, self: "#7311") and counts (n, m, count: "1,204") as whole
 *  numbers. */
export function planWords(kind, vars = {}, role = null) {
  const t = (role === "bid" || role === "accept") && own(BID_REFUSALS, kind) ? BID_REFUSALS[kind] : own(PLAN_WORDS, kind) ? PLAN_WORDS[kind] : PLAN_WORDS.failed;
  return t.replace(/\{(\w+)\}/g, (_, k) => {
    const v = vars[k];
    if (v == null) return k === "until" ? "" : k === "why" ? "no reason given" : `{${k}}`;
    if (typeof v === "bigint") return ["id", "bidId", "self"].includes(k) ? String(v) : ["n", "m", "count"].includes(k) ? String(v).replace(/\B(?=([0-9]{3})+(?![0-9]))/g, ",") : amountText(v);
    return String(v);
  });
}
