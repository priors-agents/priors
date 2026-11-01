// Merchant side: price routes in dollars on Robinhood Chain and settle through the Priors facilitator, with the
// official @x402/* packages doing all the protocol work.
//
//   import { ExactEvmScheme } from "@x402/evm/exact/server";
//   import { x402ResourceServer, HTTPFacilitatorClient } from "@x402/core/server";
//   const server = new x402ResourceServer(new HTTPFacilitatorClient(priorsFacilitator({ apiKey })))
//     .register(robinhood.network, registerUsdg(new ExactEvmScheme()));
import { HTTPFacilitatorClient, x402ResourceServer } from "@x402/core/server";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { robinhood } from "./robinhood.mjs";

/**
 * Teach an `ExactEvmScheme` (server side, from `@x402/evm/exact/server`) that a Money price ("$0.05", "0.05", 0.05)
 * on `eip155:4663` means USDG: 6 decimals, EIP-712 domain "Global Dollar" / "1" in `extra`, which the client needs
 * to sign EIP-3009. Other networks are untouched (the parser answers null, so the next parser or the scheme's
 * default runs). A price finer than one USDG unit (6 decimals) is refused rather than rounded.
 * @template {{ registerMoneyParser: Function }} S
 * @param {S} scheme
 * @param {{ asset?: string }} [opts]  a different USDG address (a fork or test token); default: mainnet USDG
 * @returns {S} the same scheme, for chaining
 */
export function registerUsdg(scheme, { asset = robinhood.usdg } = {}) {
  if (!scheme || typeof scheme.registerMoneyParser !== "function") {
    throw new TypeError("registerUsdg: pass an ExactEvmScheme from @x402/evm/exact/server (it has registerMoneyParser)");
  }
  scheme.registerMoneyParser(async (amount, network) => {
    if (network !== robinhood.network) return null;
    return { amount: dollarsToUnits(amount), asset, extra: { name: robinhood.eip712.name, version: robinhood.eip712.version } };
  });
  return scheme;
}

/** "0.05" (the decimal string ExactEvmScheme hands a money parser) → "50000". */
function dollarsToUnits(amount) {
  const s = typeof amount === "number" ? numberToPlain(amount) : String(amount).trim();
  const m = /^(\d+)(?:\.(\d+))?$/.exec(s);
  if (!m) throw new Error(`USDG price: not a dollar amount: ${JSON.stringify(s)}`);
  const frac = (m[2] || "").replace(/0+$/, "");
  if (frac.length > robinhood.usdgDecimals) throw new Error(`USDG price ${s} has more than ${robinhood.usdgDecimals} decimals (smaller than one USDG unit)`);
  const units = (BigInt(m[1]) * 10n ** BigInt(robinhood.usdgDecimals) + BigInt(frac.padEnd(robinhood.usdgDecimals, "0") || "0")).toString();
  if (units === "0") throw new Error("USDG price must be above zero");
  return units;
}
function numberToPlain(n) {
  if (!Number.isFinite(n) || n < 0) throw new Error(`USDG price: not a dollar amount: ${n}`);
  return n.toFixed(12).replace(/\.?0+$/, "");
}

/**
 * Config for the official `HTTPFacilitatorClient` (`@x402/core/server`) pointed at the Priors facilitator.
 * With an `apiKey` (the merchant key from POST /merchants/register), `createAuthHeaders` returns
 * `Authorization: Bearer <apiKey>` keyed by path ({verify, settle, supported}), as HTTPFacilitatorClient requires:
 * a flat headers object makes it throw. The key lives in a closure, not in an enumerable property, so logging or
 * JSON-serialising the config does not print it.
 * @param {{ url?: string, apiKey?: string, timeoutMs?: number }} [opts]
 * @returns {import("@x402/core/server").FacilitatorConfig}
 */
export function priorsFacilitator({ url = robinhood.facilitatorUrl, apiKey, timeoutMs } = {}) {
  let u;
  try { u = new URL(url); } catch (_) { throw new TypeError(`priorsFacilitator: not a URL: ${JSON.stringify(url)}`); }
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "::1" || u.hostname === "[::1]";
  if (u.protocol !== "https:" && !(local && u.protocol === "http:")) throw new TypeError("priorsFacilitator: the facilitator URL must be https (http only for localhost)");
  /** @type {import("@x402/core/server").FacilitatorConfig} */
  const config = { url: u.toString().replace(/\/+$/, "") };
  if (timeoutMs !== undefined) config.timeoutMs = timeoutMs;
  if (apiKey !== undefined && apiKey !== null && apiKey !== "") {
    // A key with whitespace or control characters would split or corrupt the header: refuse it.
    if (typeof apiKey !== "string" || !/^[\x21-\x7e]{8,512}$/.test(apiKey)) throw new TypeError("priorsFacilitator: apiKey must be a printable string without spaces (8 to 512 characters)");
    const key = apiKey;
    config.createAuthHeaders = async () => {
      const h = () => ({ Authorization: `Bearer ${key}` });
      return { verify: h(), settle: h(), supported: h() };
    };
  }
  return config;
}

/** `new HTTPFacilitatorClient(priorsFacilitator(opts))`. */
export function priorsFacilitatorClient(opts = {}) {
  return new HTTPFacilitatorClient(priorsFacilitator(opts));
}

// USDG on Robinhood Chain does not revert a transfer on an authorization already used or cancelled: the transaction
// succeeds (status 1), logs AuthorizationAlreadyUsed and moves nothing. A payer can spend its nonce between a
// facilitator's verify and its settle transaction (its signed cancelAuthorization, which anyone can send, or a second
// authorization with the same nonce), so a facilitator that reads the transaction's status, not its logs, answers
// success for a payment that moved nothing. The Priors facilitator reads the logs; `confirmSettlements` reads them too.
const TOPIC_TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"; // Transfer(address,address,uint256)
const TOPIC_AUTHORIZATION_USED = "0x98de503528ee59b575ef0c0a2576a82497bfc029a5685b209e9ec333479b10a5"; // AuthorizationUsed(address,bytes32)
const lc = (s) => String(s ?? "").toLowerCase();
const topicAddress = (t) => (/^0x0{24}[0-9a-f]{40}$/.test(lc(t)) ? "0x" + lc(t).slice(26) : null);
const TX_HASH = /^0x[0-9a-fA-F]{64}$/;

/**
 * Does `receipt` (eth_getTransactionReceipt's JSON, or an ethers receipt) show this USDG payment? Status 1, and a log
 * of USDG's own AuthorizationUsed(from, nonce) whose very next log is USDG's Transfer(from -> payTo) of at least
 * `amount`: the pairing Priors reads x402 income by. A no-op (AuthorizationAlreadyUsed alone), a Transfer elsewhere or
 * of less, or another contract's logs: false.
 * @param {any} receipt
 * @param {{ asset?: string, from: string, nonce: string, payTo: string, amount: bigint|number|string }} payment
 * @returns {boolean}
 */
export function receiptPaysUsdg(receipt, { asset = robinhood.usdg, from, nonce, payTo, amount }) {
  if (!receipt || Number(receipt.status) !== 1 || !Array.isArray(receipt.logs)) return false;
  const token = lc(asset), payer = lc(from), to = lc(payTo), n = lc(nonce);
  const logs = receipt.logs;
  for (let i = 0; i + 1 < logs.length; i++) {
    const u = logs[i], t = logs[i + 1];
    if (lc(u?.address) !== token || lc(u.topics?.[0]) !== TOPIC_AUTHORIZATION_USED || topicAddress(u.topics?.[1]) !== payer || lc(u.topics?.[2]) !== n) continue;
    if (lc(t?.address) !== token || lc(t.topics?.[0]) !== TOPIC_TRANSFER || topicAddress(t.topics?.[1]) !== payer || topicAddress(t.topics?.[2]) !== to) continue;
    try { if (BigInt(t.data) >= BigInt(amount)) return true; } catch (_) { /* not a Transfer's value */ }
  }
  return false;
}

/**
 * Wrap a facilitator client (`HTTPFacilitatorClient`, or any `{ verify, settle, getSupported }`) so that a successful
 * settle of a USDG payment on `eip155:4663` is kept only when its transaction's receipt, read from `rpcUrl`, shows the
 * payment (`receiptPaysUsdg`). One that does not becomes `{ success: false, errorReason: "settlement_moved_nothing" }`:
 * @x402's middleware then answers 402 and withholds the paid response. A receipt the RPC cannot give within `waitMs`
 * (an outage, a node behind) leaves the facilitator's answer as it is (it fails open: the facilitator saw the receipt
 * before answering success); so does any other network, asset or payload. Every read ends by that deadline, so a node
 * that hangs holds the paid response `waitMs` at most (3 s by default).
 * @param {any} client
 * @param {{ rpcUrl?: string, asset?: string, fetch?: typeof fetch, waitMs?: number, pollMs?: number,
 *   onUnconfirmed?: (o: { transaction: string, reason: string }) => void }} [opts]
 */
export function confirmSettlements(client, { rpcUrl = robinhood.rpcUrl, asset = robinhood.usdg, fetch: fetchImpl = (...a) => globalThis.fetch(...a), waitMs = 3_000, pollMs = 500, onUnconfirmed = null } = {}) {
  if (!client || typeof client.settle !== "function") throw new TypeError("confirmSettlements: pass a facilitator client (HTTPFacilitatorClient, or { verify, settle, getSupported })");
  let u;
  try { u = new URL(rpcUrl); } catch (_) { throw new TypeError(`confirmSettlements: rpcUrl is not a URL: ${JSON.stringify(rpcUrl)}`); }
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "::1" || u.hostname === "[::1]";
  if (u.protocol !== "https:" && !(local && u.protocol === "http:")) throw new TypeError("confirmSettlements: rpcUrl must be https (http only for localhost)");
  const url = u.toString();
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  /** The receipt, null while the node does not know it; throws on an RPC failure (never with the URL in it). The read
   *  is aborted at `end`. */
  const receiptOf = async (hash, end) => {
    let r;
    try {
      r = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_getTransactionReceipt", params: [hash] }), signal: AbortSignal.timeout(Math.max(1, end - Date.now())) });
    } catch (_) { throw new Error("rpc_unreachable"); }
    if (!r.ok) throw new Error(`rpc_http_${r.status}`);
    const j = await r.json().catch(() => null);
    if (!j || j.error) throw new Error("rpc_error");
    return j.result ?? null;
  };
  return {
    verify: (paymentPayload, requirements) => client.verify(paymentPayload, requirements),
    getSupported: () => client.getSupported(),
    async settle(paymentPayload, requirements) {
      const s = await client.settle(paymentPayload, requirements);
      if (!s || s.success !== true || requirements?.network !== robinhood.network || lc(requirements?.asset) !== lc(asset)) return s;
      const a = paymentPayload?.payload?.authorization;
      if (!a || typeof a.from !== "string" || typeof a.nonce !== "string" || typeof s.transaction !== "string" || !TX_HASH.test(s.transaction)) return s;
      let rc = null, why = "receipt_not_found";
      for (const end = Date.now() + waitMs; ;) {
        try { rc = await receiptOf(s.transaction, end); why = "receipt_not_found"; } catch (e) { rc = null; why = e.message; }
        if (rc || Date.now() >= end) break;
        await sleep(Math.min(pollMs, Math.max(0, end - Date.now())));
      }
      if (!rc) { try { onUnconfirmed?.({ transaction: s.transaction, reason: why }); } catch (_) {} return s; } // unknown: the facilitator's word stands
      if (receiptPaysUsdg(rc, { asset, from: a.from, nonce: a.nonce, payTo: requirements.payTo, amount: requirements.amount })) return s;
      return { ...s, success: false, errorReason: "settlement_moved_nothing", errorMessage: "the settlement transaction moved no USDG to payTo: its receipt has no USDG AuthorizationUsed and Transfer for this payment" };
    },
  };
}

/**
 * An `x402ResourceServer` that settles through the Priors facilitator and prices `eip155:4663` in USDG: the
 * three lines of the README's merchant snippet in one call. Pass it to `paymentMiddleware` (@x402/express,
 * @x402/hono, @x402/next) or `createPaymentWrapper` (@x402/mcp). `confirm` (true, or confirmSettlements' options)
 * also reads each USDG settlement's receipt before the paid response is released (`confirmSettlements`).
 * @param {{ url?: string, apiKey?: string, timeoutMs?: number, asset?: string, facilitatorClient?: any,
 *   confirm?: boolean | object }} [opts]
 */
export function createResourceServer({ asset, facilitatorClient, confirm = false, ...facilitator } = {}) {
  let client = facilitatorClient || priorsFacilitatorClient(facilitator);
  if (confirm) client = confirmSettlements(client, { ...(asset ? { asset } : {}), ...(confirm === true ? {} : confirm) });
  return new x402ResourceServer(client).register(robinhood.network, registerUsdg(new ExactEvmScheme(), { asset }));
}
