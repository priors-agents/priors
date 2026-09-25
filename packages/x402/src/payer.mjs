// Agent side: pay x402 USDG requirements on Robinhood Chain, borrowing the gap from a Priors v2 line when short.
//
// Built on the official client stack: `x402Client` and `x402HTTPClient` (re-exported by @x402/fetch from
// @x402/core) parse the 402, apply spend controls, build the v2 payload and encode the PAYMENT-SIGNATURE header,
// and `ExactEvmScheme` (@x402/evm) signs the EIP-3009 authorization. The request loop itself is written out here
// instead of calling `wrapFetchWithPayment`, because that wrapper cannot keep this module's promises:
//   1. Borrowing must happen after the price is known and checked, and before anything is signed. The wrapper
//      only offers a hook inside `createPaymentPayload`; a refusal there comes back as a generic
//      "Failed to create payment payload" Error, which loses the refusal code callers branch on.
//   2. One signature per purchase. When a payment-response hook reports `recovered`, the wrapper signs a FRESH
//      payload and sends it again, while the first authorization may still settle: that is how a call is paid
//      twice. Here the one signed header is resent unchanged while the merchant answers "pending", and handed back
//      (`paymentHeaders`) if it is still pending, for `resend()` later.
//   3. It has no pending loop at all, and it returns only the Response, so the signed header cannot be resent.
//   4. Legacy x402 v1 bodies with network "robinhood" (our facilitator, api/server.mjs, sdk/float.mjs) are not a
//      network @x402/evm's v1 scheme knows; they go to the v1 signer ported from sdk/float.mjs instead.
// `createUsdgClient()` still gives a plain x402Client for @x402/fetch's wrapper or @x402/mcp's client, with the
// same USDG allowance, price cap and 600 s authorization cap, for callers that never borrow.
import { ethers } from "ethers";
import { x402Client, x402HTTPClient, decodePaymentResponseHeader } from "@x402/fetch";
import { ExactEvmScheme } from "@x402/evm/exact/client";
import { robinhood, ROBINHOOD_NETWORKS, DEFAULT_MAX_PRICE, MAX_VALIDITY_SECONDS, TRANSFER_WITH_AUTHORIZATION_TYPES, toAtomicUsdg } from "./robinhood.mjs";
import { PayError, borrowGap, settleLoans, poolContract, ERC20_ABI } from "./credit.mjs";

const sameAddr = (a, b) => typeof a === "string" && typeof b === "string" && ethers.isAddress(a) && ethers.isAddress(b) && ethers.getAddress(a) === ethers.getAddress(b);
const defaultSleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** The capped window: the merchant's maxTimeoutSeconds, at most `cap` (never above 600 s), 60 s if it names none. */
function validityWindow(asked, cap = MAX_VALIDITY_SECONDS) {
  const c = Math.min(Number(cap) > 0 ? Number(cap) : MAX_VALIDITY_SECONDS, MAX_VALIDITY_SECONDS);
  const a = Number(asked);
  return Number.isSafeInteger(a) && a > 0 ? Math.min(a, c) : Math.min(60, c);
}

/**
 * An ethers v6 Signer as the `ClientEvmSigner` @x402/evm expects ({address, signTypedData({domain, types,
 * primaryType, message})}). A viem LocalAccount already has that shape and is returned as is.
 * @param {any} signer
 * @param {string} [address]  the signer's address, if already known (ethers signers resolve it asynchronously)
 */
export function toX402Signer(signer, address) {
  if (signer && typeof signer.address === "string" && typeof signer.signTypedData === "function" && typeof signer.getAddress !== "function") return signer;
  const addr = address || signer?.address;
  if (!addr || !ethers.isAddress(addr)) throw new PayError("NO_SIGNER", "toX402Signer: the signer's address is needed (pass it, or use an ethers Wallet)");
  return {
    address: ethers.getAddress(addr),
    async signTypedData({ domain, types, message }) {
      const t = { ...types };
      delete t.EIP712Domain;
      return signer.signTypedData(domain, t, message);
    },
  };
}

/**
 * `ExactEvmScheme` (client) for USDG on eip155:4663 that never signs an authorization valid for more than
 * `maxValiditySeconds` (≤ 600), whatever `maxTimeoutSeconds` the 402 names. The signed window is capped; the
 * payload's `accepted` stays the merchant's requirement verbatim (the resource server matches it field for field).
 * A requirement without `extra.name/version` is signed on USDG's own domain.
 */
export class CappedExactEvmScheme {
  /** @param {any} signer ClientEvmSigner (or an ethers Wallet) @param {{ maxValiditySeconds?: number }} [o] */
  constructor(signer, { maxValiditySeconds = MAX_VALIDITY_SECONDS } = {}) {
    this.scheme = "exact";
    this.inner = new ExactEvmScheme(signer && typeof signer.getAddress === "function" ? toX402Signer(signer) : signer);
    this.maxValiditySeconds = maxValiditySeconds;
  }
  async createPaymentPayload(x402Version, requirements, context) {
    if (requirements?.extra?.assetTransferMethod && requirements.extra.assetTransferMethod !== "eip3009") throw new PayError("UNSUPPORTED_TRANSFER_METHOD", "only EIP-3009 authorizations are signed for USDG");
    const extra = { ...(requirements.extra || {}) };
    if (!extra.name) extra.name = robinhood.eip712.name;
    if (!extra.version) extra.version = robinhood.eip712.version;
    const signed = { ...requirements, maxTimeoutSeconds: validityWindow(requirements.maxTimeoutSeconds, this.maxValiditySeconds), extra };
    return this.inner.createPaymentPayload(x402Version, signed, context);
  }
}

/**
 * An `x402Client` that pays USDG on eip155:4663 only: capped signing window, and a spend control that refuses any
 * requirement above `maxPrice` (atomic USDG or "$0.10"; default 0.10). Use it with @x402/fetch's
 * `wrapFetchWithPayment` or @x402/mcp's `wrapMCPClientWithPayment` when no borrowing is wanted.
 * @param {{ signer: any, maxPrice?: bigint|number|string, maxValiditySeconds?: number, asset?: string }} o
 */
export function createUsdgClient({ signer, maxPrice = DEFAULT_MAX_PRICE, maxValiditySeconds = MAX_VALIDITY_SECONDS, asset = robinhood.usdg, x402Signer } = {}) {
  const cap = toAtomicUsdg(maxPrice, "maxPrice");
  return new x402Client()
    .register(robinhood.network, new CappedExactEvmScheme(x402Signer || signer, { maxValiditySeconds }))
    .setSpendControls({ allowedAssets: [{ network: robinhood.network, asset, maxAmountPerPayment: cap.toString() }] });
}

/** First v2 `exact` USDG requirement on eip155:4663 this payer can sign (EIP-3009, USDG's domain). */
export function pickV2Requirement(accepts, asset = robinhood.usdg) {
  return (Array.isArray(accepts) ? accepts : []).find((r) => r && r.scheme === "exact" && r.network === robinhood.network && sameAddr(r.asset, asset)
    && /^\d+$/.test(String(r.amount)) && ethers.isAddress(r.payTo || "")
    && (!r.extra?.assetTransferMethod || r.extra.assetTransferMethod === "eip3009")
    && (!r.extra?.name || r.extra.name === robinhood.eip712.name) && (!r.extra?.version || r.extra.version === robinhood.eip712.version)) || null;
}

/** First v1 `exact` USDG requirement on Robinhood Chain (sdk/float.mjs `pickRequirement`). */
export function pickV1Requirement(accepts, asset = robinhood.usdg) {
  return (Array.isArray(accepts) ? accepts : []).find((r) => r && r.scheme === "exact" && ROBINHOOD_NETWORKS.has(r.network) && sameAddr(r.asset, asset)
    && /^\d+$/.test(String(r.maxAmountRequired)) && ethers.isAddress(r.payTo || "")) || null;
}

/**
 * Sign a v1 X-PAYMENT for `req` (port of sdk/float.mjs `signPayment`): EIP-3009 on USDG's domain, valid from 10
 * minutes ago (clock skew) until the merchant's window capped at 600 s, base64 JSON as the Priors facilitator reads it.
 */
export async function signPaymentV1(signer, req, { now = Math.floor(Date.now() / 1000), chainId = robinhood.chainId, maxValiditySeconds = MAX_VALIDITY_SECONDS } = {}) {
  const from = await signer.getAddress();
  const authorization = {
    from,
    to: ethers.getAddress(req.payTo),
    value: String(req.maxAmountRequired),
    validAfter: String(now - 600),
    validBefore: String(now + validityWindow(req.maxTimeoutSeconds, maxValiditySeconds)),
    nonce: ethers.hexlify(ethers.randomBytes(32)),
  };
  const domain = { ...robinhood.eip712, chainId, verifyingContract: ethers.getAddress(req.asset) };
  const signature = await signer.signTypedData(domain, TRANSFER_WITH_AUTHORIZATION_TYPES, authorization);
  const json = JSON.stringify({ x402Version: 1, scheme: "exact", network: req.network, payload: { signature, authorization } });
  return Buffer.from(json, "utf8").toString("base64");
}

/** Does this response say "your payment was broadcast, not confirmed yet: send the same one again"? */
async function isPending(response) {
  if (response.status !== 402) return false;
  for (const name of ["PAYMENT-RESPONSE", "X-PAYMENT-RESPONSE"]) {
    const h = response.headers.get(name);
    if (!h) continue;
    try { if (decodePaymentResponseHeader(h)?.errorReason === "settlement_pending") return true; } catch (_) { /* not a settle response */ }
  }
  try { const b = await response.clone().json(); return b?.pending === true || b?.errorReason === "settlement_pending"; } catch (_) { return false; }
}

function settlementOf(response) {
  for (const name of ["PAYMENT-RESPONSE", "X-PAYMENT-RESPONSE"]) {
    const h = response.headers.get(name);
    if (h) { try { return decodePaymentResponseHeader(h); } catch (_) { /* ignore */ } }
  }
  return undefined;
}

const asRequest = (input, init) => (input instanceof Request && !init ? input : new Request(input, init));

/**
 * Send an already-signed payment (`paymentHeaders`, e.g. {"PAYMENT-SIGNATURE": "…"}) and keep resending the SAME
 * one while the merchant answers 402 pending (x402 v2 `settlement_pending`, or a legacy `{pending:true}` body).
 * Never signs anything.
 * @returns {Promise<{ response: Response, pending: boolean, paymentHeaders?: Record<string,string> }>}
 */
export async function resend(input, paymentHeaders, { init, fetchImpl = globalThis.fetch, retries = 6, sleep = defaultSleep } = {}) {
  const base = asRequest(input, init);
  const send = () => {
    const r = base.clone();
    for (const [k, v] of Object.entries(paymentHeaders)) r.headers.set(k, v);
    r.headers.set("Access-Control-Expose-Headers", "PAYMENT-RESPONSE,X-PAYMENT-RESPONSE");
    return fetchImpl(r);
  };
  let response = await send();
  for (let i = 0; i < retries && (await isPending(response)); i++) {
    const after = Number(response.headers.get("retry-after"));
    await sleep(1000 * Math.min(30, Math.max(1, Number.isFinite(after) && after > 0 ? after : 5)));
    response = await send();
  }
  const pending = await isPending(response);
  return { response, pending, ...(pending ? { paymentHeaders } : {}) };
}

/**
 * A payer for x402 USDG on Robinhood Chain.
 * @param {import("../index.d.ts").CreatePayerOptions} opts
 * @returns {import("../index.d.ts").Payer}
 */
export function createPayer(opts = {}) {
  const { signer, agentId, pool, termSeconds, maxFee, asset, fetchImpl = globalThis.fetch, pendingRetries = 6, sleep = defaultSleep, maxValiditySeconds = MAX_VALIDITY_SECONDS } = opts;
  if (!signer || typeof signer.getAddress !== "function" || typeof signer.signTypedData !== "function") {
    throw new PayError("NO_SIGNER", "createPayer: `signer` must be an ethers v6 Signer (a Wallet connected to a Robinhood Chain provider)");
  }
  if (typeof fetchImpl !== "function") throw new PayError("NO_FETCH", "createPayer: no fetch implementation");
  const maxPrice = toAtomicUsdg(opts.maxPrice ?? DEFAULT_MAX_PRICE, "maxPrice");
  const maxBorrow = toAtomicUsdg(opts.maxBorrow ?? 0n, "maxBorrow");
  const http = new x402HTTPClient(new x402Client());

  async function pay(input, init) {
    const base = asRequest(input, init);
    const first = await fetchImpl(base.clone());
    if (first.status !== 402) return { response: first, paid: 0n, borrowed: 0n, loanId: null, dueAt: null };

    const poolC = pool ? poolContract(pool, signer) : null;
    const usdgAddr = asset || (poolC ? await poolC.usdg() : robinhood.usdg);
    let body;
    try { const t = await first.text(); body = t ? JSON.parse(t) : undefined; } catch (_) { body = undefined; }
    let paymentRequired;
    try { paymentRequired = http.getPaymentRequiredResponse((n) => first.headers.get(n), body); } catch (_) {
      if (body && body.x402Version === 2 && Array.isArray(body.accepts)) paymentRequired = body;
      else throw new PayError("BAD_402", "pay: the 402 response carries no x402 payment requirements");
    }
    const version = paymentRequired?.x402Version;
    const req = version === 2 ? pickV2Requirement(paymentRequired.accepts, usdgAddr) : version === 1 ? pickV1Requirement(paymentRequired.accepts, usdgAddr) : null;
    if (version !== 1 && version !== 2) throw new PayError("BAD_402", `pay: unsupported x402Version ${JSON.stringify(version)}`);
    if (!req) throw new PayError("NO_USDG_REQUIREMENT", "pay: the resource does not accept exact USDG on Robinhood Chain");

    const price = BigInt(version === 2 ? req.amount : req.maxAmountRequired);
    // The merchant names the price. Without a cap a funded agent signs whatever a 402 asks (its whole balance).
    if (price > maxPrice) throw new PayError("PRICE_ABOVE_MAX_PRICE", `pay: price ${price} is above maxPrice ${maxPrice}; not paying`, { price, maxPrice });

    const me = await signer.getAddress();
    if (!signer.provider) throw new PayError("NO_PROVIDER", "pay: the signer must be connected to a Robinhood Chain provider (to read its USDG balance)");
    const balance = await new ethers.Contract(usdgAddr, ERC20_ABI, signer).balanceOf(me);

    let loan = { borrowed: 0n, loanId: null, dueAt: null };
    if (balance < price) loan = await borrowGap({ signer, pool: poolC, agentId, price, balance, maxBorrow, termSeconds, maxFee, me });

    // Exactly one signature for this purchase, from here on only resent.
    let paymentHeaders;
    if (version === 2) {
      const client = createUsdgClient({ signer, maxPrice, maxValiditySeconds, asset: usdgAddr, x402Signer: toX402Signer(signer, me) });
      const payload = await client.createPaymentPayload({ ...paymentRequired, accepts: [req] });
      paymentHeaders = http.encodePaymentSignatureHeader(payload);
    } else {
      paymentHeaders = { "X-PAYMENT": await signPaymentV1(signer, req, { maxValiditySeconds }) };
    }
    const r = await resend(base, paymentHeaders, { fetchImpl, retries: pendingRetries, sleep });
    const settlement = r.response.ok ? settlementOf(r.response) : undefined;
    return { ...r, paid: r.response.ok ? price : 0n, borrowed: loan.borrowed, loanId: loan.loanId, dueAt: loan.dueAt, requirement: req, x402Version: version, ...(settlement ? { settlement } : {}) };
  }

  return {
    pay,
    resend: (input, paymentHeaders, init) => resend(input, paymentHeaders, { init, fetchImpl, retries: pendingRetries, sleep }),
    settleLoans: () => {
      if (!pool || agentId === undefined || agentId === null) throw new PayError("NO_POOL", "settleLoans: createPayer was given no pool/agentId");
      return settleLoans({ signer, pool, agentId });
    },
  };
}
