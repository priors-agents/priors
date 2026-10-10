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

/** The address that pays an x402 v2 EVM payment, or null. The arm is the one the facilitator settles by: @x402/evm's
 *  exact scheme takes the Permit2 arm whenever the payload has a `permit2Authorization` key, so its `from` pays, else
 *  EIP-3009's `authorization.from`. A payload naming both arms has no single payer: null, so the gate refuses it
 *  (GHSA-6vjc: judged on one address, paid from the other). */
export function payerOf(paymentPayload) {
  const p = paymentPayload?.payload;
  if (!p || typeof p !== "object") return null;
  const permit2 = "permit2Authorization" in p, eip3009 = "authorization" in p;
  if (permit2 && eip3009) return null;
  const from = permit2 ? p.permit2Authorization?.from : p.authorization?.from;
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
    tiers = [], basePrice = null, cacheSeconds = 60, cacheMax = 10_000, fetchImpl = globalThis.fetch, onDecision = null } = opts;
  if (source !== "api" && source !== "chain") throw new TypeError(`recordGate: source must be "api" or "chain" (got ${JSON.stringify(source)})`);
  if (!(Number.isInteger(minRepaid) && minRepaid >= 0)) throw new TypeError("recordGate: minRepaid must be a whole number");
  if (tiers.length && basePrice === null) throw new TypeError("recordGate: tiers need basePrice (the price without a record)");
  if (!(Number.isInteger(cacheMax) && cacheMax >= 1)) throw new TypeError("recordGate: cacheMax must be a whole number of at least 1");
  const cache = new Map();
  let contracts = null;

  async function readApi(address) {
    const u = new URL(checkUrl);
    u.searchParams.set("address", address);
    const r = await fetchImpl(u.href, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(8_000) });
    if (!r.ok) throw new Error(`the Priors check API answered HTTP ${r.status}`);
    return recordFromCheck(await r.json());
  }
  // The pool marks the owner of an agent that defaulted (ownerDefaults; not a custodian, which holds others' agents),
  // and the API source counts every agent of the payer's address. So the chain source counts the mark too, for the
  // payer and for the named agent's owner: naming a clean sibling, or no agent, does not pass refuseDefaulted
  // (reported by Muse, 2026-10-04).
  const marked = async (who) => !!who && who !== ethers.ZeroAddress && (await contracts.pool.ownerDefaults(who)) > 0n && !(await contracts.pool.custodian(who));
  async function readChain(address, agentId) {
    contracts ||= creditContracts({ runner: new ethers.JsonRpcProvider(rpc, undefined, { staticNetwork: true }), addresses: pool ? { pool } : {} });
    const named = agentId !== null && agentId !== undefined && /^\d{1,12}$/.test(String(agentId)) && (await contracts.pool.isController(BigInt(agentId), address));
    if (!named) return (await marked(address)) ? { ...NO_RECORD, known: true, defaulted: true } : { ...NO_RECORD };
    const s = await creditStatus(contracts, agentId);
    const defaulted = s.defaulted || (await marked(address)) || (await marked(s.owner));
    return { known: s.enrolled || defaulted, agents: [Number(agentId)], defaulted, loansRepaid: Number(s.loansRepaid), score: s.score };
  }
  /**
   * The record of `address` (and, for the chain source, of the agent it names), cached `cacheSeconds`, at most
   * `cacheMax` entries. The API source reads the address alone, so the agent a caller names is not part of its key:
   * otherwise each new `X-Priors-Agent` value, unpaid, would add an entry and a read (GHSA-vjcp). When it holds
   * `cacheMax` entries, the expired ones go, then the oldest.
   */
  async function recordOf(address, agentId = null) {
    const named = source === "chain" && agentId !== null && agentId !== undefined ? String(agentId) : "";
    const key = `${ethers.getAddress(address)}:${named}`;
    const hit = cache.get(key);
    const now = Date.now();
    if (hit && hit.until > now) return hit.record;
    const record = source === "api" ? await readApi(ethers.getAddress(address)) : await readChain(ethers.getAddress(address), agentId);
    cache.delete(key);
    if (cache.size >= cacheMax) for (const [k, v] of cache) { if (v.until <= now) cache.delete(k); }
    while (cache.size >= cacheMax) cache.delete(cache.keys().next().value);
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
