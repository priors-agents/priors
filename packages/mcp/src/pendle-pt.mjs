// PT-USDG through Pendle's router, for the account pages, the SDK and the gas gate: one place that builds the three
// calls Priors makes on Pendle (buy PT with USDG, sell PT for USDG, redeem PT for USDG after maturity), quotes them from
// the chain, and checks a call against the one shape Priors sponsors (checkRouterCall, used by gas-worker/gate.mjs).
//
// The markets are deployments/pendle.4663.json's `markets`: Pendle lists a new PT-USDG market for each maturity, so the
// record keeps every market Priors trades or has traded. At most one is "active": bought and sold until its expiry,
// redeemed after it. The others are "redeem-only": matured or retired, redeemed only, after their expiry, so a holder
// can always cash out through Priors. Every call is USDG in or out directly: the SY takes and gives USDG itself, so no
// outside aggregator (pendleSwap 0, swap type NONE) and no limit orders are ever involved, and the receiver is always the
// account that signs. A buy or a sale always names a minimum out.
//
//   PENDLE          the record, checked and frozen: { router, routerStatic, usdg, pyLpOracle, maxUsdgPerOp, markets, active }
//   MARKETS         its markets, oldest first: { market, pt, sy, yt, expiry, maturity, pyLpOracle, status, active }
//   ACTIVE_MARKET   the active one (null when none is)
//   PENDLE_ADDR     the active market's addresses in one flat object, as before markets were a list
//   marketOf(x)     a listed market by its market, PT or YT address (or the entry itself); the active one for undefined
import { decodeFunctionData, encodeFunctionData, getAddress, parseAbi } from "viem";
import RECORD from "../deployments/pendle.4663.json" with { type: "json" };

const ZERO = "0x0000000000000000000000000000000000000000";
const STATUSES = new Set(["active", "redeem-only"]);
const day = (expiry) => new Date(expiry * 1000).toISOString().slice(0, 10);

/**
 * A Pendle record (deployments/pendle.4663.json's shape) checked and frozen: addresses checksummed, expiries numbers,
 * the cap a bigint, each market's oracle filled in, at most one active market, no market, PT or YT listed twice.
 * Throws with the reason for a record that is not one. Tests build their own lists with it.
 */
export function pendleConfig(raw) {
  if (!raw || !Array.isArray(raw.markets) || !raw.markets.length) throw new Error("Pendle record: no markets");
  const addr = (v, what) => { try { const a = getAddress(v); if (a === ZERO) throw new Error(); return a; } catch (_) { throw new Error(`Pendle record: ${what} is not an address`); } };
  const router = addr(raw.router, "router"), usdg = addr(raw.usdg, "usdg");
  const oracle = raw.pyLpOracle ? addr(raw.pyLpOracle, "pyLpOracle") : null;
  const seen = new Set();
  const markets = raw.markets.map((m, i) => {
    const e = {
      market: addr(m.market, `markets[${i}].market`), pt: addr(m.pt, `markets[${i}].pt`), sy: addr(m.sy, `markets[${i}].sy`), yt: addr(m.yt, `markets[${i}].yt`),
      expiry: Number(m.expiry), pyLpOracle: m.pyLpOracle ? addr(m.pyLpOracle, `markets[${i}].pyLpOracle`) : oracle, status: m.status,
    };
    if (!Number.isSafeInteger(e.expiry) || e.expiry <= 0) throw new Error(`Pendle record: markets[${i}].expiry is not a time`);
    if (!STATUSES.has(e.status)) throw new Error(`Pendle record: markets[${i}].status is "active" or "redeem-only"`);
    for (const k of ["market", "pt", "yt"]) { const key = e[k].toLowerCase(); if (seen.has(key)) throw new Error(`Pendle record: ${e[k]} is listed twice`); seen.add(key); }
    return Object.freeze({ ...e, maturity: day(e.expiry), active: e.status === "active" });
  });
  const active = markets.filter((m) => m.active);
  if (active.length > 1) throw new Error("Pendle record: more than one active market");
  const cap = BigInt(raw.maxUsdgPerOp);
  if (cap <= 0n) throw new Error("Pendle record: maxUsdgPerOp must be above zero");
  return Object.freeze({
    chainId: Number(raw.chainId) || 4663, router, routerStatic: raw.routerStatic ? addr(raw.routerStatic, "routerStatic") : null, usdg, pyLpOracle: oracle,
    maxUsdgPerOp: cap, markets: Object.freeze(markets), active: active[0] || null,
  });
}

export const PENDLE = pendleConfig(RECORD);
export const MARKETS = PENDLE.markets;
export const ACTIVE_MARKET = PENDLE.active;
// the active market as one flat object (the latest market's addresses when none is active: its buys are refused)
const VIEW = ACTIVE_MARKET || MARKETS[MARKETS.length - 1];
export const PENDLE_ADDR = Object.freeze({
  router: PENDLE.router, market: VIEW.market, pt: VIEW.pt, yt: VIEW.yt, sy: VIEW.sy, usdg: PENDLE.usdg, expiry: VIEW.expiry, maxUsdgPerOp: PENDLE.maxUsdgPerOp,
});

const same = (x, y) => { try { return !!x && !!y && getAddress(x) === getAddress(y); } catch (_) { return false; } };
/**
 * A listed market of `conf`: `x` an entry, or a market, PT or YT address; undefined is the active market. Throws for one
 * the record does not list (and for undefined when no market is active).
 */
export function marketOf(x, conf = PENDLE) {
  if (x === undefined || x === null) {
    if (!conf.active) throw new Error("Pendle: no PT-USDG market is open for buying now");
    return conf.active;
  }
  const a = typeof x === "object" ? x.market : x;
  const m = conf.markets.find((e) => same(a, e.market) || same(a, e.pt) || same(a, e.yt));
  if (!m) throw new Error(`Pendle: ${String(a).slice(0, 42)} is not a PT-USDG market Priors lists`);
  return m;
}
/** The markets of `conf` whose PT redeems now (`nowS` at or past expiry), oldest first. */
export const maturedMarkets = (nowS, conf = PENDLE) => conf.markets.filter((m) => nowS >= m.expiry);
const tradable = (m) => { if (!m.active) throw new Error(`Pendle: the market maturing ${m.maturity} is redeem-only`); return m; };

// the router's three functions Priors uses, with Pendle's structs spelled out (IPAllActionTypeV3)
const SWAP_DATA = "(uint8 swapType, address extRouter, bytes extCalldata, bool needScale)";
const ORDER = "(uint256 salt, uint256 expiry, uint256 nonce, uint8 orderType, address token, address YT, address maker, address receiver, uint256 makingAmount, uint256 lnImpliedRate, uint256 failSafeRate, bytes permit)";
const FILL = `(${ORDER} order, bytes signature, uint256 makingAmount)`;
const LIMIT = `(address limitRouter, uint256 epsSkipMarket, ${FILL}[] normalFills, ${FILL}[] flashFills, bytes optData)`;
const TOKEN_IN = `(address tokenIn, uint256 netTokenIn, address tokenMintSy, address pendleSwap, ${SWAP_DATA} swapData)`;
const TOKEN_OUT = `(address tokenOut, uint256 minTokenOut, address tokenRedeemSy, address pendleSwap, ${SWAP_DATA} swapData)`;
const APPROX = "(uint256 guessMin, uint256 guessMax, uint256 guessOffchain, uint256 maxIteration, uint256 eps)";
export const ROUTER_ABI = parseAbi([
  `function swapExactTokenForPt(address receiver, address market, uint256 minPtOut, ${APPROX} guessPtOut, ${TOKEN_IN} input, ${LIMIT} limit) payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm)`,
  `function swapExactPtForToken(address receiver, address market, uint256 exactPtIn, ${TOKEN_OUT} output, ${LIMIT} limit) returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm)`,
  `function redeemPyToToken(address receiver, address YT, uint256 netPyIn, ${TOKEN_OUT} output) returns (uint256 netTokenOut, uint256 netSyInterm)`,
]);
export const SELECTORS = Object.freeze({ buy: "0xc81f847a", sell: "0x594a88cc" });
export const ORACLE_ABI = parseAbi(["function getPtToAssetRate(address market, uint32 duration) view returns (uint256)"]);
export const PT_ABI = parseAbi(["function balanceOf(address) view returns (uint256)", "function allowance(address owner, address spender) view returns (uint256)", "function approve(address spender, uint256 amount) returns (bool)", "function isExpired() view returns (bool)"]);

const NONE_SWAP = { swapType: 0, extRouter: ZERO, extCalldata: "0x", needScale: false };
const NO_LIMIT = { limitRouter: ZERO, epsSkipMarket: 0n, normalFills: [], flashFills: [], optData: "0x" };
// Pendle's defaults for an on-chain search of the PT amount (no off-chain guess): the full range, 256 steps, 0.01%
const DEFAULT_APPROX = { guessMin: 0n, guessMax: (1n << 256n) - 1n, guessOffchain: 0n, maxIteration: 256n, eps: 10n ** 14n };

/** USDG in, PT out to `receiver`, at least `minPtOut` (all 6 decimals), on `market` (default: the active one; only an active market). */
export function buildBuy({ receiver, usdgIn, minPtOut, market }, conf = PENDLE) {
  if (!(minPtOut > 0n)) throw new Error("a buy needs a minimum PT out");
  const m = tradable(marketOf(market, conf));
  return encodeFunctionData({ abi: ROUTER_ABI, functionName: "swapExactTokenForPt", args: [getAddress(receiver), m.market, minPtOut, DEFAULT_APPROX,
    { tokenIn: conf.usdg, netTokenIn: usdgIn, tokenMintSy: conf.usdg, pendleSwap: ZERO, swapData: NONE_SWAP }, NO_LIMIT] });
}
/** PT in, USDG out to `receiver`, at least `minUsdgOut`. Before maturity, at the market's price; only an active market. */
export function buildSell({ receiver, ptIn, minUsdgOut, market }, conf = PENDLE) {
  if (!(minUsdgOut > 0n)) throw new Error("a sale needs a minimum USDG out");
  const m = tradable(marketOf(market, conf));
  return encodeFunctionData({ abi: ROUTER_ABI, functionName: "swapExactPtForToken", args: [getAddress(receiver), m.market, ptIn,
    { tokenOut: conf.usdg, minTokenOut: minUsdgOut, tokenRedeemSy: conf.usdg, pendleSwap: ZERO, swapData: NONE_SWAP }, NO_LIMIT] });
}
/** After maturity: PT in, USDG out 1:1 to `receiver` (the SY's own redemption; `minUsdgOut` is normally ptIn), on any listed market. */
export function buildRedeem({ receiver, ptIn, minUsdgOut, market }, conf = PENDLE) {
  if (!(minUsdgOut > 0n)) throw new Error("a redemption needs a minimum USDG out");
  const m = marketOf(market, conf);
  return encodeFunctionData({ abi: ROUTER_ABI, functionName: "redeemPyToToken", args: [getAddress(receiver), m.yt, ptIn,
    { tokenOut: conf.usdg, minTokenOut: minUsdgOut, tokenRedeemSy: conf.usdg, pendleSwap: ZERO, swapData: NONE_SWAP }] });
}

/**
 * The market's spot PT price in USDG (1e18 = par), read from Pendle's PY/LP oracle (`oracle`, default the market's);
 * then what an amount buys or sells for at that price, less a slippage margin. Duration 0 is the spot rate: Pendle's
 * TWAP needs the market's oracle cardinality raised first (ops/2026-10-05-pt-usdg-start.md).
 */
export async function ptRate(client, oracle, market) {
  const m = marketOf(market);
  return client.readContract({ address: getAddress(oracle || m.pyLpOracle), abi: ORACLE_ABI, functionName: "getPtToAssetRate", args: [m.market, 0] });
}
export function quoteBuy(usdgIn, rate, slippageBps = 100n) {
  const ptOut = (usdgIn * 10n ** 18n) / rate;
  return { ptOut, minPtOut: (ptOut * (10_000n - slippageBps)) / 10_000n };
}
export function quoteSell(ptIn, rate, slippageBps = 100n) {
  const usdgOut = (ptIn * rate) / 10n ** 18n;
  return { usdgOut, minUsdgOut: (usdgOut * (10_000n - slippageBps)) / 10_000n };
}
/** Whether `market` (default: the active one, else the latest) has matured at `nowS`. */
export const matured = (nowS, market) => nowS >= (market === undefined ? VIEW : marketOf(market)).expiry;

/**
 * The gas gate's check of one router call. Returns { kind: "buy" | "sell" | "redeem", usdgIn?, ptIn?, market, pt } for a
 * call of the one shape Priors builds above, for `sender` as the receiver, on a market `conf` lists: a buy or a sale only
 * on the active market before its expiry, a redemption on any listed market from its expiry on (`now`, seconds; default
 * the clock). Throws with the reason otherwise.
 */
export function checkRouterCall(data, sender, { now = Math.floor(Date.now() / 1000), conf = PENDLE } = {}) {
  let d;
  try { d = decodeFunctionData({ abi: ROUTER_ABI, data }); } catch (_) { throw new Error("Pendle: only buying, selling or redeeming PT-USDG"); }
  const f = d.functionName, x = d.args;
  if (!same(x[0], sender)) throw new Error("Pendle: the account itself must receive what the router pays out");
  const noSwap = (s) => { if (Number(s.swapType) !== 0 || !same(s.extRouter, ZERO) || (s.extCalldata && s.extCalldata !== "0x") || s.needScale) throw new Error("Pendle: no outside aggregator"); };
  const noLimit = (l) => { if (!same(l.limitRouter, ZERO) || l.normalFills.length || l.flashFills.length || (l.optData && l.optData !== "0x")) throw new Error("Pendle: no limit orders"); };
  const usdgOut = (o) => { if (!same(o.tokenOut, conf.usdg) || !same(o.tokenRedeemSy, conf.usdg) || !same(o.pendleSwap, ZERO)) throw new Error("Pendle: paid out in USDG only"); noSwap(o.swapData); if (!(o.minTokenOut > 0n)) throw new Error("Pendle: a minimum USDG out is required"); };
  const cap = (n, what) => { if (n > conf.maxUsdgPerOp) throw new Error(`Pendle: at most ${conf.maxUsdgPerOp / 1_000_000n} ${what} at a time`); };
  // a buy or a sale: a listed market, the active one, not yet matured
  const trading = (market) => {
    const m = conf.markets.find((e) => same(market, e.market));
    if (!m) throw new Error("Pendle: only a USDG market Priors lists");
    if (!m.active) throw new Error(`Pendle: the USDG market maturing ${m.maturity} is redeem-only: no buying or selling`);
    if (now >= m.expiry) throw new Error(`Pendle: the USDG market matured on ${m.maturity}: redeem its PT instead`);
    return m;
  };
  if (f === "swapExactTokenForPt") {
    const [, market, minPtOut, , input, limit] = x;
    const m = trading(market);
    if (!same(input.tokenIn, conf.usdg) || !same(input.tokenMintSy, conf.usdg) || !same(input.pendleSwap, ZERO)) throw new Error("Pendle: paid in USDG only");
    noSwap(input.swapData); noLimit(limit);
    if (!(minPtOut > 0n)) throw new Error("Pendle: a minimum PT out is required");
    cap(input.netTokenIn, "USDG");
    return { kind: "buy", usdgIn: input.netTokenIn, market: m.market, pt: m.pt };
  }
  if (f === "swapExactPtForToken") {
    const [, market, ptIn, output, limit] = x;
    const m = trading(market);
    usdgOut(output); noLimit(limit); cap(ptIn, "PT");
    return { kind: "sell", ptIn, market: m.market, pt: m.pt };
  }
  // redeemPyToToken: the YT names the market's PT; after maturity only PT is needed, so only from the expiry on
  const [, yt, ptIn, output] = x;
  const m = conf.markets.find((e) => same(yt, e.yt));
  if (!m) throw new Error("Pendle: only the PT of a USDG market Priors lists");
  if (now < m.expiry) throw new Error(`Pendle: PT-USDG of the market maturing ${m.maturity} redeems from that day; before it, sell it`);
  usdgOut(output);
  return { kind: "redeem", ptIn, market: m.market, pt: m.pt };
}
