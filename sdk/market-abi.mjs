// AgentMarket v1's seam (docs/research/2026-10-23-hub-status/HUB-V1-SPEC.md 4.1 to 4.3 and 8 S0): the contract's
// functions and events as the listings index (data-worker/market-index.mjs, slice S2), Go mode (slice S4) and the
// contract itself (src/AgentMarket.sol, slice S6) all name them; the record pin `recordHash` and the file pin `uriHash`,
// computed here exactly as the contract does; the listing rules; and `listingView`, the one function that makes the
// words the board, Go mode and the MCP show for a listing. Frozen with the seam commit (spec 8, "Shared files").
//
// The market holds nothing between calls: one transaction swaps the agent and the USDG. An agent sells like an NFT (the
// owner's decisions of 2026-10-26, spec 4.6): its record and its Score v2 stay on its id, and a line from a root the
// market follows (the treasury's) stays on it too; the buyer bonds before it borrows. Any other line (a stock line, a
// $PRIORS book, a backer's) is left before listing. With MARKET_ADDRESS empty the index reads nothing and answers
// { open: false, listings: [] } (spec 4.2).
//
// The two pins a buyer passes to buy(), equal to what is on chain then, or the buy reverts (bait and switch, 4.1):
//
//   recordHash  keccak256(abi.encode(uint256 id, uint256 loansRepaid, uint256 volumeRepaid, uint256 qualifiedRepaid,
//               bool defaulted, uint256 sponsor, uint256 delegatedIn)), the six from the pool's getAgent(id)
//               (src/interfaces/ICreditPoolV2.sol Agent: USDG units for volumeRepaid, qualifiedRepaid and delegatedIn;
//               sponsor the root's id), each a full 32-byte word: 224 bytes hashed, no packing. The line is in it, so a
//               buyer gets the line it read.
//   uriHash     keccak256(bytes(tokenURI(id))): the registry's token URI as its UTF-8 bytes, as read, never trimmed or
//               normalised.
//
// test/vectors/agent-market.json holds four recordHash vectors (and three uriHash ones) computed here, which the contract's
// forge tests read back (scripts/test-hub-seam.mjs checks they still hold).
//
// Prices are asking prices only. A sold price, a sales count or a volume is never served by any route (spec 4.2, 6.2):
// `Sold` carries a price because the chain does, and the index reads it only for the agent's last sale time (the hold).
import { ethers } from "ethers";
import { usdgText } from "./work-types.mjs";

/* ---- the contract ---- */

/** The constructor: the ERC-8004 registry, USDG, pool v2, pool v1 (zero allowed), InviteBond v1 and InviteBondV2 (zero
 *  allowed), where the fee lands (the treasury), the root whose lines follow their agents (treasury v5's agentId; 0 for
 *  none), the guardian (GuardianPause) and the 48 h timelock that owns it. */
export const MARKET_CONSTRUCTOR = "constructor(address registry, address usdg, address poolV2, address poolV1, address inviteBond, address inviteBondV2, address feeTo, uint256 lineRoot, address guardian, address timelock)";

/**
 * The calls (4.1). list and buy stop while GuardianPause is paused; cancel never does. The fee is changed only by the
 * timelock: queueFee, then applyFee once the market's own 48 h have passed (cancelFee drops a queued one). setRefused
 * (timelock only) keeps Priors' own contracts (treasuries, vaults) from selling or buying; setFollowsLine (timelock only)
 * names the roots whose lines go with their agents.
 *   list(id, price, expiry)                            the owner lists, after approve(market, id) for this one agent
 *   cancel(id)                                         the seller, or anyone once the owner changed or it expired
 *   buy(id, maxPrice, nonce, uriHash, recordHash)      pulls the price from the caller: price minus fee to the seller,
 *                                                      the fee to feeTo; then registry.transferFrom(seller, buyer, id)
 *   recordHash(id)                                     the record pin, now (recordHashOf below)
 *   listingOf(id)                                      the standing listing: seller (zero for none), price, expiry, its
 *                                                      nonce, and the pins taken at list (uriHash, loansRepaid)
 * The getters the index and listingView read: feeBps, minFee, feeTo, pendingFee, lastSoldAt (the 14-day hold), refused.
 */
export const MARKET_FUNCTIONS = Object.freeze([
  "function list(uint256 id, uint256 price, uint64 expiry)",
  "function cancel(uint256 id)",
  "function buy(uint256 id, uint256 maxPrice, uint256 nonce, bytes32 uriHash, bytes32 recordHash)",
  "function recordHash(uint256 id) view returns (bytes32)",
  "function listingOf(uint256 id) view returns (tuple(address seller, uint256 price, uint64 expiry, uint256 nonce, bytes32 uriHash, uint256 loansRepaid) listing)",
  "function queueFee(uint256 bps, uint256 minFee, address feeTo)",
  "function applyFee()",
  "function cancelFee()",
  "function setRefused(address account, bool refused)",
  "function setFollowsLine(uint256 root, bool follows)",
  "function feeBps() view returns (uint256)",
  "function minFee() view returns (uint256)",
  "function feeTo() view returns (address)",
  "function pendingFee() view returns (uint256 bps, uint256 minFee, address feeTo, uint64 readyAt)",
  "function lastSoldAt(uint256 id) view returns (uint64)",
  "function refused(address account) view returns (bool)",
  "function followsLine(uint256 root) view returns (bool)",
]);

/** The three events the listings index reads, fixed now so the index and the contract agree (4.1). */
export const MARKET_EVENTS = Object.freeze([
  "event Listed(uint256 indexed agentId, address indexed seller, uint256 price, uint64 expiry, bytes32 uriHash, uint256 nonce)",
  "event Cancelled(uint256 indexed agentId, address indexed by, uint256 nonce)",
  "event Sold(uint256 indexed agentId, address indexed seller, address indexed buyer, uint256 price, uint256 fee, bytes32 recordHash, uint256 nonce)",
]);
/** The contract's own events for its settings: the index reads none of them. */
export const MARKET_ADMIN_EVENTS = Object.freeze([
  "event FeeQueued(uint256 bps, uint256 minFee, address feeTo, uint64 readyAt)",
  "event FeeApplied(uint256 bps, uint256 minFee, address feeTo)",
  "event FeeCancelled()",
  "event RefusedSet(address indexed account, bool refused)",
  "event FollowsLineSet(uint256 indexed root, bool follows)",
]);

/** The whole ABI, human-readable (ethers), and its Interface. */
export const MARKET_ABI = Object.freeze([MARKET_CONSTRUCTOR, ...MARKET_FUNCTIONS, ...MARKET_EVENTS, ...MARKET_ADMIN_EVENTS]);
export const MARKET_IFACE = new ethers.Interface(MARKET_ABI);
/** Each indexed event's topic0. */
export const MARKET_TOPICS = Object.freeze({
  Listed: MARKET_IFACE.getEvent("Listed").topicHash,
  Cancelled: MARKET_IFACE.getEvent("Cancelled").topicHash,
  Sold: MARKET_IFACE.getEvent("Sold").topicHash,
});

/* ---- the rules ---- */

const DAY = 86400;
/**
 * The listing rules of 4.1 and 4.6 (amounts in USDG units, 6 decimals; times in seconds). Checked at list and all again
 * at buy. The fee: 1% of the price, at least 1 USDG, out of the price (the seller gets price minus fee), rounded down as
 * the contract rounds, paid to the treasury; the code caps it at 2% and a minimum fee of 5 USDG; a change waits the
 * market's own 48 h after the timelock's. A line follows its agent only from a root the market follows (the treasury's),
 * with an InviteBondV2 bond on it when it lends; the buyer bonds before it borrows.
 */
export const LISTING_RULES = Object.freeze({
  decimals: 6,
  minPrice: 5_000_000n, // 5 USDG
  maxExpiryS: 30 * DAY,
  holdS: 14 * DAY, // at least 14 days since the agent's last Sold, before it is listed again
  feeBps: 100, // 1%
  minFee: 1_000_000n, // 1 USDG
  maxFeeBps: 200, // the code's cap: 2%
  maxMinFee: 5_000_000n, // the code's cap on the minimum fee: 5 USDG
  feeDelayS: 48 * 3600,
  linesFollow: true, // a followed root's line stays on the agent (followsLine); any other line is left before listing
  bond: 5_000_000n, // InviteBondV2's bond, what a buyer locks before the agent borrows on a followed line
});

/* ---- the pins ---- */

/** The fields recordHash covers, in order, and their ABI types. */
export const RECORD_FIELDS = Object.freeze(["id", "loansRepaid", "volumeRepaid", "qualifiedRepaid", "defaulted", "sponsor", "delegatedIn"]);
export const RECORD_TYPES = Object.freeze(["uint256", "uint256", "uint256", "uint256", "bool", "uint256", "uint256"]);
const coder = ethers.AbiCoder.defaultAbiCoder();

/** A whole number from a bigint, a safe integer or a decimal string. */
function uint(v, what) {
  if (typeof v === "bigint" && v >= 0n) return v;
  if (typeof v === "number" && Number.isSafeInteger(v) && v >= 0) return BigInt(v);
  if (typeof v === "string" && /^(0|[1-9][0-9]{0,77})$/.test(v)) return BigInt(v);
  throw new Error(`${what} must be a whole number`);
}
/** abi.encode of the record's seven fields (224 bytes), from { id (or agentId), loansRepaid, volumeRepaid,
 *  qualifiedRepaid, defaulted, sponsor, delegatedIn } (the pool's getAgent(id) with its id). Each is required: a
 *  record read without its line would pin a line the buyer never saw. */
export function recordEncoded(agent) {
  if (!agent || typeof agent !== "object") throw new Error("recordHashOf takes the agent's record");
  if (typeof agent.defaulted !== "boolean") throw new Error("defaulted must be true or false");
  const id = uint(agent.id ?? agent.agentId, "id");
  return coder.encode(RECORD_TYPES, [id, uint(agent.loansRepaid, "loansRepaid"), uint(agent.volumeRepaid, "volumeRepaid"), uint(agent.qualifiedRepaid, "qualifiedRepaid"), agent.defaulted, uint(agent.sponsor, "sponsor"), uint(agent.delegatedIn, "delegatedIn")]);
}
/** The record pin: keccak256(abi.encode(id, loansRepaid, volumeRepaid, qualifiedRepaid, defaulted, sponsor,
 *  delegatedIn)), lower case. */
export const recordHashOf = (agent) => ethers.keccak256(recordEncoded(agent));
/** The file pin: keccak256 of the token URI's UTF-8 bytes, lower case. */
export function uriHashOf(uri) {
  if (typeof uri !== "string") throw new Error("a token URI is a string");
  return ethers.keccak256(ethers.toUtf8Bytes(uri));
}

/* ---- what a listing says (4.3) ---- */

/** The fee on `price` and what the seller gets (USDG units): max(price × feeBps / 10,000 rounded down, minFee). */
export function feeOf(price, { feeBps = LISTING_RULES.feeBps, minFee = LISTING_RULES.minFee } = {}) {
  const p = uint(price, "price"), bps = uint(feeBps, "feeBps"), min = uint(minFee, "minFee");
  const pct = (p * bps) / 10_000n;
  const fee = pct > min ? pct : min;
  if (fee > p) throw new Error("the fee is more than the price");
  return { fee, sellerGets: p - fee };
}

/** The asking price as the words say it and the card's pill shows it: "120 USDG" for a whole amount, "120.50 USDG"
 *  otherwise (spec 1.4 and 1.5). `price` itself stays exact text ("120.00"). */
const priceWords = (text) => text.replace(/\.00$/, "");
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const dayOf = (s) => { const d = new Date(Number(s) * 1000); return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`; };

export const LISTING_WORDS = Object.freeze({
  noLine: "No line. Get your own after you buy.",
  line: "Its {line} USDG line from the treasury comes with it. Lock your own {bond} USDG bond before it borrows.",
  notIncluded: "Not included: its servers, code, keys, X link.",
  carry: "You get the agent with its on-chain record.",
  hold: "Can't be sold again here for 14 days.",
});
/** The keys of listingView's answer, in order. */
export const LISTING_VIEW_KEYS = Object.freeze(["price", "fee", "sellerGets", "expiresAt", "holdUntil", "line", "bond", "lines", "openLoans", "notIncluded", "carry", "words"]);

/**
 * What a listing says, for the board, Go mode and the MCP alike: { price, fee, sellerGets (USDG, written: "120.00"),
 * expiresAt (the listing's expiry), holdUntil (when a buyer at `now` could list it again), line (the treasury line that
 * comes with it, written, or null), bond (the bond a buyer locks for it, written, or null), lines (that sentence),
 * openLoans (always 0: an agent with an open loan could not be listed), notIncluded, carry, words (the lines in the
 * order the page shows them, the first saying the price as the pill does: "120 USDG. Fee 1.20. The seller gets 118.80.
 * Until 20 Nov.") }. `listing` is { price (USDG units), expiry } as listingOf or the index gives it; `feeBps` and
 * `minFee` are the market's now (default the rules'); `line` the agent's delegatedIn when its sponsor is a root the
 * market follows (0 or null: no line). An asking price only: there is no sold price here.
 */
export function listingView(listing, { now = Math.floor(Date.now() / 1000), feeBps = LISTING_RULES.feeBps, minFee = LISTING_RULES.minFee, line = null, bond = LISTING_RULES.bond } = {}) {
  if (!listing || typeof listing !== "object") throw new Error("listingView takes a listing");
  const p = uint(listing.price, "price");
  const expiresAt = Number(uint(listing.expiry, "expiry"));
  const { fee, sellerGets } = feeOf(p, { feeBps, minFee });
  const price = usdgText(p), feeText = usdgText(fee), gets = usdgText(sellerGets);
  const has = line != null && uint(line, "line") > 0n;
  const lineText = has ? usdgText(uint(line, "line")) : null, bondText = has ? usdgText(uint(bond, "bond")) : null;
  const lines = has ? LISTING_WORDS.line.replace("{line}", priceWords(lineText)).replace("{bond}", priceWords(bondText)) : LISTING_WORDS.noLine;
  return {
    price, fee: feeText, sellerGets: gets, expiresAt, holdUntil: Number(now) + LISTING_RULES.holdS,
    line: lineText, bond: bondText, lines, openLoans: 0, notIncluded: LISTING_WORDS.notIncluded, carry: LISTING_WORDS.carry,
    words: [`${priceWords(price)} USDG. Fee ${feeText}. The seller gets ${gets}. Until ${dayOf(expiresAt)}.`, LISTING_WORDS.carry, lines, LISTING_WORDS.notIncluded, LISTING_WORDS.hold],
  };
}
