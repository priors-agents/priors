// Stock tokens bought and sold from an agent's own key (docs/STOCK-ZAP-SPEC.md 15: "Agent tools" and "Selling";
// @priors/mcp's stock_buy and stock_sell behind PRIORS_STOCKS): USDG to one of the zap's pinned Stock Tokens and back,
// on its pinned Uniswap pools (deployments/stock-zap.4663.json, through sdk/stock-zap.mjs's buildBuy and buildSell),
// each trade two plain transactions from the account: an approval of exactly the amount, then the exact-input swap
// paying the account itself, with a minimum out from a fresh quote less the slippage. Its gas is the account's own ETH:
// never Priors' gas gate, never $PRIORS, never a loan.
//
//   import { stockQuote, stockBuy, stockSell, openLoansOwed, ELIGIBILITY_STATEMENT } from "./sdk/stock-trade.mjs";
//   const rpc = "https://rpc.mainnet.chain.robinhood.com";              // or a viem client, an ethers provider
//   await stockQuote(rpc, { side: "buy", symbol: "NVDA", amount: 25, account, eligible: true, agentId: 1234 });
//   await stockBuy(rpc, { symbol: "NVDA", amount: 25, eligible: true, agentId: 1234, wallet });    // signs and sends
//   await stockSell(rpc, { symbol: "NVDA", amount: "all", eligible: true, wallet });
//
// The zap's limits and the Autopilot's price guards (autopilot/rules.mjs), each refused before anything is signed with a
// StockTradeError and its `code`:
//   ELIGIBILITY   `eligible: true` is not given: the caller's statement, ELIGIBILITY_STATEMENT, the web zap's tick word for
//                 word (web/account.html's #as-ok); nothing is read before it
//   PRIORS        $PRIORS, by name or address: never
//   NOT_OFFERED   a token that is not one of the zap's 30 pinned tokens (the five thin ones included)
//   SLIPPAGE      a slippage above the record's cap (2%)
//   AMOUNT        a trade under 1 USDG or over 1,000 USDG (a sale by its quote), or over the caller's `maxUsdg`
//   OPEN_LOANS    a buy with no `agentId` (the agent whose open loans the USDG must cover; null: the account acts for none)
//   PAUSED, BLOCKED  the token, or all 35, paused by the issuer; the account on its block list
//   NO_QUOTE      no pinned pool quotes the trade
//   STALE_PRICE   Chainlink's price unreadable, its oracle paused, or older than PRICE_MAX_AGE_S (4 h)
//   OFF_PRICE     the trade's price more than MAX_DEVIATION_BPS (5%) from Chainlink's, either way
//   IMPACT        a price impact at or over the record's stop (3%)
//   MOVED         the fresh quote under the caller's `minOut`: past the slippage the caller saw
//   BALANCE       more than the account holds
//   KEEP_BACK     a buy that would leave less USDG than `agentId`'s open loans owe (less `savedUsdg`, the savings that
//                 count, as the MCP's market tools count them), plus `keepUsdg`
//   NO_GAS        too little ETH for the trade's transactions
// A trade's reads are taken at one block. Sending (`wallet`): each step simulated just before it is signed (sdk/pt-usdg.mjs
// sendCalls: a lost answer is TX_UNCONFIRMED, never a bare error), and after the approval everything is read and planned
// again on the same pool: a refusal then, or a quote under the first plan's minimum, stops the trade, and the error says
// the approval stands (its spender pulls only from its caller, so only this account's own swap can use it).
// `beforeSend(plan)` is called once a plan has passed every check, before anything is signed (a throw stops the trade
// with nothing sent); `onSend(hash, what, step)` as each step leaves ("approve" or "swap").
import { decodeFunctionResult, encodeFunctionData, formatUnits, getAddress, isAddress, parseAbi, parseUnits } from "viem";
import { ZAP, ERC20_ABI, READS_ABI, V3_QUOTER_ABI, V4_QUOTER_ABI, buildBuy, buildSell, impactBps, minOutOf, pinnedPool } from "./stock-zap.mjs";
import { rpc, sendCalls } from "./pt-usdg.mjs";
import V2 from "../deployments/4663.v2.json" with { type: "json" };

/** The web zap's eligibility tick, word for word (web/account.html's #as-ok, the deposit sheet's and the buy drawer's),
 *  less its link to the list (RESTRICTED_URL). `eligible: true` states it. */
export const ELIGIBILITY_STATEMENT = "I am not a person of the United States, the United Kingdom, Canada or Switzerland, nor of Cuba, Belarus, Iran, North Korea, Russia, Syria, Ukraine, South Sudan, Sudan, Myanmar or Venezuela, nor of the United Arab Emirates, where the offer of stock tokens is restricted, and I am not acting for one.";
export const RESTRICTED_URL = "https://docs.robinhood.com/rhj/restricted-jurisdictions";
// the Autopilot's (autopilot/rules.mjs): a price older than this is no price, and a trade this far from it is skipped
export const PRICE_MAX_AGE_S = 4 * 3600;
export const MAX_DEVIATION_BPS = 500;
// the zap's day caps (gas-worker/gate.mjs LIMITS.userStockBuys): a caller that keeps a day's count (the MCP) holds buys,
// and sales likewise, to this many a UTC day
export const TRADES_PER_DAY = 5;
export const PRIORS_TOKEN = getAddress(V2.priors);
const POOL = getAddress(V2.pool);
// SHORTCUT: the swap can't be estimated before its approval is mined, so the ETH check takes this ceiling for it, over
// twice what a pinned pool's swap used on an anvil fork of chain 4663 (2026-10-29). Ceiling: a pool or chain change
// that makes a swap cost more. Upgrade trigger: a trade that stops for gas after its approval.
export const SWAP_GAS = 400_000n;

const LOAN_T = "(uint256 agentId, uint256 sponsorId, uint256 principal, uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium, address owner, uint64 issuedAt, uint64 dueAt, uint64 defaultableAt, uint64 minScoreTerm, uint64 closedAt, uint8 status)";
const AGENT_T = "(bool enrolled, bool isRoot, bool defaulted, bool frozen, bool importedFromV1, uint64 enrolledAt, uint64 lastBorrowAt, uint64 lastRepayAt, uint256 sponsor, uint256 delegatedIn, uint256 delegatedOut, uint256 principalOut, uint256 activeLoans, uint256 premiumBps, uint256 premiumCap, uint256 loansRepaid, uint256 volumeRepaid, uint256 feesPaid, uint256 recourseHonored, uint256 childrenDefaulted, uint256 qualifiedRepaid, uint256 dollarSecondsRepaid)";
const POOL_ABI = parseAbi(["function loansOf(uint256 id) view returns (uint256[])", `function getLoan(uint256 loanId) view returns (${LOAN_T})`, `function getAgent(uint256 id) view returns (${AGENT_T})`]);
const ORACLE_PAUSED_ABI = parseAbi(["function oraclePaused() view returns (bool)"]);
const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";

export class StockTradeError extends Error {
  constructor(code, message, extra = {}) { super(message); this.name = "StockTradeError"; this.code = code; Object.assign(this, extra); }
}
const no = (side, code, why, extra) => { throw new StockTradeError(code, `stock ${side}: ${why}`, extra); };
const lc = (a) => String(a).toLowerCase();
const hex = (n) => `0x${BigInt(n).toString(16)}`;
const fmt = (units, decimals) => formatUnits(units, decimals);
const usdg = (units) => `${formatUnits(units, 6)} USDG`;

/** A pool in words: "Uniswap v3, 0.05% pool". */
export const poolLabel = (p) => `Uniswap v${p.v}, ${Number((p.fee / 10_000).toFixed(4))}% pool`;

/** The pinned token `symbol` names (a ticker, any case, a leading $ allowed, or its address), or the refusal. */
export function stockToken(symbol, side = "trade", conf = ZAP) {
  const raw = String(symbol ?? "").trim();
  if (isAddress(raw)) {
    if (lc(raw) === lc(PRIORS_TOKEN)) no(side, "PRIORS", "$PRIORS is never traded here");
    const t = conf.tokens.find((x) => lc(x.token) === lc(raw));
    if (!t) no(side, "NOT_OFFERED", `${getAddress(raw)} is not one of the ${conf.tokens.length} pinned stock tokens`);
    return t;
  }
  const sym = raw.replace(/^\$/, "").toUpperCase();
  if (sym === "PRIORS") no(side, "PRIORS", "$PRIORS is never traded here");
  if (Object.prototype.hasOwnProperty.call(conf.notOffered, sym)) no(side, "NOT_OFFERED", `${sym} is not offered: its pools on Robinhood Chain are too small`);
  const t = conf.bySymbol.get(sym);
  if (!t) no(side, "NOT_OFFERED", `${raw.slice(0, 12) || "no symbol"} is not one of the ${conf.tokens.length} pinned stock tokens`);
  return t;
}

/** `amount` in base units of `decimals`: a bigint is raw; a number or a decimal string is whole tokens. */
function unitsOf(amount, decimals, side, what) {
  if (typeof amount === "bigint") { if (amount <= 0n) no(side, "AMOUNT", `${what} must be above zero`); return amount; }
  const s = typeof amount === "number" ? String(amount) : String(amount ?? "").trim();
  if (!new RegExp(`^\\d+(\\.\\d{1,${decimals}})?$`).test(s)) no(side, "AMOUNT", `${what} must be a decimal amount with at most ${decimals} decimals`);
  const u = parseUnits(s, decimals);
  if (u <= 0n) no(side, "AMOUNT", `${what} must be above zero`);
  return u;
}

async function blockOf(client) {
  const b = await rpc(client, "eth_getBlockByNumber", ["latest", false]);
  if (!b || b.number == null) throw new StockTradeError("UNREAD", "stock trade: the latest block could not be read");
  return { number: BigInt(b.number), at: Number(BigInt(b.timestamp)) };
}
/** One view at `tag`: the decoded result, or throws. */
async function view(client, tag, address, abi, functionName, args = [], from) {
  const out = await rpc(client, "eth_call", [{ to: address, data: encodeFunctionData({ abi, functionName, args }), ...(from ? { from } : {}) }, tag]);
  return decodeFunctionResult({ abi, functionName, data: typeof out === "string" ? out : out.data });
}
const maybe = (p) => p.then((v) => v, () => null);

/** What agent `agentId`'s open loans on the pool owe now (principal plus fee of each active loan): { owed, loans:
 *  [{ loanId, due, dueAt }] }. The pool's record counts them (activeLoans): none is read for an agent with none, and
 *  the loans are read newest first until that many active ones are found (an agent with a long record has hundreds). */
export async function openLoansOwed(client, agentId, { tag = "latest" } = {}) {
  const id = BigInt(agentId);
  const open = Number((await view(client, tag, POOL, POOL_ABI, "getAgent", [id])).activeLoans);
  const loans = [];
  if (open > 0) {
    const ids = await view(client, tag, POOL, POOL_ABI, "loansOf", [id]);
    for (let i = ids.length - 1; i >= 0 && loans.length < open; i--) {
      const l = await view(client, tag, POOL, POOL_ABI, "getLoan", [ids[i]]);
      if (Number(l.status) === 1) loans.push({ loanId: ids[i], due: l.principal + l.fee, dueAt: Number(l.dueAt) });
    }
    if (loans.length < open) throw new Error(`the pool counts ${open} open loans of agent #${id} and ${loans.length} were found`);
  }
  return { owed: loans.reduce((a, l) => a + l.due, 0n), loans };
}

/** USD value, in USDG units, of `units` of a token at Chainlink's `answer`. */
const usdOf = (units, answer, t) => (units * BigInt(answer) * 1_000_000n) / (10n ** BigInt(t.decimals) * 10n ** BigInt(t.feedDecimals));

/** The side, and the caller's statement: first, so that nothing is read for a caller that has not made it. */
function stated(o) {
  const side = o.side;
  if (side !== "buy" && side !== "sell") throw new StockTradeError("SIDE", 'stock trade: side is "buy" or "sell"');
  if (o.eligible !== true) no(side, "ELIGIBILITY", `refused: the caller has not stated its eligibility (eligible: true), which states: "${ELIGIBILITY_STATEMENT}" (${RESTRICTED_URL})`);
  return side;
}

/**
 * The plan of one trade, read at one block, every check passed, or the refusal (StockTradeError). o: { side ("buy" |
 * "sell"), symbol, amount (a buy: USDG; a sale: the token, or "all"), account, eligible, slippageBps (default the
 * record's, 1%), minOut (the least the caller accepts, in the token out), agentId (a buy: the agent whose open loans
 * stay covered, or null), savedUsdg, keepUsdg, maxUsdg, pool (a record pool: the trade quotes that one only) }.
 * Returns { side, symbol, name, token, decimals, account, block, at, pool, label, spender, amountIn, out, minOut,
 * slippageBps, impactBps, price, priceAt, priceAge, deviationBps, valueUsdg, held: { usdg, token }, owed, keep,
 * allowance, deadline, calls: [{ to, data, value, what, step }] } (the approval left out when the allowance is already
 * exactly the amount).
 */
export async function stockTradePlan(client, o = {}, conf = ZAP) {
  const side = stated(o);
  const t = stockToken(o.symbol, side, conf);
  const slip = o.slippageBps ?? conf.defaultSlippageBps;
  if (!(Number.isInteger(slip) && slip > 0 && slip <= conf.maxSlippageBps)) no(side, "SLIPPAGE", `the slippage is at most ${conf.maxSlippageBps / 100}% (${conf.maxSlippageBps} bps)`);
  const cap = o.maxUsdg != null && BigInt(o.maxUsdg) < conf.maxUsdgPerOp ? BigInt(o.maxUsdg) : conf.maxUsdgPerOp;
  let amountIn = null;
  if (side === "buy") {
    amountIn = unitsOf(o.amount, 6, side, "the amount of USDG");
    if (amountIn < conf.minUsdgPerOp) no(side, "AMOUNT", `the smallest trade is ${usdg(conf.minUsdgPerOp)}`);
    if (amountIn > cap) no(side, "AMOUNT", `one trade is at most ${usdg(cap)}`);
    if (o.agentId === undefined) no(side, "OPEN_LOANS", "name agentId, the agent whose open loans this USDG must still cover (null: this account acts for no agent)");
  } else if (o.amount !== "all") amountIn = unitsOf(o.amount, t.decimals, side, `the amount of ${t.symbol}`);
  const minWanted = o.minOut != null ? BigInt(o.minOut) : null;
  if (!o.account || !isAddress(o.account)) throw new StockTradeError("ACCOUNT", `stock ${side}: give the account that signs`);
  const account = getAddress(o.account);
  const forced = o.pool != null ? pinnedPool(t, o.pool) : null;
  if (o.pool != null && !forced) no(side, "NOT_OFFERED", `not a pinned pool of ${t.symbol}`);

  let b, r;
  try {
    b = await blockOf(client);
    const tag = hex(b.number);
    const [cash, held, paused, allPaused, blocked, round, oraclePaused] = await Promise.all([
      view(client, tag, conf.usdg, ERC20_ABI, "balanceOf", [account]),
      view(client, tag, t.token, ERC20_ABI, "balanceOf", [account]),
      view(client, tag, t.token, READS_ABI, "tokenPaused"),
      view(client, tag, conf.registry, READS_ABI, "paused"),
      view(client, tag, conf.registry, READS_ABI, "isBlocked", [account]),
      maybe(view(client, tag, t.feed, READS_ABI, "latestRoundData")),
      maybe(view(client, tag, t.token, ORACLE_PAUSED_ABI, "oraclePaused")),
    ]);
    r = { tag, cash, held, paused, allPaused, blocked, round, oraclePaused };
  } catch (e) {
    if (e instanceof StockTradeError) throw e;
    throw new StockTradeError("UNREAD", `stock ${side}: the chain could not be read just now (${e?.shortMessage || e?.message || e})`);
  }
  if (r.allPaused) no(side, "PAUSED", "stock tokens are paused by their issuer, so none can be traded right now");
  if (r.paused) no(side, "PAUSED", `${t.symbol} is paused by its issuer, so it can't be traded right now`);
  if (r.blocked) no(side, "BLOCKED", "the stock tokens' issuer has blocked this account");
  if (side === "sell" && amountIn === null) {
    amountIn = r.held;
    if (amountIn === 0n) no(side, "BALANCE", `${account} holds no ${t.symbol}`);
  }
  if (side === "buy" && r.cash < amountIn) no(side, "BALANCE", `this takes ${usdg(amountIn)} and ${account} holds ${usdg(r.cash)}`);
  if (side === "sell" && r.held < amountIn) no(side, "BALANCE", `this sells ${fmt(amountIn, t.decimals)} ${t.symbol} and ${account} holds ${fmt(r.held, t.decimals)}`);
  // Chainlink's price: fresh, unpaused
  const answer = r.round ? r.round[1] : null, priceAt = r.round ? Number(r.round[3]) : null;
  if (!(answer > 0n) || priceAt === null) no(side, "STALE_PRICE", `Chainlink's price of ${t.symbol} can't be read just now`);
  if (r.oraclePaused === true) no(side, "STALE_PRICE", `Chainlink's price of ${t.symbol} is paused by its issuer (a corporate action)`);
  const age = b.at - priceAt;
  if (age > PRICE_MAX_AGE_S) no(side, "STALE_PRICE", `Chainlink's price of ${t.symbol} is ${Math.round(age / 60)} minutes old, over ${PRICE_MAX_AGE_S / 3600} hours (the US market may be closed)`);

  // each pinned pool's quote (or the one asked), at the same block
  const pools = forced ? [forced] : t.pools;
  const quotes = await Promise.all(pools.map(async (p) => {
    try {
      const out = p.v === 4
        ? (await view(client, r.tag, conf.v4.quoter, V4_QUOTER_ABI, "quoteExactInputSingle", [{ poolKey: p.key, zeroForOne: side === "buy" ? p.zeroForOne : !p.zeroForOne, exactAmount: amountIn, hookData: "0x" }]))[0]
        : (await view(client, r.tag, conf.v3.quoter, V3_QUOTER_ABI, "quoteExactInputSingle", [{ tokenIn: side === "buy" ? conf.usdg : t.token, tokenOut: side === "buy" ? t.token : conf.usdg, amountIn, fee: p.fee, sqrtPriceLimitX96: 0n }]))[0];
      const s0 = await maybe(p.v === 4 ? view(client, r.tag, conf.v4.stateView, READS_ABI, "getSlot0", [p.id]) : view(client, r.tag, p.pool, READS_ABI, "slot0"));
      // the input is token0 for a buy when USDG is (p.zeroForOne), for a sale when the token is
      return { pool: p, out, impactBps: s0 ? impactBps({ usdgIn: amountIn, out, sqrtPriceX96: s0[0], fee: p.fee, usdgIsToken0: side === "buy" ? p.zeroForOne : !p.zeroForOne }) : null };
    } catch (_) { return { pool: p, out: null, impactBps: null }; }
  }));
  const ok = quotes.filter((q) => q.out !== null && q.out > 0n);
  if (!ok.length) no(side, "NO_QUOTE", `no pinned pool quotes ${fmt(amountIn, side === "buy" ? 6 : t.decimals)} ${side === "buy" ? "USDG" : t.symbol} of ${t.symbol} right now`);
  const best = ok.reduce((a, q) => (q.out > a.out ? q : a));
  if (best.impactBps !== null && best.impactBps >= conf.impactStopBps) no(side, "IMPACT", `the price impact would be ${(best.impactBps / 100).toFixed(2)}%, at or over ${conf.impactStopBps / 100}%: try a smaller amount`);
  // the trade against Chainlink's price, either way
  const usdIn = side === "buy" ? amountIn : usdOf(amountIn, answer, t), usdOut = side === "buy" ? usdOf(best.out, answer, t) : best.out;
  const deviationBps = usdIn > 0n ? Number(((usdIn > usdOut ? usdIn - usdOut : usdOut - usdIn) * 10_000n) / usdIn) : 0;
  if (deviationBps > MAX_DEVIATION_BPS) no(side, "OFF_PRICE", `the trade's price is ${(deviationBps / 100).toFixed(2)}% from Chainlink's, over ${MAX_DEVIATION_BPS / 100}%`);
  const valueUsdg = side === "buy" ? amountIn : best.out;
  if (side === "sell" && valueUsdg < conf.minUsdgPerOp) no(side, "AMOUNT", `the smallest trade is ${usdg(conf.minUsdgPerOp)} (this sale quotes ${usdg(valueUsdg)})`);
  if (side === "sell" && valueUsdg > cap) no(side, "AMOUNT", `one trade is at most ${usdg(cap)} (this sale quotes ${usdg(valueUsdg)})`);
  // the minimum out: the quote less the slippage, and never under what the caller saw
  let minOut = minOutOf(best.out, slip, conf);
  const outDec = side === "buy" ? t.decimals : 6, outName = side === "buy" ? t.symbol : "USDG";
  if (minWanted !== null) {
    if (best.out < minWanted) no(side, "MOVED", `the price moved past the slippage: a fresh quote gives ${fmt(best.out, outDec)} ${outName}, under the ${fmt(minWanted, outDec)} ${outName} asked for at least`, { quoteOut: best.out });
    if (minWanted > minOut) minOut = minWanted;
  }
  if (!(minOut > 0n)) no(side, "AMOUNT", "the amount is too small to name a minimum out");
  // a buy leaves what the open loans owe (the savings that count), and what the caller keeps back
  let owed = 0n, keep = o.keepUsdg != null ? BigInt(o.keepUsdg) : 0n;
  if (side === "buy") {
    if (o.agentId !== null) {
      try { owed = (await openLoansOwed(client, o.agentId, { tag: r.tag })).owed; } catch (e) { throw new StockTradeError("UNREAD", `stock buy: agent #${o.agentId}'s open loans could not be read just now (${e?.shortMessage || e?.message || e})`); }
    }
    const saved = o.savedUsdg != null ? BigInt(o.savedUsdg) : 0n;
    keep += owed > saved ? owed - saved : 0n;
    if (r.cash - amountIn < keep) {
      const room = r.cash > keep ? r.cash - keep : 0n;
      no(side, "KEEP_BACK", `this would leave ${usdg(r.cash - amountIn)} in the wallet, under the ${usdg(keep)} it keeps back${owed > 0n ? ` (agent #${o.agentId}'s open loans owe ${usdg(owed)}${saved > 0n ? `, ${usdg(saved)} of it covered by savings` : ""})` : ""}: at most ${usdg(room)} can buy now. Stock is never bought with USDG a loan needs back`, { owed, keep, room });
    }
  }
  const p = best.pool, spender = p.v === 4 ? conf.v4.swapper : conf.v3.router;
  const tokenIn = side === "buy" ? conf.usdg : t.token;
  let allowance;
  try { allowance = await view(client, r.tag, tokenIn, ERC20_ABI, "allowance", [account, spender]); } catch (_) { allowance = 0n; }
  const deadline = b.at + conf.deadlineS;
  const built = side === "buy"
    ? buildBuy({ account, symbol: t.symbol, pool: p, usdgIn: amountIn, minOut, deadline }, conf)
    : buildSell({ account, symbol: t.symbol, pool: p, amountIn, minOut, deadline }, conf);
  const inText = side === "buy" ? usdg(amountIn) : `${fmt(amountIn, t.decimals)} ${t.symbol}`;
  const spenderName = p.v === 4 ? "V4SwapOnce" : "SwapRouter02";
  const calls = [
    ...(allowance === amountIn ? [] : [{ ...built[0], value: 0n, step: "approve", what: `the approval of ${inText} to ${spenderName}` }]),
    { ...built[1], value: 0n, step: "swap", what: `the ${side === "buy" ? "buy" : "sale"} of ${inText} for at least ${fmt(minOut, outDec)} ${outName} (${poolLabel(p)})` },
  ];
  return {
    side, symbol: t.symbol, name: t.name, token: t.token, decimals: t.decimals, account, block: b.number, at: b.at,
    pool: p, label: poolLabel(p), spender, amountIn, out: best.out, minOut, slippageBps: slip, impactBps: best.impactBps,
    price: answer, priceAt, priceAge: age, feedDecimals: t.feedDecimals, deviationBps, valueUsdg,
    held: { usdg: r.cash, token: r.held }, owed, keep, allowance, deadline, calls,
  };
}

/** A plan in words, one line: "10 USDG -> about 0.0412 NVDA (at least 0.0408), Uniswap v3, 0.05% pool; ...". */
export function planText(p) {
  const [inD, inN, outD, outN] = p.side === "buy" ? [6, "USDG", p.decimals, p.symbol] : [p.decimals, p.symbol, 6, "USDG"];
  return `${fmt(p.amountIn, inD)} ${inN} -> about ${fmt(p.out, outD)} ${outN} (at least ${fmt(p.minOut, outD)}, ${p.slippageBps / 100}% slippage), ${p.label}${p.impactBps !== null ? `, price impact ${(p.impactBps / 100).toFixed(2)}%` : ""}; Chainlink's ${p.symbol} round ${Math.round(p.priceAge / 60)} min old, the trade ${(p.deviationBps / 100).toFixed(2)}% from it; block ${p.block}.`;
}

/** The account that signs: `account`, else the wallet's own address. */
async function accountOf(account, wallet) {
  if (account) return getAddress(account);
  if (wallet && wallet.account && wallet.account.address) return getAddress(wallet.account.address); // viem WalletClient
  if (wallet && typeof wallet.getAddress === "function") return getAddress(await wallet.getAddress()); // ethers Signer
  throw new StockTradeError("ACCOUNT", "stock trade: give the account that signs (account) or a wallet to send with");
}

/** The account's ETH covers the steps at today's gas price: the first's estimate (+25%), SWAP_GAS for a swap after it. */
async function gasCheck(client, side, account, calls) {
  let price, eth, est;
  try {
    price = BigInt(await rpc(client, "eth_gasPrice", []));
    eth = BigInt(await rpc(client, "eth_getBalance", [account, "latest"]));
  } catch (e) { throw new StockTradeError("UNREAD", `stock ${side}: the gas price or the account's ETH could not be read just now`); }
  try { est = BigInt(await rpc(client, "eth_estimateGas", [{ from: account, to: calls[0].to, data: calls[0].data }])); } catch (_) { est = calls[0].step === "swap" ? SWAP_GAS : 75_000n; }
  const need = (est + est / 4n + (calls.length > 1 ? SWAP_GAS : 0n)) * price;
  if (eth < need) no(side, "NO_GAS", `${account} has ${formatUnits(eth, 18)} ETH, under the ${formatUnits(need, 18)} ETH its ${calls.length > 1 ? "two transactions" : "transaction"} may cost in gas`);
}

/** What `account` received of `token` in the receipt of `hash` (its Transfer logs), or null when unread. */
async function receivedIn(client, hash, token, account) {
  try {
    const rc = await rpc(client, "eth_getTransactionReceipt", [hash]);
    const to = `0x${lc(account).slice(2).padStart(64, "0")}`;
    return (rc.logs || []).filter((l) => lc(l.address) === lc(token) && l.topics && lc(l.topics[0]) === TRANSFER && lc(l.topics[2]) === to).reduce((a, l) => a + BigInt(l.data), 0n);
  } catch (_) { return null; }
}

/** A plan that stopped after its approval: the error, with what stands. */
function stoppedAfter(e, p, hashes) {
  const inText = p.side === "buy" ? usdg(p.amountIn) : `${fmt(p.amountIn, p.decimals)} ${p.symbol}`;
  const why = e?.message ? String(e.message).replace(/^stock (buy|sale|sell): /, "") : String(e);
  return new StockTradeError(e?.code || "STOPPED", `stock ${p.side}: the approval was sent (tx ${hashes.join(", ")}), then the trade stopped: ${why}. Nothing more was sent. The approval of exactly ${inText} to ${p.spender} stands; its spender pulls only from its caller, so only this account's own swap can use it`, { hashes: [...hashes], stoppedAfterApproval: true, cause: e });
}

/**
 * One trade: the plan, and with `wallet` (an ethers Wallet or Signer, a viem WalletClient) its steps sent. o: as
 * stockTradePlan, plus wallet, waitTimeoutMs, beforeSend(plan), onSend(hash, what, step). Returns the plan, and once sent
 * { ...plan, hashes, received } (received: what the swap's receipt paid the account, or null when unread).
 */
export async function stockTrade(client, o = {}, conf = ZAP) {
  stated(o);
  const account = await accountOf(o.account, o.wallet).catch((e) => { throw e instanceof StockTradeError ? e : new StockTradeError("ACCOUNT", String(e?.message || e)); });
  let p = await stockTradePlan(client, { ...o, account }, conf);
  if (!o.wallet) return p;
  await gasCheck(client, p.side, account, p.calls);
  if (o.beforeSend) await o.beforeSend(p);
  const recheck = `this account's USDG and ${p.symbol} (wallet_balance, or the token's balanceOf)`;
  // each step's nonce, read here just before it: a wallet whose provider caches its reads (ethers' default, 250 ms) could
  // give a step the one the step before it took (the approval's, or the last trade's), and the node would refuse it
  const send = async (c) => {
    let n = c;
    try { n = { ...c, nonce: Number(BigInt(await rpc(client, "eth_getTransactionCount", [account, "pending"]))) }; } catch (_) { /* the wallet's own */ }
    return sendCalls(client, o.wallet, [n], account, { waitTimeoutMs: o.waitTimeoutMs, recheck, onSend: o.onSend ? (h, what) => o.onSend(h, what, c.step) : undefined });
  };
  const hashes = [];
  if (p.calls.length === 2) {
    hashes.push(...(await send(p.calls[0])));
    // read and planned again at the latest block, on the same pool and amount, never under the first minimum
    let again;
    try { again = await stockTradePlan(client, { ...o, account, amount: p.amountIn, pool: p.pool, minOut: p.minOut, slippageBps: p.slippageBps }, conf); } catch (e) { throw stoppedAfter(e, p, hashes); }
    if (again.calls.length !== 1) throw stoppedAfter(new Error("the approval is not the amount the swap takes"), p, hashes);
    p = again;
  }
  try { hashes.push(...(await send(p.calls[p.calls.length - 1]))); } catch (e) {
    if (hashes.length && !e?.unconfirmed) throw stoppedAfter(e, p, hashes);
    if (hashes.length && e?.unconfirmed) e.hashes = [...hashes, ...(e.hashes || [])];
    throw e;
  }
  const received = await receivedIn(client, hashes[hashes.length - 1], p.side === "buy" ? p.token : conf.usdg, account);
  return { ...p, hashes, received };
}

/** A quote and the calls, sent nothing: stockTradePlan for `side`. */
export const stockQuote = (client, o = {}, conf = ZAP) => stockTradePlan(client, o, conf);
/** Buy `amount` USDG of `symbol`: the calls, sent when `wallet` is given. */
export const stockBuy = (client, o = {}, conf = ZAP) => stockTrade(client, { ...o, side: "buy" }, conf);
/** Sell `amount` of `symbol` (or "all") for USDG: the calls, sent when `wallet` is given. */
export const stockSell = (client, o = {}, conf = ZAP) => stockTrade(client, { ...o, side: "sell" }, conf);
