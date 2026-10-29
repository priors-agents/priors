// AgentMarketV2's builder share, the seam (the builder share spec, sections 2, 5 and 10; docs/AGENT-MARKET.md "Builder
// share"): the calls, events and errors of the share as the listings index, the gas gate, Go mode, the board, the MCP
// and the contract itself (src/AgentMarketV2.sol, src/interfaces/IAgentBuilders.sol) all name them; the split of a
// price into the fee, the share and the seller's net, exactly as the contract's splitOf makes it; what a listing or a
// bid says once a share applies; and the calls an agent or a script sends. sdk/market-bids.mjs folds the calls and
// events into V2's ABI (MARKET_V2_ABI); this module imports nothing from it, so either can be loaded first.
//
// The account that holds an agent never sold here (on V2 or on v1, `previous`) sets, once, a share of 1 to 500 bps
// (0.01% to 5%) of each later sale's price, paid to an address it names, the builder. After that only the builder
// changes it: lower, or to another address; never higher. The seller pays it out of the price, after the fee and never
// more than the fee leaves; none when the seller is the builder. The buyer, and a bid's maker, pay the price and no
// more. A buy pays the lower of the share at list and at buy, as it does the fee; an accept pays the share then, and
// the seller's minNet holds it. Nobody gets an agent whose share it could not read first: a share is never set while a
// listing of the agent stands (on V2 or v1: cancel, set, list again), and an accept refuses a bid made before the
// share was set (builderSince). A builder USDG refuses never stops a sale: the seller gets the share, and the market
// logs BuilderMissed.
//
//   setBuilder(id, to, bps)       the agent's holder, once, before any sale here and with no listing standing; paused
//                                 with the trading calls
//   changeBuilder(id, to, bps)    the builder only: bps at most the current one (0 allowed), `to` the next builder;
//                                 never paused
//   enableBuilders()              the owner (the Safe) only, once and for good: shares are off from the deploy until
//                                 then (setBuilder refuses with BuildersOff, so none exists; paused, with IsPaused
//                                 first); buildersOn() reads it
//
// test/vectors/agent-builders.json (scripts/builder-vectors.mjs) holds the selectors, topics, errors, splits and sample
// calls; the contract's forge tests read it back, and scripts/test-market-builders.mjs holds this module to it.
//
// A builder's paid amount is a sold price divided by its rate: `BuilderPaid` carries it because the chain does, and
// nothing here reads or words it.
import { ethers } from "ethers";
import { LISTING_RULES, feeOf } from "./market-abi.mjs";
import { toId } from "./credit-profile.mjs";
import { usdgText, usdgUnits } from "./work-types.mjs";

/* ---- the contract ---- */

/** A share as builderOf returns it (IAgentBuilders.Builder, one slot). `to` zero: no share was ever set. */
export const BUILDER_FIELDS = Object.freeze(["to", "bps"]);
const BUILDER_TUPLE = "tuple(address to, uint16 bps)";

/**
 * The share's calls (spec 2.4). setBuilder stops while GuardianPause is paused; changeBuilder never does. The views:
 * builderOf(id); builderSince(id), the first bid id an accept of the agent takes (nextBidId when its share was set; 0
 * for none): an older bid is refused; saleSplit(id), what a buy of the standing listing pays now (zeros: no listing),
 * the pins at list included; splitOf(id, price, seller), what an accept at `price` by `seller` pays now;
 * MAX_BUILDER_BPS, 500. The switch: enableBuilders(), the owner's only, once (a second call changes nothing), and
 * buildersOn(), false until then.
 */
export const BUILDER_FUNCTIONS = Object.freeze([
  "function setBuilder(uint256 id, address to, uint256 bps)",
  "function changeBuilder(uint256 id, address to, uint256 bps)",
  `function builderOf(uint256 id) view returns (${BUILDER_TUPLE} builder)`,
  "function builderSince(uint256 id) view returns (uint256)",
  "function saleSplit(uint256 id) view returns (uint256 fee, uint256 share, uint256 net)",
  "function splitOf(uint256 id, uint256 price, address seller) view returns (uint256 fee, uint256 share, uint256 net)",
  "function MAX_BUILDER_BPS() view returns (uint256)",
  "function enableBuilders()",
  "function buildersOn() view returns (bool)",
]);

/** The share's events (docs/AGENT-MARKET.md, "Builder events"). A sale that pays a share logs BuilderPaid, or
 *  BuilderMissed when USDG refused the builder, just before its Sold or BidTaken. The index reads who and whether,
 *  never the amount. BuildersEnabled, with no field, is the owner's switch: logged once, when shares turn on. */
export const BUILDER_EVENTS = Object.freeze([
  "event BuilderSet(uint256 indexed agentId, address indexed to, uint256 bps)",
  "event BuilderPaid(uint256 indexed agentId, address indexed to, uint256 amount)",
  "event BuilderMissed(uint256 indexed agentId, address indexed to, uint256 amount)",
  "event BuildersEnabled()",
]);

/** The share's errors (spec 2.8): the new ones, PayOutOfGas (the market's and BidSpender's, one selector), BuildersOff
 *  (setBuilder's while the owner has not turned shares on), then the two reused from v1 with v1's signatures.
 *  ListingStands names the market where the listing stands (V2 or v1); BuilderAfterBid is acceptBid's, for a bid made
 *  before the share was set. `new ethers.Interface(BUILDER_ERRORS)` decodes them. */
export const BUILDER_ERRORS = Object.freeze([
  "error NotBuilder(uint256 id, address caller)",
  "error BuilderTaken(uint256 id)",
  "error AlreadySold(uint256 id)",
  "error BadShare(uint256 bps)",
  "error BadBuilder(address to)",
  "error ListingStands(uint256 id, address market)",
  "error BuilderAfterBid(uint256 bidId, uint256 id)",
  "error PayOutOfGas()",
  "error BuildersOff()",
  "error NotOwner(uint256 id, address seller)",
  "error PriceTooLow(uint256 price)",
]);

const IFACE = new ethers.Interface([...BUILDER_FUNCTIONS, ...BUILDER_EVENTS]);
/** Each builder event's topic0. */
export const BUILDER_TOPICS = Object.freeze({
  BuilderSet: IFACE.getEvent("BuilderSet").topicHash,
  BuilderPaid: IFACE.getEvent("BuilderPaid").topicHash,
  BuilderMissed: IFACE.getEvent("BuilderMissed").topicHash,
  BuildersEnabled: IFACE.getEvent("BuildersEnabled").topicHash,
});

/* ---- the rules and the split ---- */

/** A share is 1 to 500 bps of the price (0.01% to 5%; MAX_BUILDER_BPS); a change may take it to 0. Go mode's form
 *  starts at 2.5%. */
export const BUILDER_RULES = Object.freeze({ minBps: 1, maxBps: 500, defaultBps: 250 });

/** Whole bps from 0 (or `min`) to 500. */
function bpsOf(v, min, what = "bps") {
  if (!Number.isSafeInteger(v) || v < min || v > BUILDER_RULES.maxBps) throw new Error(`${what} is a whole number from ${min} to ${BUILDER_RULES.maxBps}`);
  return v;
}

/**
 * The split of `price` (USDG units) as the contract's splitOf makes it: { fee, share, net } in USDG units. The fee is
 * market-abi's feeOf (`feeBps` and `minFee` the market's now, default the rules'); the share is `bps` of the price,
 * rounded down, never more than what the fee leaves, and none when the seller is the builder (`sellerIsBuilder`) or
 * `bps` is 0. A price under 5 USDG throws, as the contract reverts. A buy of a standing listing pays the lower fee and
 * the lower share of list and now: read saleSplit(id) for that.
 */
export function splitOf(price, { feeBps = LISTING_RULES.feeBps, minFee = LISTING_RULES.minFee, bps = 0, sellerIsBuilder = false } = {}) {
  const p = toId(price, "price");
  if (p < LISTING_RULES.minPrice) throw new Error("a price is 5 USDG or more");
  const b = BigInt(bpsOf(bps, 0));
  if (typeof sellerIsBuilder !== "boolean") throw new Error("sellerIsBuilder is true or false");
  const { fee } = feeOf(p, { feeBps, minFee });
  let share = sellerIsBuilder ? 0n : (p * b) / 10_000n;
  if (share > p - fee) share = p - fee;
  return { fee, share, net: p - fee - share };
}

/** A share's rate as the words say it: 250 is "2.5%", 500 "5%", 1 "0.01%". */
export function pctText(bps) {
  const b = bpsOf(bps, 0);
  const frac = String(b % 100).padStart(2, "0").replace(/0+$/, "");
  return `${Math.floor(b / 100)}${frac ? "." + frac : ""}%`;
}

/** An address, checksummed or all lower case, never zero; lower case. */
function addressOf(a, what) {
  let x;
  try { x = ethers.getAddress(a); } catch (_) { throw new Error(`${what} must be an address`); }
  if (x === ethers.ZeroAddress) throw new Error(`${what} must not be the zero address`);
  return x.toLowerCase();
}
const shortAddr = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/* ---- the words (spec 10) ---- */

/**
 * The words of the builder share, one set for every surface (the board, Go mode and the MCP translate or show them).
 * None says an amount a builder was paid, and none says "royalty". `errors.off` answers BuildersOff, and a paused
 * setBuilder's IsPaused too while buildersOn() is false: the pause is checked first, and `errors.paused` would promise
 * a set once it ends.
 */
export const BUILDER_WORDS = Object.freeze({
  label: "Builder share",
  yours: "Your builder shares",
  paidTo: "Paid to",
  setShare: "Set builder share",
  lower: "Lower",
  handOver: "Hand over",
  row: "{pct} to {addr}",
  listing: "{price} USDG. Fee {fee}. Builder share {share}. The seller gets {net}. Until {date}.",
  buy: "When you sell #{id} here, {pct} of the price goes to its builder.",
  sell: "{pct} of your price goes to its builder, {addr}.",
  anyEach: "{price} USDG each. Fee {fee}. The owner gets up to {net}. Until {date}.",
  mcp: "Builder share: {pct} of each sale here goes to {addr}.",
  setting: Object.freeze({
    gets: "You get {pct} of the price each time #{id} sells here.",
    later: "You can lower it or hand it to another address later. You can't raise it.",
    before: "It can only be set while #{id} has never been sold here.",
    here: "Sales outside this market pay no share.",
    sellFirst: "Set a builder share before you list. It can't be set once #{id} is sold here.",
  }),
  errors: Object.freeze({
    taken: "#{id} already has a builder share. Only its builder can change it.",
    sold: "#{id} has been sold here already. A builder share can only be set before that.",
    notYours: "Only the account that holds #{id} can set its builder share. Use the account that holds it.",
    high: "A builder share is 5% at most. Lower it, then set it.",
    low: "A builder share is at least 0.01%. Raise it, then set it.",
    raise: "A builder share can only go down. Choose {pct} or less.",
    notBuilder: "Only the builder can change this share. Use the account it pays.",
    badTo: "That address can't receive the share. Choose another address.",
    paused: "Setting a share is paused for now. Lowering one still works.",
    listed: "#{id} is listed for sale. Cancel the listing, set the share, then list it again.",
    afterBid: "This bid was made before #{id} had a builder share, so it can't be accepted. A bid made since can.",
    off: "Builder shares can't be set on this market yet.",
  }),
  bell: Object.freeze({
    paid: "#{id} changed hands here. Your builder share went to your account.",
    missed: "Your builder share for #{id} couldn't be paid. The seller kept it.",
  }),
});

/** A share as the sheet shows it: { to (lower case), bps, pct ("2.5%"), words ("2.5% to 0x1234…abcd") }. `to` is the
 *  builder; `bps` 0 to 500 (a share lowered to 0 still has its builder). Null for none (`to` zero or missing). */
export function builderView(b) {
  if (!b || b.to == null || BigInt(b.to) === 0n) return null;
  const to = addressOf(b.to, "the builder"), bps = bpsOf(Number(b.bps), 0), pct = pctText(bps);
  return { to, bps, pct, words: BUILDER_WORDS.row.replace("{pct}", pct).replace("{addr}", shortAddr(to)) };
}

const noCents = (text) => text.replace(/\.00$/, "");
/** A listingView's or bidView's first line: "{price} USDG. Fee {fee}. The seller|owner gets {net}. Until {date}." */
const LINE = /^(.+ USDG\. Fee [0-9]+(?:\.[0-9]+)?\.) The (seller|owner) gets [0-9]+(?:\.[0-9]+)?\. (Until .+\.)$/;

/**
 * A listingView (sdk/market-abi.mjs) or bidView (sdk/market-bids.mjs) answer with a builder `share` (USDG units, the
 * contract's: saleSplit's for a listing, splitOf's for a bid) taken from what the seller gets: `share` written after
 * `fee`, `sellerGets` lowered by it, and the first line naming it ("120 USDG. Fee 1.20. Builder share 3. The seller
 * gets 115.80. Until 20 Nov."). A share of 0 returns the view as it is. It throws on a share more than the seller
 * gets, a view that has one already, or a first line it does not know.
 */
export function withShare(view, { share = 0 } = {}) {
  const s = toId(share, "share");
  if (s === 0n) return view;
  if (!view || typeof view !== "object" || !Array.isArray(view.words)) throw new Error("withShare takes a listingView or a bidView");
  if ("share" in view) throw new Error("the view has a share already");
  const gets = usdgUnits(view.sellerGets);
  if (s > gets) throw new Error("the share is more than the seller gets");
  const m = LINE.exec(view.words[0]);
  if (!m) throw new Error("the view's first line is not a price line");
  const bid = "needs" in view; // a bid's line says every amount without cents, a listing's the net exactly
  const shareText = usdgText(s), netText = usdgText(gets - s);
  const line = `${m[1]} Builder share ${noCents(shareText)}. The ${m[2]} gets ${bid ? noCents(netText) : netText}. ${m[3]}`;
  const out = {};
  for (const [k, v] of Object.entries(view)) {
    out[k] = k === "sellerGets" ? netText : k === "words" ? [line, ...view.words.slice(1)] : v;
    if (k === "fee") out.share = shareText;
  }
  return out;
}

/* ---- the calls, for agents and scripts ---- */

/** A builder's address as the contract takes it: never zero, the market or its bids' spender (CREATE(market, 1),
 *  sdk/market-bids.mjs spenderOf): a share sent to either would stay there. The contract also refuses v1
 *  (`previous`), USDG and the registry, which this module does not know: a caller that does refuses them first. */
function builderTo(market, to) {
  const mkt = addressOf(market, "the market"), t = addressOf(to, "the builder");
  if (t === mkt || t === ethers.getCreateAddress({ from: mkt, nonce: 1 }).toLowerCase()) throw new Error("the builder is never the market or its spender");
  return { mkt, t };
}

/** setBuilder(id, to, bps): the agent's holder sets its share, once, before any sale here. `bps` 1 to 500. { to, data } */
export function setBuilderCall({ market, id, to, bps }) {
  const { mkt, t } = builderTo(market, to);
  return { to: mkt, data: IFACE.encodeFunctionData("setBuilder", [toId(id, "id"), t, bpsOf(bps, BUILDER_RULES.minBps)]) };
}

/** changeBuilder(id, to, bps): the builder lowers its share (0 allowed: it stays set and pays nothing) or hands it to
 *  `to`; the contract refuses a raise. { to, data } */
export function changeBuilderCall({ market, id, to, bps }) {
  const { mkt, t } = builderTo(market, to);
  return { to: mkt, data: IFACE.encodeFunctionData("changeBuilder", [toId(id, "id"), t, bpsOf(bps, 0)]) };
}
