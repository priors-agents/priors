// PT-USDG for agents and builders: quote, buy, sell and redeem Pendle's principal token for USDG on Robinhood Chain
// (chain 4663; the markets of deployments/pendle.4663.json: the active one, maturing 2027-03-25 today, and any earlier
// one kept for redemption), and read a wallet's position, through the same router calls the gas gate checks
// (sdk/pendle-pt.mjs builds them; this module only adds the reads, the approvals and the sending).
//
//   import { ptQuote, ptBuy, ptSell, ptRedeem, ptPosition } from "./sdk/pt-usdg.mjs";
//   const rpc = "https://rpc.mainnet.chain.robinhood.com";            // or a viem PublicClient, an ethers provider
//   await ptQuote(rpc, { side: "buy", amount: 100 });                  // 100 USDG -> PT, at the oracle's spot price
//   const { calls } = await ptBuy(rpc, { account, amount: 100 });     // [approve USDG, router call]: { to, data, value }
//   await ptBuy(rpc, { amount: 100, wallet });                         // or send them (a viem WalletClient or an ethers Signer)
//   await ptSell(rpc, { account, amount: "50.5" });                    // PT -> USDG at the market, before maturity
//   await ptRedeem(rpc, { account, amount: "all" });                   // PT -> USDG 1:1, from its maturity (any listed market)
//   await ptPosition(rpc, account);                                    // balance, value now, days left, implied fixed APY
//
// Markets: buys, sales and quotes are on the active market (PT_USDG); a redemption takes `market` (a market, PT or YT
// address from PT_MARKETS), or by default the oldest matured market the account holds PT of. ptPosition lists the
// account's PT of every listed market (`markets`), so PT of a matured, redeem-only market shows with its Redeem.
//
// PriorsV2 (sdk/priors-v2.mjs) carries the same as methods: p.ptQuote, p.ptBuy, p.ptSell, p.ptRedeem, p.ptPosition, and
// p.openPtLine(agentId, amount) to post PT-USDG behind an agent's line once the stock vault lists it.
//
// Amounts: a number or a decimal string is whole USDG or PT ("12.5"); a bigint is raw 6-decimal units; "all" (sell,
// redeem) is the account's whole PT balance. Each trade names a minimum out (the quote less `slippageBps`, 1% by
// default): the router reverts rather than fill worse. The quote is the oracle's spot price, before the trade's own
// price impact (about 0.1% per 1,000 USDG on 2026-10-01): a large trade may need a wider slippage or several trades.
// Every approval is for exactly the amount of the trade after it, the shape the gas gate sponsors; a call bundle is
// sponsorable when its amount is within PT_USDG.maxUsdgPerOp (2,000).
import { formatUnits, getAddress, parseUnits, encodeFunctionData, decodeFunctionResult } from "viem";
import { PENDLE, PENDLE_ADDR, ORACLE_ABI, PT_ABI, buildBuy, buildSell, buildRedeem, quoteBuy, quoteSell, marketOf, maturedMarkets } from "./pendle-pt.mjs";
import PT from "../deployments/pt-usdg.4663.json" with { type: "json" };

const YEAR = 365 * 86400;
const ZERO = "0x0000000000000000000000000000000000000000";
const VAULT_ASSET_ABI = [{ type: "function", name: "assets", stateMutability: "view", inputs: [{ name: "token", type: "address" }],
  outputs: [{ name: "feed", type: "address" }, { name: "maxAge", type: "uint64" }, { name: "tokenDecimals", type: "uint8" }, { name: "feedDecimals", type: "uint8" },
    { name: "enabled", type: "bool" }, { name: "ltvBps", type: "uint16" }, { name: "lineCap", type: "uint128" }] },
  { type: "function", name: "openLinesOf", stateMutability: "view", inputs: [{ name: "token", type: "address" }], outputs: [{ name: "", type: "uint256" }] }];

const iso = (expiry) => new Date(expiry * 1000).toISOString().replace(".000Z", "Z");
const VIEW = marketOf(PENDLE_ADDR.market);
/** Every listed market, oldest first (deployments/pendle.4663.json): its token, addresses, maturity and status. */
export const PT_MARKETS = Object.freeze(PENDLE.markets.map((m) => Object.freeze({
  token: m.pt, market: m.market, yt: m.yt, sy: m.sy, oracle: m.pyLpOracle, expiry: m.expiry, maturity: iso(m.expiry), status: m.status,
})));
/** The token of the active market, its market and where Priors posts it (deployments/pendle.4663.json, deployments/pt-usdg.4663.json). */
export const PT_USDG = Object.freeze({
  chainId: 4663, symbol: "PT-USDG", decimals: 6,
  token: PENDLE_ADDR.pt, market: PENDLE_ADDR.market, router: PENDLE_ADDR.router, usdg: PENDLE_ADDR.usdg, yt: PENDLE_ADDR.yt, sy: PENDLE_ADDR.sy,
  oracle: VIEW.pyLpOracle, stockVault: getAddress(PT.stockVault), status: VIEW.status,
  expiry: PENDLE_ADDR.expiry, maturity: iso(PENDLE_ADDR.expiry),
  maxUsdgPerOp: PENDLE_ADDR.maxUsdgPerOp,
  // the owner's launch settings for the stock vault (docs/PT-USDG.md): planned until the Safe's setAsset, then read from the vault
  planned: Object.freeze({ ltvBps: Number(PT.setAsset.ltvBps), lineCap: BigInt(PT.setAsset.lineCap) }),
});

// ---- the chain: a URL, a viem client, an EIP-1193 provider or an ethers provider/signer ----

let rpcId = 0;
/** One JSON-RPC request through whatever `client` is. */
export async function rpc(client, method, params = []) {
  if (typeof client === "string") {
    const res = await fetch(client, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }) });
    if (!res.ok) throw new Error(`${method}: the RPC answered HTTP ${res.status}`);
    const j = await res.json();
    if (j.error) { const e = new Error(`${method}: ${j.error.message || "RPC error"}`); e.data = j.error.data; throw e; }
    return j.result;
  }
  if (client && typeof client.request === "function") return client.request({ method, params }); // viem, EIP-1193
  if (client && typeof client.send === "function" && typeof client.getNetwork === "function") return client.send(method, params); // ethers JsonRpcProvider
  if (client && client.provider && client.provider !== client) return rpc(client.provider, method, params); // an ethers signer
  if (client && typeof client.call === "function" && method === "eth_call") return client.call(params[0]); // any ethers provider
  throw new Error("give an RPC URL, a viem client, an EIP-1193 provider or an ethers provider");
}
async function read(client, address, abi, functionName, args = [], from) {
  const data = encodeFunctionData({ abi, functionName, args });
  const out = await rpc(client, "eth_call", [{ to: address, data, ...(from ? { from } : {}) }, "latest"]);
  return decodeFunctionResult({ abi, functionName, data: typeof out === "string" ? out : out.data });
}
async function chainNow(client) {
  try { const b = await rpc(client, "eth_getBlockByNumber", ["latest", false]); if (b && b.timestamp != null) return Number(BigInt(b.timestamp)); } catch (_) { /* the clock below */ }
  return Math.floor(Date.now() / 1000);
}

// ---- figures ----

/** `amount` in 6-decimal units: a bigint is raw, a number or a decimal string is whole tokens. */
export function ptUnits(amount) {
  if (typeof amount === "bigint") { if (amount <= 0n) throw new Error("the amount must be above zero"); return amount; }
  const s = typeof amount === "number" ? amount.toFixed(6).replace(/\.?0+$/, "") : String(amount ?? "").trim();
  if (!/^\d+(\.\d{1,6})?$/.test(s)) throw new Error(`not an amount of USDG or PT (6 decimals at most): ${String(amount).slice(0, 40)}`);
  const u = parseUnits(s, 6);
  if (u <= 0n) throw new Error("the amount must be above zero");
  return u;
}
const fmt6 = (u) => formatUnits(u, 6);
const bps = (n) => { const b = BigInt(n); if (b < 0n || b >= 10_000n) throw new Error("slippageBps is between 0 and 9999"); return b; };

/**
 * The fixed yield a buyer at `rate` (USDG per PT, 1e18 = par) locks in to maturity, `secondsLeft` away: an annual
 * rate, compounded, as Pendle states its implied APY ((1 / price) ^ (1 year / time left) - 1). 0 at or after maturity.
 */
export function impliedApy(rate, secondsLeft) {
  const r = Number(rate) / 1e18;
  if (!(secondsLeft > 0) || !(r > 0)) return 0;
  return Math.pow(1 / r, YEAR / secondsLeft) - 1;
}
const pct = (x) => `${(x * 100).toFixed(2)}%`;

/** A listed market's spot price of PT in USDG (1e18 = par) from Pendle's PY/LP oracle (`market` default: the active
 *  one); par from its maturity on. */
export async function ptRateOf(client, { now, market } = {}) {
  const m = marketOf(market ?? PT_USDG.market);
  const t = now ?? (await chainNow(client));
  if (t >= m.expiry) return { rate: 10n ** 18n, now: t };
  return { rate: await read(client, m.pyLpOracle, ORACLE_ABI, "getPtToAssetRate", [m.market, 0]), now: t };
}
function terms(rate, now, m = VIEW) {
  const left = Math.max(0, m.expiry - now);
  const apy = impliedApy(rate, left);
  return { rate, price: Number(rate) / 1e18, matured: left === 0, maturity: iso(m.expiry), daysToMaturity: Math.ceil(left / 86400), impliedApy: apy, impliedApyText: pct(apy),
    market: m.market, token: m.pt, status: m.status };
}
/** The market a redemption takes when none is named: the oldest matured market `holds` (address -> PT) has any of,
 *  else the latest matured one, else the active one (whose quote then says to sell before maturity). */
function redeemMarket(now, holds) {
  const due = maturedMarkets(now);
  return due.find((m) => holds && holds(m.pt) > 0n) || due[due.length - 1] || VIEW;
}

/**
 * What a trade gives now, from the oracle's spot price: `side` "buy" (USDG in, PT out), "sell" (PT in, USDG out, before
 * maturity) or "redeem" (PT in, USDG out 1:1, from maturity). Amounts are 6-decimal bigints, with their text alongside.
 */
export async function ptQuote(client, { side = "buy", amount, slippageBps, now, market } = {}) {
  if (!["buy", "sell", "redeem"].includes(side)) throw new Error('side is "buy", "sell" or "redeem"');
  const units = ptUnits(amount);
  const t0 = now ?? (await chainNow(client));
  const m = market != null ? marketOf(market) : side === "redeem" ? redeemMarket(t0) : VIEW;
  if (side !== "redeem" && !m.active) throw new Error(`the PT-USDG market maturing ${iso(m.expiry)} is redeem-only: redeem its PT from then on${PENDLE.active ? `, or buy and sell on the market maturing ${iso(PENDLE.active.expiry)}` : ""}`);
  const { rate, now: t } = await ptRateOf(client, { now: t0, market: m.market });
  const info = terms(rate, t, m);
  if (side !== "redeem" && info.matured) throw new Error(`PT-USDG matured on ${info.maturity}: redeem it 1:1 for USDG instead`);
  if (side === "redeem" && !info.matured) throw new Error(`PT-USDG redeems 1:1 from ${info.maturity}; before that, sell it`);
  const slip = bps(slippageBps ?? (side === "redeem" ? 10 : 100));
  let out, min;
  if (side === "buy") ({ ptOut: out, minPtOut: min } = quoteBuy(units, rate, slip));
  else if (side === "sell") ({ usdgOut: out, minUsdgOut: min } = quoteSell(units, rate, slip));
  else { out = units; min = (units * (10_000n - slip)) / 10_000n; }
  if (min <= 0n) throw new Error("the amount is too small to name a minimum out");
  const tokenIn = side === "buy" ? "USDG" : "PT-USDG", tokenOut = side === "buy" ? "PT-USDG" : "USDG";
  return {
    side, tokenIn, tokenOut, amountIn: units, expectedOut: out, minOut: min, slippageBps: Number(slip),
    amountInText: fmt6(units), expectedOutText: fmt6(out), minOutText: fmt6(min), ...info,
    // a buy held to maturity: what it pays then (1 PT = 1 USDG), and the gain over what it cost
    ...(side === "buy" ? { atMaturity: out, atMaturityText: fmt6(out), fixedGainText: fmt6(out - units) } : {}),
    sponsorable: units <= PT_USDG.maxUsdgPerOp,
  };
}

// ---- the calls ----

const approveData = (spender, amount) => encodeFunctionData({ abi: PT_ABI, functionName: "approve", args: [spender, amount] });
const call = (to, data, what) => ({ to: getAddress(to), data, value: 0n, what });

async function accountOf(account, wallet) {
  if (account) return getAddress(account);
  if (wallet && wallet.account && wallet.account.address) return getAddress(wallet.account.address); // viem WalletClient
  if (wallet && typeof wallet.getAddress === "function") return getAddress(await wallet.getAddress()); // ethers Signer
  throw new Error("give the account that signs (account) or a wallet to send with");
}

/** Wait for `hash` and check it succeeded. */
async function receipt(client, hash, { timeoutMs = 180_000 } = {}) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const rc = await rpc(client, "eth_getTransactionReceipt", [hash]);
    if (rc) { if (rc.status !== "0x1" && rc.status !== 1 && rc.status !== "success") throw new Error(`transaction ${hash} reverted`); return rc; }
    if (Date.now() > end) throw new Error(`transaction ${hash} not mined after ${timeoutMs / 1000} s`);
    await new Promise((r) => setTimeout(r, 1500));
  }
}

/** Send `calls` in order from `wallet`, each simulated first, each waited for: the hashes. */
export async function sendCalls(client, wallet, calls, from) {
  const hashes = [];
  for (const c of calls) {
    try { await rpc(client, "eth_call", [{ from, to: c.to, data: c.data }, "latest"]); } catch (e) { throw new Error(`${c.what || "the call"} would revert: ${e.shortMessage || e.message}`); }
    let hash;
    if (wallet.account && typeof wallet.sendTransaction === "function" && !wallet.getAddress) {
      hash = await wallet.sendTransaction({ account: wallet.account, chain: wallet.chain ?? null, to: c.to, data: c.data, value: c.value });
    } else {
      const tx = await wallet.sendTransaction({ to: c.to, data: c.data, value: c.value });
      hash = tx.hash;
    }
    await receipt(client, hash);
    hashes.push(hash);
  }
  return hashes;
}

async function bundle(client, { kind, account, wallet, amount, slippageBps, minOut, approve = "auto", now, market }) {
  const from = await accountOf(account, wallet);
  const t = now ?? (await chainNow(client));
  let m = market != null ? marketOf(market) : VIEW;
  if (kind === "redeem" && market == null) {
    // the oldest matured market the account holds PT of (each matured market's balance read once)
    const due = maturedMarkets(t), held = new Map();
    for (const d of due) held.set(d.pt, await read(client, d.pt, PT_ABI, "balanceOf", [from]));
    m = redeemMarket(t, (pt) => held.get(pt) ?? 0n);
  }
  let units;
  if (amount === "all") {
    if (kind === "buy") throw new Error('"all" is for selling or redeeming PT');
    units = await read(client, m.pt, PT_ABI, "balanceOf", [from]);
    if (units === 0n) throw new Error(`${from} holds no PT-USDG${m.market === VIEW.market ? "" : ` of the market maturing ${iso(m.expiry)}`}`);
  } else units = ptUnits(amount);
  const q = await ptQuote(client, { side: kind, amount: units, slippageBps, now: t, market: m.market });
  const min = minOut != null ? ptUnits(minOut) : q.minOut;
  const payToken = kind === "buy" ? PT_USDG.usdg : m.pt;
  const [have, allowed] = await Promise.all([
    read(client, payToken, PT_ABI, "balanceOf", [from]),
    approve === "auto" ? read(client, payToken, PT_ABI, "allowance", [from, PT_USDG.router]) : Promise.resolve(approve === "always" ? 0n : units),
  ]);
  const warnings = [];
  if (have < units) warnings.push(`${from} holds ${fmt6(have)} ${kind === "buy" ? "USDG" : "PT-USDG"}, less than the ${fmt6(units)} this trade takes`);
  if (!q.sponsorable) warnings.push(`above ${fmt6(PT_USDG.maxUsdgPerOp)}: Priors' gas sponsorship takes at most that much a trade (your own gas is fine)`);
  const data = kind === "buy" ? buildBuy({ receiver: from, usdgIn: units, minPtOut: min, market: m.market })
    : kind === "sell" ? buildSell({ receiver: from, ptIn: units, minUsdgOut: min, market: m.market })
    : buildRedeem({ receiver: from, ptIn: units, minUsdgOut: min, market: m.market });
  const calls = [
    ...(allowed < units ? [call(payToken, approveData(PT_USDG.router, units), `approve ${fmt6(units)} ${kind === "buy" ? "USDG" : "PT-USDG"} to Pendle's router`)] : []),
    call(PT_USDG.router, data, kind === "buy" ? `buy at least ${fmt6(min)} PT-USDG with ${fmt6(units)} USDG` : kind === "sell" ? `sell ${fmt6(units)} PT-USDG for at least ${fmt6(min)} USDG` : `redeem ${fmt6(units)} PT-USDG for at least ${fmt6(min)} USDG`),
  ];
  const out = { kind, account: from, chainId: PT_USDG.chainId, quote: { ...q, minOut: min, minOutText: fmt6(min) }, calls, warnings };
  if (!wallet) return out;
  if (have < units) throw new Error(warnings[0]);
  return { ...out, hashes: await sendCalls(client, wallet, calls, from) };
}

/** Buy PT-USDG with `amount` USDG: the calls (approve, then the router's swap), sent when `wallet` is given. */
export const ptBuy = (client, o = {}) => bundle(client, { ...o, kind: "buy" });
/** Sell `amount` PT-USDG (or "all") for USDG at the market, before maturity. */
export const ptSell = (client, o = {}) => bundle(client, { ...o, kind: "sell" });
/** Redeem `amount` PT-USDG (or "all") for USDG 1:1, from maturity on: of `market` (a market, PT or YT address), or by
 *  default of the oldest matured market the account holds PT of. */
export const ptRedeem = (client, o = {}) => bundle(client, { ...o, kind: "redeem" });

/**
 * `account`'s PT-USDG of the active market: its balance, what it is worth now at the oracle's spot price, what it pays
 * at maturity, the days left and the fixed APY a buyer locks in now; the stock vault's listing of the token (whether it
 * backs a line yet); and `markets`, its PT of every listed market ({ token, market, maturity, status, matured, balance,
 * balanceText, action: "trade" | "redeem" | "hold" }), so PT of an earlier, redeem-only market shows with its Redeem.
 */
export async function ptPosition(client, account, { now } = {}) {
  const who = getAddress(account);
  const { rate, now: t } = await ptRateOf(client, { now });
  const [balance, listing] = await Promise.all([read(client, PT_USDG.token, PT_ABI, "balanceOf", [who]), ptListing(client)]);
  const value = (balance * rate) / 10n ** 18n;
  const markets = [];
  for (const m of PT_MARKETS) {
    const b = m.token === PT_USDG.token ? balance : await read(client, m.token, PT_ABI, "balanceOf", [who]).catch(() => null);
    const due = t >= m.expiry;
    markets.push({ token: m.token, market: m.market, maturity: m.maturity, status: m.status, matured: due, balance: b, balanceText: b == null ? null : fmt6(b),
      action: due ? "redeem" : m.status === "active" ? "trade" : "hold" });
  }
  return {
    account: who, token: PT_USDG.token, balance, balanceText: fmt6(balance), value, valueText: fmt6(value),
    atMaturity: balance, atMaturityText: fmt6(balance), ...terms(rate, t), listing, markets,
  };
}

/**
 * The stock vault's listing of PT-USDG: { listed, enabled, ltvBps, lineCap, openLines, backsLines } (`backsLines`: a
 * line can open on it now); `listed` false until the Safe's setAsset. null when the vault cannot be read.
 */
export async function ptListing(client) {
  try {
    const [a, open] = await Promise.all([read(client, PT_USDG.stockVault, VAULT_ASSET_ABI, "assets", [PT_USDG.token]), read(client, PT_USDG.stockVault, VAULT_ASSET_ABI, "openLinesOf", [PT_USDG.token]).catch(() => null)]);
    const [feed, , tokenDecimals, , enabled, ltvBps, lineCap] = a;
    const listed = getAddress(feed) !== ZERO && Number(tokenDecimals) === PT_USDG.decimals;
    return { listed, enabled: listed && enabled === true, ltvBps: Number(ltvBps), lineCap: BigInt(lineCap), openLines: open,
      backsLines: listed && enabled === true && BigInt(lineCap) > 0n && (open === null || open < BigInt(lineCap)), planned: PT_USDG.planned };
  } catch (_) { return null; }
}

/** The same figures as JSON-safe values (bigints as decimal strings), for an MCP tool or an HTTP answer. */
export function jsonSafe(x) {
  return JSON.parse(JSON.stringify(x, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
}
