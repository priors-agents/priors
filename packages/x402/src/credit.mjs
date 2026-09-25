// Priors v2 credit line on Robinhood Chain, the parts a payer and an MCP server need: borrow the gap before a
// purchase, repay, read an agent's line, record and score. ethers v6.
//
// `borrowGap` and `settleLoans` are a port of sdk/float.mjs (repository `priors`, 2026-09-24), kept rule for rule:
// maxBorrow is checked against the PRICE before any transaction, the draw is max(shortfall, pool minLoan), the term
// defaults to 7 days clamped into the pool's range (an explicit term above maxTerm is refused), the fee is bounded by
// the pool's own quote (or maxFee), and the draw lands in the payer's wallet because EIP-3009 needs the payer to hold
// the funds. The package carries its own copy so it installs on its own; the package tests check it
// against sdk/float.mjs on the same inputs.
import { ethers } from "ethers";
import { robinhood, DEFAULT_TERM_SECONDS } from "./robinhood.mjs";

const LOAN_T = "tuple(uint256 agentId, uint256 sponsorId, uint256 principal, uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium, address owner, uint64 issuedAt, uint64 dueAt, uint64 defaultableAt, uint64 minScoreTerm, uint64 closedAt, uint8 status)";
const AGENT_T = "tuple(bool enrolled,bool isRoot,bool defaulted,bool frozen,bool importedFromV1,uint64 enrolledAt,uint64 lastBorrowAt,uint64 lastRepayAt,uint256 sponsor,uint256 delegatedIn,uint256 delegatedOut,uint256 principalOut,uint256 activeLoans,uint256 premiumBps,uint256 premiumCap,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid)";
const PARAMS_T = "tuple(uint256 minLoan, uint256 maxLoan, uint64 minTerm, uint64 maxTerm, uint64 grace, uint64 minScoreTerm, uint256 feeBps, uint256 sponsorFeeBps, uint256 protocolFeeBps, uint256 minStake, uint256 maxUtilizationBps, uint256 keeperBounty)";

/** CreditPoolV2, the subset used here, with its custom errors so a revert decodes to a name. */
export const POOL_ABI = [
  "function usdg() view returns (address)",
  "function registry() view returns (address)",
  `function getParams() view returns (${PARAMS_T})`,
  "function quoteFee(uint256 agentId, uint256 principal, uint64 term) view returns (uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium)",
  "function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee) returns (uint256)",
  "function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue)",
  "function loansOf(uint256 id) view returns (uint256[])",
  `function getLoan(uint256 loanId) view returns (${LOAN_T})`,
  `function getAgent(uint256) view returns (${AGENT_T})`,
  "function isController(uint256 id, address who) view returns (bool)",
  "function pausedUntil() view returns (uint64)",
  "event Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 indexed sponsorId, uint256 principal, uint256 fee, uint64 dueAt, address to)",
  "error Paused()", "error ZeroAmount()", "error NotOwnerOf(uint256 id, address caller)", "error NotController(uint256 id, address caller)",
  "error InvalidAgent(uint256 id)", "error IsRoot(uint256 id)", "error AgentDefaulted(uint256 id)", "error V1Busy(uint256 id)",
  "error InsufficientCapacity(uint256 id, uint256 requested, uint256 available)", "error InsufficientLiquidity(uint256 requested, uint256 available)",
  "error UtilizationTooHigh()", "error LoanSizeOutOfRange(uint256 amount)", "error TermOutOfRange(uint64 term)", "error FeeTooHigh(uint256 fee, uint256 maxFee)",
  "error IsFrozen(uint256 id)", "error OwnerDefaulted(address owner)", "error BorrowBlockedByBacker(uint256 rootId)",
  "error LoanNotActive(uint256 loanId)", "error WrongLoan(uint256 loanId)", "error DueTooHigh(uint256 due, uint256 maxDue)",
];
/** CreditLensV2: the score (0..1000) and v1-layout credit report. */
export const LENS_ABI = [
  "function score(uint256 id) view returns (uint256)",
  "function available(uint256 id) view returns (uint256)",
];
export const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
  "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
];
const REGISTRY_ABI = ["function ownerOf(uint256) view returns (address)"];
export const LOAN_STATUS = ["none", "active", "repaid", "defaulted"];
const LOAN_ACTIVE = 1n;

/** A refusal or failure with a stable `code` (the same codes as sdk/float.mjs's FloatError). */
export class PayError extends Error {
  constructor(code, message, details = {}) { super(message); this.name = "PayError"; this.code = code; Object.assign(this, details); }
}

/** A pool address or contract, bound to `runner`. A plain object without `connect` (a test double) is used as is. */
export const poolContract = (pool, runner) => (typeof pool === "string" ? new ethers.Contract(pool, POOL_ABI, runner) : pool && typeof pool.connect === "function" ? pool.connect(runner) : pool);

/** "Name(args)" for a contract revert when it decodes, else the provider's short message. */
export function explainRevert(err, iface = new ethers.Interface(POOL_ABI)) {
  const data = err?.data ?? err?.info?.error?.data ?? err?.error?.data;
  if (err?.revert?.name) return `${err.revert.name}(${(err.revert.args || []).map(String).join(", ")})`;
  if (typeof data === "string" && data.length >= 10) {
    for (const i of [iface, new ethers.Interface(ERC20_ABI)]) {
      try { const e = i.parseError(data); if (e) return `${e.name}(${e.args.map(String).join(", ")})`; } catch (_) { /* next */ }
    }
  }
  return err?.shortMessage || err?.reason || err?.message || String(err);
}

/**
 * Borrow what a purchase is short of, from the agent's line, into the payer's wallet. Port of sdk/float.mjs's
 * borrow step; every refusal happens before any transaction.
 * @param {{ signer: any, pool: any, agentId?: bigint|number|string, price: bigint, balance: bigint, maxBorrow: bigint,
 *   termSeconds?: bigint|number, maxFee?: bigint, me?: string }} o
 * @returns {Promise<{ borrowed: bigint, loanId: bigint|null, dueAt: bigint|null, fee: bigint, term: bigint }>}
 */
export async function borrowGap({ signer, pool, agentId, price, balance, maxBorrow, termSeconds, maxFee, me }) {
  const cap = BigInt(maxBorrow ?? 0n);
  if (price > cap) throw new PayError("PRICE_ABOVE_MAX_BORROW", `pay: price ${price} is above maxBorrow ${cap}; not borrowing`, { price, maxBorrow: cap });
  const poolC = pool ? poolContract(pool, signer) : null;
  if (!poolC || agentId === undefined || agentId === null) throw new PayError("NO_POOL", "pay: short of USDG and no pool/agentId to borrow from");
  const p = await poolC.getParams();
  const shortfall = price - balance;
  const amount = shortfall > p.minLoan ? shortfall : p.minLoan;
  if (amount > cap) throw new PayError("MIN_LOAN_ABOVE_MAX_BORROW", `pay: the pool's minimum loan ${p.minLoan} is above maxBorrow ${cap}; not borrowing`, { amount, maxBorrow: cap });
  if (amount > p.maxLoan) throw new PayError("ABOVE_MAX_LOAN", `pay: ${amount} is above the pool's maxLoan ${p.maxLoan}`);
  let term = termSeconds === undefined ? BigInt(DEFAULT_TERM_SECONDS) : BigInt(termSeconds);
  if (term < p.minTerm) term = p.minTerm;
  if (termSeconds === undefined && term > p.maxTerm) term = p.maxTerm;
  if (term > p.maxTerm) throw new PayError("TERM_OUT_OF_RANGE", `pay: term ${term} is above the pool's maxTerm ${p.maxTerm}`);
  const [fee] = await poolC.quoteFee(agentId, amount, term);
  if (maxFee !== undefined && fee > BigInt(maxFee)) throw new PayError("FEE_TOO_HIGH", `pay: loan fee ${fee} is above maxFee ${maxFee}`);
  const to = me || (await signer.getAddress());
  // Simulate first: a doomed borrow says why (its custom error) before any gas is spent.
  if (poolC.borrow && typeof poolC.borrow.staticCall === "function") {
    try { await poolC.borrow.staticCall(agentId, amount, term, to, fee); } catch (e) { throw new PayError("BORROW_WOULD_REVERT", `pay: borrow would revert: ${explainRevert(e, poolC.interface)}`); }
  }
  const rc = await (await poolC.borrow(agentId, amount, term, to, fee)).wait();
  const ev = (rc?.logs || []).map((l) => { try { return poolC.interface.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === "Borrowed");
  return { borrowed: amount, loanId: ev ? ev.args.loanId : null, dueAt: ev ? ev.args.dueAt : null, fee, term };
}

/**
 * Repay the agent's open loans, earliest due first, while the signer's USDG covers principal + fee (sdk/float.mjs).
 * @returns {Promise<{ repaid: bigint[], open: bigint[] }>}
 */
export async function settleLoans({ signer, pool, agentId }) {
  const poolC = poolContract(pool, signer);
  const me = await signer.getAddress();
  // Only the signer's own agent: a wrong or stale agentId would otherwise pay a stranger's loans (P-7).
  if (!(await poolC.isController(agentId, me))) throw new PayError("NOT_CONTROLLER", `agent #${agentId} is not controlled by ${me} (neither its owner nor its pool delegate)`);
  const usdg = new ethers.Contract(await poolC.usdg(), ERC20_ABI, signer);
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

// ---------------------------------------------------------------------------------------------------------------
// Reads and single writes for tools (the MCP server): plain objects with bigint amounts.
// ---------------------------------------------------------------------------------------------------------------

/**
 * @param {{ runner: any, addresses?: { pool?: string, lens?: string, usdg?: string, registry?: string } }} o
 */
export function creditContracts({ runner, addresses = {} }) {
  const a = { pool: robinhood.pool, lens: robinhood.lens, usdg: robinhood.usdg, registry: robinhood.registry, ...addresses };
  return {
    addresses: a,
    pool: new ethers.Contract(a.pool, POOL_ABI, runner),
    lens: new ethers.Contract(a.lens, LENS_ABI, runner),
    usdg: new ethers.Contract(a.usdg, ERC20_ABI, runner),
    registry: new ethers.Contract(a.registry, REGISTRY_ABI, runner),
  };
}

const loanView = (id, l) => ({ loanId: BigInt(id), agentId: l.agentId, sponsorId: l.sponsorId, principal: l.principal, fee: l.fee, due: l.principal + l.fee, issuedAt: Number(l.issuedAt), dueAt: Number(l.dueAt), defaultableAt: Number(l.defaultableAt), status: LOAN_STATUS[Number(l.status)] || "unknown" });

/** An agent's line, record, open loans and score, from the pool and lens. */
export async function creditStatus(c, agentId) {
  const id = BigInt(agentId);
  const [a, score, owner] = await Promise.all([c.pool.getAgent(id), c.lens.score(id).catch(() => null), c.registry.ownerOf(id).catch(() => null)]);
  const ids = await c.pool.loansOf(id);
  const loans = await Promise.all(ids.map(async (lid) => loanView(lid, await c.pool.getLoan(lid))));
  const blocked = a.defaulted || a.frozen || a.sponsor === 0n;
  return {
    agentId: id, owner, enrolled: a.enrolledAt !== 0n, isRoot: a.isRoot, defaulted: a.defaulted, frozen: a.frozen,
    sponsor: a.sponsor, premiumBps: a.premiumBps, line: a.delegatedIn, drawn: a.principalOut,
    available: blocked ? 0n : a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0n,
    loansRepaid: a.loansRepaid, qualifiedRepaid: a.qualifiedRepaid, volumeRepaid: a.volumeRepaid, feesPaid: a.feesPaid,
    enrolledAt: Number(a.enrolledAt), score: score === null ? null : Number(score),
    openLoans: loans.filter((l) => l.status === "active").sort((x, y) => x.dueAt - y.dueAt),
  };
}

/** Quote a borrow and check it against the pool's ranges, without sending anything. */
export async function quoteBorrow(c, agentId, amount, termSeconds) {
  const p = await c.pool.getParams();
  const term = BigInt(termSeconds);
  if (amount < p.minLoan || amount > p.maxLoan) throw new PayError("LOAN_SIZE_OUT_OF_RANGE", `the pool lends between ${p.minLoan} and ${p.maxLoan} atomic USDG per loan`, { minLoan: p.minLoan, maxLoan: p.maxLoan });
  if (term < p.minTerm || term > p.maxTerm) throw new PayError("TERM_OUT_OF_RANGE", `the pool's terms run from ${p.minTerm} to ${p.maxTerm} seconds`, { minTerm: p.minTerm, maxTerm: p.maxTerm });
  const q = await c.pool.quoteFee(BigInt(agentId), amount, term);
  return { amount, term, fee: q.fee, due: amount + q.fee };
}

/** Borrow `amount` for `termSeconds` into the signer's wallet; fee capped at the quote. Simulates first. */
export async function borrowLine(c, signer, agentId, amount, termSeconds) {
  const q = await quoteBorrow(c, agentId, amount, termSeconds);
  const pool = c.pool.connect(signer);
  const me = await signer.getAddress();
  const args = [BigInt(agentId), amount, q.term, me, q.fee];
  try { await pool.borrow.staticCall(...args); } catch (e) { throw new PayError("BORROW_WOULD_REVERT", `borrow would revert: ${explainRevert(e, pool.interface)}`); }
  const tx = await pool.borrow(...args);
  const rc = await tx.wait();
  const ev = rc.logs.map((l) => { try { return pool.interface.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === "Borrowed");
  return { hash: tx.hash, loanId: ev ? ev.args.loanId : null, principal: amount, fee: ev ? ev.args.fee : q.fee, dueAt: ev ? Number(ev.args.dueAt) : null };
}

/** Repay one loan in full from the signer's USDG; approves exactly what is due. */
export async function repayLoan(c, signer, loanId) {
  const pool = c.pool.connect(signer);
  const usdg = c.usdg.connect(signer);
  const l = await pool.getLoan(BigInt(loanId));
  if (l.status !== LOAN_ACTIVE) throw new PayError("LOAN_NOT_ACTIVE", `loan #${loanId} is not active (${LOAN_STATUS[Number(l.status)] || "unknown"})`);
  const due = l.principal + l.fee;
  const me = await signer.getAddress();
  // The pool lets anyone repay any loan; this helper spends the signer's USDG only on an agent the signer controls.
  if (!(await pool.isController(l.agentId, me))) throw new PayError("NOT_CONTROLLER", `loan #${loanId} belongs to agent #${l.agentId}, which ${me} does not control (neither its owner nor its pool delegate)`);
  const bal = await usdg.balanceOf(me);
  if (bal < due) throw new PayError("INSUFFICIENT_USDG", `repaying loan #${loanId} needs ${due} atomic USDG but the wallet holds ${bal}`, { due, balance: bal });
  const target = await pool.getAddress();
  if ((await usdg.allowance(me, target)) < due) await (await usdg.approve(target, due)).wait();
  try { await pool.repay.staticCall(BigInt(loanId), l.agentId, due); } catch (e) { throw new PayError("REPAY_WOULD_REVERT", `repay would revert: ${explainRevert(e, pool.interface)}`); }
  const tx = await pool.repay(BigInt(loanId), l.agentId, due);
  await tx.wait();
  return { hash: tx.hash, loanId: BigInt(loanId), agentId: l.agentId, paid: due };
}

/** USDG and native (gas) balance of an address. */
export async function balances(c, provider, address) {
  const [usdg, native] = await Promise.all([c.usdg.balanceOf(address), provider.getBalance(address)]);
  return { address, usdg, native };
}
