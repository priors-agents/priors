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
import { NETWORKS, TRANSFER_WITH_AUTHORIZATION_TYPES, domainFor, encodePaymentHeader, USDG_MAINNET } from "./x402.mjs";

const LOAN = "tuple(uint256 agentId, uint256 sponsorId, uint256 principal, uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium, address owner, uint64 issuedAt, uint64 dueAt, uint64 defaultableAt, uint64 minScoreTerm, uint64 closedAt, uint8 status)";
export const POOL_V2_FLOAT_ABI = [
  "function usdg() view returns (address)",
  "function getParams() view returns (tuple(uint256 minLoan, uint256 maxLoan, uint64 minTerm, uint64 maxTerm, uint64 grace, uint64 minScoreTerm, uint256 feeBps, uint256 sponsorFeeBps, uint256 protocolFeeBps, uint256 minStake, uint256 maxUtilizationBps, uint256 keeperBounty))",
  "function quoteFee(uint256 agentId, uint256 principal, uint64 term) view returns (uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium)",
  "function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee) returns (uint256)",
  "function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue)",
  "function loansOf(uint256 id) view returns (uint256[])",
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
 * @param {RequestInit} [o.init]  passed to every fetch
 * @param {number} [o.pendingRetries]  resends of the SAME payment while the merchant answers "pending" (default 6)
 * @returns {Promise<{response: Response, paid: bigint, borrowed: bigint, loanId: bigint|null, dueAt: bigint|null, requirement?: object,
 *   pending?: boolean, paymentHeader?: string}>}  `pending: true` means the payment may still land: resend
 *   `paymentHeader` as X-PAYMENT later (see `resend`), and do NOT call pay() again for the same purchase, which would
 *   sign a second payment while the first can still settle.
 */
export async function pay(url, { signer, pool, agentId, maxBorrow = 0n, maxPrice = DEFAULT_MAX_PRICE, maxValiditySeconds = DEFAULT_MAX_VALIDITY_SECONDS, fetchImpl = fetch, termSeconds, maxFee, init = {}, asset, pendingRetries = 6, sleep = defaultSleep } = {}) {
  if (!signer) throw new FloatError("NO_SIGNER", "pay: a signer is required");
  const first = await fetchImpl(url, init);
  if (first.status !== 402) return { response: first, paid: 0n, borrowed: 0n, loanId: null, dueAt: null };

  const poolC = pool ? poolContract(pool, signer) : null;
  const usdgAddr = asset || (poolC ? await poolC.usdg() : USDG_MAINNET);
  let body;
  try { body = await first.json(); } catch (_) { throw new FloatError("BAD_402", "pay: the 402 response is not x402 JSON"); }
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
    // to = the agent itself: EIP-3009 needs the payer to hold the funds, so the draw lands in the agent's wallet and
    // is spent by the signed authorization below. (A borrow-and-pay router would send it straight to payTo.)
    const rc = await (await poolC.borrow(agentId, amount, term, me, fee)).wait();
    const ev = rc.logs.map((l) => { try { return poolC.interface.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === "Borrowed");
    loanId = ev ? ev.args.loanId : null;
    dueAt = ev ? ev.args.dueAt : null; // when to have settleLoans() run by, so the line is never defaulted
    borrowed = amount;
  }

  const header = await signPayment(signer, req, { maxValiditySeconds });
  const r = await resend(url, header, { init, fetchImpl, retries: pendingRetries, sleep });
  return { ...r, paid: r.response.ok ? price : 0n, borrowed, loanId, dueAt, requirement: req };
}

const defaultSleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isPending = async (response) => {
  if (response.status !== 402) return false;
  try { const b = await response.clone().json(); return b?.pending === true; } catch (_) { return false; }
};

/**
 * Send an already-signed X-PAYMENT, and keep resending the SAME one while the merchant answers 402 `pending`
 * (its settlement was broadcast but not confirmed yet; see docs/FLOAT.md). Never signs anything:
 * a new signature while the first payment can still land is how a call gets paid twice.
 * @returns {Promise<{response: Response, pending: boolean, paymentHeader?: string}>}
 */
export async function resend(url, paymentHeader, { init = {}, fetchImpl = fetch, retries = 6, sleep = defaultSleep } = {}) {
  const headers = new Headers(init.headers || {});
  headers.set("X-PAYMENT", paymentHeader);
  let response = await fetchImpl(url, { ...init, headers });
  for (let i = 0; i < retries && (await isPending(response)); i++) {
    const after = Number(response.headers.get("retry-after"));
    await sleep(1000 * Math.min(30, Math.max(1, Number.isFinite(after) && after > 0 ? after : 5)));
    response = await fetchImpl(url, { ...init, headers });
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
