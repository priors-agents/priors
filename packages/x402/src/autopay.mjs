// Autopay from the agent's own wallet: the agent's declared ERC-8004 wallet approves
// AutoRepay v2 for a USDG budget and enrolls itself for its agent, with a limit per loan. The plan
// lasts while the agent keeps the owner and the wallet it enrolled under (its epoch): after a new key or a sale, enroll
// again. AutoRepay v1 (retired before use) is refused. From then on
// Priors' keeper (or anyone) calls AutoRepay.run(loanId) in the 6 hours before each loan is due, and the loan is repaid
// from this wallet, then (with useSavings) its savings, if they hold enough. No click per loan. ethers v6.
//
// AutoRepay has no owner, no upgrade and no setter; it sends the wallet's money only to the pool, for the agent's own
// loans, in their window. The budget is the allowance (4 x the limit by default), never unlimited.
//
// Also here:
//   - repayWindow(issuedAt, dueAt): when a loan's window opens, the contract's own rule (opensAt), for a runtime that
//     repays by itself inside the same window (settleLoans({ onlyInWindow: true }));
//   - autopayReserve(status, now): what loans in the next 24 h will pull from the wallet, which pay_url keeps back.
import { ethers } from "ethers";
import { PayError } from "./credit.mjs"; // used inside functions only: credit.mjs imports repayWindow from here

/** AutoRepay, the subset the agent's wallet uses, with its custom errors so a revert decodes to a name. */
export const AUTOREPAY_ABI = [
  "function enroll(uint256 agentId, uint256 cap, bool useSavings, bool late)",
  "function revoke(uint256 agentId)",
  "function hold(bool on)",
  "function planOf(address wallet, uint256 agentId) view returns (uint32 cap, address owner, bool on, bool useSavings, bool late, uint32 epoch)",
  "function epochOf(uint256 agentId) view returns (uint32 epoch, bool stale)",
  "function VERSION() view returns (uint256)",
  "function held(address who) view returns (bool)",
  "function pausedUntil() view returns (uint64)",
  "function WINDOW() view returns (uint64)",
  "function MAX_CAP() view returns (uint256)",
  "function check(uint256 loanId) view returns (tuple(uint8 status, uint256 agentId, uint256 due, uint64 opens, uint64 closes, address wallet, uint256 fromWallet, uint256 fromWalletSavings, address owner, uint256 fromOwner, uint256 fromOwnerSavings))",
  "event AutoRepaid(uint256 indexed loanId, uint256 indexed agentId, address wallet, uint256 fromWallet, uint256 fromWalletSavings, address owner, uint256 fromOwner, uint256 fromOwnerSavings)",
  "error BadCap(uint256 cap)", "error NotAgentWallet(uint256 agentId, address caller)", "error NotOwner(uint256 agentId, address caller)",
  "error LoanNotActive(uint256 loanId)", "error IsPaused(uint64 until)", "error TooEarly(uint256 loanId, uint64 opens)", "error NoPlan(uint256 loanId)",
  "error Shortfall(uint256 due, uint256 available)", "error RegistryDown(uint256 agentId)", "error VaultOverpaid(uint256 asked, uint256 received)",
];
const REGISTRY_ABI = ["function ownerOf(uint256) view returns (address)", "function getAgentWallet(uint256 agentId) view returns (address)"];
const ERC20_ABI = ["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"];
const VAULT_ABI = [...ERC20_ABI, "function previewRedeem(uint256 shares) view returns (uint256)", "function previewDeposit(uint256 assets) view returns (uint256)"];
const POOL_ABI = [
  "function loansOf(uint256 id) view returns (uint256[])",
  "function getLoan(uint256 loanId) view returns (tuple(uint256 agentId, uint256 sponsorId, uint256 principal, uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium, address owner, uint64 issuedAt, uint64 dueAt, uint64 defaultableAt, uint64 minScoreTerm, uint64 closedAt, uint8 status))",
];

/** AutoRepayV2.Status, in order. */
export const AUTOPAY_STATUS = Object.freeze(["ready", "not active", "paused", "too early", "no plan", "short", "registry down"]);
/** The window's constants (AutoRepay v2: WINDOW 6 h as deployed, MIN_WINDOW 2 h, SEASON 7 days, MIN_AGE 1 h). */
export const AUTOPAY_WINDOW = Object.freeze({ window: 6 * 3600, minWindow: 2 * 3600, season: 7 * 86400, minAge: 3600 });
/** The AutoRepay this package version runs with (AutoRepayV2.VERSION). */
export const AUTOREPAY_VERSION = 2;
/** The most this package version enrolls per loan by default (stage 0: $25). */
export const AUTOPAY_STAGE_CAP = 25_000_000n;
/** Budget: allowances of 4 x the limit per loan. */
export const BUDGET_LOANS = 4n;
/** How far ahead pay_url keeps back what Autopay loans will pull. */
export const RESERVE_SECONDS = 24 * 3600;

/**
 * When a loan's repay window opens: the last WINDOW before `dueAt`, but for a term over a week never before day 7
 * unless that would leave under MIN_WINDOW of on-time attempts, and never in the loan's first hour
 * (AutoRepayV2.opensAt). Seconds.
 */
export function repayWindow(issuedAt, dueAt, w = AUTOPAY_WINDOW) {
  issuedAt = Number(issuedAt); dueAt = Number(dueAt);
  const term = dueAt - issuedAt;
  let opens = dueAt - Math.min(term, w.window);
  if (term > w.season) opens = Math.max(opens, Math.min(issuedAt + w.season, dueAt - w.minWindow));
  opens = Math.max(opens, issuedAt + (w.minAge ?? 0));
  return { opens, dueAt };
}

/** AutoRepay v1 (retired before use) has no VERSION(): refused before any approval. */
async function needV2(c) {
  let v = 1;
  try { v = Number(await c.autoRepay.VERSION()); } catch (_) { /* v1 */ }
  if (v !== AUTOREPAY_VERSION) throw new PayError("AUTOREPAY_V1", `Autopay: ${c.address} is AutoRepay v${v}, which is retired; set PRIORS_AUTOREPAY to AutoRepay v${AUTOREPAY_VERSION} (deployments/4663.v2.json autoRepay), or update the package`);
}

/** The contracts: AutoRepay at `address`, the registry, USDG, the savings vault (optional) and the pool. */
export function autopayContracts({ runner, address, registry, usdg, savingsVault = null, pool }) {
  if (!address || !ethers.isAddress(address)) throw new PayError("NO_AUTOREPAY", "Autopay isn't deployed yet: no AutoRepay address is configured.");
  return {
    address: ethers.getAddress(address),
    autoRepay: new ethers.Contract(address, AUTOREPAY_ABI, runner),
    registry: new ethers.Contract(registry, REGISTRY_ABI, runner),
    usdg: new ethers.Contract(usdg, ERC20_ABI, runner),
    vault: savingsVault ? new ethers.Contract(savingsVault, VAULT_ABI, runner) : null,
    pool: new ethers.Contract(pool, POOL_ABI, runner),
  };
}

/**
 * The agent's Autopay as its wallet `wallet` sees it: {
 *   declared: the registry names `wallet` the agent's wallet (only then can it enroll, and a plan only pays then),
 *   plan: { on, cap, owner, useSavings, late, epoch, current (its owner is the agent's owner now, and it was set in
 *     the agent's current epoch), stale (on, but set before the agent's owner or wallet changed: enroll again) },
 *   held, paused: { until } | null,
 *   allowance: { usdg, shares }, budget: what a run can pull now (USDG within its allowance and balance, plus savings
 *     within the share allowance when the plan uses them),
 *   loans: each open loan with AutoRepay.check (status, opens, closes, fromWallet, fromWalletSavings), soonest due first,
 *   next: the first open loan, short: the first loan due in the next 7 days the budget can't cover ({ loanId, need,
 *     have }) or null }.
 */
export async function autopayStatus(c, wallet, agentId, { now = Math.floor(Date.now() / 1000) } = {}) {
  const w = ethers.getAddress(wallet), id = BigInt(agentId);
  const [declaredAs, owner, plan, held, pausedUntil, allow, bal, ep] = await Promise.all([
    c.registry.getAgentWallet(id), c.registry.ownerOf(id), c.autoRepay.planOf(w, id), c.autoRepay.held(w), c.autoRepay.pausedUntil(),
    c.usdg.allowance(w, c.address), c.usdg.balanceOf(w), c.autoRepay.epochOf(id).catch(() => null),
  ]);
  const p = { on: plan.on ?? plan[2], cap: BigInt(plan.cap ?? plan[0]), owner: plan.owner ?? plan[1], useSavings: plan.useSavings ?? plan[3], late: plan.late ?? plan[4], epoch: Number(plan.epoch ?? plan[5] ?? 0) };
  const epoch = ep ? Number(ep.epoch ?? ep[0]) : null;
  p.stale = Boolean(p.on && epoch !== null && p.epoch !== epoch);
  p.current = p.on && !p.stale && String(p.owner).toLowerCase() === String(owner).toLowerCase();
  let shares = 0n, shareAllow = 0n, savingsValue = 0n;
  if (c.vault) {
    [shares, shareAllow] = await Promise.all([c.vault.balanceOf(w), c.vault.allowance(w, c.address)]);
    const usable = shareAllow < shares ? shareAllow : shares;
    if (usable > 0n) savingsValue = await c.vault.previewRedeem(usable);
  }
  const cash = allow < bal ? allow : bal;
  const budget = p.on ? cash + (p.useSavings ? savingsValue : 0n) : 0n;
  const ids = await c.pool.loansOf(id);
  const loans = [];
  for (const loanId of ids) {
    const l = await c.pool.getLoan(loanId);
    if (Number(l.status) !== 1) continue;
    let q = null;
    try { q = await c.autoRepay.check(loanId); } catch (_) { /* unread */ }
    loans.push({ loanId: BigInt(loanId), due: BigInt(l.principal) + BigInt(l.fee), issuedAt: Number(l.issuedAt), dueAt: Number(l.dueAt), defaultableAt: Number(l.defaultableAt), owner: l.owner,
      status: q ? AUTOPAY_STATUS[Number(q.status)] : null, opens: q ? Number(q.opens) : repayWindow(l.issuedAt, l.dueAt).opens, closes: q ? Number(q.closes) : null,
      fromWallet: q ? BigInt(q.fromWallet) : 0n, fromWalletSavings: q ? BigInt(q.fromWalletSavings) : 0n });
  }
  loans.sort((x, y) => x.dueAt - y.dueAt);
  let need = 0n, short = null;
  if (p.current) for (const l of loans.filter((x) => x.dueAt <= now + 7 * 86400)) {
    need += l.due;
    if (need > budget || l.due > p.cap) { short = { loanId: l.loanId, need, have: budget, overCap: l.due > p.cap }; break; }
  }
  return {
    declared: String(declaredAs).toLowerCase() === w.toLowerCase(), owner, plan: p, held, paused: Number(pausedUntil) > now ? { until: Number(pausedUntil) } : null,
    allowance: { usdg: allow, shares: shareAllow }, balance: bal, budget, loans, next: loans[0] || null, short,
  };
}

/**
 * What the wallet must keep for Autopay: the loans whose window opens within `horizon` seconds (24 h), while the plan
 * is on and current. 0n otherwise.
 */
export function autopayReserve(status, now = Math.floor(Date.now() / 1000), horizon = RESERVE_SECONDS) {
  if (!status || !status.plan || !status.plan.current || status.held) return 0n;
  return status.loans.filter((l) => l.opens <= now + horizon && l.due <= status.plan.cap).reduce((t, l) => t + l.due, 0n);
}

/** The default limit per loan: the line plus a 30-day fee (1% per 30 days), rounded up to the dollar, at most `ceiling`. */
export function defaultCap(line, ceiling = AUTOPAY_STAGE_CAP) {
  line = BigInt(line || 0);
  const withFee = line + (line + 99n) / 100n;
  const whole = ((withFee + 999_999n) / 1_000_000n) * 1_000_000n;
  return whole === 0n ? ceiling : whole < ceiling ? whole : ceiling;
}

/**
 * Turn Autopay on from the agent's wallet `signer`: approve AutoRepay for `budget` USDG (default 4 x `cap`; the
 * allowance is only raised, never lowered), and its savings worth the same with `useSavings`, then enroll. Refuses a
 * wallet the registry does not name the agent's, and a cap above `ceiling` (the package's stage cap unless raised).
 * Needs ETH for gas. @returns {{ hashes: string[], cap: bigint, budget: bigint }}
 */
export async function autopayOn(c, signer, agentId, { cap, useSavings = false, late = true, budget, ceiling = AUTOPAY_STAGE_CAP } = {}) {
  const me = await signer.getAddress(), id = BigInt(agentId);
  cap = BigInt(cap);
  if (cap <= 0n) throw new PayError("CAP", "Autopay: the limit per loan must be above zero");
  if (cap > BigInt(ceiling)) throw new PayError("CAP", `Autopay: the limit per loan is at most ${ethers.formatUnits(ceiling, 6)} USDG for now`);
  const declared = await c.registry.getAgentWallet(id);
  if (String(declared).toLowerCase() !== me.toLowerCase()) throw new PayError("NOT_AGENT_WALLET", `Autopay: ${me} is not agent #${id}'s declared wallet (the registry names ${declared}), so it can't enroll`);
  await needV2(c);
  budget = budget === undefined ? cap * BUDGET_LOANS : BigInt(budget);
  const hashes = [];
  const send = async (p) => { const tx = await p; hashes.push(tx.hash); await tx.wait(); };
  const ar = c.autoRepay.connect(signer), u = c.usdg.connect(signer);
  if ((await c.usdg.allowance(me, c.address)) < budget) await send(u.approve(c.address, budget));
  if (useSavings) {
    if (!c.vault) throw new PayError("NO_SAVINGS", "Autopay: no savings vault is configured, so it can't use savings");
    const shares = await c.vault.previewDeposit(budget);
    if ((await c.vault.allowance(me, c.address)) < shares) await send(c.vault.connect(signer).approve(c.address, shares));
  }
  await send(ar.enroll(id, cap, Boolean(useSavings), Boolean(late)));
  return { hashes, cap, budget };
}

/** Turn Autopay off for `agentId` (revoke). With `clearBudget`, also set the wallet's allowances to AutoRepay to 0. */
export async function autopayOff(c, signer, agentId, { clearBudget = false } = {}) {
  const me = await signer.getAddress(), hashes = [];
  const send = async (p) => { const tx = await p; hashes.push(tx.hash); await tx.wait(); };
  await send(c.autoRepay.connect(signer).revoke(BigInt(agentId)));
  if (clearBudget) {
    if ((await c.usdg.allowance(me, c.address)) > 0n) await send(c.usdg.connect(signer).approve(c.address, 0n));
    if (c.vault && (await c.vault.allowance(me, c.address)) > 0n) await send(c.vault.connect(signer).approve(c.address, 0n));
  }
  return { hashes };
}
