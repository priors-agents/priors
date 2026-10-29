// Stock tokens bought with USDG, in one sponsored operation (Go mode's stock buy, web/account-zap.js; the gas gate's
// STOCK_ZAP rule, gas-worker/gate.mjs; docs/STOCK-ZAP-SPEC.md): the record (deployments/stock-zap.4663.json) checked and
// frozen, the two calls Priors builds, the gate's check of the swap, and a quote for node and the rigs.
//
// A buy is exactly two calls: USDG approved to the swap's spender for exactly the amount swapped, then the swap, the
// tokens paid to the account itself.
//   - a v4 pool (its key: the lower of USDG and the token, the higher, a static fee, its tick spacing, no hooks): Priors'
//     V4SwapOnce.swapExactIn(key, zeroForOne, amountIn, minOut, limit, to, deadline), zeroForOne = (currency0 == USDG),
//     the price limit at v4's extreme for that direction (it fills in full or reverts on minOut);
//   - a v3 pool: Uniswap's SwapRouter02.multicall(deadline, [exactInputSingle({ tokenIn: USDG, tokenOut: token, fee,
//     recipient: account, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0 })]) (multicall's deadline form:
//     exactInputSingle has none of its own).
// web/zap-core.js encodes the same calls without viem for the page; scripts/test-stock-zap.mjs holds the two byte for byte.
// A sale is the same two calls the other way, on the same pinned pools (docs/STOCK-ZAP-SPEC.md 15, "Selling"): the
// stock token approved to the swap's spender for exactly the amount sold, then the exact-input swap to USDG, paid to the
// account itself (v4: zeroForOne = (currency0 == the token), its own extreme limit; v3: tokenIn the token, tokenOut
// USDG). The gas gate sponsors buys only (checkZapCall): a sale is sent from the agent's own key (sdk/stock-trade.mjs).
//
//   ZAP                 the record, checked (zapConfig)
//   zapConfig(raw)      a record checked and frozen, or throws with the reason
//   v4Key, v4Id         a v4 pool's key (USDG, the token, fee, tick spacing; no hooks) and its id (keccak256 of the key)
//   buildBuy(o)         the two calls of a buy: [{ to, data } approve, { to, data } swap]
//   buildSell(o)        the two calls of a sale: [{ to, data } approve of the token, { to, data } swap to USDG]
//   checkZapCall        the gate's check of a stock swap call for `sender`: { kind, symbol, usdgIn, minOut, spender }, or
//                       throws with the reason ("stock buy: …")
//   swapKeyId(data)     the pool id a V4SwapOnce.swapExactIn names, or null (the gate routes by it)
//   quoteZap            the pinned pools' quotes for a buy, read at one block (node and the rigs)
import { decodeFunctionData, encodeAbiParameters, encodeFunctionData, getAddress, keccak256, parseAbi } from "viem";
import RECORD from "../deployments/stock-zap.4663.json" with { type: "json" };
import ASSETS from "../deployments/stock-assets.4663.json" with { type: "json" };

export const ZAP_RECORD_PATH = "deployments/stock-zap.4663.json";
const ZERO = "0x0000000000000000000000000000000000000000";
const KEY_T = "(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks)";
const EIS_T = "(address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)";
export const ERC20_ABI = parseAbi(["function approve(address spender, uint256 amount) returns (bool)", "function balanceOf(address) view returns (uint256)", "function allowance(address owner, address spender) view returns (uint256)"]);
export const SWAPPER_ABI = parseAbi([
  `function swapExactIn(${KEY_T} key, bool zeroForOne, uint128 amountIn, uint256 minOut, uint160 sqrtPriceLimitX96, address to, uint256 deadline) returns (uint256 paid, uint256 out)`,
  "error TooLittleOut(uint256 out, uint256 minOut)", "error Expired()",
]);
// SwapRouter02's deadline form of multicall, and the one call allowed inside it
export const ROUTER_ABI = parseAbi(["function multicall(uint256 deadline, bytes[] data) payable returns (bytes[] results)"]);
export const EXACT_INPUT_ABI = parseAbi([`function exactInputSingle(${EIS_T} params) payable returns (uint256 amountOut)`]);
export const V4_QUOTER_ABI = parseAbi([`function quoteExactInputSingle((${KEY_T} poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountOut, uint256 gasEstimate)`]);
export const V3_QUOTER_ABI = parseAbi(["function quoteExactInputSingle((address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96) params) returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)"]);
export const READS_ABI = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
  "function tokenPaused() view returns (bool)", "function paused() view returns (bool)", "function isBlocked(address) view returns (bool)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);
/** v4's TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: the extreme limits of a USDG-in swap, by direction. No price
 *  stops it early: it fills in full or reverts on its minimum out. */
export const MIN_SQRT_PRICE_LIMIT = 4295128740n;
export const MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341n;
export const limitFor = (zeroForOne) => (zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT);
const V3_FEES = new Set([100, 500, 3000, 10000]);
const DYNAMIC_FEE = 0x800000;

const same = (x, y) => { try { return !!x && !!y && getAddress(x) === getAddress(y); } catch (_) { return false; } };
const lowerFirst = (a, b) => (BigInt(a) < BigInt(b) ? [getAddress(a), getAddress(b)] : [getAddress(b), getAddress(a)]);

/** A v4 pool's key: the lower of USDG and the token as currency0, the higher as currency1, the fee and tick spacing, no
 *  hooks. */
export function v4Key(usdg, token, fee, tickSpacing) {
  const [currency0, currency1] = lowerFirst(usdg, token);
  return { currency0, currency1, fee: Number(fee), tickSpacing: Number(tickSpacing), hooks: ZERO };
}
/** A v4 pool's id: keccak256(abi.encode(key)), lower case. */
export const v4Id = (k) => keccak256(encodeAbiParameters([{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }], [getAddress(k.currency0), getAddress(k.currency1), Number(k.fee), Number(k.tickSpacing), getAddress(k.hooks)])).toLowerCase();

/** A record of deployments/stock-zap.4663.json's shape, checked and frozen; throws with the reason for one that is not:
 *  every address an address; every token one of stock-assets' (deployments/stock-assets.4663.json) at the same address,
 *  listed once; 1 to 3 pools a token and none for a token not offered; each v4 pool hookless with a static fee and its
 *  id its key's hash; each v3 fee a Uniswap tier; 0 < min ≤ max; the default slippage ≤ the max ≤ 500 bps; the
 *  deadline under its bound; the price impact's warning under its stop. */
export function zapConfig(raw, assets = ASSETS.assets) {
  const no = (why) => { throw new Error(`stock zap record: ${why}`); };
  const addr = (v, what) => { let a; try { a = getAddress(v); } catch (_) { no(`${what} is not an address`); } if (a === ZERO) no(`${what} is the zero address`); return a; };
  if (!raw || typeof raw !== "object") no("not an object");
  const usdg = addr(raw.usdg, "usdg"), registry = addr(raw.registry, "registry");
  const v4 = Object.freeze({ poolManager: addr(raw.v4 && raw.v4.poolManager, "v4.poolManager"), swapper: addr(raw.v4 && raw.v4.swapper, "v4.swapper"), quoter: addr(raw.v4 && raw.v4.quoter, "v4.quoter"), stateView: addr(raw.v4 && raw.v4.stateView, "v4.stateView") });
  const v3 = Object.freeze({ router: addr(raw.v3 && raw.v3.router, "v3.router"), quoter: addr(raw.v3 && raw.v3.quoter, "v3.quoter"), factory: addr(raw.v3 && raw.v3.factory, "v3.factory") });
  let min, max;
  try { min = BigInt(raw.minUsdgPerOp); max = BigInt(raw.maxUsdgPerOp); } catch (_) { no("minUsdgPerOp and maxUsdgPerOp must be whole numbers"); }
  if (!(min > 0n && min <= max)) no("the bounds must be 0 < minUsdgPerOp ≤ maxUsdgPerOp");
  const slips = Array.isArray(raw.slippageBps) ? raw.slippageBps.map(Number) : [];
  const def = Number(raw.defaultSlippageBps), maxSlip = Number(raw.maxSlippageBps);
  if (!(Number.isInteger(maxSlip) && maxSlip > 0 && maxSlip <= 500)) no("maxSlippageBps must be 1 to 500");
  if (!(Number.isInteger(def) && def > 0 && def <= maxSlip)) no("defaultSlippageBps must be above 0 and at most maxSlippageBps");
  if (!slips.length || !slips.every((s) => Number.isInteger(s) && s > 0 && s <= maxSlip) || !slips.includes(def)) no("slippageBps must be choices up to maxSlippageBps, the default among them");
  const deadlineS = Number(raw.deadlineS), maxDeadlineS = Number(raw.maxDeadlineS);
  if (!(Number.isInteger(deadlineS) && deadlineS > 0 && deadlineS < maxDeadlineS)) no("deadlineS must be above 0 and under maxDeadlineS");
  const warn = Number(raw.impactWarnBps), stop = Number(raw.impactStopBps);
  if (!(Number.isInteger(warn) && Number.isInteger(stop) && warn > 0 && warn < stop && stop < 10_000)) no("impactWarnBps must be under impactStopBps");
  const bySym = new Map(assets.map((a) => [a.symbol, a]));
  const notOffered = raw.notOffered && typeof raw.notOffered === "object" ? raw.notOffered : {};
  for (const s of Object.keys(notOffered)) if (!bySym.has(s)) no(`${s} (not offered) is not a listed stock token`);
  if (!Array.isArray(raw.tokens) || !raw.tokens.length) no("no tokens");
  const seen = new Set(), v4ById = new Map(), v3ByPair = new Map(), v3ByPool = new Map();
  const tokens = raw.tokens.map((t) => {
    const a = t && bySym.get(t.symbol);
    if (!a) no(`${t && t.symbol} is not one of the listed stock tokens`);
    if (seen.has(t.symbol)) no(`${t.symbol} is listed twice`);
    seen.add(t.symbol);
    if (Object.prototype.hasOwnProperty.call(notOffered, t.symbol)) no(`${t.symbol} is not offered, yet has pools`);
    const token = addr(t.token, `${t.symbol}'s token`);
    if (token !== getAddress(a.token)) no(`${t.symbol}'s token is not stock-assets' ${a.token}`);
    if (!Array.isArray(t.pools) || t.pools.length < 1 || t.pools.length > 3) no(`${t.symbol} must have 1 to 3 pools`);
    const pools = t.pools.map((p) => {
      if (p.v === 4) {
        if (p.hooks !== undefined && !same(p.hooks, ZERO)) no(`${t.symbol}: a v4 pool with hooks`);
        const fee = Number(p.fee), ts = Number(p.tickSpacing);
        if (!(Number.isInteger(fee) && fee >= 0 && fee < DYNAMIC_FEE)) no(`${t.symbol}: a v4 pool's fee must be static (under 0x800000)`);
        if (!(Number.isInteger(ts) && ts >= 1 && ts <= 32767)) no(`${t.symbol}: a v4 pool's tick spacing must be 1 to 32767`);
        const key = Object.freeze(v4Key(usdg, token, fee, ts)), id = v4Id(key);
        if (String(p.id).toLowerCase() !== id) no(`${t.symbol}: a v4 pool's id is not its key's hash`);
        if (v4ById.has(id)) no(`${t.symbol}: a v4 pool listed twice`);
        const pool = Object.freeze({ v: 4, symbol: t.symbol, token, fee, tickSpacing: ts, id, key, zeroForOne: same(key.currency0, usdg) });
        v4ById.set(id, pool);
        return pool;
      }
      if (p.v === 3) {
        const fee = Number(p.fee);
        if (!V3_FEES.has(fee)) no(`${t.symbol}: a v3 fee must be 100, 500, 3000 or 10000`);
        const pool = Object.freeze({ v: 3, symbol: t.symbol, token, fee, pool: addr(p.pool, `${t.symbol}'s v3 pool`), zeroForOne: BigInt(usdg) < BigInt(token) });
        const pair = `${token.toLowerCase()}:${fee}`;
        if (v3ByPair.has(pair)) no(`${t.symbol}: a v3 pool listed twice`);
        v3ByPair.set(pair, pool); v3ByPool.set(pool.pool.toLowerCase(), pool);
        return pool;
      }
      return no(`${t.symbol}: a pool must be v 3 or 4`);
    });
    return Object.freeze({ symbol: t.symbol, name: a.name, token, decimals: Number(a.decimals), feed: getAddress(a.feed), feedDecimals: Number(a.feedDecimals), pools: Object.freeze(pools) });
  });
  return Object.freeze({
    chainId: Number(raw.chainId) || 4663, usdg, registry, v4, v3, minUsdgPerOp: min, maxUsdgPerOp: max,
    slippageBps: Object.freeze(slips), defaultSlippageBps: def, maxSlippageBps: maxSlip, deadlineS, maxDeadlineS, impactWarnBps: warn, impactStopBps: stop,
    tokens: Object.freeze(tokens), bySymbol: new Map(tokens.map((t) => [t.symbol, t])), v4ById, v3ByPair, v3ByPool, notOffered: Object.freeze({ ...notOffered }),
  });
}

export const ZAP = zapConfig(RECORD);

/** minOut: `out` less `slippageBps`, rounded down; a slippage above the record's cap is refused. */
export function minOutOf(out, slippageBps, conf = ZAP) {
  const s = Number(slippageBps);
  if (!(Number.isInteger(s) && s > 0 && s <= conf.maxSlippageBps)) throw new Error(`stock buy: slippage is at most ${conf.maxSlippageBps / 100}%`);
  return (BigInt(out) * BigInt(10_000 - s)) / 10_000n;
}

/** The two calls of a buy of `symbol` on `pool` (one of its record pools: the object, its id or its address): USDG
 *  approved to that pool's spender for exactly `usdgIn`, then the swap for at least `minOut`, paid to `account`, by
 *  `deadline` (unix seconds). [{ to, data }, { to, data }]. */
/** One of token `t`'s record pools: the object, its v4 id or its v3 address; or undefined. */
export const pinnedPool = (t, pool) => t.pools.find((x) => x === pool || (x.v === 4 && String(pool).toLowerCase() === x.id) || (x.v === 3 && same(pool, x.pool)));

export function buildBuy({ account, symbol, pool, usdgIn, minOut, deadline }, conf = ZAP) {
  const t = conf.bySymbol.get(symbol);
  if (!t) throw new Error(`stock buy: ${symbol} is not offered`);
  const p = pinnedPool(t, pool);
  if (!p) throw new Error(`stock buy: not a pool of ${symbol} in the record`);
  usdgIn = BigInt(usdgIn); minOut = BigInt(minOut);
  if (usdgIn < conf.minUsdgPerOp || usdgIn > conf.maxUsdgPerOp) throw new Error("stock buy: the amount is out of bounds");
  if (!(minOut > 0n)) throw new Error("stock buy: a minimum out is required");
  const to = getAddress(account), dl = BigInt(deadline);
  const spender = p.v === 4 ? conf.v4.swapper : conf.v3.router;
  const approve = { to: conf.usdg, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [spender, usdgIn] }) };
  if (p.v === 4) return [approve, { to: spender, data: encodeFunctionData({ abi: SWAPPER_ABI, functionName: "swapExactIn", args: [p.key, p.zeroForOne, usdgIn, minOut, limitFor(p.zeroForOne), to, dl] }) }];
  const inner = encodeFunctionData({ abi: EXACT_INPUT_ABI, functionName: "exactInputSingle", args: [{ tokenIn: conf.usdg, tokenOut: t.token, fee: p.fee, recipient: to, amountIn: usdgIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }] });
  return [approve, { to: spender, data: encodeFunctionData({ abi: ROUTER_ABI, functionName: "multicall", args: [dl, [inner]] }) }];
}

/** The two calls of a sale of `amountIn` (the token's base units) of `symbol` on `pool` (one of its record pools: the
 *  object, its id or its address): the token approved to that pool's spender for exactly `amountIn`, then the swap for
 *  at least `minOut` USDG, paid to `account`, by `deadline` (unix seconds). [{ to, data }, { to, data }]. The size of a
 *  sale in USDG is the planner's to bound (sdk/stock-trade.mjs): only the quote knows it. */
export function buildSell({ account, symbol, pool, amountIn, minOut, deadline }, conf = ZAP) {
  const t = conf.bySymbol.get(symbol);
  if (!t) throw new Error(`stock sell: ${symbol} is not offered`);
  const p = pinnedPool(t, pool);
  if (!p) throw new Error(`stock sell: not a pool of ${symbol} in the record`);
  amountIn = BigInt(amountIn); minOut = BigInt(minOut);
  if (!(amountIn > 0n && amountIn < 2n ** 128n)) throw new Error("stock sell: the amount is out of bounds");
  if (!(minOut > 0n)) throw new Error("stock sell: a minimum out is required");
  const to = getAddress(account), dl = BigInt(deadline);
  const spender = p.v === 4 ? conf.v4.swapper : conf.v3.router;
  const approve = { to: t.token, data: encodeFunctionData({ abi: ERC20_ABI, functionName: "approve", args: [spender, amountIn] }) };
  // the token in: on v4, zeroForOne exactly when the token is currency0, at that direction's extreme limit
  if (p.v === 4) { const z = !p.zeroForOne; return [approve, { to: spender, data: encodeFunctionData({ abi: SWAPPER_ABI, functionName: "swapExactIn", args: [p.key, z, amountIn, minOut, limitFor(z), to, dl] }) }]; }
  const inner = encodeFunctionData({ abi: EXACT_INPUT_ABI, functionName: "exactInputSingle", args: [{ tokenIn: t.token, tokenOut: conf.usdg, fee: p.fee, recipient: to, amountIn, amountOutMinimum: minOut, sqrtPriceLimitX96: 0n }] });
  return [approve, { to: spender, data: encodeFunctionData({ abi: ROUTER_ABI, functionName: "multicall", args: [dl, [inner]] }) }];
}

/** The pool id a V4SwapOnce.swapExactIn call names (lower case), or null when `data` is not one. */
export function swapKeyId(data) {
  try { const d = decodeFunctionData({ abi: SWAPPER_ABI, data }); return d.functionName === "swapExactIn" ? v4Id(d.args[0]) : null; } catch (_) { return null; }
}

/** The gate's check of a stock swap call to `to` (V4SwapOnce or SwapRouter02) for `sender`: the one function, exactly
 *  re-encoded, a record pool, USDG in, the account itself paid, a minimum out above 0, no price limit short of a full
 *  fill, 0 < amountIn ≤ maxUsdgPerOp, now < deadline ≤ now + maxDeadlineS. Returns { kind ("v4" | "v3"), symbol, usdgIn,
 *  minOut, spender }; throws with the reason. */
export function checkZapCall(to, data, sender, { now = Math.floor(Date.now() / 1000), conf = ZAP } = {}) {
  const bounds = (amountIn, deadline) => {
    if (!(amountIn > 0n)) throw new Error("stock buy: no USDG in");
    if (amountIn > conf.maxUsdgPerOp) throw new Error(`stock buy: at most ${conf.maxUsdgPerOp / 1_000_000n} USDG a buy`);
    if (deadline <= BigInt(now) || deadline > BigInt(now + conf.maxDeadlineS)) throw new Error(`stock buy: the deadline must be ahead, at most ${conf.maxDeadlineS} s`);
  };
  const exact = (abi, d, raw) => { if (encodeFunctionData({ abi, functionName: d.functionName, args: d.args }).toLowerCase() !== String(raw).toLowerCase()) throw new Error("stock buy: malformed call"); };
  if (same(to, conf.v4.swapper)) {
    let d;
    try { d = decodeFunctionData({ abi: SWAPPER_ABI, data }); } catch (_) { throw new Error("stock buy: only V4SwapOnce's swapExactIn"); }
    if (d.functionName !== "swapExactIn") throw new Error("stock buy: only V4SwapOnce's swapExactIn");
    exact(SWAPPER_ABI, d, data);
    const [key, zeroForOne, amountIn, minOut, limit, recipient, deadline] = d.args;
    const p = conf.v4ById.get(v4Id(key));
    if (!p) throw new Error("stock buy: only the record's pools");
    if (zeroForOne !== p.zeroForOne) throw new Error("stock buy: USDG in, the stock token out only");
    if (!same(recipient, sender)) throw new Error("stock buy: the account itself must receive the tokens");
    if (!(minOut > 0n)) throw new Error("stock buy: a minimum out is required");
    if (limit !== limitFor(p.zeroForOne)) throw new Error("stock buy: the swap must fill in full (no price limit)");
    bounds(amountIn, deadline);
    return { kind: "v4", symbol: p.symbol, usdgIn: amountIn, minOut, spender: conf.v4.swapper };
  }
  if (same(to, conf.v3.router)) {
    let d, e;
    try { d = decodeFunctionData({ abi: ROUTER_ABI, data }); } catch (_) { throw new Error("stock buy: only SwapRouter02's multicall(deadline, [exactInputSingle])"); }
    exact(ROUTER_ABI, d, data);
    const [deadline, calls] = d.args;
    if (calls.length !== 1) throw new Error("stock buy: one exactInputSingle in the multicall");
    try { e = decodeFunctionData({ abi: EXACT_INPUT_ABI, data: calls[0] }); } catch (_) { throw new Error("stock buy: only exactInputSingle inside the multicall"); }
    exact(EXACT_INPUT_ABI, e, calls[0]);
    const x = e.args[0];
    if (!same(x.tokenIn, conf.usdg)) throw new Error("stock buy: USDG in, the stock token out only");
    const p = conf.v3ByPair.get(`${String(x.tokenOut).toLowerCase()}:${Number(x.fee)}`);
    if (!p) throw new Error("stock buy: only the record's pools");
    if (!same(x.recipient, sender)) throw new Error("stock buy: the account itself must receive the tokens");
    if (!(x.amountOutMinimum > 0n)) throw new Error("stock buy: a minimum out is required");
    if (x.sqrtPriceLimitX96 !== 0n) throw new Error("stock buy: the swap must fill in full (no price limit)");
    bounds(x.amountIn, deadline);
    return { kind: "v3", symbol: p.symbol, usdgIn: x.amountIn, minOut: x.amountOutMinimum, spender: conf.v3.router };
  }
  throw new Error("stock buy: not a stock buy's contract");
}

const Q96 = 2n ** 96n;
/** Price impact in bps (floored at 0): 1 − out / ideal, where ideal is usdgIn less the pool's fee at the pool's price
 *  now (sqrtPriceX96: token1 per token0 in raw units), in bigints. */
export function impactBps({ usdgIn, out, sqrtPriceX96, fee, usdgIsToken0 }) {
  const s2 = BigInt(sqrtPriceX96) ** 2n, net = BigInt(usdgIn) * (1_000_000n - BigInt(fee));
  if (s2 === 0n || net <= 0n) return 0;
  // ideal = num / den
  const [num, den] = usdgIsToken0 ? [net * s2, 1_000_000n * Q96 * Q96] : [net * Q96 * Q96, 1_000_000n * s2];
  const gap = num - BigInt(out) * den;
  return gap <= 0n ? 0 : Number((gap * 10_000n) / num);
}

/** The pinned pools' quotes for a buy of `usdgIn` USDG of `symbol`, read at one block (the latest when asked):
 *  { block, at, best: { pool, out, minOut, impactBps } | null, quotes: [{ pool, out | null }], answer, updatedAt,
 *  paused, allPaused, blocked, usdg, held }. `client` is a viem public client. A token not in the record is refused
 *  before any read. */
export async function quoteZap(client, { symbol, usdgIn, account = null, slippageBps = null }, conf = ZAP) {
  const t = conf.bySymbol.get(symbol);
  if (!t) throw new Error(`stock buy: ${symbol} is not offered`);
  usdgIn = BigInt(usdgIn);
  const b = await client.getBlock();
  const blockNumber = b.number;
  const who = account ? getAddress(account) : ZERO;
  const contracts = [
    { address: conf.usdg, abi: ERC20_ABI, functionName: "balanceOf", args: [who] },
    { address: t.token, abi: ERC20_ABI, functionName: "balanceOf", args: [who] },
    { address: t.token, abi: READS_ABI, functionName: "tokenPaused" },
    { address: conf.registry, abi: READS_ABI, functionName: "paused" },
    { address: conf.registry, abi: READS_ABI, functionName: "isBlocked", args: [who] },
    { address: t.feed, abi: READS_ABI, functionName: "latestRoundData" },
    ...t.pools.map((p) => (p.v === 4 ? { address: conf.v4.stateView, abi: READS_ABI, functionName: "getSlot0", args: [p.id] } : { address: p.pool, abi: READS_ABI, functionName: "slot0" })),
  ];
  const r = await client.multicall({ contracts, allowFailure: true, blockNumber });
  const v = (i) => (r[i] && r[i].status === "success" ? r[i].result : null);
  const quotes = await Promise.all(t.pools.map(async (p, i) => {
    try {
      const out = p.v === 4
        ? (await client.simulateContract({ address: conf.v4.quoter, abi: V4_QUOTER_ABI, functionName: "quoteExactInputSingle", args: [{ poolKey: p.key, zeroForOne: p.zeroForOne, exactAmount: usdgIn, hookData: "0x" }], blockNumber })).result[0]
        : (await client.simulateContract({ address: conf.v3.quoter, abi: V3_QUOTER_ABI, functionName: "quoteExactInputSingle", args: [{ tokenIn: conf.usdg, tokenOut: t.token, amountIn: usdgIn, fee: p.fee, sqrtPriceLimitX96: 0n }], blockNumber })).result[0];
      const s0 = v(6 + i);
      return { pool: p, out, impactBps: s0 ? impactBps({ usdgIn, out, sqrtPriceX96: s0[0], fee: p.fee, usdgIsToken0: p.zeroForOne }) : null };
    } catch (_) { return { pool: p, out: null, impactBps: null }; }
  }));
  const ok = quotes.filter((q) => q.out !== null && q.out > 0n);
  const best = ok.length ? ok.reduce((a, q) => (q.out > a.out ? q : a)) : null;
  const round = v(5);
  return {
    block: blockNumber, at: Number(b.timestamp), symbol, usdgIn, quotes,
    best: best ? { ...best, minOut: minOutOf(best.out, slippageBps ?? conf.defaultSlippageBps, conf) } : null,
    answer: round ? round[1] : null, updatedAt: round ? Number(round[3]) : null,
    paused: v(2), allPaused: v(3), blocked: account ? v(4) : null, usdg: account ? v(0) : null, held: account ? v(1) : null,
  };
}
