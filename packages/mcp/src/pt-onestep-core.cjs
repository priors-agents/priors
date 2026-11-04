/* PT one step (SITE_PT_ONESTEP=on; docs/PT-USDG.md, "One step: buy and back a line"): USDG to PT-USDG to an open line
   on the stock vault, as one batch. The plan of it (the least PT the buy takes, from a fresh quote less the slippage, and
   what goes behind the line) and its four calls, built the same way for Go mode (web/account-pt-onestep.js: one
   sponsored operation) and for agents (@priors/mcp's pt_buy_and_deposit: packages/mcp/src/pt-onestep-core.cjs is this
   file, byte for byte, its four calls sent from the agent's own wallet):
     1. USDG.approve(router, usdgIn)                                exactly what the buy takes
     2. router.swapExactTokenForPt(account, market, minPtOut, ...)  USDG in, the PT paid to the account itself
     3. PT.approve(stockVault, deposit)                             exactly what the open takes
     4. stockVault.open(agentId, PT, deposit, consent, sig)         the account's own consent, for that agent, naming
                                                                    the vault's root
   deposit is the buy's minPtOut, plus the PT the account already holds when the caller includes it: the router pays at
   least minPtOut or the whole batch reverts, so the open never asks for more PT than the account has. The buy is the one
   shape the gas gate sponsors (sdk/pendle-pt.mjs buildBuy and checkRouterCall), and the approval and the open are the
   account bundle's own deposit (web-src/priors-app.mjs openStockLine), byte for byte (scripts/test-pt-onestep.mjs).

   Pure: no DOM, no chain, no library; no address of its own (the caller's `conf` names the router, USDG, the market, the
   PT and the vault). The caller brings `encode(to, sig, args) -> { to, data }` (Go mode: the bundle's
   PriorsApp.encodeCall; the MCP: viem's encodeFunctionData) and the reads. Amounts are 6-decimal bigints; times seconds.

   window.PriorsPtOnestepCore (a page) / module.exports (node):
     LIMITS             { minUsdg (1 USDG), maxQuoteAgeS (60), slippageBps (100, the default), maxSlippageBps (300) }
     SIG                the four functions' signatures, structs spelled out
     plan(o)            o { conf, usdgIn, rate (USDG per PT, 1e18 = par), rateAt (when it was read), now, slippageBps?,
                        held? (the account's PT), includeHeld? (default true) } -> { usdgIn, rate, expectedPt, minPtOut,
                        held, deposit, slippageBps, quotedAt }, frozen; or throws an Error whose .code is "amount" | "min"
                        | "cap" | "slippage" | "redeem-only" | "matured" | "rate" | "stale" | "held"
     confirm(shown, fresh)  `fresh` (a plan made at the tap) when it gives at least what `shown` said: the same USDG, a
                        least PT and a deposit no smaller; else throws .code "moved"
     calls(encode, p, o)    plan `p`'s four calls, each { to, data, what }, for o { conf, account, agentId, root (the
                        vault's agentId), consent, sig }; throws .code "consent" (not the account's own, for that agent,
                        naming that root) or "amount" (nothing to deposit)
     lineOf(o)          o { value, ltvBps, maxLine? }: the line the vault opens on a deposit worth `value`
     usdgForLine(o)     o { line, value1 (the vault's value of one whole PT), ltvBps, held, rate, slippageBps? }: the
                        least USDG whose buy, with `held`, reaches a `line` (0n when `held` already does) */
(function () {
  "use strict";
  const E18 = 10n ** 18n, BPS = 10_000n, UNIT = 1_000_000n;
  const ZERO = "0x0000000000000000000000000000000000000000";
  const LIMITS = Object.freeze({ minUsdg: UNIT, maxQuoteAgeS: 60, slippageBps: 100, maxSlippageBps: 300 });
  // the router's buy (sdk/pendle-pt.mjs ROUTER_ABI, Pendle's IPAllActionTypeV3 structs spelled out), the ERC-20 approval
  // and the vault's open (web-src/priors-app.mjs ABI.vault, CreditPoolV2.Consent spelled out)
  const SWAP_DATA = "(uint8 swapType, address extRouter, bytes extCalldata, bool needScale)";
  const ORDER = "(uint256 salt, uint256 expiry, uint256 nonce, uint8 orderType, address token, address YT, address maker, address receiver, uint256 makingAmount, uint256 lnImpliedRate, uint256 failSafeRate, bytes permit)";
  const FILL = "(" + ORDER + " order, bytes signature, uint256 makingAmount)";
  const LIMIT = "(address limitRouter, uint256 epsSkipMarket, " + FILL + "[] normalFills, " + FILL + "[] flashFills, bytes optData)";
  const TOKEN_IN = "(address tokenIn, uint256 netTokenIn, address tokenMintSy, address pendleSwap, " + SWAP_DATA + " swapData)";
  const APPROX = "(uint256 guessMin, uint256 guessMax, uint256 guessOffchain, uint256 maxIteration, uint256 eps)";
  const CONSENT = "(uint256 agentId, uint256 sponsorId, address owner, uint256 maxPremiumBps, uint256 nonce, uint256 deadline)";
  const SIG = Object.freeze({
    approve: "function approve(address spender, uint256 amount) returns (bool)",
    buy: "function swapExactTokenForPt(address receiver, address market, uint256 minPtOut, " + APPROX + " guessPtOut, " + TOKEN_IN + " input, " + LIMIT + " limit) payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm)",
    open: "function open(uint256 id, address token, uint256 amount, " + CONSENT + " c, bytes sig) returns (uint256)",
  });
  const NONE_SWAP = () => ({ swapType: 0, extRouter: ZERO, extCalldata: "0x", needScale: false });
  const NO_LIMIT = () => ({ limitRouter: ZERO, epsSkipMarket: 0n, normalFills: [], flashFills: [], optData: "0x" });
  // Pendle's on-chain search of the PT amount, no off-chain guess (sdk/pendle-pt.mjs DEFAULT_APPROX)
  const APPROX_ALL = () => ({ guessMin: 0n, guessMax: (1n << 256n) - 1n, guessOffchain: 0n, maxIteration: 256n, eps: 10n ** 14n });

  const no = (code, message) => Object.assign(new Error(message || code), { code });
  const isBig = (v) => typeof v === "bigint";
  const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
  // 6-decimal units in plain digits, trailing zeros dropped (12_500_000n -> "12.5"), for the calls' own words
  const fmt6 = (u) => { const s = String(u), neg = s.startsWith("-"), d = (neg ? s.slice(1) : s).padStart(7, "0"); const f = d.slice(-6).replace(/0+$/, ""); return (neg ? "-" : "") + d.slice(0, -6) + (f ? "." + f : ""); };

  /** The buy and the deposit, from a quote read at `rateAt`; throws why it can't be done now (see the header). */
  function plan({ conf, usdgIn, rate, rateAt, now, slippageBps, held = 0n, includeHeld = true }) {
    if (!isBig(usdgIn) || usdgIn <= 0n) throw no("amount", "a buy needs an amount of USDG");
    if (usdgIn < LIMITS.minUsdg) throw no("min", "the smallest buy is 1 USDG");
    if (usdgIn > BigInt(conf.maxUsdgPerOp)) throw no("cap", "above the most one sponsored trade takes");
    const slip = slippageBps == null ? LIMITS.slippageBps : slippageBps;
    if (!Number.isInteger(slip) || slip < 0 || slip > LIMITS.maxSlippageBps) throw no("slippage", "a slippage of 0 to 300 bps");
    if (conf.active === false) throw no("redeem-only", "the market is redeem-only");
    if (!(now < Number(conf.expiry))) throw no("matured", "the market has matured");
    // a rate above par is no PT's before maturity: a misread one would name a minimum below the market
    if (!isBig(rate) || rate <= 0n || rate > E18) throw no("rate", "no usable quote");
    if (!Number.isFinite(rateAt) || now - rateAt > LIMITS.maxQuoteAgeS || rateAt - now > 30) throw no("stale", "the quote is not fresh");
    if (!isBig(held) || held < 0n) throw no("held", "the balance is not one");
    const expectedPt = (usdgIn * E18) / rate;
    const minPtOut = (expectedPt * (BPS - BigInt(slip))) / BPS;
    if (minPtOut <= 0n) throw no("amount", "too small to name a least PT out");
    const used = includeHeld ? held : 0n;
    return Object.freeze({ usdgIn, rate, expectedPt, minPtOut, held: used, deposit: minPtOut + used, slippageBps: slip, quotedAt: rateAt });
  }

  /** The plan made at the tap, when it gives at least what the screen said; else "moved". */
  function confirm(shown, fresh) {
    if (!shown || !fresh || fresh.usdgIn !== shown.usdgIn || fresh.minPtOut < shown.minPtOut || fresh.deposit < shown.deposit) throw no("moved", "the price or the balance moved");
    return fresh;
  }

  /** Plan `p`'s four calls, in order, for the account's own consent. */
  function calls(encode, p, { conf, account, agentId, root, consent, sig }) {
    const id = BigInt(agentId);
    if (!consent || !same(consent.owner, account) || BigInt(consent.agentId) !== id || root == null || BigInt(consent.sponsorId) !== BigInt(root)) throw no("consent", "the consent must be the account's own, for this agent, naming the vault's root");
    if (!isBig(p.deposit) || p.deposit <= 0n || !isBig(p.minPtOut) || p.minPtOut <= 0n) throw no("amount", "nothing to deposit");
    const c = { agentId: id, sponsorId: BigInt(consent.sponsorId), owner: consent.owner, maxPremiumBps: BigInt(consent.maxPremiumBps), nonce: BigInt(consent.nonce), deadline: BigInt(consent.deadline) };
    const what = (x, w) => Object.assign({}, x, { what: w });
    return [
      what(encode(conf.usdg, SIG.approve, [conf.router, p.usdgIn]), `approve ${fmt6(p.usdgIn)} USDG to Pendle's router`),
      what(encode(conf.router, SIG.buy, [account, conf.market, p.minPtOut, APPROX_ALL(), { tokenIn: conf.usdg, netTokenIn: p.usdgIn, tokenMintSy: conf.usdg, pendleSwap: ZERO, swapData: NONE_SWAP() }, NO_LIMIT()]), `buy at least ${fmt6(p.minPtOut)} PT-USDG with ${fmt6(p.usdgIn)} USDG`),
      what(encode(conf.pt, SIG.approve, [conf.stockVault, p.deposit]), `approve ${fmt6(p.deposit)} PT-USDG to the stock vault`),
      what(encode(conf.stockVault, SIG.open, [id, conf.pt, p.deposit, c, sig]), `deposit ${fmt6(p.deposit)} PT-USDG and open agent #${id}'s line`),
    ];
  }

  /** The line on a deposit worth `value` (StockVault.open: value × ltvOf / 10,000, at most maxLine). */
  function lineOf({ value, ltvBps, maxLine }) {
    const line = (BigInt(value) * BigInt(ltvBps)) / BPS;
    return maxLine != null && line > BigInt(maxLine) ? BigInt(maxLine) : line;
  }

  /** The least USDG whose buy (its least PT out, at `rate` less the slippage), with `held`, reaches `line`. */
  function usdgForLine({ line, value1, ltvBps, held = 0n, rate, slippageBps }) {
    const slip = BigInt(slippageBps == null ? LIMITS.slippageBps : slippageBps);
    // the PT whose value reaches the line: value(d) = d × value1 / 1e6, line = value × ltv / 1e4 (each rounded down)
    const need = (BigInt(line) * BPS * UNIT + BigInt(ltvBps) * BigInt(value1) - 1n) / (BigInt(ltvBps) * BigInt(value1)) + 1n;
    const buy = need > held ? need - held : 0n;
    if (buy === 0n) return 0n;
    // the USDG whose least PT out is at least `buy`: min = (usdg × 1e18 / rate) × (1e4 - slip) / 1e4
    let usdg = (buy * BPS * BigInt(rate) + (BPS - slip) * E18 - 1n) / ((BPS - slip) * E18);
    while ((((usdg * E18) / BigInt(rate)) * (BPS - slip)) / BPS < buy) usdg += 1n;
    return usdg;
  }

  const api = { LIMITS, SIG, plan, confirm, calls, lineOf, usdgForLine };
  if (typeof window !== "undefined") window.PriorsPtOnestepCore = api;
  if (typeof module === "object" && module && module.exports) module.exports = api;
})();
