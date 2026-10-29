// AgentMarketV2's bids, the seam (the bids spec, sections 2.3 and 5; docs/AGENT-MARKET.md "Bids"): the calls, events
// and errors of the bids as the listings index (data-worker/market-index.mjs), the gas gate, Go mode, the board, the
// MCP and the contract itself (src/AgentMarketV2.sol, src/interfaces/IAgentBids.sol) all name them; the address of the
// bids' USDG spender; the lists of agent ids a bid on an origin names, as Merkle roots; `bidView`, the words an open bid
// says; and the calls an agent or a script sends. sdk/market-abi.mjs, v1's seam, stays frozen: V2 is v1's list, cancel
// and buy unchanged, plus bids and the builder share (sdk/market-builders.mjs), so V2's ABI here is v1's pieces, the
// bids and the share's.
//
// A bid is funded by allowance, not escrow. The maker approves a USDG reserve to BidSpender, a child contract the
// market creates in its constructor (its only CREATE, so the spender is CREATE(market, nonce 1): spenderOf below), and
// the USDG stays in the maker's account until an owner accepts. One reserve backs many bids. The market and the spender
// hold no USDG and no agent between calls, as v1. Bids live on chain: `bid` and `bidAny` store the bid by msg.sender
// and emit an event; there are no signatures, no off-chain store and no write API.
//
//   bid(id, price, expiry, uriHash, minRepaid, minLine)      a bid on one agent; uriHash 0 (any file) or
//                                                            keccak256(tokenURI) as read (market-abi uriHashOf)
//   bidAny(root, count, price, expiry, minRepaid, minLine)   a bid on up to `count` (1 to 20) agents of one list, named
//                                                            by its Merkle root (idsRootOf); price is for one agent
//   cancelBid(bidId)                                         the maker, at any time; never paused
//   acceptBid(bidId, id, proof, minNet)                      the agent's owner sells it to the maker in one transaction:
//                                                            v1's rules with the caller as seller, the maker as a buyer,
//                                                            the maker's pins, then the spender pulls the agent's
//                                                            builder share to its builder, price - fee - share to the
//                                                            seller and the fee to feeTo, and the registry moves the
//                                                            agent; minNet is the seller's pin against a fee applied or
//                                                            a share changed meanwhile (both taken from the seller's
//                                                            side)
//
// A list's leaf is keccak256(bytes.concat(keccak256(abi.encode(uint256 id)))), OpenZeppelin's double-hashed leaf, and
// the tree is sdk/credit-profile.mjs's (merkleRoot, merkleProof, verifyProof): ids whole, deduplicated and sorted
// ascending, pairs hashed sorted, an odd node carried up unchanged; OpenZeppelin's MerkleProof checks its proofs.
// test/vectors/agent-bids.json (scripts/bid-vectors.mjs) holds the selectors, topics and errors, leaves, roots and proofs
// for lists of 1, 2, 3, 7 and 1,000 ids, spenderOf of three addresses and sample calls; the contract's forge tests read
// it back, and scripts/test-market-bids.mjs holds this module to it.
//
// An open bid's amount is shown as an asking price is. An accepted bid's amount is a sold price: `BidTaken` carries it
// because the chain does, and nothing here words it.
import { ethers } from "ethers";
import DEP from "../deployments/4663.v2.json" with { type: "json" };
import { MARKET_FUNCTIONS, MARKET_EVENTS, MARKET_ADMIN_EVENTS, LISTING_RULES, feeOf } from "./market-abi.mjs";
import { toId, merkleRoot, merkleProof, verifyProof } from "./credit-profile.mjs";
import { usdgText } from "./work-types.mjs";
import { BUILDER_FUNCTIONS, BUILDER_EVENTS, BUILDER_WORDS, splitOf, withShare } from "./market-builders.mjs";

/* ---- the contract ---- */

/** The constructor: v1's ten (market-abi MARKET_CONSTRUCTOR, in the same order), then `previous`: AgentMarket v1, or
 *  zero on a chain without one; V2 reads its lastSoldAt so the 14-day hold spans both markets. The guardian and
 *  `timelock` (the owner of the settings) are the Safe, as for v1; the fee still waits the market's own 48 h. */
export const MARKET_V2_CONSTRUCTOR = "constructor(address registry, address usdg, address poolV2, address poolV1, address inviteBond, address inviteBondV2, address feeTo, uint256 lineRoot, address guardian, address timelock, address previous)";

/** A bid as bidOf returns it (IAgentBids.Bid, four slots), field by field. `maker` zero: no bid (never made, cancelled,
 *  or used up). `target` is bytes32(agentId) for a bid on one agent, the list's root for a bid on an origin; `uriHash`
 *  is 0 for a bid on an origin. */
export const BID_FIELDS = Object.freeze(["maker", "expiry", "left", "any", "price", "minLine", "minRepaid", "target", "uriHash"]);
const BID_TUPLE = "tuple(address maker, uint64 expiry, uint16 left, bool any, uint96 price, uint96 minLine, uint64 minRepaid, bytes32 target, bytes32 uriHash)";

/**
 * The bid calls (spec 2.3). bid, bidAny and acceptBid stop while GuardianPause is paused; cancelBid never does. The
 * views: bidOf(bidId); bidTook(bidId, id), true once a bid on an origin took that agent (it never takes one twice);
 * nextBidId (the first bid is 1); bidSpender (the reserve's spender, spenderOf(market)); previous (v1, or zero).
 * lastSoldAt(id) is in MARKET_FUNCTIONS: on V2 it is the later of V2's own and previous's.
 */
export const BID_FUNCTIONS = Object.freeze([
  "function bid(uint256 id, uint256 price, uint64 expiry, bytes32 uriHash, uint256 minRepaid, uint256 minLine) returns (uint256 bidId)",
  "function bidAny(bytes32 root, uint256 count, uint256 price, uint64 expiry, uint256 minRepaid, uint256 minLine) returns (uint256 bidId)",
  "function cancelBid(uint256 bidId)",
  "function acceptBid(uint256 bidId, uint256 id, bytes32[] proof, uint256 minNet)",
  `function bidOf(uint256 bidId) view returns (${BID_TUPLE} bid)`,
  "function bidTook(uint256 bidId, uint256 id) view returns (bool)",
  "function nextBidId() view returns (uint256)",
  "function bidSpender() view returns (address)",
  "function previous() view returns (address)",
]);

/** The four bid events the index reads, fixed now so the index and the contract agree (docs/AGENT-MARKET.md, "Bid
 *  events"). An accept also emits v1's `Cancelled` first when a listing of the agent stood. */
export const BID_EVENTS = Object.freeze([
  "event BidMade(uint256 indexed bidId, uint256 indexed agentId, address indexed maker, uint256 price, uint64 expiry, bytes32 uriHash, uint256 minRepaid, uint256 minLine)",
  "event BidAnyMade(uint256 indexed bidId, bytes32 indexed root, address indexed maker, uint256 price, uint256 count, uint64 expiry, uint256 minRepaid, uint256 minLine)",
  "event BidCancelled(uint256 indexed bidId, address indexed maker)",
  "event BidTaken(uint256 indexed agentId, address indexed seller, address indexed maker, uint256 bidId, uint256 price, uint256 fee, bytes32 recordHash)",
]);

/** The bids' errors (spec 2.3): the new ones, then the four reused from v1 with v1's signatures (so v1's selectors),
 *  then BidSpender's. An accept also fails with any of v1's sale errors (NotOwner, OnHold, ...). Not in MARKET_V2_ABI;
 *  `new ethers.Interface(BID_ERRORS)` decodes them. */
export const BID_ERRORS = Object.freeze([
  "error NoBid(uint256 bidId)",
  "error BidExpired(uint256 bidId, uint64 expiry)",
  "error BadBid()",
  "error NotMaker(uint256 bidId, address caller)",
  "error NotFunded(uint256 amount)",
  "error NotInBid(uint256 bidId, uint256 id)",
  "error AlreadyTaken(uint256 bidId, uint256 id)",
  "error RecordBelow(uint256 id, uint256 loansRepaid)",
  "error LineBelow(uint256 id, uint256 delegatedIn)",
  "error NetBelow(uint256 net, uint256 minNet)",
  "error SelfBuy()",
  "error PriceTooLow(uint256 price)",
  "error BadExpiry(uint64 expiry)",
  "error UriChanged(uint256 id)",
  "error NotMarket(address caller)",
]);

/** V2's whole ABI, human-readable (ethers), and its Interface: v1's calls and events unchanged, plus the bids and the
 *  builder share's (sdk/market-builders.mjs). */
export const MARKET_V2_ABI = Object.freeze([MARKET_V2_CONSTRUCTOR, ...MARKET_FUNCTIONS, ...BID_FUNCTIONS, ...BUILDER_FUNCTIONS, ...MARKET_EVENTS, ...BID_EVENTS, ...BUILDER_EVENTS, ...MARKET_ADMIN_EVENTS]);
export const MARKET_V2_IFACE = new ethers.Interface(MARKET_V2_ABI);
/** Each bid event's topic0. */
export const BID_TOPICS = Object.freeze({
  BidMade: MARKET_V2_IFACE.getEvent("BidMade").topicHash,
  BidAnyMade: MARKET_V2_IFACE.getEvent("BidAnyMade").topicHash,
  BidCancelled: MARKET_V2_IFACE.getEvent("BidCancelled").topicHash,
  BidTaken: MARKET_V2_IFACE.getEvent("BidTaken").topicHash,
});

/* ---- the rules ---- */

const DAY = 86400;
/**
 * The bid rules (amounts in USDG units, times in seconds). A bid is 5 USDG or more for one agent, as a listing, and
 * lives at most 30 days (7 by default on Priors' screens). A bid on an origin takes 1 to 20 agents; an accept's proof is
 * at most 32 hashes. The maker's balance and allowance must cover price × count when it bids; after that the index
 * shows only the bids its funds cover. maxSponsored is Go mode's cap: all of an account's open bids together at most
 * 1,000 USDG, the reserve included. A wallet of its own has no cap but its reserve.
 */
export const BID_RULES = Object.freeze({
  minPrice: 5_000_000n, // 5 USDG (LISTING_RULES.minPrice)
  maxLifeS: 30 * DAY,
  defaultDays: 7,
  maxCount: 20,
  maxProof: 32,
  maxSponsored: 1_000_000_000n, // 1,000 USDG
});

const U64 = 2n ** 64n - 1n, U96 = 2n ** 96n - 1n;
const HEX32 = /^0x[0-9a-fA-F]{64}$/;

/** An address, checksummed or all lower case, never zero; lower case. */
function addressOf(a, what) {
  let x;
  try { x = ethers.getAddress(a); } catch (_) { throw new Error(`${what} must be an address`); }
  if (x === ethers.ZeroAddress) throw new Error(`${what} must not be the zero address`);
  return x.toLowerCase();
}

/**
 * The bids' USDG spender for a market: CREATE(market, nonce 1), the BidSpender its constructor makes, lower case. Go
 * mode, the gas gate and the board derive it from the market's address and check it against the market's own
 * bidSpender(); the reserve is approved to it and to nothing else.
 */
export const spenderOf = (market) => ethers.getCreateAddress({ from: addressOf(market, "the market"), nonce: 1 }).toLowerCase();

/* ---- the lists a bid on an origin names ---- */

const coder = ethers.AbiCoder.defaultAbiCoder();
/** An agent id's leaf: keccak256(bytes.concat(keccak256(abi.encode(uint256 id)))), lower case. */
export const leafOf = (id) => ethers.keccak256(ethers.keccak256(coder.encode(["uint256"], [toId(id, "an agent id")])));

/** A list of agent ids as its root commits to it: whole numbers (bigints, decimal strings or safe integers), each once,
 *  ascending, as decimal strings. At least one. */
export function listOf(ids) {
  if (!Array.isArray(ids) || !ids.length) throw new Error("a list names at least one agent id");
  const out = [...new Set(ids.map((v) => toId(v, "an agent id")))];
  return out.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)).map(String);
}

/** The root a bid on these ids names (bidAny's root), lower case. */
export const idsRootOf = (ids) => merkleRoot(listOf(ids).map(leafOf));

/** The proof acceptBid passes for `id` in the list `ids` (bytes32 values, lower case; [] for a list of one), or null
 *  when the id is not in it. */
export function proofOf(ids, id) {
  const list = listOf(ids), i = list.indexOf(toId(id, "an agent id").toString());
  return i < 0 ? null : merkleProof(list.map(leafOf), i);
}

/** Whether `proof` shows `id` in the list whose root is `root`, as the contract checks it (at most 32 hashes, each a
 *  bytes32). Anything that is not such a proof, or an id that is not a whole number, is false: an answer from elsewhere
 *  (the API, a link) is checked here, never trusted. */
export function inRoot(root, id, proof) {
  if (typeof root !== "string" || !HEX32.test(root) || BigInt(root) === 0n) return false;
  if (!Array.isArray(proof) || proof.length > BID_RULES.maxProof || !proof.every((p) => typeof p === "string" && HEX32.test(p))) return false;
  let leaf;
  try { leaf = leafOf(id); } catch (_) { return false; }
  return verifyProof(proof.map((p) => p.toLowerCase()), root.toLowerCase(), leaf);
}

/* ---- what a bid says (spec 13) ---- */

/** An amount as the words say it: "40" for a whole amount, "40.50" otherwise (market-abi's priceWords). */
const noCents = (text) => text.replace(/\.00$/, "");
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const dayWords = (s) => { const d = new Date(Number(s) * 1000); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`; };
/** A count with thousands marked, the same in every runtime: 1000 is "1,000". */
const countWords = (n) => String(n).replace(/\B(?=([0-9]{3})+(?![0-9]))/g, ",");
/** A UTC day ("2026-10-27", as the data Worker writes a list's day) or unix seconds, as seconds. */
function dayS(day) {
  if (typeof day === "string" && /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(day)) {
    const t = Date.parse(`${day}T00:00:00Z`);
    if (Number.isFinite(t)) return t / 1000;
  }
  if (Number.isSafeInteger(day) && day > 0) return day;
  throw new Error("a list's day is a UTC day like 2026-10-27");
}

/**
 * The words of bids, one set for every surface (the board, Go mode and the MCP translate or show them; none says a
 * sold price). The first group is bidView's: the maker's pins, then a bid on an origin's list. Then the sheet lines
 * for making a bid and for accepting one, the refusals by kind, and the bell.
 */
export const BID_WORDS = Object.freeze({
  sameFile: "Only as its file is now.",
  line: "Only with its {line} USDG line.",
  repaid: "Only with {n} repaid loans or more.",
  repaidOne: "Only with 1 repaid loan or more.",
  anyOf: "Any one of the {n} {origin} agents the Directory listed on {date}.",
  left: "{left} of {count} left.",
  stays: "Your USDG stays in your account until an owner accepts. Priors holds nothing.",
  making: "{price} USDG for #{id}. The owner gets {net} after the fee. Until {date}.",
  makingShare: "{price} USDG for #{id}. The owner gets {net} after the fee and the builder share. Until {date}.",
  newOwner: "If #{id} changes hands, its new owner can accept too.",
  firstOwner: "The first owner to accept sells you one.",
  reserve: "Your bids can take up to {x} USDG from your account. A bid past that waits until you add USDG.",
  accepting: "{by} pays {price} USDG for #{id}. You get {net} after the fee, and #{id} goes to them at once.",
  acceptingShare: "{by} pays {price} USDG for #{id}. You get {net} after the fee and the builder share, and #{id} goes to them at once.",
  yours: "#{id} is yours. Lock your own {bond} USDG bond before it borrows on its line.",
  errors: Object.freeze({
    gone: "This bid is closed. It was cancelled, used or ran out.",
    unfunded: "This bid can't be taken right now. Its maker doesn't have the USDG approved for it.",
    maker: "This bid's maker can't buy right now. Choose another bid.",
    card: "This agent's file changed since the bid. The bid asked for the file as it was.",
    repaid: "The bid asks for {n} repaid loans or more. This agent has {m}.",
    lineBelow: "The bid asks for its {line} USDG line. The line is smaller or gone now.",
    notInBid: "This agent isn't in that bid's list. The list is the Directory's of {date}.",
    taken: "This bid already took this agent. Choose another bid.",
    selfBid: "You hold this agent. Use Sell to set a price.",
    selfAccept: "This is your own bid. Cancel it from Your bids.",
    listed: "It's listed for {price} USDG. Buy it instead.",
    low: "A bid is 5 USDG or more. Raise it, then bid.",
    over: "Go mode bids up to 1,000 USDG in all. Cancel a bid, or bid from your own wallet on the board.",
    short: "You have {cash} USDG. Add {short} more, then bid.",
    cantSell: "This agent can't be sold here.",
    adapter: "This agent can't be sold here. Its NFT's adapter holds it.",
    hold: "This agent changed hands in the last 14 days. It can be sold again on {date}.",
    loan: "This agent has a loan open. Repay it, then accept.",
    line: "This agent's line can't go with it. Leave the line, then accept.",
    fee: "The fee changed since you looked. Read the bid again, then accept.",
    paused: "Bids are paused for now. Cancelling still works.",
    badSet: "This list didn't check out. Nothing was sent.",
  }),
  bell: Object.freeze({
    made: "A bid of {price} USDG on #{id}.",
    taken: "Your bid on #{id} was accepted. #{id} is yours.",
    tookAny: "Your bid on any {origin} agent took #{id}.",
  }),
});
/** The keys of bidView's answer, in order. */
export const BID_VIEW_KEYS = Object.freeze(["price", "fee", "sellerGets", "expiresAt", "left", "needs", "words"]);

/**
 * What an open bid says, for the board, Go mode and the MCP alike: { price, fee, sellerGets (USDG, written: "40.00"),
 * expiresAt, left (the agents it can still take; 1 for a bid on one agent), needs ({ sameFile, repaid, line }: the
 * maker's pins; line written, or null), words (the first like a listing's, "40 USDG. Fee 1. The owner gets 39. Until 3
 * Nov."; for a bid on an origin, its list and how many it can still take; then the pins) }.
 *
 * `item` is a bid as bidOf or the index gives it: { price (USDG units, for one agent), expiry, left, any: true (or
 * kind: "any") for a bid on an origin, count (the agents it asked for; default `left`), uriHash, minRepaid, minLine }.
 * `feeBps` and `minFee` are the market's now (default the rules'): an accept takes the fee then, from the owner's side,
 * so a fee applied meanwhile changes what the owner gets, never what the maker pays. `origin`, `n` and `day`, for a bid
 * on an origin: the origin's name, how many agents its list holds and the UTC day the Directory published it; without
 * all three the list is not named. Nothing here depends on the clock, so unlike listingView it takes no `now`.
 *
 * `builderBps` is the agent's builder share (sdk/market-builders.mjs; 0, the default, for none, or when the agent's
 * owner is its builder): an accept pays it from the owner's side too, so `share` is written after `fee`, `sellerGets`
 * is lowered by it and the first line names it ("40 USDG. Fee 1. Builder share 1. The owner gets 38. Until 3 Nov.").
 * null, for a bid on an origin read without an agent: what an owner gets then is at most the price less the fee
 * ("20 USDG each. Fee 1. The owner gets up to 19. Until 20 Nov."). With 0 the answer is as it always was.
 *
 * It throws on a bid the chain could not hold or that no agent could ever fill (below 5 USDG, past uint96, more agents
 * than 20 or left than asked, a file pin on a bid on an origin, a repaid pin past 2^53): callers drop it. An open bid
 * only: there is no accepted price here.
 */
export function bidView(item, { feeBps = LISTING_RULES.feeBps, minFee = LISTING_RULES.minFee, origin = null, n = null, day = null, builderBps = 0 } = {}) {
  if (!item || typeof item !== "object") throw new Error("bidView takes a bid");
  if (item.kind !== undefined && item.kind !== "agent" && item.kind !== "any") throw new Error('a bid\'s kind is "agent" or "any"');
  const any = item.any === true || item.kind === "any";
  const p = toId(item.price, "price");
  if (p < BID_RULES.minPrice || p > U96) throw new Error("a bid is 5 USDG or more, for one agent");
  const expiresAt = Number(toId(item.expiry, "expiry"));
  const left = toId(item.left ?? 1, "left"), count = any ? toId(item.count ?? left, "count") : 1n;
  if (left < 1n || left > count || count > BigInt(BID_RULES.maxCount) || (!any && left !== 1n)) throw new Error("a bid takes 1 to 20 agents, never more than it asked for");
  const uriHash = item.uriHash == null ? ethers.ZeroHash : String(item.uriHash);
  if (!HEX32.test(uriHash)) throw new Error("uriHash is a bytes32");
  const sameFile = BigInt(uriHash) !== 0n;
  if (any && sameFile) throw new Error("a bid on an origin pins no file");
  const minRepaid = toId(item.minRepaid ?? 0, "minRepaid"), minLine = toId(item.minLine ?? 0, "minLine");
  if (minRepaid > BigInt(Number.MAX_SAFE_INTEGER) || minLine > U96) throw new Error("a pin no agent could meet");
  if (builderBps === null && !any) throw new Error("a bid on one agent knows its agent's builder share");
  const { fee, sellerGets } = feeOf(p, { feeBps, minFee });
  const price = usdgText(p), feeText = usdgText(fee), gets = usdgText(sellerGets);
  const repaid = Number(minRepaid), line = minLine > 0n ? usdgText(minLine) : null;
  const words = [builderBps === null
    ? BUILDER_WORDS.anyEach.replace("{price}", noCents(price)).replace("{fee}", noCents(feeText)).replace("{net}", noCents(gets)).replace("{date}", dayWords(expiresAt))
    : `${noCents(price)} USDG. Fee ${noCents(feeText)}. The owner gets ${noCents(gets)}. Until ${dayWords(expiresAt)}.`];
  if (any) {
    if (origin != null && n != null && day != null) {
      if (typeof origin !== "string" || !origin.trim()) throw new Error("origin is the origin's name");
      if (!Number.isSafeInteger(n) || n < 1) throw new Error("n is how many agents the list holds");
      words.push(BID_WORDS.anyOf.replace("{n}", countWords(n)).replace("{origin}", origin.trim()).replace("{date}", dayWords(dayS(day))));
    }
    words.push(BID_WORDS.left.replace("{left}", String(left)).replace("{count}", String(count)));
  }
  if (sameFile) words.push(BID_WORDS.sameFile);
  if (line) words.push(BID_WORDS.line.replace("{line}", noCents(line)));
  if (repaid === 1) words.push(BID_WORDS.repaidOne);
  else if (repaid > 1) words.push(BID_WORDS.repaid.replace("{n}", countWords(repaid)));
  const view = { price, fee: feeText, sellerGets: gets, expiresAt, left: Number(left), needs: { sameFile, repaid, line }, words };
  return builderBps ? withShare(view, { share: splitOf(p, { feeBps, minFee, bps: builderBps }).share }) : view;
}

/* ---- the calls, for agents and scripts ---- */

const ERC20 = new ethers.Interface(["function approve(address spender, uint256 amount) returns (bool)"]);
const marketCall = (market, fn, args) => ({ to: addressOf(market, "the market"), data: MARKET_V2_IFACE.encodeFunctionData(fn, args) });

/** The terms bid and bidAny share, checked as the contract checks them (_bidTerms): price 5 USDG or more and within
 *  uint96; an expiry after `now` and within 30 days (`expiry`, or `days` from `now`, 7 by default); minRepaid within
 *  uint64, minLine within uint96. */
function termsOf({ price, expiry, days, now, minRepaid = 0, minLine = 0 }) {
  const p = toId(price, "price");
  if (p < BID_RULES.minPrice) throw new Error("a bid is 5 USDG or more");
  if (p > U96) throw new Error("price is out of range");
  const t = now == null ? BigInt(Math.floor(Date.now() / 1000)) : toId(now, "now");
  if (expiry != null && days != null) throw new Error("give expiry or days, not both");
  let e;
  if (expiry != null) e = toId(expiry, "expiry");
  else {
    const d = days ?? BID_RULES.defaultDays;
    if (!Number.isSafeInteger(d) || d < 1 || d * DAY > BID_RULES.maxLifeS) throw new Error("days is 1 to 30");
    e = t + BigInt(d * DAY);
  }
  if (e <= t || e > t + BigInt(BID_RULES.maxLifeS)) throw new Error("a bid ends after now and within 30 days");
  const r = toId(minRepaid, "minRepaid"), l = toId(minLine, "minLine");
  if (r > U64) throw new Error("minRepaid is out of range");
  if (l > U96) throw new Error("minLine is out of range");
  return { price: p, expiry: e, minRepaid: r, minLine: l };
}

/** The reserve: USDG approve(spenderOf(market), amount), what all of the maker's bids together can take. An exact
 *  amount, never an unlimited approval; 0 takes it back (every bid is then not funded). Go mode keeps it at most
 *  BID_RULES.maxSponsored. `usdg` defaults to deployments/4663.v2.json's. { to, data } */
export function reserveCall({ market, amount, usdg = DEP.usdg }) {
  const a = toId(amount, "amount");
  if (a === ethers.MaxUint256) throw new Error("the reserve is an amount, never an unlimited approval");
  return { to: addressOf(usdg, "USDG"), data: ERC20.encodeFunctionData("approve", [spenderOf(market), a]) };
}

/** bid(id, price, expiry, uriHash, minRepaid, minLine): a bid on one agent. `uriHash` 0 (the default) takes the agent
 *  with any file; uriHashOf(tokenURI) only as its file is now. { to, data } */
export function bidCall({ market, id, price, expiry, days, now, uriHash = ethers.ZeroHash, minRepaid = 0, minLine = 0 }) {
  const t = termsOf({ price, expiry, days, now, minRepaid, minLine });
  if (typeof uriHash !== "string" || !HEX32.test(uriHash)) throw new Error("uriHash is a bytes32");
  return marketCall(market, "bid", [toId(id, "id"), t.price, t.expiry, uriHash.toLowerCase(), t.minRepaid, t.minLine]);
}

/** bidAny(root, count, price, expiry, minRepaid, minLine): a bid on up to `count` agents of one list, `price` each.
 *  Give the list's `ids` (its root is computed here, and count is at most its size) or its `root`; with both, the root
 *  must be the list's. { to, data } */
export function bidAnyCall({ market, root, ids, count, price, expiry, days, now, minRepaid = 0, minLine = 0 }) {
  const t = termsOf({ price, expiry, days, now, minRepaid, minLine });
  const c = toId(count, "count");
  if (c < 1n || c > BigInt(BID_RULES.maxCount)) throw new Error("a bid on an origin takes 1 to 20 agents");
  let r = root == null ? null : String(root);
  if (r != null && (!HEX32.test(r) || BigInt(r) === 0n)) throw new Error("root is a bytes32, never 0");
  if (ids != null) {
    const list = listOf(ids), mine = merkleRoot(list.map(leafOf));
    if (r != null && r.toLowerCase() !== mine) throw new Error("the root is not the list's");
    if (c > BigInt(list.length)) throw new Error("count is more than the list holds");
    r = mine;
  }
  if (r == null) throw new Error("a bid on an origin names its list: ids or root");
  return marketCall(market, "bidAny", [r.toLowerCase(), c, t.price, t.expiry, t.minRepaid, t.minLine]);
}

/** cancelBid(bidId): the maker's own bid. { to, data } */
export function cancelBidCall({ market, bidId }) {
  const b = toId(bidId, "bidId");
  if (b < 1n) throw new Error("bid ids start at 1");
  return marketCall(market, "cancelBid", [b]);
}

/** acceptBid(bidId, id, proof, minNet) alone: the owner sells agent `id` to the bid's maker, once the registry's
 *  getApproved(id) is the market. To give that approval, use acceptCalls: it cancels a dormant listing first. `proof`:
 *  [] for a bid on one agent, proofOf(list, id) for a bid on an origin. `minNet`, the least the owner takes after the
 *  fee and the agent's builder share, at least 1 unit (the contract refuses an accept that pays the owner nothing, and
 *  so does the gas gate): give it, or give the bid's `price` (and the market's `feeBps` and `minFee`, default the
 *  rules', and the agent's `builderBps`, 0 for none or when the owner is its builder: read builderOf(id) or the
 *  contract's splitOf) and it is the exact net now. { to, data } */
export function acceptCall({ market, bidId, id, proof = [], minNet, price, feeBps, minFee, builderBps = 0 }) {
  const b = toId(bidId, "bidId");
  if (b < 1n) throw new Error("bid ids start at 1");
  if (!Array.isArray(proof) || proof.length > BID_RULES.maxProof || !proof.every((p) => typeof p === "string" && HEX32.test(p))) throw new Error("a proof is at most 32 bytes32 values");
  if (minNet == null && price == null) throw new Error("give minNet, or the bid's price");
  const fees = { feeBps: feeBps ?? LISTING_RULES.feeBps, minFee: minFee ?? LISTING_RULES.minFee };
  const net = minNet != null ? toId(minNet, "minNet") : builderBps ? splitOf(toId(price, "price"), { ...fees, bps: builderBps }).net : feeOf(toId(price, "price"), fees).sellerGets;
  if (net < 1n) throw new Error("minNet is at least 1 USDG unit: an accept never pays the owner nothing");
  return marketCall(market, "acceptBid", [b, toId(id, "id"), proof.map((p) => p.toLowerCase()), net]);
}

const REGISTRY = new ethers.Interface(["function approve(address to, uint256 tokenId)"]);
/** An address as read from the chain (listingOf's seller, getApproved), zero allowed; lower case. */
function readAddress(a, what) {
  if (a == null) throw new Error(`${what} is read from the chain first (the zero address for none)`);
  try { return ethers.getAddress(a).toLowerCase(); } catch (_) { throw new Error(`${what} must be an address`); }
}

/**
 * The owner's whole accept, in the order a plain wallet sends it, each call only after the one before is mined (or all
 * in one batch):
 *   1. cancel(id), when the owner's own listing of the agent stands while the market is not approved for it. Such a
 *      listing is dormant, not gone: the approval below brings it back at its old price and nonce, and anyone could buy
 *      it there before the accept lands (docs/AGENT-MARKET.md "Stopping a sale"; the bids spec's walletAcceptPlan);
 *   2. approve(market, id) on the registry, when getApproved(id) is not the market;
 *   3. acceptBid, as acceptCall builds it.
 * `owner` is the account that accepts; `listingSeller` (the market's listingOf(id).seller) and `approved` (the
 * registry's getApproved(id)) are read just before, the zero address for none. `registry` defaults to
 * deployments/4663.v2.json's. The rest is acceptCall's. [{ to, data }, ...]
 */
export function acceptCalls({ market, registry = DEP.registry, owner, listingSeller, approved, ...accept }) {
  const mkt = addressOf(market, "the market"), who = addressOf(owner, "the owner");
  const seller = readAddress(listingSeller, "listingSeller"), now = readAddress(approved, "approved");
  const last = acceptCall({ market, ...accept });
  const id = toId(accept.id, "id"), calls = [];
  if (now !== mkt) {
    if (seller === who) calls.push(marketCall(market, "cancel", [id]));
    calls.push({ to: addressOf(registry, "the registry"), data: REGISTRY.encodeFunctionData("approve", [mkt, id]) });
  }
  calls.push(last);
  return calls;
}
