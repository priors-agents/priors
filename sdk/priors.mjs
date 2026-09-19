// Priors SDK: everything an agent needs to build a credit history, in one small ESM module on ethers v6.
//
//   import { Priors } from "./sdk/priors.mjs";
//   const s = new Priors({ rpc, pool, treasury, signer });   // signer: the wallet that owns the ERC-8004 id
//   await s.firstLine(agentId);                                // the treasury vouches $5 for a fresh identity
//   const loanId = await s.borrow(agentId, 5, 7);              // $5 for 7 days
//   await s.repay(loanId);                                     // principal + fee; approves USDG if needed
//   await s.score(agentId);                                    // 0..1000, straight from the contract
//
// Amounts are in whole dollars (USDG has 6 decimals; the SDK converts). Every call is one transaction or one
// view; nothing is stored anywhere but the chain.
import { ethers } from "ethers";

const USDC = 1_000_000n;
export const POOL_ABI = [
  "function borrow(uint256 agentId, uint256 amount, uint64 term, address to) returns (uint256 loanId)",
  "function repay(uint256 loanId)",
  "function score(uint256 agentId) view returns (uint256)",
  "function available(uint256 agentId) view returns (uint256)",
  "function creditReport(uint256) view returns (tuple(bool enrolled,bool isRoot,bool defaulted,uint256 sponsor,uint256 capacity,uint256 available,uint256 delegatedIn,uint256 delegatedOut,uint256 earned,uint256 stake,uint256 principalOut,uint256 activeLoans,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint64 enrolledAt,uint256 score,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid))",
  "function getLoan(uint256) view returns (tuple(uint256 agentId,uint256 principal,uint256 fee,uint64 issuedAt,uint64 dueAt,uint64 closedAt,uint8 status,bool isRecourse,uint256 recourseFor))",
  "function loansOf(uint256 agentId) view returns (uint256[])",
  "function getParams() view returns (tuple(uint256 minLoan,uint256 maxLoan,uint64 minTerm,uint64 maxTerm,uint64 grace,uint64 recourseTerm,uint256 feeBps,uint256 growthBps,uint256 maxEarned,uint256 maxEarnPerEpoch,uint64 epochLength,uint64 minSeasoning,uint256 minStake,uint256 sponsorFeeBps,uint256 protocolFeeBps,uint64 minScoreTerm))",
  "function usdc() view returns (address)",
  "function registry() view returns (address)",
  "function vouch(uint256 sponsorId, uint256 agentId, uint256 amount)",
  "function enrollRoot(uint256 agentId, uint256 stakeAmount)",
  "function setDelegate(uint256 agentId, address delegate)",
  "event Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, uint64 dueAt, address to)",
];
export const TREASURY_ABI = [
  "function firstLine(uint256 agentId)",
  "function raise(uint256 agentId)",
  "function epochRoom() view returns (uint256)",
  "function firstLined(uint256) view returns (bool)",
  "function eligibleForRaise(tuple(bool enrolled,bool isRoot,bool defaulted,uint256 sponsor,uint256 capacity,uint256 available,uint256 delegatedIn,uint256 delegatedOut,uint256 earned,uint256 stake,uint256 principalOut,uint256 activeLoans,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint64 enrolledAt,uint256 score,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid)) view returns (bool)",
  "function agentId() view returns (uint256)",
];
const ERC20_ABI = ["function approve(address,uint256)", "function allowance(address,address) view returns (uint256)", "function balanceOf(address) view returns (uint256)"];
const REGISTRY_ABI = ["function ownerOf(uint256) view returns (address)", "function register(string) returns (uint256)", "event Registered(uint256 indexed agentId, address indexed owner, string agentURI)"];

const toUnits = (dollars) => (typeof dollars === "bigint" ? dollars : BigInt(Math.round(Number(dollars) * 1e6)));
const toDollars = (units) => Number(units) / 1e6;

export class Priors {
  /** @param {{rpc?: string, provider?: any, pool: string, treasury?: string, signer?: any}} opts */
  constructor(opts) {
    // cacheTimeout off: on chains that mine instantly, ethers' 250 ms result cache hands back stale nonces
    this.provider = opts.provider || new ethers.JsonRpcProvider(opts.rpc, undefined, { cacheTimeout: -1 });
    this.signer = opts.signer ? (opts.signer.provider ? opts.signer : opts.signer.connect(this.provider)) : null;
    const runner = this.signer || this.provider;
    this.pool = new ethers.Contract(opts.pool, POOL_ABI, runner);
    this.treasury = opts.treasury ? new ethers.Contract(opts.treasury, TREASURY_ABI, runner) : null;
  }

  // ---- read ----
  async score(agentId) { return Number(await this.pool.score(agentId)); }
  async report(agentId) {
    const r = await this.pool.creditReport(agentId);
    return {
      enrolled: r.enrolled, isRoot: r.isRoot, defaulted: r.defaulted, sponsor: Number(r.sponsor), score: Number(r.score),
      capacity: toDollars(r.capacity), available: toDollars(r.available), delegatedIn: toDollars(r.delegatedIn), earned: toDollars(r.earned), stake: toDollars(r.stake),
      principalOut: toDollars(r.principalOut), activeLoans: Number(r.activeLoans), loansRepaid: Number(r.loansRepaid), qualifiedRepaid: Number(r.qualifiedRepaid),
      dollarDaysRepaid: Number(r.dollarSecondsRepaid / 86400n) / 1e6, volumeRepaid: toDollars(r.volumeRepaid), feesPaid: toDollars(r.feesPaid),
      recourseHonored: Number(r.recourseHonored), childrenDefaulted: Number(r.childrenDefaulted), enrolledAt: Number(r.enrolledAt),
    };
  }
  async loans(agentId) {
    const ids = await this.pool.loansOf(agentId);
    return Promise.all(ids.map(async (id) => { const l = await this.pool.getLoan(id); return { loanId: Number(id), principal: toDollars(l.principal), fee: toDollars(l.fee), issuedAt: Number(l.issuedAt), dueAt: Number(l.dueAt), status: ["none", "active", "repaid", "defaulted"][Number(l.status)], isRecourse: l.isRecourse }; }));
  }
  /** Fee for a loan of `dollars` over `days`, in dollars, from the live params. */
  async quote(dollars, days) {
    const p = await this.pool.getParams();
    const fee = (toUnits(dollars) * p.feeBps * BigInt(days * 86400)) / (10_000n * BigInt(30 * 86400));
    return { fee: toDollars(fee), total: toDollars(toUnits(dollars) + fee), qualifiesForScore: days * 86400 >= Number(p.minScoreTerm) };
  }

  // ---- write ----
  _needSigner() { if (!this.signer) throw new Error("this call needs a signer"); }
  /** Ask the treasury for a first $5 line. Works for any ERC-8004 identity that was never enrolled. Anyone may call it. */
  async firstLine(agentId) { this._needSigner(); if (!this.treasury) throw new Error("no treasury address configured"); const tx = await this.treasury.firstLine(agentId); return (await tx.wait()).hash; }
  /** Raise a treasury-sponsored agent's line once its record qualifies. */
  async raise(agentId) { this._needSigner(); const tx = await this.treasury.raise(agentId); return (await tx.wait()).hash; }
  async canRaise(agentId) { return this.treasury.eligibleForRaise(await this.pool.creditReport(agentId)); }
  /** Borrow `dollars` for `days`; USDG lands in `to` (default: the signer). Returns the loanId. */
  async borrow(agentId, dollars, days, to) {
    this._needSigner();
    const tx = await this.pool.borrow(agentId, toUnits(dollars), BigInt(days * 86400), to || (await this.signer.getAddress()));
    const rc = await tx.wait();
    for (const log of rc.logs) { try { const ev = this.pool.interface.parseLog(log); if (ev && ev.name === "Borrowed") return Number(ev.args.loanId); } catch (_) {} }
    throw new Error("Borrowed event not found");
  }
  /** Repay principal + fee. Approves the pool for exactly what is due if the allowance is short. */
  async repay(loanId) {
    this._needSigner();
    const l = await this.pool.getLoan(loanId);
    const due = l.principal + l.fee;
    const usdc = new ethers.Contract(await this.pool.usdc(), ERC20_ABI, this.signer);
    const me = await this.signer.getAddress();
    if ((await usdc.allowance(me, await this.pool.getAddress())) < due) await (await usdc.approve(await this.pool.getAddress(), due)).wait();
    const tx = await this.pool.repay(loanId);
    return (await tx.wait()).hash;
  }
  /** Register a new ERC-8004 identity on registries that expose register(string). Returns the agentId. */
  async register(uri) {
    this._needSigner();
    const reg = new ethers.Contract(await this.pool.registry(), REGISTRY_ABI, this.signer);
    const rc = await (await reg.register(uri || "")).wait();
    for (const log of rc.logs) { try { const ev = reg.interface.parseLog(log); if (ev && ev.name === "Registered") return Number(ev.args.agentId); } catch (_) {} }
    throw new Error("Registered event not found");
  }
}
export default Priors;
