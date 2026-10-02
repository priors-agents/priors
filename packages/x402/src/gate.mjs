// Merchant side: check who is paying before you serve them. The payer's Priors record (what it has borrowed and
// repaid on Robinhood Chain, whether it ever defaulted) decides whether a payment is accepted, and at what price.
//
//   import { createResourceServer, recordGate } from "@priors/x402";
//   const server = createResourceServer({ apiKey });
//   recordGate({ refuseDefaulted: true, minRepaid: 1 }).attach(server);
//
// The gate runs in the resource server's `onBeforeVerify` hook: a payment it refuses is never sent to the facilitator,
// so it is never verified or settled and no money moves. The client gets the usual 402 with the reason.
//
// Where the record comes from:
//   source "api" (default)   https://priors.trade/api/check?address=<payer>: every agent the payer's address owns or
//                            declared as its payment wallet; no key. Defaulted if any of them defaulted.
//   source "chain"           Priors pool v2 read over `rpc` (no Priors service involved; works on a fork). The payer
//                            names its agent in the `X-Priors-Agent` header, and the gate checks the paying address
//                            controls that agent (owner or delegate) before reading its record.
//
// Price tiers (optional): `tierPrice(...)` gives the route a price that depends on the payer's record, from a payer
// address the client states in `X-Payer` (an agent id in `X-Priors-Agent` for the chain source). That statement is only
// a request: the gate checks the address that actually signed and refuses a payment below the price that payer is
// entitled to, so claiming someone else's record buys nothing.
import { ethers } from "ethers";
import { robinhood } from "./robinhood.mjs";
import { creditContracts, creditStatus } from "./credit.mjs";

export const CHECK_API = "https://priors.trade/api/check";

/** The address that signed an x402 v2 EVM payment (EIP-3009 `authorization.from`, or Permit2's `from`), or null. */
export function payerOf(paymentPayload) {
  const p = paymentPayload?.payload;
  const from = p?.authorization?.from ?? p?.permit2Authorization?.from ?? null;
  return typeof from === "string" && ethers.isAddress(from) ? ethers.getAddress(from) : null;
}

const NO_RECORD = Object.freeze({ known: false, agents: [], defaulted: false, loansRepaid: 0, score: null });

/** A record from the check API's answer: the best of the matched agents, defaulted if any one did. */
export function recordFromCheck(body) {
  const agents = Array.isArray(body?.agents) ? body.agents : [];
  if (!agents.length) return { ...NO_RECORD };
  const num = (x) => (Number.isFinite(Number(x)) ? Number(x) : 0);
  const scores = agents.map((a) => (a.scoreV2 && Number.isFinite(Number(a.scoreV2.score)) ? Number(a.scoreV2.score) : null)).filter((x) => x !== null);
  return {
    known: true,
    agents: agents.map((a) => num(a.agentId)),
    defaulted: agents.some((a) => a.record?.defaulted === true),
    loansRepaid: Math.max(...agents.map((a) => num(a.record?.loansRepaid))),
    score: scores.length ? Math.max(...scores) : null,
  };
}

/** Does `record` meet `policy`? { ok, reason } — reason is shown to the payer. */
export function judge(record, { refuseDefaulted = true, minRepaid = 0, minScore = null } = {}) {
  if (refuseDefaulted && record.defaulted) return { ok: false, reason: "priors_payer_defaulted", message: "This payer has defaulted on a Priors loan: payments from it are refused here." };
  if (record.loansRepaid < minRepaid) return { ok: false, reason: "priors_record_too_short", message: `This service asks for a Priors record of at least ${minRepaid} repaid loan(s); the payer has ${record.loansRepaid}. See https://priors.trade to build one.` };
  if (minScore !== null && (record.score ?? 0) < minScore) return { ok: false, reason: "priors_score_too_low", message: `This service asks for a Priors score of at least ${minScore}; the payer has ${record.score ?? 0}.` };
  return { ok: true };
}

/** The price a payer with `record` pays: the lowest tier it qualifies for, else `base`. Tiers: [{ minRepaid, price }]. */
export function priceFor(record, base, tiers = []) {
  let best = base;
  for (const t of tiers) if (record.loansRepaid >= t.minRepaid && !record.defaulted && dollars(t.price) < dollars(best)) best = t.price;
  return best;
}
const dollars = (p) => Number(String(p).replace(/^\$/, ""));

/**
 * A record gate. Options: { source: "api" | "chain", checkUrl, rpc, pool, refuseDefaulted, minRepaid, minScore,
 * tiers, basePrice, cacheSeconds, fetchImpl, onDecision }. `attach(server)` installs it on an x402ResourceServer;
 * `tierPrice()` returns a dynamic price for a route; `recordOf(address, agentId?)` reads a record.
 */
export function recordGate(opts = {}) {
  const { source = "api", checkUrl = CHECK_API, rpc = robinhood.rpcUrl, pool, refuseDefaulted = true, minRepaid = 0, minScore = null,
    tiers = [], basePrice = null, cacheSeconds = 60, fetchImpl = globalThis.fetch, onDecision = null } = opts;
  if (source !== "api" && source !== "chain") throw new TypeError(`recordGate: source must be "api" or "chain" (got ${JSON.stringify(source)})`);
  if (!(Number.isInteger(minRepaid) && minRepaid >= 0)) throw new TypeError("recordGate: minRepaid must be a whole number");
  if (tiers.length && basePrice === null) throw new TypeError("recordGate: tiers need basePrice (the price without a record)");
  const cache = new Map();
  let contracts = null;

  async function readApi(address) {
    const u = new URL(checkUrl);
    u.searchParams.set("address", address);
    const r = await fetchImpl(u.href, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(8_000) });
    if (!r.ok) throw new Error(`the Priors check API answered HTTP ${r.status}`);
    return recordFromCheck(await r.json());
  }
  async function readChain(address, agentId) {
    if (agentId === null || agentId === undefined || !/^\d{1,12}$/.test(String(agentId))) return { ...NO_RECORD };
    contracts ||= creditContracts({ runner: new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true }), addresses: pool ? { pool } : {} });
    if (!(await contracts.pool.isController(BigInt(agentId), address))) return { ...NO_RECORD };
    const s = await creditStatus(contracts, agentId);
    return { known: s.enrolled, agents: [Number(agentId)], defaulted: s.defaulted, loansRepaid: Number(s.loansRepaid), score: s.score };
  }
  /** The record of `address` (and, for the chain source, of the agent it names), cached `cacheSeconds`. */
  async function recordOf(address, agentId = null) {
    const key = `${ethers.getAddress(address)}:${agentId ?? ""}`;
    const hit = cache.get(key);
    if (hit && hit.until > Date.now()) return hit.record;
    const record = source === "api" ? await readApi(ethers.getAddress(address)) : await readChain(ethers.getAddress(address), agentId);
    cache.set(key, { record, until: Date.now() + cacheSeconds * 1000 });
    return record;
  }
  const agentHeader = (ctx) => ctx?.adapter?.getHeader?.("x-priors-agent") ?? null;
  const agentFromTransport = (t) => t?.request?.adapter?.getHeader?.("x-priors-agent") ?? t?.adapter?.getHeader?.("x-priors-agent") ?? null;

  /** onBeforeVerify: refuse a payment the policy does not accept, or one below the price this payer is entitled to. */
  async function beforeVerify({ paymentPayload, requirements, transportContext }) {
    const payer = payerOf(paymentPayload);
    if (!payer) return { abort: true, reason: "priors_payer_unknown", message: "The payment does not name its payer." };
    let record;
    try { record = await recordOf(payer, agentFromTransport(transportContext)); } catch (e) {
      // the record could not be read: a merchant that asks for one refuses, rather than serving on a guess
      const decision = { ok: false, reason: "priors_record_unavailable", message: `The payer's Priors record could not be read (${e?.message || e}); try again shortly.` };
      onDecision?.({ payer, record: null, ...decision });
      return { abort: true, reason: decision.reason, message: decision.message };
    }
    let decision = judge(record, { refuseDefaulted, minRepaid, minScore });
    if (decision.ok && tiers.length) {
      const owed = priceFor(record, basePrice, tiers);
      const decimals = robinhood.usdgDecimals;
      const owedUnits = BigInt(Math.round(dollars(owed) * 10 ** decimals));
      if (BigInt(requirements?.amount ?? 0) < owedUnits) decision = { ok: false, reason: "priors_price_not_entitled", message: `That price is for a payer with a longer Priors record; this payer's price is $${dollars(owed)}.` };
    }
    onDecision?.({ payer, record, ...decision });
    return decision.ok ? undefined : { abort: true, reason: decision.reason, message: decision.message };
  }

  return {
    recordOf,
    beforeVerify,
    /** Install on an x402ResourceServer (from createResourceServer or @x402/core). Returns the server. */
    attach(server) { server.onBeforeVerify(beforeVerify); return server; },
    /**
     * A dynamic price for a route: the tier the stated payer qualifies for (`X-Payer`, or `X-Priors-Agent` for the
     * chain source), `basePrice` otherwise. The gate checks the real signer when the payment arrives.
     */
    tierPrice() {
      if (!tiers.length) throw new TypeError("recordGate: tierPrice needs tiers and basePrice");
      return async (ctx) => {
        const stated = ctx?.adapter?.getHeader?.("x-payer");
        const agentId = agentHeader(ctx);
        try {
          if (source === "api" && stated && ethers.isAddress(stated)) return priceFor(await recordOf(stated), basePrice, tiers);
          if (source === "chain" && stated && ethers.isAddress(stated) && agentId) return priceFor(await recordOf(stated, agentId), basePrice, tiers);
        } catch (_) { /* no record read: the base price */ }
        return basePrice;
      };
    },
  };
}
