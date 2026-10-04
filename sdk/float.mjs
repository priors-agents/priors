// Credit as float (docs/FLOAT.md): pay an x402-priced resource from the agent's USDG, borrowing only the
// shortfall from its Priors v2 line.
//
//   import { pay, settleLoans } from "priors/float";
//   const { response, paid, borrowed, loanId } = await pay(url, { signer, pool, agentId, maxBorrow: 5_000000n, maxPrice: 1_000000n });
//   (maxPrice caps what one call pays, default 0.1 USDG: the merchant's 402 names the price, not the agent)
//   ...later, once the agent has been paid:
//   await settleLoans({ signer, pool, agentId });
//
// `signer` is the agent's wallet: the controller of `agentId` on the pool (owner or delegate) and the payer.
// The payment itself is x402 v1 "exact" on Robinhood Chain: an EIP-3009 TransferWithAuthorization signed on USDG's
// "Global Dollar" v1 domain, sent back base64-encoded in X-PAYMENT (format: sdk/x402.mjs).
import { ethers } from "ethers";
import { NETWORKS, TRANSFER_WITH_AUTHORIZATION_TYPES, domainFor, encodePaymentHeader, decodePaymentHeader, USDG_MAINNET } from "./x402.mjs";

const LOAN = "tuple(uint256 agentId, uint256 sponsorId, uint256 principal, uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium, address owner, uint64 issuedAt, uint64 dueAt, uint64 defaultableAt, uint64 minScoreTerm, uint64 closedAt, uint8 status)";
export const POOL_V2_FLOAT_ABI = [
  "function usdg() view returns (address)",
  "function getParams() view returns (tuple(uint256 minLoan, uint256 maxLoan, uint64 minTerm, uint64 maxTerm, uint64 grace, uint64 minScoreTerm, uint256 feeBps, uint256 sponsorFeeBps, uint256 protocolFeeBps, uint256 minStake, uint256 maxUtilizationBps, uint256 keeperBounty))",
  "function quoteFee(uint256 agentId, uint256 principal, uint64 term) view returns (uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium)",
  "function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee) returns (uint256)",
  "function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue)",
  "function loansOf(uint256 id) view returns (uint256[])",
  "function isController(uint256 id, address who) view returns (bool)",
  `function getLoan(uint256 loanId) view returns (${LOAN})`,
  "event Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 indexed sponsorId, uint256 principal, uint256 fee, uint64 dueAt, address to)",
];
const ERC20 = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const LOAN_ACTIVE = 1n;
/** Default most one pay() call signs away, atomic USDG (0.1 USDG, the x402 reference client's default cap). */
export const DEFAULT_MAX_PRICE = 100_000n;
/** Default longest an authorization stays cashable, seconds, whatever maxTimeoutSeconds the merchant asks. */
export const DEFAULT_MAX_VALIDITY_SECONDS = 600;
/** Default loan term when pay() has to borrow: float is pay now, get paid within the week (x402 audit F3). */
export const DEFAULT_TERM_SECONDS = 7 * 86400;

export class FloatError extends Error {
  constructor(code, message, details = {}) { super(message); this.name = "FloatError"; this.code = code; Object.assign(this, details); }
}

const poolContract = (pool, signer) => (typeof pool === "string" ? new ethers.Contract(pool, POOL_V2_FLOAT_ABI, signer) : pool.connect ? pool.connect(signer) : pool);
const sameAddr = (a, b) => typeof a === "string" && typeof b === "string" && ethers.isAddress(a) && ethers.isAddress(b) && ethers.getAddress(a) === ethers.getAddress(b);

// ---------------------------------------------------------------------------------------------------------------
// A line sponsored by the V5 seat vault (addresses.seatVaultV5, once it is deployed): the borrower's refresh first
// ---------------------------------------------------------------------------------------------------------------

/**
 * The V5 seat vault, the calls a borrower makes on it. V5's `open` records a line but vouches nothing on the pool: the
 * line becomes borrowable through `refresh(agentId)`, sent by the agent's owner, or by its pool delegate once V5 has
 * recorded that delegate (`noteDelegate(agentId)`, which anyone may send) for 24 hours.
 */
export const SEAT_VAULT_V5_ABI = [
  "function rootId() view returns (uint256)",
  "function refresh(uint256 id)",
  "function noteDelegate(uint256 id)",
  "function delegateOf(uint256 id) view returns (address who, uint64 at)",
  "error Reentrancy()", "error NoPrice()", "error BookNotOpen()", "error ReadStarved()",
];
const V5_AGENT_T = "tuple(bool enrolled,bool isRoot,bool defaulted,bool frozen,bool importedFromV1,uint64 enrolledAt,uint64 lastBorrowAt,uint64 lastRepayAt,uint256 sponsor,uint256 delegatedIn,uint256 delegatedOut,uint256 principalOut,uint256 activeLoans,uint256 premiumBps,uint256 premiumCap,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid)";
const V5_POOL_ABI = [`function getAgent(uint256) view returns (${V5_AGENT_T})`, "function registry() view returns (address)"];
const V5_DELEGATE_WAIT = 86_400n;
const V5_WORDS = {
  NoPrice: "V5 has no price yet; try again after V5's keeper syncs",
  BookNotOpen: "the agent has no open line on the V5 seat vault",
  ReadStarved: "the refresh ran out of gas",
  Reentrancy: "V5 was inside another call; try again",
};
/** Gas for a V5 call: estimate x 1.5 + 150 000. At a bare estimate V5's bounded reads inside `refresh` are starved and
 *  caught, so the call succeeds and skips its raise. */
const v5GasLimit = (estimate) => (BigInt(estimate) * 3n) / 2n + 150_000n;
const addressOf = async (c) => (typeof c === "string" ? c : c.getAddress());
const usdgText = (units) => `${ethers.formatUnits(units, 6)} USDG`;
const isoTime = (s) => new Date(Number(s) * 1000).toISOString();
function v5Reason(err, iface) {
  const data = err?.data ?? err?.info?.error?.data ?? err?.error?.data;
  let name = err?.revert?.name;
  if (!name && typeof data === "string" && data.length >= 10) { try { name = iface.parseError(data)?.name; } catch (_) { /* not V5's */ } }
  if (name) return V5_WORDS[name] ? `${name} (${V5_WORDS[name]})` : name;
  return err?.shortMessage || err?.reason || err?.message || String(err);
}

/**
 * The step before a borrow on a line the V5 seat vault sponsors. V5 vouches nothing when it opens a line and raises the
 * pool's vouch only on the borrower's own `refresh(agentId)`, from a price under 45 minutes old; without it the borrow
 * reverts InsufficientCapacity. When `agentId`'s sponsor is V5's root (`seatVaultV5AgentId`, else V5's `rootId()`), this
 * sends that refresh with gas = estimate x 1.5 + 150 000, waits for it, and checks the line now covers `amount`.
 * Without `seatVaultV5` it reads and sends nothing; on a line another root sponsors it sends nothing.
 * Refused before anything is sent: a signer that is not the agent's owner and that V5 has not recorded as its delegate,
 * or recorded less than 24 hours ago (V5 would take the refresh and skip the raise). Every error has a `code`
 * (V5_DELEGATE_NOT_NOTED, V5_DELEGATE_WAITING, V5_REFRESH_FAILED, V5_LINE_SHORT) and means nothing was borrowed.
 * @param {{ signer: ethers.Signer, pool: string|ethers.Contract, seatVaultV5?: string|ethers.Contract|null,
 *   seatVaultV5AgentId?: bigint|number|string, agentId: bigint|number|string, amount?: bigint }} o
 * @returns {Promise<null | { hash: string, sponsor: bigint, available: bigint }>} null when nothing was sent
 */
export async function refreshV5Line({ signer, pool, seatVaultV5, seatVaultV5AgentId, agentId, amount }) {
  if (!seatVaultV5) return null;
  const id = BigInt(agentId);
  const poolR = new ethers.Contract(await addressOf(pool), V5_POOL_ABI, signer);
  const v5 = new ethers.Contract(await addressOf(seatVaultV5), SEAT_VAULT_V5_ABI, signer);
  const { sponsor } = await poolR.getAgent(id);
  if (sponsor === 0n) return null;
  const root = seatVaultV5AgentId === undefined || seatVaultV5AgentId === null ? await v5.rootId() : BigInt(seatVaultV5AgentId);
  if (sponsor !== root) return null;

  // Up only for the owner, or for the pool delegate V5 recorded at least 24 h ago (V5 skips the raise for anyone else).
  const me = await signer.getAddress();
  const owner = await new ethers.Contract(await poolR.registry(), ["function ownerOf(uint256) view returns (address)"], signer).ownerOf(id);
  if (!sameAddr(owner, me)) {
    const [who, at] = await v5.delegateOf(id);
    if (!sameAddr(who, me)) {
      throw new FloatError("V5_DELEGATE_NOT_NOTED", `agent #${id}'s line is sponsored by the V5 seat vault, which raises it only on a refresh from the agent's owner (${owner}) or from a pool delegate it recorded at least 24 h ago, and it has not recorded ${me}. Make this key the agent's pool delegate, send noteDelegate(${id}) to the V5 seat vault (anyone may), and borrow with this key 24 h later; or borrow with the owner's key. Nothing was sent.`, { agentId: id, delegate: who });
    }
    const now = BigInt((await signer.provider.getBlock("latest")).timestamp);
    if (now < at + V5_DELEGATE_WAIT) {
      throw new FloatError("V5_DELEGATE_WAITING", `the V5 seat vault recorded ${me} as agent #${id}'s delegate at ${isoTime(at)}, and a delegate's refresh raises the line only 24 h after that: borrow with this key from ${isoTime(at + V5_DELEGATE_WAIT)}, or with the owner's key (${owner}) now. Nothing was sent.`, { agentId: id, readyAt: Number(at + V5_DELEGATE_WAIT) });
    }
  }

  const refresh = v5.getFunction("refresh");
  const failed = (e, sent) => new FloatError("V5_REFRESH_FAILED", `refresh(${id}) on the V5 seat vault ${sent ? "failed" : "would revert"}: ${v5Reason(e, v5.interface)}. Nothing was borrowed.`, { agentId: id, cause: e });
  let gasLimit;
  try {
    await refresh.staticCall(id);
    gasLimit = v5GasLimit(await refresh.estimateGas(id));
  } catch (e) { throw failed(e, false); }
  let tx, rc;
  try { tx = await refresh(id, { gasLimit }); rc = await tx.wait(); } catch (e) { throw failed(e, true); }
  if (!rc || rc.status !== 1) throw failed(new Error(`mined with status 0 (tx ${tx.hash})`), true);

  const a = await poolR.getAgent(id);
  const available = a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0n;
  if (amount !== undefined && available < BigInt(amount)) {
    throw new FloatError("V5_LINE_SHORT", `refresh(${id}) on the V5 seat vault (tx ${tx.hash}) left ${usdgText(available)} to draw, below the ${usdgText(BigInt(amount))} asked: V5 raises a line only from a price under 45 minutes old (try again after V5's keeper syncs), and only as far as its backing allows now. Nothing was borrowed.`, { agentId: id, available, hash: tx.hash });
  }
  return { hash: tx.hash, sponsor, available };
}

/** Pick the first "exact" USDG-on-Robinhood requirement from a 402 body. */
export function pickRequirement(body, asset = USDG_MAINNET) {
  const accepts = Array.isArray(body?.accepts) ? body.accepts : [];
  return accepts.find((r) => r && r.scheme === "exact" && NETWORKS.has(r.network) && sameAddr(r.asset, asset) && /^\d+$/.test(String(r.maxAmountRequired)) && ethers.isAddress(r.payTo || "")) || null;
}

/**
 * Sign an EIP-3009 authorization for `req` and return the X-PAYMENT header value. The window runs until the
 * merchant's maxTimeoutSeconds, capped at `maxValiditySeconds`: the 402 body is the merchant's to write, and an
 * uncapped window would hand it an authorization it could still cash long after the call failed.
 */
export async function signPayment(signer, req, { now = Math.floor(Date.now() / 1000), chainId = 4663, maxValiditySeconds = DEFAULT_MAX_VALIDITY_SECONDS } = {}) {
  const from = await signer.getAddress();
  const asked = Number(req.maxTimeoutSeconds);
  // The 600 s ceiling is a floor under the caller too: an option may only shorten the window, never lift it.
  const cap = Math.min(Number(maxValiditySeconds) > 0 ? Number(maxValiditySeconds) : DEFAULT_MAX_VALIDITY_SECONDS, DEFAULT_MAX_VALIDITY_SECONDS);
  const window = Number.isSafeInteger(asked) && asked > 0 ? Math.min(asked, cap) : Math.min(60, cap);
  // Valid from 10 minutes ago (clock skew, as the reference client) until the capped window.
  const authorization = {
    from,
    to: ethers.getAddress(req.payTo),
    value: String(req.maxAmountRequired),
    validAfter: String(now - 600),
    validBefore: String(now + window),
    nonce: ethers.hexlify(ethers.randomBytes(32)),
  };
  const signature = await signer.signTypedData(domainFor(req.asset, chainId), TRANSFER_WITH_AUTHORIZATION_TYPES, authorization);
  return encodePaymentHeader({ x402Version: 1, scheme: "exact", network: req.network, payload: { signature, authorization } });
}

/**
 * Fetch `url`; on a 402, pay it in USDG, borrowing the shortfall from the agent's v2 line if needed.
 * @param {string} url
 * @param {object} o
 * @param {ethers.Signer} o.signer   agent wallet (controller of agentId, payer)
 * @param {string|ethers.Contract} o.pool   CreditPoolV2 address or contract
 * @param {bigint|number|string} o.agentId
 * @param {bigint|number|string} o.maxBorrow  most this call may borrow, atomic USDG (0 = never borrow)
 * @param {bigint|number|string} [o.maxPrice]  most this call may pay, atomic USDG (default 100000 = 0.1 USDG); a
 *   402 asking more is refused before anything is signed or borrowed, whatever the balance
 * @param {number} [o.maxValiditySeconds]  cap on the authorization's lifetime (default 600)
 * @param {typeof fetch} [o.fetchImpl]
 * @param {number} [o.termSeconds]  loan term (default 7 days, clamped to the pool's [minTerm, maxTerm]); an explicit
 *   term below minTerm is raised, above maxTerm refused
 * @param {bigint} [o.maxFee]  refuse a loan whose fee is above this
 * @param {string|ethers.Contract} [o.seatVaultV5]  the V5 seat vault (the deployment record's `seatVaultV5`): on a line
 *   it sponsors, the borrow is preceded by the borrower's refresh on V5 (`refreshV5Line`)
 * @param {bigint|number|string} [o.seatVaultV5AgentId]  V5's root agent id (default: read from V5's `rootId()`)
 * @param {RequestInit} [o.init]  passed to every fetch (a redirect is not followed unless `init.redirect` says so)
 * @param {number} [o.pendingRetries]  resends of the SAME payment while the merchant answers "pending" (default 6)
 * @param {number} [o.timeoutMs]  per-request timeout (default 60 s; 0 = none)
 * @returns {Promise<{response: Response, paid: bigint, borrowed: bigint, loanId: bigint|null, dueAt: bigint|null, requirement?: object,
 *   pending?: boolean, timedOut?: boolean, transportError?: boolean, paymentHeader?: string, validBefore?: number}>}
 *   Once a payment is signed, `paymentHeader` and `validBefore` are always returned (and carried by any error thrown
 *   after it, with the loan): until validBefore the merchant can still cash it, so a caller that retries must resend
 *   `paymentHeader` (see `resend`), never call pay() again for the same purchase, which would sign a second payment.
 *   `pending: true` (a "pending" answer, a timeout or a lost connection) means it may still land. A borrow whose answer
 *   was lost throws `BORROW_UNCONFIRMED` with `borrowed` (and `unconfirmed: true`, `hash`): the loan may exist, so check
 *   the agent's loans and repay it.
 */
export async function pay(url, o = {}) {
  if (!o.signer) throw new FloatError("NO_SIGNER", "pay: a signer is required");
  // One payment at a time per wallet: two concurrent calls on a short balance would each read it short and each borrow
  // the gap (private report GHSA-482p, F3). The second waits and sees the first's loan.
  const key = String(await o.signer.getAddress()).toLowerCase();
  const run = (payQueues.get(key) || Promise.resolve()).then(() => payOne(url, o));
  const tail = run.then(() => {}, () => {});
  payQueues.set(key, tail);
  tail.then(() => { if (payQueues.get(key) === tail) payQueues.delete(key); });
  return run;
}
const payQueues = new Map();

async function payOne(url, { signer, pool, agentId, maxBorrow = 0n, maxPrice = DEFAULT_MAX_PRICE, maxValiditySeconds = DEFAULT_MAX_VALIDITY_SECONDS, fetchImpl = fetch, termSeconds, maxFee, init = {}, asset, pendingRetries = 6, sleep = defaultSleep, timeoutMs = DEFAULT_TIMEOUT_MS, seatVaultV5, seatVaultV5AgentId } = {}) {
  const first = await fetchImpl(url, requestInit(init, timeoutMs)); // a timeout here throws: nothing is signed yet
  if (first.status !== 402) return { response: first, paid: 0n, borrowed: 0n, loanId: null, dueAt: null };

  const poolC = pool ? poolContract(pool, signer) : null;
  const usdgAddr = asset || (poolC ? await poolC.usdg() : USDG_MAINNET);
  let body;
  try { body = JSON.parse((await readCapped(first)).text); } catch (_) { throw new FloatError("BAD_402", "pay: the 402 response is not x402 JSON"); }
  const req = pickRequirement(body, usdgAddr);
  if (!req) throw new FloatError("NO_USDG_REQUIREMENT", "pay: the resource does not accept exact USDG on Robinhood Chain");

  const price = BigInt(req.maxAmountRequired);
  // The merchant names the price. Without a cap a funded agent signs whatever a 402 asks (its whole balance).
  if (price > BigInt(maxPrice)) throw new FloatError("PRICE_ABOVE_MAX_PRICE", `pay: price ${price} is above maxPrice ${maxPrice}; not paying`, { price, maxPrice: BigInt(maxPrice) });
  const cap = BigInt(maxBorrow);
  const me = await signer.getAddress();
  const usdg = new ethers.Contract(usdgAddr, ERC20, signer);
  const balance = await usdg.balanceOf(me);

  let borrowed = 0n, loanId = null, dueAt = null;
  if (balance < price) {
    // Checked before any transaction: a refused call opens no loan.
    if (price > cap) throw new FloatError("PRICE_ABOVE_MAX_BORROW", `pay: price ${price} is above maxBorrow ${cap}; not borrowing`, { price, maxBorrow: cap });
    if (!poolC || agentId === undefined) throw new FloatError("NO_POOL", "pay: short of USDG and no pool/agentId to borrow from");
    const p = await poolC.getParams();
    const shortfall = price - balance;
    const amount = shortfall > p.minLoan ? shortfall : p.minLoan;
    if (amount > cap) throw new FloatError("MIN_LOAN_ABOVE_MAX_BORROW", `pay: the pool's minimum loan ${p.minLoan} is above maxBorrow ${cap}; not borrowing`, { amount, maxBorrow: cap });
    if (amount > p.maxLoan) throw new FloatError("ABOVE_MAX_LOAN", `pay: ${amount} is above the pool's maxLoan ${p.maxLoan}`);
    // Float is "pay now, get paid next week": the default is 7 days, clamped into the pool's range. An explicit term
    // above maxTerm is still refused rather than silently shortened (x402 audit F3).
    let term = termSeconds === undefined ? BigInt(DEFAULT_TERM_SECONDS) : BigInt(termSeconds);
    if (term < p.minTerm) term = p.minTerm;
    if (termSeconds === undefined && term > p.maxTerm) term = p.maxTerm;
    if (term > p.maxTerm) throw new FloatError("TERM_OUT_OF_RANGE", `pay: term ${term} is above the pool's maxTerm ${p.maxTerm}`);
    const [fee] = await poolC.quoteFee(agentId, amount, term);
    if (maxFee !== undefined && fee > BigInt(maxFee)) throw new FloatError("FEE_TOO_HIGH", `pay: loan fee ${fee} is above maxFee ${maxFee}`);
    // A line the V5 seat vault sponsors is borrowable only after the borrower's refresh on V5 (refreshV5Line).
    if (seatVaultV5) await refreshV5Line({ signer, pool: poolC, seatVaultV5, seatVaultV5AgentId, agentId, amount });
    // to = the agent itself: EIP-3009 needs the payer to hold the funds, so the draw lands in the agent's wallet and
    // is spent by the signed authorization below. (A borrow-and-pay router would send it straight to payTo.)
    // A lost answer (the broadcast's or the receipt's) may hide a loan that mined: BORROW_UNCONFIRMED carries the amount
    // (GHSA-v9xj). Only CALL_EXCEPTION (a refused estimate, or a mined revert) and INSUFFICIENT_FUNDS borrowed nothing.
    let tx, rc;
    try { tx = await poolC.borrow(agentId, amount, term, me, fee); rc = await tx.wait(); } catch (e) {
      if (e?.code === "CALL_EXCEPTION" || e?.code === "INSUFFICIENT_FUNDS") throw e;
      const hash = typeof tx?.hash === "string" ? tx.hash : null;
      throw new FloatError("BORROW_UNCONFIRMED", `pay: a borrow of ${amount} was sent${hash ? ` (tx ${hash})` : ""} and its answer was lost (${e?.shortMessage || e?.message || String(e)}): it may have opened a loan`,
        { borrowed: amount, loanId: null, dueAt: null, unconfirmed: true, hash, cause: e });
    }
    const ev = rc.logs.map((l) => { try { return poolC.interface.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === "Borrowed");
    loanId = ev ? ev.args.loanId : null;
    dueAt = ev ? ev.args.dueAt : null; // when to have settleLoans() run by, so the line is never defaulted
    borrowed = amount;
  }

  // Exactly one signature for this purchase. An error from here carries the loan (and, once signed, the header).
  let header, validBefore;
  try {
    header = await signPayment(signer, req, { maxValiditySeconds });
    validBefore = Number(decodePaymentHeader(header).payload.authorization.validBefore);
    const r = await resend(url, header, { init, fetchImpl, retries: pendingRetries, sleep, timeoutMs });
    return { ...r, paid: r.response.ok ? price : 0n, borrowed, loanId, dueAt, requirement: req, paymentHeader: header, validBefore };
  } catch (e) {
    if (e && typeof e === "object") Object.assign(e, { borrowed, loanId, dueAt, ...(header ? { paymentHeader: header, validBefore } : {}) });
    throw e;
  }
}

const defaultSleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** Per-request timeout, 60 s by default: a merchant that never answers cannot hold pay() forever. */
export const DEFAULT_TIMEOUT_MS = 60_000;
/** Merchant bodies are read at most this far, as in @priors/x402: a merchant streaming gigabytes cannot exhaust memory. */
export const MAX_BODY_BYTES = 256 * 1024;

/** A response body as text, at most `max` bytes; the rest is cancelled, not read. */
async function readCapped(response, max = MAX_BODY_BYTES) {
  if (!response?.body) return { text: "", cut: false };
  const reader = response.body.getReader();
  const chunks = [];
  let n = 0, cut = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (n + value.byteLength > max) { chunks.push(value.subarray(0, max - n)); n = max; cut = true; await reader.cancel().catch(() => {}); break; }
    chunks.push(value); n += value.byteLength;
  }
  const buf = new Uint8Array(n);
  let o = 0;
  for (const c of chunks) { buf.set(c, o); o += c.byteLength; }
  return { text: new TextDecoder().decode(buf), cut };
}

/**
 * The caller's init with a redirect never followed (a signed payment must not travel to a host the caller did not
 * name; the 3xx is the answer, as in @priors/x402) unless the caller sets `redirect`, and the timeout joined to its signal.
 */
function requestInit(init, timeoutMs) {
  const signals = [timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : null, init.signal || null].filter(Boolean);
  return { ...init, redirect: init.redirect ?? "manual", ...(signals.length ? { signal: signals.length === 1 ? signals[0] : AbortSignal.any(signals) } : {}) };
}
const isAbort = (e) => e?.name === "AbortError" || e?.name === "TimeoutError";

const isPending = async (response) => {
  if (response.status !== 402) return false;
  try { const b = JSON.parse((await readCapped(response.clone(), 64 * 1024)).text); return b?.pending === true; } catch (_) { return false; }
};

/**
 * Send an already-signed X-PAYMENT, and keep resending the SAME one while the merchant answers 402 `pending`
 * (its settlement was broadcast but not confirmed yet; see docs/FLOAT.md). Never signs anything:
 * a new signature while the first payment can still land is how a call gets paid twice. Once the payment may be out,
 * no error is thrown: a timeout or an abort is reported as pending (`timedOut: true`, a synthetic 504), any other
 * transport error as pending too (`transportError: true`, a synthetic 502, the error in `error`), with the header.
 * @returns {Promise<{response: Response, pending: boolean, timedOut?: boolean, transportError?: boolean, error?: unknown, paymentHeader?: string}>}
 */
export async function resend(url, paymentHeader, { init = {}, fetchImpl = fetch, retries = 6, sleep = defaultSleep, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const headers = new Headers(init.headers || {});
  headers.set("X-PAYMENT", paymentHeader);
  const send = () => fetchImpl(url, requestInit({ ...init, headers }, timeoutMs));
  let response;
  try {
    response = await send();
    for (let i = 0; i < retries && (await isPending(response)); i++) {
      const after = Number(response.headers.get("retry-after"));
      await sleep(1000 * Math.min(30, Math.max(1, Number.isFinite(after) && after > 0 ? after : 5)));
      response = await send();
    }
  } catch (e) {
    if (isAbort(e)) return { response: new Response(null, { status: 504, statusText: "payer timeout" }), pending: true, timedOut: true, paymentHeader };
    return { response: new Response(null, { status: 502, statusText: "payer transport error" }), pending: true, transportError: true, error: e, paymentHeader };
  }
  const pending = await isPending(response);
  return { response, pending, ...(pending ? { paymentHeader } : {}) };
}

/**
 * Repay the agent's open loans, earliest due first, while its USDG balance covers principal + fee.
 * @returns {Promise<{repaid: bigint[], open: bigint[]}>}
 */
export async function settleLoans({ signer, pool, agentId }) {
  const poolC = poolContract(pool, signer);
  const me = await signer.getAddress();
  // Only the signer's own agent: a wrong or stale agentId would otherwise pay a stranger's loans.
  if (!(await poolC.isController(agentId, me))) throw new FloatError("NOT_CONTROLLER", `agent #${agentId} is not controlled by ${me} (neither its owner nor its pool delegate)`);
  const usdg = new ethers.Contract(await poolC.usdg(), ERC20, signer);
  const ids = await poolC.loansOf(agentId);
  const loans = (await Promise.all(ids.map(async (id) => ({ id, l: await poolC.getLoan(id) })))).filter((x) => x.l.status === LOAN_ACTIVE);
  loans.sort((a, b) => (a.l.dueAt < b.l.dueAt ? -1 : a.l.dueAt > b.l.dueAt ? 1 : 0));
  const repaid = [], open = [];
  let balance = await usdg.balanceOf(me);
  const target = await poolC.getAddress();
  for (const { id, l } of loans) {
    const due = l.principal + l.fee;
    if (balance < due) { open.push(id); continue; }
    if ((await usdg.allowance(me, target)) < due) await (await usdg.approve(target, due)).wait();
    await (await poolC.repay(id, agentId, due)).wait();
    balance -= due;
    repaid.push(id);
  }
  return { repaid, open };
}
