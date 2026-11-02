// Rialto's Quote API for the stock tokens (docs.rialto.xyz, "Quote API Overview"; the guide
// github.com/rialto-plds/rialto-api-docs RIALTO_SWAP_API.md, read 2026-11-02): a quote checked before anything of it is
// used, the choice between it and the pinned pool's quote (sdk/stock-zap.mjs), and the two calls it then takes. Pure:
// no network, no key. The key lives only in the gas gate (gas-worker/rialto.mjs): Rialto's own rule is that a partner
// key never reaches a page, an app, a repository or a log.
//
// GET /quote?sell_token&buy_token&sell_amount&taker&slippage_bps (API key, Bearer) answers the best route Rialto finds
// (its propAMMs, internal liquidity and AMMs) and a ready transaction for its RialtoRouter. Priors asks it only in
// `allowance` settlement: the taker approves the router for exactly the amount sold, then sends the router transaction
// unchanged. That is the mode Rialto gives a smart account (Go mode's Alchemy Modular Account v2) anyway, and it keeps
// both of Priors' paths at "an exact approval, then the one swap" (docs/STOCK-ZAP-SPEC.md 6). Priors charges no fee on
// a Rialto trade (the owner, 2026-11-02): the request never carries swap_fee_bps, and a quote naming an integrator fee
// is refused.
//
// The router is never taken from the quote alone: Rialto's Router Registry names the active one (feature 2, the
// taker-submitted swap; `ownerOf(2)` reverts while the feature is paused), and checkQuote takes only a quote whose
// transaction goes to it.
//
//   RIALTO_REGISTRY, RIALTO_FEATURE, REGISTRY_ABI   the registry that names Rialto's router (Rialto's API address is the
//                       gate's alone, gas-worker/rialto.mjs: this file ships in @priors/mcp, which never calls Rialto)
//   quoteQuery(o)       the /quote query for a trade (URLSearchParams string), in allowance settlement, with no fee
//   checkQuote(body, o) a quote checked against the trade asked for -> frozen terms, or throws RialtoError with the reason
//   chooseRoute(o)      "rialto" when its quote gives more of the bought token than the pinned pool's, else "pinned"
//   rialtoCalls(terms)  the two calls: the exact approval of the sold token to the router, then Rialto's transaction
//   wireTerms / readWire  terms to JSON (amounts as digits) and back, checked again
import { encodeFunctionData, formatUnits, getAddress, isAddress, keccak256, parseAbi } from "viem";

export const RIALTO_CHAIN_ID = 4663;
/** Rialto's Router Registry on Robinhood Chain (the guide's "Registry deployments"), and the feature id of the
 *  taker-submitted swap: `ownerOf(2)` is the router a quote's transaction must go to. */
export const RIALTO_REGISTRY = "0x71a120CbBf3Ce7cD910a3c50fF77aFc62735687E";
export const RIALTO_FEATURE = 2;
export const REGISTRY_ABI = parseAbi(["function ownerOf(uint256 featureId) view returns (address)"]);
const APPROVE_ABI = parseAbi(["function approve(address spender, uint256 amount) returns (bool)"]);
/** The most slippage Priors lets a trade take (docs/STOCK-ZAP-SPEC.md 6: 2%), and how long the gate keeps a quote's
 *  transaction for the account it quoted (Rialto: quotes "can go stale quickly"). */
export const MAX_SLIPPAGE_BPS = 200;
export const QUOTE_TTL_S = 90;

export class RialtoError extends Error {
  constructor(message, o = {}) { super(message); this.name = "RialtoError"; Object.assign(this, o); }
}
const fail = (m, o) => { throw new RialtoError(m, o); };
const HEX = /^0x(?:[0-9a-fA-F]{2})+$/;
const DIGITS = /^(0|[1-9]\d*)$/;
const same = (a, b) => { try { return getAddress(a) === getAddress(b); } catch (_) { return false; } };
const addr = (v, what) => (typeof v === "string" && isAddress(v, { strict: false }) && !/^0x0{40}$/i.test(v) ? getAddress(v) : fail(`${what}: not an address`));
const big = (v, what) => {
  if (typeof v === "bigint" && v >= 0n) return v;
  if (typeof v === "number" && Number.isSafeInteger(v) && v >= 0) return BigInt(v);
  if (typeof v === "string" && DIGITS.test(v)) return BigInt(v);
  return fail(`${what}: not an amount`);
};
const bps = (v) => (Number.isInteger(v) && v >= 1 && v <= MAX_SLIPPAGE_BPS ? v : fail(`slippage: from 1 to ${MAX_SLIPPAGE_BPS} basis points`));

/** The /quote query for selling `sellAmount` (base units, `sellDecimals`) of `sellToken` for `buyToken`, paid to
 *  `taker`, at most `slippageBps` off: Rialto takes the amount as a decimal and addresses only (no symbols), and is
 *  asked for allowance settlement on Robinhood Chain. No swap_fee_bps, ever: Priors takes no fee. */
export function quoteQuery({ sellToken, buyToken, sellAmount, sellDecimals, taker, slippageBps }) {
  const s = addr(sellToken, "sell token"), b = addr(buyToken, "buy token"), t = addr(taker, "taker");
  if (same(s, b)) fail("the same token on both sides");
  const amount = big(sellAmount, "sell amount");
  if (amount === 0n) fail("sell amount: not an amount");
  if (!Number.isInteger(sellDecimals) || sellDecimals < 0 || sellDecimals > 36) fail("sell token: no decimals");
  return new URLSearchParams({
    sell_token: s, buy_token: b, sell_amount: formatUnits(amount, sellDecimals), taker: t,
    slippage_bps: String(bps(slippageBps)), settlement: "allowance", chain_id: String(RIALTO_CHAIN_ID),
  }).toString();
}

/**
 * A /quote answer `body` taken only when it is the trade asked for: on Robinhood Chain, allowance settlement (no
 * Permit2 payload, no signature offset), the transaction to `router` (the registry's ownerOf(2)) with no value, the
 * tokens and the raw sell amount asked, paid to `taker`, an output above 0 with a minimum within `slippageBps` of it,
 * no integrator fee, and the taker holding enough (issues.balance). An approval Rialto asks for (issues.allowance) must
 * be to the router itself. -> frozen terms: { quoteId, router, spender, data, sellToken, buyToken, sellAmount,
 * buyAmount, minBuyAmount, gas, feeBps, legs }. Throws RialtoError (balance: true when the taker holds too little).
 */
export function checkQuote(body, { sellToken, buyToken, sellAmount, taker, router, slippageBps }) {
  if (!body || typeof body !== "object") fail("Rialto's quote: not a quote");
  const want = { sell: addr(sellToken, "sell token"), buy: addr(buyToken, "buy token"), taker: addr(taker, "taker"), router: addr(router, "router") };
  const amount = big(sellAmount, "sell amount"), slip = bps(slippageBps);
  if (Number(body.chain_id) !== RIALTO_CHAIN_ID) fail("Rialto's quote: another chain");
  if (body.settlement !== "allowance") fail("Rialto's quote: not allowance settlement");
  const tx = body.tx;
  if (!tx || typeof tx !== "object") fail("Rialto's quote: no transaction");
  if (body.permit2 != null || tx.signature_offset != null) fail("Rialto's quote: a Permit2 payload in allowance settlement");
  if (!same(tx.to, want.router)) fail("Rialto's quote: its transaction is not to Rialto's registered router");
  if (big(tx.value ?? "0", "value") !== 0n) fail("Rialto's quote: its transaction sends ETH");
  if (typeof tx.data !== "string" || !HEX.test(tx.data) || tx.data.length < 10) fail("Rialto's quote: no transaction data");
  if (!same(body.sell_token, want.sell) || !same(body.buy_token, want.buy)) fail("Rialto's quote: other tokens");
  if (big(body.sell_amount, "sell amount") !== amount) fail("Rialto's quote: another amount");
  if (!same(body.taker, want.taker)) fail("Rialto's quote: another taker");
  if (body.integrator_fee != null) fail("Rialto's quote: an integrator fee");
  const buyAmount = big(body.buy_amount, "buy amount"), minBuyAmount = big(body.min_buy_amount, "minimum");
  if (buyAmount === 0n || minBuyAmount === 0n) fail("Rialto's quote: nothing out");
  if (minBuyAmount > buyAmount) fail("Rialto's quote: a minimum above its output");
  // Rialto rounds the minimum down (min = floor(buy * (10000 - slippage) / 10000), read 2026-11-02 on a live quote)
  if (minBuyAmount < (buyAmount * BigInt(10000 - slip)) / 10000n) fail("Rialto's quote: a minimum below the slippage asked");
  const issues = body.issues && typeof body.issues === "object" ? body.issues : {};
  if (issues.balance != null) fail("not enough of the sold token for that amount", { balance: true });
  if (issues.allowance != null && !same(issues.allowance.spender, want.router)) fail("Rialto's quote: an approval to another spender");
  if (typeof body.quote_id !== "string" || !/^[0-9a-fA-F-]{8,64}$/.test(body.quote_id)) fail("Rialto's quote: no quote id");
  const feeBps = Number(body.platform_fee && body.platform_fee.total_bps);
  return Object.freeze({
    quoteId: body.quote_id, router: want.router, spender: want.router, data: tx.data.toLowerCase(),
    sellToken: want.sell, buyToken: want.buy, taker: want.taker, sellAmount: amount, buyAmount, minBuyAmount,
    gas: Number.isSafeInteger(tx.estimated_gas) ? tx.estimated_gas : null,
    feeBps: Number.isFinite(feeBps) ? feeBps : null,
    legs: Array.isArray(body.route && body.route.legs) ? body.route.legs.length : null,
  });
}

/** The route a trade takes: "rialto" only when Rialto's terms give strictly more of the bought token than the pinned
 *  pool's quote (`pinnedOut`, base units, null when no pinned pool serves the token), else "pinned" (null when neither
 *  can: no pinned pool and no Rialto quote). Equal goes to the pinned pool, today's path. */
export function chooseRoute({ pinnedOut = null, rialto = null }) {
  const p = pinnedOut == null ? null : big(pinnedOut, "pinned output");
  if (rialto && rialto.buyAmount > 0n && (p == null || rialto.buyAmount > p)) return { route: "rialto", out: rialto.buyAmount, min: rialto.minBuyAmount };
  if (p == null || p === 0n) return { route: null, out: null, min: null };
  return { route: "pinned", out: p, min: null };
}

/** The two calls of a Rialto trade from the account: the sold token approved to the router for exactly the amount, then
 *  Rialto's transaction, unchanged. */
export function rialtoCalls(terms) {
  return [
    { to: terms.sellToken, data: encodeFunctionData({ abi: APPROVE_ABI, functionName: "approve", args: [terms.spender, terms.sellAmount] }), value: 0n },
    { to: terms.router, data: terms.data, value: 0n },
  ];
}

/** keccak256 of a quote's transaction data: what the gate keeps to know the call it sponsors is the one it quoted. */
export const dataHashOf = (data) => keccak256(data);

/** Terms as JSON (amounts as digits). */
export function wireTerms(t) {
  return { quoteId: t.quoteId, router: t.router, spender: t.spender, data: t.data, sellToken: t.sellToken, buyToken: t.buyToken, taker: t.taker,
    sellAmount: String(t.sellAmount), buyAmount: String(t.buyAmount), minBuyAmount: String(t.minBuyAmount), gas: t.gas, feeBps: t.feeBps, legs: t.legs };
}

/** wireTerms' JSON read back and checked: the same shape, addresses and digits, or throws RialtoError. */
export function readWire(w) {
  if (!w || typeof w !== "object") fail("not a quote");
  if (typeof w.data !== "string" || !HEX.test(w.data) || w.data.length < 10) fail("Rialto's quote: no transaction data");
  if (!same(w.router, w.spender)) fail("Rialto's quote: an approval to another spender");
  const buyAmount = big(w.buyAmount, "buy amount"), minBuyAmount = big(w.minBuyAmount, "minimum");
  if (minBuyAmount === 0n || minBuyAmount > buyAmount) fail("Rialto's quote: a minimum above its output");
  return Object.freeze({
    quoteId: String(w.quoteId || ""), router: addr(w.router, "router"), spender: addr(w.spender, "spender"), data: w.data.toLowerCase(),
    sellToken: addr(w.sellToken, "sell token"), buyToken: addr(w.buyToken, "buy token"), taker: addr(w.taker, "taker"), sellAmount: big(w.sellAmount, "sell amount"),
    buyAmount, minBuyAmount, gas: Number.isSafeInteger(w.gas) ? w.gas : null, feeBps: Number.isFinite(w.feeBps) ? w.feeBps : null,
    legs: Number.isSafeInteger(w.legs) ? w.legs : null,
  });
}
