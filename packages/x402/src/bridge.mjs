// The Base float: moving the agent's own money between USDG on Robinhood Chain and USDC on Base, so it can pay x402
// sellers that take USDC on Base only (docs/X402-BASE-PLAN.md, phase 1). Two routes, both pinned in networks.mjs (hosts,
// contracts, tokens, by full address; the two lookalike "USDG" tokens on Robinhood Chain are never matched):
//
//   out, fundBase: Across. A quote from app.across.to is refused unless its tokens, chains and both spokes are the
//     pinned ones, the amount is above Across's minimum, the quote is fresh enough for the spoke (depositQuoteTimeBuffer
//     3600 s, less a margin to get mined), and the fee (amount - outputAmount) is within maxFeeBps. Then: an approval of
//     exactly the amount to the pinned Robinhood Chain spoke (never unlimited, and only when the allowance is short), a
//     simulated depositV3 to the wallet itself on Base with outputAmount exactly the quote's (a higher one may never
//     be filled, and then waits hours for Across's refund), the caller's record written (onDepositSending) before the
//     deposit is broadcast, and a poll of Across's deposit status (not the Base balance, which other income moves too)
//     until it is filled or the time runs out: BRIDGE_PENDING with the hash, never a second deposit. A deposit whose
//     answer was lost may have mined: DEPOSIT_UNCONFIRMED (credit.mjs sendBorrow's rule).
//   back, returnToRobinhood: Relay, gasless (the agent holds no ETH on Base). Relay's quote carries an EIP-712
//     ReceiveWithAuthorization for the agent to sign. That typed data is NEVER signed as it comes back: every field is
//     checked (primaryType, USDC's domain "USD Coin"/"2" on chain 8453, from the wallet, to Relay's pinned approval proxy,
//     the exact value, validAfter not in the future, validBefore at most ~15 minutes ahead, a 32-byte nonce, USDG on
//     Robinhood Chain by full address as the output, the wallet as recipient, the fee within maxFeeBps), and the message
//     signed is rebuilt here from those checked values on this module's own types and domain. It is a second EIP-3009
//     signature on the token x402 payments use, so it never goes through CappedExactEvmScheme or an x402 client.
//
// Nothing here borrows: a caller that bridges borrowed money (the MCP's fund_base) borrows first, against its own caps.
// Nothing here retries a transfer either: a transfer that may be out is reported (with what identifies it), never sent
// again. ethers v6.
import { ethers } from "ethers";
import { PayError, ERC20_ABI, explainRevert } from "./credit.mjs";
import { formatUsdg } from "./robinhood.mjs";
import { readCapped } from "./payer.mjs";
import { ACROSS, RELAY, ROBINHOOD_USDG, BASE_USDC } from "./networks.mjs";
// The error class every refusal here is, from this entry point too (bridge.d.ts declares it, as credit.d.ts does).
export { PayError } from "./credit.mjs";

const sameAddr = (a, b) => typeof a === "string" && typeof b === "string" && /^0x[0-9a-fA-F]{40}$/.test(a) && /^0x[0-9a-fA-F]{40}$/.test(b) && a.toLowerCase() === b.toLowerCase();
const defaultSleep = (ms) => new Promise((r) => setTimeout(r, ms));
const nowS = () => Math.floor(Date.now() / 1000);
const TX_RE = /^0x[0-9a-fA-F]{64}$/;
const B32_RE = /^0x[0-9a-fA-F]{64}$/;

/** Across SpokePool (v3.5), the subset used here: depositV3 with plain addresses, the event it emits (its address
 *  fields as bytes32), and the errors a deposit can revert with, so a refusal decodes to a name. */
export const ACROSS_SPOKE_ABI = [
  "function depositV3(address depositor, address recipient, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 destinationChainId, address exclusiveRelayer, uint32 quoteTimestamp, uint32 fillDeadline, uint32 exclusivityParameter, bytes message) payable",
  "function depositQuoteTimeBuffer() view returns (uint32)",
  "function fillDeadlineBuffer() view returns (uint32)",
  "event FundsDeposited(bytes32 inputToken, bytes32 outputToken, uint256 inputAmount, uint256 outputAmount, uint256 indexed destinationChainId, uint256 indexed depositId, uint32 quoteTimestamp, uint32 fillDeadline, uint32 exclusivityDeadline, bytes32 indexed depositor, bytes32 recipient, bytes32 exclusiveRelayer, bytes message)",
  "error InvalidQuoteTimestamp()", "error InvalidFillDeadline()", "error InvalidExclusiveRelayer()", "error DepositsArePaused()",
  "error MsgValueDoesNotMatchInputAmount()", "error DisabledRoute()", "error InvalidOutputToken()", "error MaxTransferSizeExceeded()",
];
/** EIP-3009 ReceiveWithAuthorization: what Relay's gasless route has the wallet sign on USDC. This module's own copy:
 *  the types a Relay quote carries are checked against it and never used. */
export const RECEIVE_WITH_AUTHORIZATION_TYPES = Object.freeze({
  ReceiveWithAuthorization: Object.freeze([
    { name: "from", type: "address" }, { name: "to", type: "address" }, { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" }, { name: "validBefore", type: "uint256" }, { name: "nonce", type: "bytes32" },
  ].map(Object.freeze)),
});
const USDC_AUTH_ABI = ["function authorizationState(address authorizer, bytes32 nonce) view returns (bool)"];

/** A bridge fee above this, in basis points of the amount, is refused unless the caller says otherwise. */
export const DEFAULT_MAX_FEE_BPS = 100;
/** An Across quote older than this is refused: the spoke takes one up to 3600 s old, and the deposit must be mined first. */
export const ACROSS_MAX_QUOTE_AGE_S = ACROSS.quoteTimeBuffer - 600;
/** An Across quote whose fill deadline is closer than this is refused: no time for a relayer to fill it. */
export const ACROSS_MIN_FILL_WINDOW_S = 600;
/** The longest exclusivity (seconds from the deposit) an Across quote may give one relayer. */
export const ACROSS_MAX_EXCLUSIVITY_S = 600;
/** Relay's quote slippage, asked for explicitly (basis points); a quote whose minimum out sits further below its expected
 *  out than RELAY_MAX_SLIPPAGE_BPS is refused. */
export const RELAY_SLIPPAGE_BPS = 50;
export const RELAY_MAX_SLIPPAGE_BPS = 200;

/** A whole number from an API field (a JSON number or a digit string), or null. */
function uintOf(v) {
  if (typeof v === "number" && Number.isSafeInteger(v) && v >= 0) return BigInt(v);
  if (typeof v === "string" && /^\d{1,78}$/.test(v)) return BigInt(v);
  return null;
}
/** A token field as Across writes it: an address, or { address, chainId }. */
const tokenAddr = (t) => (typeof t === "string" ? t : t && typeof t === "object" ? t.address : null);
const tokenChain = (t) => (t && typeof t === "object" && t.chainId !== undefined ? Number(t.chainId) : null);
/** bytes32 as Across's event writes an address. */
const b32Addr = (b) => ethers.getAddress(ethers.dataSlice(b, 12));

/** An API answer as JSON: at most 256 KB read, a timeout, and no answer text quoted in an error (it would reach a model). */
async function getJson(fetchImpl, url, init, timeoutMs, code, what) {
  let r;
  try { r = await fetchImpl(url, { ...(init || {}), headers: { accept: "application/json", ...(init?.headers || {}) }, signal: AbortSignal.timeout(timeoutMs) }); } catch (e) {
    throw new PayError(code, `${what}: could not reach it (${e?.name === "TimeoutError" ? "timed out" : e?.code || e?.name || "network error"})`);
  }
  let body = null;
  try { const { text, cut } = await readCapped(r, 256 * 1024); if (!cut && text) body = JSON.parse(text); } catch (_) { body = null; }
  return { status: r.status, ok: r.ok, body };
}

// ---------------------------------------------------------------------------------------------------------------
// Across: Robinhood Chain USDG -> Base USDC
// ---------------------------------------------------------------------------------------------------------------

/**
 * An Across suggested-fees answer, checked: every field the deposit uses is read from here and refused unless it is
 * what the pinned route allows. Pure (no network), so each rule can be tested on its own.
 * @param {any} q  the JSON answer
 * @param {{ amount: bigint, maxFeeBps?: number, now?: number }} o
 */
export function checkAcrossQuote(q, { amount, maxFeeBps = DEFAULT_MAX_FEE_BPS, now = nowS() }) {
  const no = (m, d = {}) => new PayError("BRIDGE_QUOTE_REFUSED", `Across quote refused: ${m}; nothing was sent`, d);
  amount = BigInt(amount);
  if (!q || typeof q !== "object") throw no("no quote in the answer");
  if (!sameAddr(tokenAddr(q.inputToken), ROBINHOOD_USDG.asset) || (tokenChain(q.inputToken) !== null && tokenChain(q.inputToken) !== ROBINHOOD_USDG.chainId)) throw no("its input token is not USDG on Robinhood Chain");
  if (!sameAddr(tokenAddr(q.outputToken), BASE_USDC.asset) || (tokenChain(q.outputToken) !== null && tokenChain(q.outputToken) !== BASE_USDC.chainId)) throw no("its output token is not USDC on Base");
  if (!sameAddr(q.spokePoolAddress, ACROSS.spokes[ROBINHOOD_USDG.chainId])) throw no("it names another Robinhood Chain spoke than the pinned one");
  if (!sameAddr(q.destinationSpokePoolAddress, ACROSS.spokes[BASE_USDC.chainId])) throw no("it names another Base spoke than the pinned one");
  if (q.isAmountTooLow !== false) throw no(`the amount is below Across's minimum`);
  const minDeposit = uintOf(q.limits?.minDeposit);
  if (minDeposit === null || amount < minDeposit) throw no(`${formatUsdg(amount)} USDG is below Across's minimum of ${minDeposit === null ? "an unknown amount" : `${formatUsdg(minDeposit)} USDG`}`, { minDeposit });
  const maxDeposit = uintOf(q.limits?.maxDeposit);
  if (maxDeposit !== null && amount > maxDeposit) throw no("the amount is above Across's maximum");
  const outputAmount = uintOf(q.outputAmount);
  if (outputAmount === null || outputAmount === 0n || outputAmount > amount) throw no("its output amount is missing, zero or above the amount sent");
  const timestamp = uintOf(q.timestamp);
  if (timestamp === null || timestamp > BigInt(now + 60) || BigInt(now) - timestamp > BigInt(ACROSS_MAX_QUOTE_AGE_S)) throw no("its timestamp is not within the spoke's quote window");
  const fillDeadline = uintOf(q.fillDeadline);
  if (fillDeadline === null || fillDeadline < BigInt(now + ACROSS_MIN_FILL_WINDOW_S) || fillDeadline > timestamp + BigInt(ACROSS.fillDeadlineBuffer) || fillDeadline > 0xffffffffn) throw no("its fill deadline is too close or beyond what the spoke accepts");
  const exclusiveRelayer = typeof q.exclusiveRelayer === "string" && /^0x[0-9a-fA-F]{40}$/.test(q.exclusiveRelayer) ? ethers.getAddress(q.exclusiveRelayer) : null;
  const exclusivity = uintOf(q.exclusivityDeadline ?? 0);
  if (exclusiveRelayer === null || exclusivity === null || exclusivity > BigInt(ACROSS_MAX_EXCLUSIVITY_S) || (exclusiveRelayer === ethers.ZeroAddress && exclusivity !== 0n)) throw no("its exclusivity is not a relayer for at most a few minutes");
  const fee = amount - outputAmount;
  const bps = Number((fee * 10_000n) / amount);
  if (fee * 10_000n > amount * BigInt(maxFeeBps)) throw new PayError("BRIDGE_FEE_TOO_HIGH", `Across quote refused: the fee is ${formatUsdg(fee)} USDG (${bps / 100}%), above the ${maxFeeBps / 100}% allowed; nothing was sent`, { fee, feeBps: bps, maxFeeBps });
  return Object.freeze({
    route: "across", amount, outputAmount, fee, feeBps: bps, timestamp: Number(timestamp), fillDeadline: Number(fillDeadline),
    exclusiveRelayer, exclusivityDeadline: Number(exclusivity), spoke: ACROSS.spokes[ROBINHOOD_USDG.chainId],
    estimatedFillTimeSec: Number.isSafeInteger(q.estimatedFillTimeSec) ? q.estimatedFillTimeSec : null,
  });
}

/**
 * A checked Across quote for `amount` atomic USDG from Robinhood Chain to USDC on Base (GET /api/suggested-fees on the
 * pinned host). Read-only: nothing is created anywhere.
 * @returns {Promise<ReturnType<typeof checkAcrossQuote>>}
 */
export async function acrossQuote({ amount, maxFeeBps = DEFAULT_MAX_FEE_BPS, fetchImpl = globalThis.fetch, now = nowS, timeoutMs = 10_000 }) {
  amount = BigInt(amount);
  if (amount <= 0n) throw new PayError("BAD_AMOUNT", "acrossQuote: the amount must be above zero");
  const u = new URL("/api/suggested-fees", ACROSS.api);
  for (const [k, v] of Object.entries({ inputToken: ROBINHOOD_USDG.asset, outputToken: BASE_USDC.asset, originChainId: ROBINHOOD_USDG.chainId, destinationChainId: BASE_USDC.chainId, amount: String(amount) })) u.searchParams.set(k, String(v));
  const r = await getJson(fetchImpl, u.href, {}, timeoutMs, "BRIDGE_QUOTE_FAILED", "Across quote");
  if (!r.ok) throw new PayError("BRIDGE_QUOTE_FAILED", `Across quote: HTTP ${r.status}; nothing was sent`, { status: r.status });
  return checkAcrossQuote(r.body, { amount, maxFeeBps, now: now() });
}

/**
 * Where an Across deposit stands (GET /api/deposit/status by the deposit's transaction hash, on the pinned host):
 * "filled" (landed on Base), "pending" (not filled yet, or not indexed yet: a 404), "expired" (not filled by its
 * deadline: Across refunds it to the depositor on Robinhood Chain in a later bundle, hours), "refunded", or "unknown".
 * @returns {Promise<{ status: string, fillTx: string|null, refundTx: string|null }>}
 */
export async function depositStatus({ hash, fetchImpl = globalThis.fetch, timeoutMs = 5_000 }) {
  if (!TX_RE.test(String(hash))) throw new PayError("BAD_HASH", "depositStatus: not a transaction hash");
  const u = new URL("/api/deposit/status", ACROSS.api);
  u.searchParams.set("originChainId", String(ROBINHOOD_USDG.chainId));
  u.searchParams.set("depositTxHash", hash);
  const r = await getJson(fetchImpl, u.href, {}, timeoutMs, "BRIDGE_STATUS_FAILED", "Across deposit status");
  if (r.status === 404) return { status: "pending", fillTx: null, refundTx: null };
  if (!r.ok || !r.body || typeof r.body !== "object") return { status: "unknown", fillTx: null, refundTx: null };
  const s = String(r.body.status ?? "");
  const tx = (v) => (TX_RE.test(String(v ?? "")) ? String(v) : null);
  return { status: ["pending", "filled", "expired", "refunded", "slowFillRequested"].includes(s) ? (s === "slowFillRequested" ? "pending" : s) : "unknown", fillTx: tx(r.body.fillTxnRef ?? r.body.fillTx), refundTx: tx(r.body.depositRefundTxnRef ?? r.body.depositRefundTxHash) };
}

/**
 * Move `amount` atomic USDG from the signer's wallet on Robinhood Chain to USDC in the same address on Base, through
 * Across (see the top of this file for every rule). The signer must hold the USDG and some ETH for gas on Robinhood
 * Chain. Resolves once Across reports the deposit filled; otherwise throws, and what it throws says whether anything
 * left the wallet:
 *   before the deposit is sent (nothing moved; an exact approval may stay): BRIDGE_QUOTE_REFUSED, BRIDGE_FEE_TOO_HIGH,
 *     BRIDGE_QUOTE_FAILED, INSUFFICIENT_USDG, BRIDGE_WOULD_REVERT, NOT_RECORDED, BRIDGE_REVERTED or NO_GAS (`moved: false`);
 *   after (the USDG is out, never send it again; `moved: true`, the `hash` when known): DEPOSIT_UNCONFIRMED (the answer
 *     was lost: it may have mined), BRIDGE_PENDING (mined, not filled within the time: it may still fill, or be
 *     refunded on Robinhood Chain after its fill deadline), BRIDGE_REFUNDED (Across gave it back on Robinhood Chain).
 * `onDepositSending(transfer)` is awaited right before the broadcast: a caller that keeps a record writes it there (if
 * it throws, nothing is sent: NOT_RECORDED). `onDepositSent({ ...transfer, hash })` once the hash is known (best effort).
 * The status is polled every `pollMs` until `timeoutMs` from the broadcast, or `pollUntil` (epoch ms) if sooner.
 */
export async function fundBase({ signer, amount, maxFeeBps = DEFAULT_MAX_FEE_BPS, fetchImpl = globalThis.fetch, now = nowS, timeoutMs = 30_000, pollUntil, pollMs = 2_000, sleep = defaultSleep, onDepositSending, onDepositSent }) {
  amount = BigInt(amount);
  if (amount <= 0n) throw new PayError("BAD_AMOUNT", "fundBase: the amount must be above zero");
  if (!signer || typeof signer.getAddress !== "function" || !signer.provider) throw new PayError("NO_PROVIDER", "fundBase: the signer must be an ethers Signer connected to a Robinhood Chain provider");
  const me = ethers.getAddress(await signer.getAddress());
  const q = await acrossQuote({ amount, maxFeeBps, fetchImpl, now });
  const usdg = new ethers.Contract(ROBINHOOD_USDG.asset, ERC20_ABI, signer);
  const spoke = new ethers.Contract(q.spoke, ACROSS_SPOKE_ABI, signer);
  const balance = BigInt(await usdg.balanceOf(me));
  if (balance < amount) throw new PayError("INSUFFICIENT_USDG", `fundBase: the wallet holds ${formatUsdg(balance)} USDG on Robinhood Chain, less than ${formatUsdg(amount)}; nothing was sent`, { balance, amount, moved: false });

  // Exactly the amount, to the pinned spoke, and only when the allowance is short: never an unlimited approval.
  let approveHash = null;
  if (BigInt(await usdg.allowance(me, q.spoke)) < amount) {
    try { await usdg.approve.staticCall(q.spoke, amount); } catch (e) { throw new PayError("BRIDGE_WOULD_REVERT", `fundBase: approving the Across spoke would revert (${explainRevert(e)}); nothing was sent`, { moved: false }); }
    let tx;
    try { tx = await usdg.approve(q.spoke, amount); } catch (e) {
      if (e?.code === "INSUFFICIENT_FUNDS") throw new PayError("NO_GAS", "fundBase: the wallet has no ETH for gas on Robinhood Chain; nothing was sent", { moved: false });
      throw e;
    }
    approveHash = tx.hash;
    await tx.wait(); // an approval whose answer is lost moves nothing: the error goes up as it is
  }
  const args = [me, me, ROBINHOOD_USDG.asset, BASE_USDC.asset, amount, q.outputAmount, BigInt(BASE_USDC.chainId), q.exclusiveRelayer, q.timestamp, q.fillDeadline, q.exclusivityDeadline, "0x"];
  // Simulate first: a doomed deposit says why (its custom error) before any gas is spent or any record is written.
  try { await spoke.depositV3.staticCall(...args); } catch (e) {
    throw new PayError("BRIDGE_WOULD_REVERT", `fundBase: the Across deposit would revert (${explainRevert(e, spoke.interface)}); nothing was sent${approveHash ? ` (the exact approval, tx ${approveHash}, stays)` : ""}`, { moved: false, approveHash });
  }
  const transfer = { route: "across", from: me, amount, outputAmount: q.outputAmount, fee: q.fee, quoteTimestamp: q.timestamp, fillDeadline: q.fillDeadline, startedAt: now() };
  if (typeof onDepositSending === "function") {
    try { await onDepositSending(transfer); } catch (err) {
      throw new PayError("NOT_RECORDED", `fundBase: the transfer could not be recorded (${err?.message || err}), so it was not sent`, { cause: err, moved: false, approveHash });
    }
  }

  // From here the USDG may be out. A lost answer (the broadcast's or the receipt's) may hide a deposit that mined.
  let tx, rc;
  try {
    tx = await spoke.depositV3(...args);
    if (typeof onDepositSent === "function") { try { await onDepositSent({ ...transfer, hash: tx.hash }); } catch (_) { /* best effort: the record already says a transfer may be out */ } }
    rc = await tx.wait();
  } catch (e) {
    // A refused estimate before broadcast and a mined revert both raise CALL_EXCEPTION; no gas is refused before it is
    // sent: nothing moved either way.
    if (e?.code === "CALL_EXCEPTION") throw new PayError("BRIDGE_REVERTED", `fundBase: the Across deposit reverted (${explainRevert(e, spoke.interface)}); nothing moved`, { moved: false, hash: typeof tx?.hash === "string" ? tx.hash : null, approveHash });
    if (e?.code === "INSUFFICIENT_FUNDS") throw new PayError("NO_GAS", "fundBase: the wallet has no ETH for gas on Robinhood Chain; nothing was sent", { moved: false, approveHash });
    const hash = typeof tx?.hash === "string" ? tx.hash : null;
    throw new PayError("DEPOSIT_UNCONFIRMED", `fundBase: an Across deposit of ${formatUsdg(amount)} USDG was sent${hash ? ` (tx ${hash})` : ""} and its answer was lost (${e?.shortMessage || e?.message || String(e)}): it may have mined. Do not send it again`,
      { moved: true, unconfirmed: true, hash, amount, outputAmount: q.outputAmount, fillDeadline: q.fillDeadline, cause: e });
  }
  // The deposit as the spoke recorded it: each field is what was asked for, or the difference is reported.
  const ev = (rc?.logs || []).filter((l) => sameAddr(l.address, q.spoke)).map((l) => { try { return spoke.interface.parseLog(l); } catch (_) { return null; } }).find((x) => x && x.name === "FundsDeposited");
  const depositId = ev ? BigInt(ev.args.depositId) : null;
  const mismatch = [];
  if (ev) {
    const a = ev.args;
    if (b32Addr(a.depositor) !== me) mismatch.push("depositor");
    if (b32Addr(a.recipient) !== me) mismatch.push("recipient");
    if (!sameAddr(b32Addr(a.inputToken), ROBINHOOD_USDG.asset)) mismatch.push("inputToken");
    if (!sameAddr(b32Addr(a.outputToken), BASE_USDC.asset)) mismatch.push("outputToken");
    if (BigInt(a.inputAmount) !== amount) mismatch.push("inputAmount");
    if (BigInt(a.outputAmount) !== q.outputAmount) mismatch.push("outputAmount");
    if (BigInt(a.destinationChainId) !== BigInt(BASE_USDC.chainId)) mismatch.push("destinationChainId");
  }
  const done = { route: "across", hash: tx.hash, approveHash, depositId, amount, outputAmount: q.outputAmount, fee: q.fee, feeBps: q.feeBps, fillDeadline: q.fillDeadline, ...(ev ? {} : { noEvent: true }), ...(mismatch.length ? { mismatch } : {}) };

  const until = Math.min(Date.now() + timeoutMs, Number.isFinite(pollUntil) ? pollUntil : Infinity);
  let last = "pending";
  for (;;) {
    let st;
    try { st = await depositStatus({ hash: tx.hash, fetchImpl, timeoutMs: Math.max(500, Math.min(5_000, until - Date.now())) }); } catch (_) { st = { status: "unknown" }; }
    last = st.status;
    if (st.status === "filled") return { ...done, filled: true, fillTx: st.fillTx };
    if (st.status === "refunded") throw new PayError("BRIDGE_REFUNDED", `fundBase: Across did not fill the deposit (tx ${tx.hash}) and refunded it to ${me} on Robinhood Chain${st.refundTx ? ` (tx ${st.refundTx})` : ""}`, { ...done, moved: true, status: st.status, refundTx: st.refundTx });
    if (Date.now() + pollMs >= until) break;
    await sleep(pollMs);
  }
  throw new PayError("BRIDGE_PENDING", `fundBase: the Across deposit (tx ${tx.hash}) was sent and had not landed on Base when the wait ended (status ${last}). It may still land, or after its fill deadline (${new Date(q.fillDeadline * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC) Across refunds it on Robinhood Chain. Do not send it again`,
    { ...done, moved: true, status: last });
}

// ---------------------------------------------------------------------------------------------------------------
// Relay: Base USDC -> Robinhood Chain USDG, gasless
// ---------------------------------------------------------------------------------------------------------------

/**
 * Relay's quote for `amount` atomic USDC on Base to USDG on Robinhood Chain, exact input, gasless (POST /quote on the
 * pinned host: it creates nothing on chain). The raw answer: checkRelayReturn decides what of it is used.
 */
export async function relayQuote({ me, amount, fetchImpl = globalThis.fetch, timeoutMs = 10_000 }) {
  const body = {
    user: me, recipient: me, originChainId: BASE_USDC.chainId, destinationChainId: ROBINHOOD_USDG.chainId,
    originCurrency: BASE_USDC.asset, destinationCurrency: ROBINHOOD_USDG.asset, amount: String(BigInt(amount)),
    tradeType: "EXACT_INPUT", usePermit: true, slippageTolerance: String(RELAY_SLIPPAGE_BPS),
  };
  const r = await getJson(fetchImpl, new URL("/quote", RELAY.api).href, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }, timeoutMs, "RELAY_QUOTE_FAILED", "Relay quote");
  if (!r.ok || !r.body) throw new PayError("RELAY_QUOTE_FAILED", `Relay quote: HTTP ${r.status}; nothing was signed`, { status: r.status });
  return r.body;
}

/**
 * A Relay quote, checked field by field, turned into the one authorization this wallet will sign: the message is
 * rebuilt from the checked values on this module's domain and types, never taken from the quote. Pure (no network).
 * @param {any} quote  Relay's /quote answer
 * @param {{ me: string, amount: bigint, now?: number, maxFeeBps?: number }} o
 * @returns {{ requestId: string, domain: object, types: object, primaryType: "ReceiveWithAuthorization", message: object,
 *   submit: { endpoint: "/execute/permits", body: { kind: "eip3009", requestId: string, api: "swap" } },
 *   amount: bigint, expectedOut: bigint, minimumOut: bigint, fee: bigint, feeBps: number, nonce: string, validBefore: number }}
 */
export function checkRelayReturn(quote, { me, amount, now = nowS(), maxFeeBps = DEFAULT_MAX_FEE_BPS }) {
  const no = (m) => new PayError("RELAY_QUOTE_REFUSED", `Relay quote refused: ${m}; nothing was signed`);
  amount = BigInt(amount);
  if (!ethers.isAddress(me)) throw no("no wallet address");
  me = ethers.getAddress(me);
  if (!quote || typeof quote !== "object") throw no("no quote in the answer");
  const requestId = String(quote.requestId ?? "");
  if (!B32_RE.test(requestId)) throw no("its request id is not 32 bytes");
  // One step, one item: a signature. A quote that also asks for a transaction (an approval, a deposit) is not gasless.
  if (!Array.isArray(quote.steps) || quote.steps.length !== 1) throw no("it does not ask for exactly one step");
  const step = quote.steps[0];
  if (step?.kind !== "signature" || !Array.isArray(step.items) || step.items.length !== 1) throw no("its step is not one signature");
  const data = step.items[0]?.data;
  const sign = data?.sign;
  if (!sign || sign.signatureKind !== "eip712" || sign.primaryType !== "ReceiveWithAuthorization") throw no("it does not ask for a ReceiveWithAuthorization");
  // Its types must be exactly ours (anything else, signed as ours, is not what they would verify).
  const t = sign.types || {};
  const want = RECEIVE_WITH_AUTHORIZATION_TYPES.ReceiveWithAuthorization;
  const theirs = t.ReceiveWithAuthorization;
  if (Object.keys(t).some((k) => k !== "ReceiveWithAuthorization" && k !== "EIP712Domain") || !Array.isArray(theirs) || theirs.length !== want.length
    || theirs.some((f, i) => !f || f.name !== want[i].name || f.type !== want[i].type)) throw no("its typed data has other fields than ReceiveWithAuthorization's");
  const d = sign.domain || {};
  if (Object.keys(d).some((k) => !["name", "version", "chainId", "verifyingContract"].includes(k))) throw no("its domain has fields USDC's does not");
  if (d.name !== BASE_USDC.eip712.name || d.version !== BASE_USDC.eip712.version || Number(d.chainId) !== BASE_USDC.chainId || !sameAddr(d.verifyingContract, BASE_USDC.asset)) throw no("its domain is not USDC's on Base");
  const v = sign.value || {};
  if (!sameAddr(v.from, me)) throw no("the authorization is not from this wallet");
  if (!sameAddr(v.to, RELAY.receiver)) throw no("the authorization does not go to Relay's pinned approval proxy");
  if (uintOf(v.value) !== amount) throw no("the authorization's value is not the amount asked");
  const validAfter = uintOf(v.validAfter), validBefore = uintOf(v.validBefore);
  if (validAfter === null || validAfter > BigInt(now)) throw no("the authorization's validAfter is in the future");
  if (validBefore === null || validBefore <= BigInt(now + 60) || validBefore - BigInt(now) > BigInt(RELAY.maxValiditySeconds)) throw no(`the authorization is not valid for between 1 and ${RELAY.maxValiditySeconds / 60} minutes`);
  if (typeof v.nonce !== "string" || !B32_RE.test(v.nonce)) throw no("the authorization's nonce is not 32 bytes");
  const post = data.post;
  if (!post || post.endpoint !== "/execute/permits" || post.method !== "POST" || post.body?.kind !== "eip3009" || String(post.body?.requestId ?? "").toLowerCase() !== requestId.toLowerCase() || post.body?.api !== "swap") throw no("it does not submit to /execute/permits for this request");
  // What comes out, and where: USDG on Robinhood Chain by full address, to this wallet.
  const det = quote.details || {};
  if (det.sender !== undefined && !sameAddr(det.sender, me)) throw no("its sender is not this wallet");
  if (!sameAddr(det.recipient, me)) throw no("its recipient is not this wallet");
  const cin = det.currencyIn, cout = det.currencyOut;
  if (Number(cin?.currency?.chainId) !== BASE_USDC.chainId || !sameAddr(cin?.currency?.address, BASE_USDC.asset) || uintOf(cin?.amount) !== amount) throw no("what goes in is not this amount of USDC on Base");
  if (Number(cout?.currency?.chainId) !== ROBINHOOD_USDG.chainId || !sameAddr(cout?.currency?.address, ROBINHOOD_USDG.asset)) throw no("what comes out is not USDG on Robinhood Chain");
  const expectedOut = uintOf(cout?.amount), minimumOut = uintOf(cout?.minimumAmount);
  if (expectedOut === null || minimumOut === null || expectedOut === 0n || minimumOut > expectedOut || expectedOut > amount + amount / 100n) throw no("its output amounts do not add up");
  if ((expectedOut - minimumOut) * 10_000n > expectedOut * BigInt(RELAY_MAX_SLIPPAGE_BPS)) throw no(`its minimum out is more than ${RELAY_MAX_SLIPPAGE_BPS / 100}% under its expected out`);
  const fee = expectedOut >= amount ? 0n : amount - expectedOut;
  const feeBps = Number((fee * 10_000n) / amount);
  if (fee * 10_000n > amount * BigInt(maxFeeBps)) throw new PayError("BRIDGE_FEE_TOO_HIGH", `Relay quote refused: the fee is ${formatUsdg(fee)} USDC (${feeBps / 100}%), above the ${maxFeeBps / 100}% allowed; nothing was signed`, { fee, feeBps, maxFeeBps });
  return {
    requestId,
    domain: { name: BASE_USDC.eip712.name, version: BASE_USDC.eip712.version, chainId: BASE_USDC.chainId, verifyingContract: BASE_USDC.asset },
    types: { ReceiveWithAuthorization: want.map((f) => ({ ...f })) },
    primaryType: "ReceiveWithAuthorization",
    message: { from: me, to: RELAY.receiver, value: amount, validAfter, validBefore, nonce: v.nonce.toLowerCase() },
    submit: { endpoint: "/execute/permits", body: { kind: "eip3009", requestId, api: "swap" } },
    amount, expectedOut, minimumOut, fee, feeBps, nonce: v.nonce.toLowerCase(), validBefore: Number(validBefore),
  };
}

/**
 * Hand Relay the signed authorization: POST /execute/permits?signature=<sig> with the checked body.
 *
 * UNVERIFIED against the live API (2026-10-08): the request shape is the one Relay's quote names (endpoint, method,
 * body) and the one Relay's own SDK sends (@relayprotocol/relay-sdk 8.0.4, utils/executeSteps/signatureStep.js: the
 * body as JSON, the signature as the `signature` query parameter). It was not called here, because a submit can move
 * money; the owner's real-money test (docs/X402-BASE-PLAN.md, "Built (phase 1)") is what confirms it. Any answer but a
 * plain 2xx is thrown as RELAY_SUBMIT_UNCONFIRMED: Relay may have the signature anyway, so the caller treats the
 * return as in flight until the authorization expires, and never signs a second one before then. An answer that asks
 * for further steps is not followed (nothing more is ever signed or sent for a return).
 */
export async function submitRelayPermit({ plan, signature, fetchImpl = globalThis.fetch, timeoutMs = 10_000 }) {
  if (!/^0x[0-9a-fA-F]{130}$/.test(String(signature))) throw new PayError("BAD_SIGNATURE", "submitRelayPermit: not a 65-byte signature");
  const u = new URL(plan.submit.endpoint, RELAY.api);
  u.searchParams.set("signature", signature);
  let r;
  try { r = await getJson(fetchImpl, u.href, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(plan.submit.body) }, timeoutMs, "RELAY_SUBMIT_UNCONFIRMED", "Relay submit"); } catch (e) {
    throw Object.assign(e, { code: "RELAY_SUBMIT_UNCONFIRMED", requestId: plan.requestId, validBefore: plan.validBefore });
  }
  if (!r.ok) throw new PayError("RELAY_SUBMIT_UNCONFIRMED", `Relay answered HTTP ${r.status} to the signed authorization; it may still use it until it expires`, { status: r.status, requestId: plan.requestId, validBefore: plan.validBefore });
  if (Array.isArray(r.body?.steps) && r.body.steps.length) throw new PayError("RELAY_SUBMIT_UNCONFIRMED", "Relay asked for further steps after the authorization; none were taken, and it may still use the authorization until it expires", { requestId: plan.requestId, validBefore: plan.validBefore });
  return { status: r.status };
}

/**
 * Where a Relay request stands (GET /intents/status/v3 on the pinned host): "success" (the USDG was delivered),
 * "failure" or "refund" (not delivered; a refund goes back to the wallet on Base), else "pending" (waiting, pending,
 * submitted, delayed, or not known yet).
 * @returns {Promise<{ status: "success"|"failure"|"refund"|"pending", txHashes: string[] }>}
 */
export async function relayStatus({ requestId, fetchImpl = globalThis.fetch, timeoutMs = 5_000 }) {
  if (!B32_RE.test(String(requestId))) throw new PayError("BAD_REQUEST_ID", "relayStatus: not a 32-byte request id");
  const u = new URL("/intents/status/v3", RELAY.api);
  u.searchParams.set("requestId", requestId);
  const r = await getJson(fetchImpl, u.href, {}, timeoutMs, "RELAY_STATUS_FAILED", "Relay status");
  const s = String(r.body?.status ?? "");
  const txHashes = Array.isArray(r.body?.txHashes) ? r.body.txHashes.filter((h) => TX_RE.test(String(h))) : [];
  return { status: s === "success" ? "success" : s === "failure" ? "failure" : s === "refund" || s === "refunded" ? "refund" : "pending", txHashes };
}

/** Whether USDC on Base has used this EIP-3009 nonce of `from` (the authorization was spent), read on chain. */
export async function authorizationUsed({ baseProvider, from, nonce }) {
  return Boolean(await new ethers.Contract(BASE_USDC.asset, USDC_AUTH_ABI, baseProvider).authorizationState(from, nonce));
}

/**
 * Move `amount` atomic USDC from the signer's address on Base back to USDG in the same address on Robinhood Chain,
 * through Relay's gasless route: one checked, rebuilt ReceiveWithAuthorization (checkRelayReturn), signed once, handed
 * to Relay (submitRelayPermit, UNVERIFIED), and its status polled. With `baseProvider`, an amount above the Base balance
 * is refused before anything is signed. `onSigned(transfer)` is awaited after the signature and before it leaves (if it
 * throws: NOT_RECORDED, and the signature is never sent). Resolves on "success"; otherwise throws RELAY_QUOTE_REFUSED,
 * BRIDGE_FEE_TOO_HIGH, RELAY_QUOTE_FAILED, INSUFFICIENT_USDC, NOT_RECORDED (nothing left the wallet: `moved: false`),
 * RETURN_FAILED (Relay reports failure or refund: the USDC stays or comes back on Base) or RETURN_PENDING (the
 * authorization is out and may still be used until `validBefore`: never sign another before then), both `moved: true`.
 */
export async function returnToRobinhood({ signer, amount, maxFeeBps = DEFAULT_MAX_FEE_BPS, fetchImpl = globalThis.fetch, now = nowS, baseProvider, timeoutMs = 30_000, pollUntil, pollMs = 2_000, sleep = defaultSleep, onSigned }) {
  amount = BigInt(amount);
  if (amount <= 0n) throw new PayError("BAD_AMOUNT", "returnToRobinhood: the amount must be above zero");
  const me = ethers.getAddress(await signer.getAddress());
  if (baseProvider) {
    const bal = BigInt(await new ethers.Contract(BASE_USDC.asset, ERC20_ABI, baseProvider).balanceOf(me));
    if (bal < amount) throw new PayError("INSUFFICIENT_USDC", `returnToRobinhood: the wallet holds ${formatUsdg(bal)} USDC on Base, less than ${formatUsdg(amount)}; nothing was signed`, { balance: bal, amount, moved: false });
  }
  const plan = checkRelayReturn(await relayQuote({ me, amount, fetchImpl }), { me, amount, now: now(), maxFeeBps });
  const signature = await signer.signTypedData(plan.domain, plan.types, plan.message);
  if (ethers.verifyTypedData(plan.domain, plan.types, plan.message, signature) !== me) throw new PayError("BAD_SIGNATURE", "returnToRobinhood: the signature does not verify for this wallet; nothing was sent", { moved: false });
  const transfer = { route: "relay", from: me, amount, expectedOut: plan.expectedOut, fee: plan.fee, requestId: plan.requestId, nonce: plan.nonce, validBefore: plan.validBefore, startedAt: now() };
  if (typeof onSigned === "function") {
    try { await onSigned(transfer); } catch (err) { throw new PayError("NOT_RECORDED", `returnToRobinhood: the authorization could not be recorded (${err?.message || err}), so it was not sent`, { cause: err, moved: false }); }
  }
  const out = { ...transfer };
  try { await submitRelayPermit({ plan, signature, fetchImpl }); } catch (e) {
    throw new PayError("RETURN_PENDING", `returnToRobinhood: the authorization was handed to Relay and its answer was not a plain yes (${e?.message || e}); it may still be used until ${new Date(plan.validBefore * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC. Do not sign another before then`, { ...out, moved: true, cause: e });
  }
  const until = Math.min(Date.now() + timeoutMs, Number.isFinite(pollUntil) ? pollUntil : Infinity);
  let last = "pending";
  for (;;) {
    let st;
    try { st = await relayStatus({ requestId: plan.requestId, fetchImpl, timeoutMs: Math.max(500, Math.min(5_000, until - Date.now())) }); } catch (_) { st = { status: "pending", txHashes: [] }; }
    last = st.status;
    if (st.status === "success") return { ...out, delivered: true, txHashes: st.txHashes };
    // The authorization was handed over: whatever Relay reports, it is treated as out until it expires (`moved: true`).
    if (st.status === "failure" || st.status === "refund") throw new PayError("RETURN_FAILED", `returnToRobinhood: Relay reports ${st.status} for request ${plan.requestId}: the USDG was not delivered${st.status === "refund" ? " and the USDC goes back to the wallet on Base" : ""}`, { ...out, moved: true, status: st.status });
    if (Date.now() + pollMs >= until) break;
    await sleep(pollMs);
  }
  throw new PayError("RETURN_PENDING", `returnToRobinhood: Relay has the authorization (request ${plan.requestId}) and had not delivered when the wait ended (status ${last}). It may still deliver; the authorization can be used until ${new Date(plan.validBefore * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC. Do not sign another before then`, { ...out, moved: true, status: last });
}
