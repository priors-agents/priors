// Priors SDK v2: pool v2 (CreditPoolV2), treasury v4 (TreasurySponsorV4) and seats v2 (SeatVaultV2), in one ESM
// module on ethers v6. The v1 module (sdk/priors.mjs) stays as it is, for the v1 pool.
//
//   import { PriorsV2 } from "./sdk/priors-v2.mjs";
//   const p = new PriorsV2({ signer, addresses });   // addresses: deployments/<chainId>.v2.json (DeployV2 writes it)
//
//   lender   await p.deposit(50); await p.withdraw("all"); await p.position(addr)
//   staker   await p.offer(agentId); await p.withdrawOffer(agentId); await p.closeSeat(agentId)
//            await p.claimSeatFees(to); await p.pendingSeatFees(addr); await p.seatable(agentId); await p.openSeats()
//   backer   await p.enrollRoot(rootId, 20); await p.addStake(rootId, 5)
//            await p.vouchWithConsent(rootId, agentId, 10, premiumBps, consent, sig); await p.claimSponsorFees(rootId, to)
//   agent    const id = await p.register(uri)
//            const { consent, sig } = await p.signConsent({ agentId, sponsorId, maxPremiumBps, deadline })
//            await p.redeemInvite(agentId, "priors-invite:<id>:<expiry>:<sig>")   // treasury v4 first line
//            await p.acceptSeat(agentId, staker)                                  // a staker's seat offer
//            const { loanId } = await p.borrow(agentId, 5, 7 * 86400)             // $5 for 7 days
//            await p.repay(loanId); await p.openLoans(agentId); await p.status(agentId)
//
// Amounts: a number or a decimal string is whole USDG ("5", 5.5); a bigint is raw 6-decimal units. Every write
// simulates first (a revert is explained with the contracts' own custom errors, before any gas is spent) and
// approves the exact USDG or $PRIORS it needs when the allowance is short.
//
// EXTENSION POINT: x402 `pay()` / `settleLoans()` live in sdk/float.mjs, not here. That module adds them with
// `extendPriorsV2({ pay, settleLoans })` (below), which refuses to overwrite a method this file defines. Everything
// it needs is public on an instance: `borrow`, `repay`, `openLoans`, `quoteFee`, `toUnits`, `usdg`, `pool`, `signer`.
import { ethers } from "ethers";
import { parseInvite, explainRevert } from "./priors.mjs";
import { pay as floatPay, settleLoans as floatSettleLoans } from "./float.mjs";

export { parseInvite, explainRevert };

// ---------------------------------------------------------------------------------------------------------------
// ABIs (human-readable, from src/CreditPoolV2.sol, src/SeatVaultV2.sol, src/TreasurySponsorV4.sol)
// ---------------------------------------------------------------------------------------------------------------

const CONSENT_T = "tuple(uint256 agentId,uint256 sponsorId,address owner,uint256 maxPremiumBps,uint256 nonce,uint256 deadline)";
const AGENT_T =
  "tuple(bool enrolled,bool isRoot,bool defaulted,bool frozen,bool importedFromV1,uint64 enrolledAt,uint64 lastBorrowAt,uint64 lastRepayAt,uint256 sponsor,uint256 delegatedIn,uint256 delegatedOut,uint256 principalOut,uint256 activeLoans,uint256 premiumBps,uint256 premiumCap,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid)";
const LOAN_T =
  "tuple(uint256 agentId,uint256 sponsorId,uint256 principal,uint256 fee,uint256 sponsorCut,uint256 reserveCut,uint256 premium,address owner,uint64 issuedAt,uint64 dueAt,uint64 defaultableAt,uint64 minScoreTerm,uint64 closedAt,uint8 status)";
const PARAMS_T =
  "tuple(uint256 minLoan,uint256 maxLoan,uint64 minTerm,uint64 maxTerm,uint64 grace,uint64 minScoreTerm,uint256 feeBps,uint256 sponsorFeeBps,uint256 protocolFeeBps,uint256 minStake,uint256 maxUtilizationBps,uint256 keeperBounty)";

export const POOL_V2_ABI = [
  // lenders
  "function deposit(uint256 assets, address receiver, uint256 minShares) returns (uint256)",
  "function withdraw(uint256 shares, address receiver) returns (uint256)",
  "function shares(address) view returns (uint256)",
  "function lastDepositAt(address) view returns (uint64)",
  "function convertToShares(uint256) view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function poolLiquidity() view returns (uint256)",
  "function totalPrincipalOut() view returns (uint256)",
  "function MIN_HOLD() view returns (uint64)",
  "function EARLY_EXIT_BPS() view returns (uint256)",
  // roots
  "function enrollRoot(uint256 rootId, uint256 assets)",
  "function addStake(uint256 rootId, uint256 assets)",
  "function unlock(uint256 rootId, uint256 shares, address to) returns (uint256)",
  "function rootShares(uint256) view returns (uint256)",
  "function backing(uint256) view returns (uint256)",
  "function freeBacking(uint256) view returns (uint256)",
  "function claimSponsorFees(uint256 sponsorId, address to) returns (uint256)",
  "function sponsorFees(uint256) view returns (uint256)",
  "function feesFrom(uint256 sponsorId, uint256 agentId) view returns (uint256)",
  // consent and vouching
  `function consentDigest(${CONSENT_T} c) view returns (bytes32)`,
  "function nonces(uint256) view returns (uint256)",
  `function vouchWithConsent(uint256 sponsorId, uint256 agentId, uint256 amount, uint256 premiumBps, ${CONSENT_T} c, bytes sig)`,
  "function vouch(uint256 sponsorId, uint256 agentId, uint256 amount)",
  "function leave(uint256 agentId)",
  "function setDelegate(uint256 agentId, address delegate)",
  "function isController(uint256 id, address who) view returns (bool)",
  // loans
  "function quoteFee(uint256 agentId, uint256 principal, uint64 term) view returns (uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium)",
  "function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee) returns (uint256)",
  "function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue)",
  `function getLoan(uint256) view returns (${LOAN_T})`,
  "function loansOf(uint256) view returns (uint256[])",
  "function loanCount() view returns (uint256)",
  `function getAgent(uint256) view returns (${AGENT_T})`,
  `function getParams() view returns (${PARAMS_T})`,
  "function ownerDefaults(address) view returns (uint256)",
  "function custodian(address) view returns (bool)",
  "function pausedUntil() view returns (uint64)",
  "function usdg() view returns (address)",
  "function registry() view returns (address)",
  "event Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 indexed sponsorId, uint256 principal, uint256 fee, uint64 dueAt, address to)",
  "event Deposited(address indexed lender, uint256 assets, uint256 shares)",
  "event Withdrawn(address indexed lender, uint256 assets, uint256 shares)",
  // errors
  "error Paused()", "error NotSeeded()", "error AlreadySeeded()", "error ZeroAmount()",
  "error NotOwnerOf(uint256 id, address caller)", "error NotController(uint256 id, address caller)", "error NotGuardian()",
  "error InvalidAgent(uint256 id)", "error NotRoot(uint256 id)", "error IsRoot(uint256 id)", "error AgentDefaulted(uint256 id)",
  "error V1Busy(uint256 id)", "error WrongSponsor(uint256 id, uint256 sponsor)", "error LoanOpen(uint256 id)",
  "error BadConsent()", "error ConsentExpired()", "error PremiumTooHigh(uint256 bps, uint256 cap)",
  "error InsufficientBacking(uint256 rootId, uint256 requested, uint256 free)",
  "error InsufficientCapacity(uint256 id, uint256 requested, uint256 available)",
  "error InsufficientLiquidity(uint256 requested, uint256 available)", "error UtilizationTooHigh()",
  "error LoanSizeOutOfRange(uint256 amount)", "error TermOutOfRange(uint64 term)", "error FeeTooHigh(uint256 fee, uint256 maxFee)",
  "error IsFrozen(uint256 id)", "error OwnerDefaulted(address owner)", "error BorrowBlockedByBacker(uint256 rootId)",
  "error LoanNotActive(uint256 loanId)", "error LoanNotDue(uint256 loanId, uint64 defaultableAt)", "error WrongLoan(uint256 loanId)",
  "error DueTooHigh(uint256 due, uint256 maxDue)", "error BelowMinStake(uint256 amount, uint256 minStake)",
  "error SlippageShares(uint256 minted, uint256 minShares)", "error InvalidHook(address hook)", "error HookNotReady(uint64 eta)",
  "error StillBacking(uint256 rootId)", "error ReserveShort(uint256 requested, uint256 reserve)",
  "error AlreadyImported(uint256 id)", "error NoV1()", "error ImportOutOfRange(uint256 id)", "error InvalidParams()", "error Renounce()",
];

export const SEAT_VAULT_V2_ABI = [
  "function offer(uint256 id)",
  `function accept(uint256 id, address staker, ${CONSENT_T} c, bytes sig)`,
  `function seat(uint256 id, ${CONSENT_T} c, bytes sig)`,
  "function withdrawOffer(uint256 id, address staker)",
  "function close(uint256 id)",
  "function settle(uint256 id, uint256 loanId)",
  "function poke(uint256 id)",
  "function claim(address to) returns (uint256)",
  "function pendingFees(uint256 id) view returns (uint256)",
  "function feesOwed(address) view returns (uint256)",
  "function offers(uint256 id, address staker) view returns (uint256)",
  "function getSeat(uint256 id) view returns (tuple(address staker,uint64 openedAt,bool closing,uint8 status,uint128 line,uint128 burnBps,uint256 amount,uint256 feeMark))",
  "function openSeats() view returns (uint256[])",
  "function seatable(uint256 id) view returns (bool)",
  "function epochRoom() view returns (uint256)",
  "function seatsPaused() view returns (bool)",
  "function params() view returns (uint256 seatSize, uint256 line, uint256 burnBps, uint256 maxOpenSeats, uint256 epochCap, uint64 epochLength)",
  "function agentId() view returns (uint256)",
  "function token() view returns (address)",
  "error Reentrancy()", "error NotAdopted()", "error AlreadyAdopted()", "error NotOurs(uint256 agentId)", "error Paused()",
  "error ZeroAmount()", "error NotController(uint256 agentId, address caller)", "error NoOffer(uint256 agentId, address staker)",
  "error OfferExists(uint256 agentId, address staker)", "error OfferTooSmall(uint256 agentId, uint256 offered, uint256 seatSize)",
  "error TermsChanged(uint256 agentId)", "error NotSeatable(uint256 agentId)", "error NoOpenSeat(uint256 agentId)",
  "error NotStakerOrController(uint256 agentId, address caller)", "error AgentDefaulted(uint256 agentId)",
  "error StillBacked(uint256 agentId)", "error BadProof(uint256 agentId, uint256 loanId)",
  "error TooManySeats(uint256 open, uint256 max)", "error EpochCapReached(uint256 wanted, uint256 left)",
  "error BadTransfer(uint256 expected, uint256 received)", "error InvalidParams()", "error Protected(address token)",
];

export const TREASURY_V4_ABI = [
  `function firstLine(uint256 id, uint64 expiry, bytes invite, ${CONSENT_T} c, bytes consentSig)`,
  "function inviteDigest(uint256 id, uint64 expiry) view returns (bytes32)",
  "function inviters(address) view returns (bool)",
  "function inviteUsed(bytes32) view returns (bool)",
  "function firstLined(uint256) view returns (bool)",
  "function agentId() view returns (uint256)",
  "function epochRoom() view returns (uint256)",
  "function raise(uint256 id)",
  "function eligibleForRaise(uint256 id) view returns (bool)",
  "function rules() view returns (uint256 reserveBps, uint256 firstLine, uint256 secondLine, uint256 epochCap, uint64 epochLength, uint64 minSeasoning, uint256 minQualified, uint256 minScore, uint64 idleAfter)",
  "error NotAdopted()", "error AlreadyAdopted()", "error NotOurs(uint256 agentId)", "error AlreadyLined(uint256 agentId)",
  "error NotEligible(uint256 agentId)", "error OwnerDefaulted(address owner)", "error EpochCapReached(uint256 wanted, uint256 left)",
  "error NotInvited(uint256 agentId, address signer)", "error InviteExpired(uint256 agentId, uint64 expiry)",
  "error InviteUsed(uint256 agentId)", "error NotIdle(uint256 agentId, uint256 reclaimableAt)", "error LoanOpen(uint256 agentId)",
  "error NothingToReclaim(uint256 agentId)", "error InvalidRules()", "error InvalidAddress()", "error UseSweep()", "error TransferFailed()",
  // OpenZeppelin ECDSA, reached from firstLine when the invite is not a signature at all
  "error ECDSAInvalidSignature()", "error ECDSAInvalidSignatureLength(uint256 length)", "error ECDSAInvalidSignatureS(bytes32 s)",
];

const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  // OpenZeppelin v5 ERC-20 errors, in case a token raises them
  "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
  "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
];
const REGISTRY_ABI = [
  "function ownerOf(uint256) view returns (address)",
  "function balanceOf(address) view returns (uint256)",
  "function register(string) returns (uint256)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
  "error ERC721NonexistentToken(uint256 tokenId)",
];

export const LOAN_STATUS = ["none", "active", "repaid", "defaulted"];
export const SEAT_STATUS = ["none", "open", "closed", "settled"];

/** EIP-712 for pool consents: CreditPoolV2's constructor says EIP712("Priors Credit", "2"). */
export const CONSENT_TYPES = {
  Consent: [
    { name: "agentId", type: "uint256" },
    { name: "sponsorId", type: "uint256" },
    { name: "owner", type: "address" },
    { name: "maxPremiumBps", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
export const INVITE_TYPES = { Invite: [{ name: "agentId", type: "uint256" }, { name: "expiry", type: "uint64" }] };

// ---------------------------------------------------------------------------------------------------------------
// Units
// ---------------------------------------------------------------------------------------------------------------

/** USDG: a bigint is raw units; a number or decimal string is whole dollars (6 decimals, exact for strings). */
export function toUnits(amount) {
  if (typeof amount === "bigint") return amount;
  if (typeof amount === "number") {
    if (!Number.isFinite(amount) || amount < 0) throw new Error(`not an amount: ${amount}`);
    return ethers.parseUnits(amount.toFixed(6), 6);
  }
  const s = String(amount ?? "").trim();
  if (!/^\d+(\.\d{1,6})?$/.test(s)) throw new Error(`not an amount: ${JSON.stringify(amount)} (use e.g. 5 or 12.5)`);
  return ethers.parseUnits(s, 6);
}
export const fmtUsdg = (units) => ethers.formatUnits(units, 6);
export const fmtPriors = (units) => ethers.formatUnits(units, 18);

// ---------------------------------------------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------------------------------------------

/**
 * Simulate, then send with 25% gas headroom (same reasons as sdk/priors.mjs: a doomed transaction returns its
 * reason only before the send, and a bare estimate can undershoot a branch taken at mining time).
 */
async function sendChecked(contract, method, args, ifaces) {
  const fn = contract.getFunction(method);
  try {
    await fn.staticCall(...args);
  } catch (err) {
    const shown = args.map((a) => (typeof a === "string" && a.length > 80 ? a.slice(0, 12) + "…" : typeof a === "object" && a !== null && !Array.isArray(a) ? "{…}" : String(a)));
    const e = new Error(`${method.split("(")[0]}(${shown.join(", ")}) would revert: ${explainRevert(err, ifaces)}`);
    e.cause = err;
    throw e;
  }
  let overrides = {};
  try {
    const est = await fn.estimateGas(...args);
    overrides = { gasLimit: est + est / 4n };
  } catch (_) { /* let ethers estimate on its own */ }
  const tx = await fn(...args, overrides);
  const rc = await tx.wait();
  if (!rc || rc.status !== 1) throw new Error(`${method.split("(")[0]} mined with status 0 (tx ${tx.hash})`);
  return rc;
}

const consentTuple = (c) => [BigInt(c.agentId), BigInt(c.sponsorId), c.owner, BigInt(c.maxPremiumBps), BigInt(c.nonce), BigInt(c.deadline)];

// ---------------------------------------------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------------------------------------------

export class PriorsV2 {
  /**
   * @param {{ signer?: any, provider?: any, rpc?: string,
   *           addresses: { pool: string, treasuryV4?: string, seatVault?: string, usdg?: string, registry?: string, priors?: string } }} opts
   */
  constructor(opts = {}) {
    const a = opts.addresses || {};
    if (!a.pool) throw new Error("addresses.pool is required");
    this.provider = opts.provider || opts.signer?.provider || (opts.rpc ? new ethers.JsonRpcProvider(opts.rpc, undefined, { cacheTimeout: -1 }) : null);
    if (!this.provider) throw new Error("give a signer connected to a provider, a provider, or an rpc");
    this.signer = opts.signer ? (opts.signer.provider ? opts.signer : opts.signer.connect(this.provider)) : null;
    this.addresses = a;
    const run = this.signer || this.provider;
    this.pool = new ethers.Contract(a.pool, POOL_V2_ABI, run);
    this.treasury = a.treasuryV4 ? new ethers.Contract(a.treasuryV4, TREASURY_V4_ABI, run) : null;
    this.vault = a.seatVault ? new ethers.Contract(a.seatVault, SEAT_VAULT_V2_ABI, run) : null;
    this.usdg = a.usdg ? new ethers.Contract(a.usdg, ERC20_ABI, run) : null;
    this.token = a.priors ? new ethers.Contract(a.priors, ERC20_ABI, run) : null;
    this.registry = a.registry ? new ethers.Contract(a.registry, REGISTRY_ABI, run) : null;
    // every interface a call here can revert with: a vault or treasury call bubbles the pool's errors up
    this._ifaces = [this.pool.interface, ...(this.vault ? [this.vault.interface] : []), ...(this.treasury ? [this.treasury.interface] : []), new ethers.Interface(ERC20_ABI), new ethers.Interface(REGISTRY_ABI)];
    this.toUnits = toUnits;
  }

  /** A revert as `Name(args)`, decoded against every v2 ABI. */
  explain(err) { return explainRevert(err, this._ifaces); }

  async _usdg() {
    if (!this.usdg) this.usdg = new ethers.Contract(await this.pool.usdg(), ERC20_ABI, this.signer || this.provider);
    return this.usdg;
  }
  async _registry() {
    if (!this.registry) this.registry = new ethers.Contract(await this.pool.registry(), REGISTRY_ABI, this.signer || this.provider);
    return this.registry;
  }
  _needSigner() { if (!this.signer) throw new Error("this call needs a signer"); }
  _need(c, name) { if (!c) throw new Error(`no ${name} address configured`); return c; }
  async me() { this._needSigner(); return this.signer.getAddress(); }

  /** Approve `spender` for exactly `amount` of `token` if the allowance is short; also checks the balance. */
  async _ensure(token, spender, amount, what) {
    const me = await this.me();
    const bal = await token.balanceOf(me);
    if (bal < amount) throw new Error(`${what}: needs ${amount} units but ${me} holds ${bal}`);
    if ((await token.allowance(me, spender)) < amount) await sendChecked(token, "approve", [spender, amount], this._ifaces);
  }

  // ---- lenders -------------------------------------------------------------------------------------------------

  /** Deposit USDG for pool shares. `minShares` defaults to the quote less 0.5% (the share price only rises). */
  async deposit(amount, { receiver, minShares } = {}) {
    const assets = toUnits(amount);
    const me = await this.me();
    const usdg = await this._usdg();
    await this._ensure(usdg, await this.pool.getAddress(), assets, "deposit");
    const min = minShares ?? ((await this.pool.convertToShares(assets)) * 995n) / 1000n;
    const rc = await sendChecked(this.pool, "deposit", [assets, receiver || me, min], this._ifaces);
    const ev = this._event(rc, "Deposited");
    return { hash: rc.hash, assets, shares: ev ? ev.args.shares : null };
  }

  /** Withdraw `shares` (bigint) or `'all'`. Inside the 7-day hold, 0.5% stays with the pool. */
  async withdraw(shares = "all", { receiver } = {}) {
    const me = await this.me();
    const s = shares === "all" ? await this.pool.shares(me) : BigInt(shares);
    if (s === 0n) throw new Error(`${me} holds no pool shares`);
    const rc = await sendChecked(this.pool, "withdraw", [s, receiver || me], this._ifaces);
    const ev = this._event(rc, "Withdrawn");
    return { hash: rc.hash, shares: s, assets: ev ? ev.args.assets : null };
  }

  /** A lender's shares, their value now, and when the early-exit fee stops applying. */
  async position(addr) {
    const who = addr || (await this.me());
    const [shares, last, hold] = await Promise.all([this.pool.shares(who), this.pool.lastDepositAt(who), this.pool.MIN_HOLD()]);
    const value = shares === 0n ? 0n : await this.pool.convertToAssets(shares);
    return { address: who, shares, value, lastDepositAt: Number(last), feeFreeAt: last === 0n ? 0 : Number(last + hold) };
  }

  // ---- stakers (seat vault) ------------------------------------------------------------------------------------

  /** Escrow a seat's worth of $PRIORS behind `agentId` (approved automatically). Nothing is vouched until accepted. */
  async offer(agentId) {
    const vault = this._need(this.vault, "seatVault");
    const token = this.token || (this.token = new ethers.Contract(await vault.token(), ERC20_ABI, this.signer));
    const { seatSize } = await vault.params();
    await this._ensure(token, await vault.getAddress(), seatSize, "offer");
    return { hash: (await sendChecked(vault, "offer", [agentId], this._ifaces)).hash, seatSize };
  }
  /** Take back an untaken offer (the staker's own by default). */
  async withdrawOffer(agentId, staker) {
    const vault = this._need(this.vault, "seatVault");
    return (await sendChecked(vault, "withdrawOffer", [agentId, staker || (await this.me())], this._ifaces)).hash;
  }
  /** Close a seat (staker or agent controller). With a loan open it closes when the last one is repaid. */
  async closeSeat(agentId) {
    const vault = this._need(this.vault, "seatVault");
    return (await sendChecked(vault, "close", [agentId], this._ifaces)).hash;
  }
  /** Pay out the USDG fees credited to the caller. Pokes the caller's open seats first so nothing is left behind. */
  async claimSeatFees(to) {
    const vault = this._need(this.vault, "seatVault");
    const me = await this.me();
    for (const id of await vault.openSeats()) {
      const s = await vault.getSeat(id);
      if (s.staker.toLowerCase() === me.toLowerCase() && (await vault.pendingFees(id)) > 0n) await sendChecked(vault, "poke", [id], this._ifaces);
    }
    const owed = await vault.feesOwed(me);
    if (owed === 0n) throw new Error(`no seat fees owed to ${me}`);
    const rc = await sendChecked(vault, "claim", [to || me], this._ifaces);
    return { hash: rc.hash, amount: owed };
  }
  /** Fees owed to `addr`: credited, plus what its open seats would be credited now. */
  async pendingSeatFees(addr) {
    const vault = this._need(this.vault, "seatVault");
    const who = (addr || (await this.me())).toLowerCase();
    let total = await vault.feesOwed(who);
    for (const id of await vault.openSeats()) {
      const s = await vault.getSeat(id);
      if (s.staker.toLowerCase() === who) total += await vault.pendingFees(id);
    }
    return total;
  }
  /** Whether a seat could open behind `agentId` now (the vault's own check). */
  async seatable(agentId) { return this._need(this.vault, "seatVault").seatable(agentId); }
  /**
   * The seats open now. There is no cheap on-chain list of every seatable identity (the registry is not
   * enumerable); filter candidate ids with `seatableAgents(ids)`.
   */
  async openSeats() {
    const vault = this._need(this.vault, "seatVault");
    const ids = await vault.openSeats();
    return Promise.all(ids.map(async (id) => ({ agentId: Number(id), ...this._seat(await vault.getSeat(id)) })));
  }
  async seatableAgents(ids) {
    const vault = this._need(this.vault, "seatVault");
    const ok = await Promise.all(ids.map((id) => vault.seatable(id)));
    return ids.filter((_, i) => ok[i]).map(Number);
  }
  _seat(s) {
    return { staker: s.staker, openedAt: Number(s.openedAt), closing: s.closing, status: SEAT_STATUS[Number(s.status)], line: BigInt(s.line), burnBps: Number(s.burnBps), amount: s.amount };
  }

  // ---- backers (roots) -----------------------------------------------------------------------------------------

  /** Make `rootId` (an identity the signer owns) a backer with `stake` USDG locked as pool shares. */
  async enrollRoot(rootId, stake) {
    const assets = toUnits(stake);
    await this._ensure(await this._usdg(), await this.pool.getAddress(), assets, "enrollRoot");
    return (await sendChecked(this.pool, "enrollRoot", [rootId, assets], this._ifaces)).hash;
  }
  /** Add stake behind a root. Anyone may; only the root's owner can take it out. */
  async addStake(rootId, amount) {
    const assets = toUnits(amount);
    await this._ensure(await this._usdg(), await this.pool.getAddress(), assets, "addStake");
    return (await sendChecked(this.pool, "addStake", [rootId, assets], this._ifaces)).hash;
  }
  /**
   * Open (or hand off to) a sponsorship of `line` USDG at `premiumBps`, with the consent the agent's owner signed
   * (`signConsent`). Only the sponsor's owner can call it.
   */
  async vouchWithConsent(sponsorId, agentId, line, premiumBps, consent, sig) {
    return (await sendChecked(this.pool, "vouchWithConsent", [sponsorId, agentId, toUnits(line), premiumBps, consentTuple(consent), sig], this._ifaces)).hash;
  }
  /** Claim a root's sponsor fees to `to` (default: the signer). */
  async claimSponsorFees(sponsorId, to) {
    const me = await this.me();
    const amount = await this.pool.sponsorFees(sponsorId);
    if (amount === 0n) throw new Error(`root #${sponsorId} has no sponsor fees to claim`);
    const rc = await sendChecked(this.pool, "claimSponsorFees", [sponsorId, to || me], this._ifaces);
    return { hash: rc.hash, amount };
  }
  /** A root's stake and fees. */
  async root(rootId) {
    const [a, shares, backing, free, fees] = await Promise.all([this.pool.getAgent(rootId), this.pool.rootShares(rootId), this.pool.backing(rootId), this.pool.freeBacking(rootId), this.pool.sponsorFees(rootId)]);
    return { isRoot: a.isRoot, shares, backing, freeBacking: free, delegatedOut: a.delegatedOut, sponsorFees: fees };
  }

  // ---- agents --------------------------------------------------------------------------------------------------

  /**
   * Register a new ERC-8004 identity; returns its id, read from the registry's ERC-721 mint log to the signer
   * (the registry-specific `Registered` event differs between implementations; see sdk/priors.mjs).
   */
  async register(uri = "") {
    const reg = await this._registry();
    const me = (await this.me()).toLowerCase();
    const rc = await sendChecked(reg, "register", [uri], this._ifaces);
    const T = ethers.id("Transfer(address,address,uint256)");
    const ZERO = ethers.ZeroHash;
    const regAddr = (await reg.getAddress()).toLowerCase();
    const ours = rc.logs.filter((l) => l.address.toLowerCase() === regAddr && l.topics.length === 4 && l.topics[0] === T && l.topics[1] === ZERO && ethers.getAddress("0x" + l.topics[2].slice(26)).toLowerCase() === me);
    if (ours.length !== 1) throw new Error(`expected one identity minted to ${me} in tx ${rc.hash}, found ${ours.length}`);
    return Number(BigInt(ours[0].topics[3]));
  }

  /**
   * Sign the pool consent that lets `sponsorId` back `agentId`, as the agent's NFT owner. EIP-712 on the pool:
   * domain "Priors Credit" v2, Consent(agentId, sponsorId, owner, maxPremiumBps, nonce, deadline). The nonce is the
   * agent's current one, so a consent is good for exactly one vouchWithConsent. Checked against the pool's own
   * `consentDigest` before it is handed back, so a domain mismatch fails here, not as `BadConsent` on chain.
   */
  async signConsent({ agentId, sponsorId, maxPremiumBps = 0, deadline, nonce } = {}) {
    const owner = await this.me();
    const onchainOwner = await (await this._registry()).ownerOf(agentId);
    if (onchainOwner.toLowerCase() !== owner.toLowerCase()) throw new Error(`agent #${agentId} is owned by ${onchainOwner}, not by the signer ${owner}: only the owner can consent`);
    const { chainId } = await this.provider.getNetwork();
    const now = (await this.provider.getBlock("latest")).timestamp;
    const consent = {
      agentId: BigInt(agentId),
      sponsorId: BigInt(sponsorId),
      owner,
      maxPremiumBps: BigInt(maxPremiumBps),
      nonce: nonce ?? (await this.pool.nonces(agentId)),
      deadline: BigInt(deadline ?? now + 3600),
    };
    const domain = { name: "Priors Credit", version: "2", chainId, verifyingContract: await this.pool.getAddress() };
    const sig = await this.signer.signTypedData(domain, CONSENT_TYPES, consent);
    const want = await this.pool.consentDigest(consentTuple(consent));
    if (ethers.TypedDataEncoder.hash(domain, CONSENT_TYPES, consent) !== want) throw new Error("consent digest does not match the pool's consentDigest (wrong pool address or chain?)");
    return { consent, sig };
  }

  /**
   * Redeem a treasury v4 invite (`priors-invite:<agentId>:<expiry>:<sig>`) for a first line: the inviter's signature
   * plus the owner's pool consent naming the treasury's root. The signer must own `agentId`.
   */
  async redeemInvite(agentId, inviteCode) {
    const t4 = this._need(this.treasury, "treasuryV4");
    const inv = parseInvite(inviteCode, agentId);
    const signer = ethers.recoverAddress(await t4.inviteDigest(agentId, inv.expiry), inv.signature);
    if (!(await t4.inviters(signer))) throw new Error(`the invite for #${agentId} was signed by ${signer}, which treasury v4 has not named an inviter (signed for another treasury version?)`);
    const sponsorId = await t4.agentId();
    const { consent, sig } = await this.signConsent({ agentId, sponsorId, maxPremiumBps: 0 });
    const rc = await sendChecked(t4, "firstLine", [agentId, inv.expiry, inv.signature, consentTuple(consent), sig], this._ifaces);
    return { hash: rc.hash, sponsorId: Number(sponsorId) };
  }

  /** Take staker `staker`'s seat offer on `agentId`: the vault vouches its line with the owner's consent. */
  async acceptSeat(agentId, staker) {
    const vault = this._need(this.vault, "seatVault");
    if ((await vault.offers(agentId, staker)) === 0n) throw new Error(`no seat offer from ${staker} on agent #${agentId}`);
    const sponsorId = await vault.agentId();
    const { consent, sig } = await this.signConsent({ agentId, sponsorId, maxPremiumBps: 0 });
    const rc = await sendChecked(vault, "accept", [agentId, staker, consentTuple(consent), sig], this._ifaces);
    return { hash: rc.hash, sponsorId: Number(sponsorId) };
  }

  /** The fee for `amount` over `termSeconds` for this agent (its sponsor's premium included), from the pool. */
  async quoteFee(agentId, amount, termSeconds) {
    const q = await this.pool.quoteFee(agentId, toUnits(amount), BigInt(termSeconds));
    return { fee: q.fee, sponsorCut: q.sponsorCut, reserveCut: q.reserveCut, premium: q.premium };
  }

  /**
   * Borrow `amount` for `termSeconds`. USDG lands in `to` (default: the signer). `maxFee` defaults to the pool's
   * own quote, so a premium raised between quote and mining reverts (FeeTooHigh) instead of costing more.
   */
  async borrow(agentId, amount, termSeconds, { to, maxFee } = {}) {
    const units = toUnits(amount);
    const term = BigInt(termSeconds);
    const fee = maxFee ?? (await this.pool.quoteFee(agentId, units, term)).fee;
    const rc = await sendChecked(this.pool, "borrow", [agentId, units, term, to || (await this.me()), fee], this._ifaces);
    const ev = this._event(rc, "Borrowed");
    if (!ev) throw new Error("Borrowed event not found");
    return { hash: rc.hash, loanId: Number(ev.args.loanId), principal: ev.args.principal, fee: ev.args.fee, dueAt: Number(ev.args.dueAt) };
  }

  /** Repay a loan in full; approves USDG for exactly what is due, bound to the loan's agent and amount. */
  async repay(loanId) {
    const l = await this.pool.getLoan(loanId);
    if (Number(l.status) !== 1) throw new Error(`loan #${loanId} is not active (${LOAN_STATUS[Number(l.status)]})`);
    const due = l.principal + l.fee;
    await this._ensure(await this._usdg(), await this.pool.getAddress(), due, `repay(${loanId})`);
    const rc = await sendChecked(this.pool, "repay", [loanId, l.agentId, due], this._ifaces);
    return { hash: rc.hash, loanId: Number(loanId), paid: due };
  }

  /** Every loan of an agent, decoded. */
  async loans(agentId) {
    const ids = await this.pool.loansOf(agentId);
    return Promise.all(ids.map(async (id) => this._loan(id, await this.pool.getLoan(id))));
  }
  /** The agent's active loans. */
  async openLoans(agentId) { return (await this.loans(agentId)).filter((l) => l.status === "active"); }
  _loan(id, l) {
    return { loanId: Number(id), agentId: Number(l.agentId), sponsorId: Number(l.sponsorId), principal: l.principal, fee: l.fee, due: l.principal + l.fee, issuedAt: Number(l.issuedAt), dueAt: Number(l.dueAt), defaultableAt: Number(l.defaultableAt), status: LOAN_STATUS[Number(l.status)] };
  }

  /** Where an agent stands: identity, sponsor (which kind), line, loans, seat, and the owner's USDG. */
  async status(agentId) {
    const reg = await this._registry();
    const owner = await reg.ownerOf(agentId).catch(() => null);
    const a = await this.pool.getAgent(agentId);
    const [tRoot, vRoot] = await Promise.all([this.treasury ? this.treasury.agentId() : 0n, this.vault ? this.vault.agentId() : 0n]);
    const sponsor = a.sponsor;
    const sponsorKind = sponsor === 0n ? "none" : sponsor === tRoot ? "treasury v4" : sponsor === vRoot ? "seat vault" : "backer";
    const available = a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0n;
    const seat = this.vault ? this._seat(await this.vault.getSeat(agentId)) : null;
    const usdg = await this._usdg();
    return {
      agentId: Number(agentId), owner, enrolled: a.enrolled, isRoot: a.isRoot, defaulted: a.defaulted, frozen: a.frozen,
      sponsor: Number(sponsor), sponsorKind, premiumBps: Number(a.premiumBps),
      line: a.delegatedIn, principalOut: a.principalOut, available, activeLoans: Number(a.activeLoans),
      loansRepaid: Number(a.loansRepaid), qualifiedRepaid: Number(a.qualifiedRepaid), volumeRepaid: a.volumeRepaid, feesPaid: a.feesPaid,
      openLoans: await this.openLoans(agentId),
      seat: seat && seat.status !== "none" ? seat : null,
      ownerUsdg: owner ? await usdg.balanceOf(owner) : 0n,
    };
  }

  _event(rc, name) {
    const pool = this.pool.target.toLowerCase();
    for (const log of rc.logs) {
      if (log.address.toLowerCase() !== pool) continue;
      try { const ev = this.pool.interface.parseLog(log); if (ev && ev.name === name) return ev; } catch (_) {}
    }
    return null;
  }
}

/**
 * EXTENSION POINT for other modules (sdk/float.mjs adds `pay` and `settleLoans`): installs methods on
 * PriorsV2.prototype. Refuses to overwrite a method defined here or already installed, so two modules cannot
 * silently replace each other's behaviour.
 */
export function extendPriorsV2(methods) {
  for (const [name, fn] of Object.entries(methods)) {
    if (typeof fn !== "function") throw new Error(`extendPriorsV2: ${name} is not a function`);
    if (name in PriorsV2.prototype) throw new Error(`extendPriorsV2: PriorsV2.${name} already exists`);
    Object.defineProperty(PriorsV2.prototype, name, { value: fn, writable: false, configurable: false, enumerable: false });
  }
  return PriorsV2;
}

/* Credit as float (docs/FLOAT.md): x402 payment that borrows the shortfall from the agent's line. The logic lives
   in float.mjs; these bind it to this instance's signer and pool. */
extendPriorsV2({
  /** @param {string} url @param {{agentId, maxBorrow, maxPrice?, maxValiditySeconds?, termSeconds?, maxFee?, fetchImpl?, init?}} opts */
  pay(url, opts = {}) { this._needSigner(); return floatPay(url, { ...opts, signer: this.signer, pool: this.pool }); },
  /** Repay open loans of `agentId`, earliest due first, while the balance covers them. */
  settleLoans(agentId) { this._needSigner(); return floatSettleLoans({ signer: this.signer, pool: this.pool, agentId }); },
});

export { sendChecked };
export default PriorsV2;
