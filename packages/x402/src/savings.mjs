// Savings for an agent on Robinhood Chain: spare USDG kept in a Morpho vault (ERC-4626, Morpho Vault V2), taken back
// out when the agent has to pay or repay. The default vault is Steakhouse USDG.
//
// The agent's own money in someone else's vault: Priors never holds it, and the vault's risk is the agent's (Morpho's
// contracts; the curator's markets, fees and allocators; a loss in a market lowers the share value at once; the
// issuer of USDG can freeze addresses). Before anything moves, the vault must be a contract whose asset is USDG.
//
// How money comes out (audits of 2026-09-29):
// - A plain withdrawal pays from the vault's idle USDG, then from its liquidity market. How much it can pay is read
//   (idle + the liquidity market's free liquidity) and confirmed by simulating the withdrawal: Morpho Vault V2 answers
//   0 to every `max*` view by design.
// - When that is not enough, the vault lets anyone move its money out of its OTHER markets into idle
//   (`forceDeallocate`, "in-kind redemption", which allocators cannot prevent). This module does that and the
//   withdrawal in one transaction (`multicall`), only from markets whose penalty is 0, with the penalty charged to an
//   address that holds nothing: if a penalty is switched on between the check and the transaction, the whole
//   transaction reverts instead of costing the saver.
// - Every transaction is sent with a gas margin (Morpho does more work when a market was last touched in an earlier
//   second, so an exact estimate can run out of gas a block later), and can be stopped by an AbortSignal up to the
//   moment it is sent.
import { ethers } from "ethers";
import { robinhood } from "./robinhood.mjs";

/** Steakhouse USDG (Morpho Vault V2) on Robinhood Chain. */
export const DEFAULT_SAVINGS_VAULT = "0xBeEff033F34C046626B8D0A041844C5d1A5409dd";
/** forceDeallocate's penalty payer: an address with no shares and no allowance, so any non-zero penalty reverts. */
const NO_PENALTY_PAYER = "0x0000000000000000000000000000000000000001";

export const VAULT_ABI = [
  "function asset() view returns (address)",
  "function name() view returns (string)",
  "function balanceOf(address) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
  "function deposit(uint256 assets, address onBehalf) returns (uint256 shares)",
  "function withdraw(uint256 assets, address receiver, address onBehalf) returns (uint256 shares)",
  "function redeem(uint256 shares, address receiver, address onBehalf) returns (uint256 assets)",
  "function forceDeallocate(address adapter, bytes data, uint256 assets, address onBehalf) returns (uint256)",
  "function forceDeallocatePenalty(address adapter) view returns (uint256)",
  "function multicall(bytes[] data)",
  "function adaptersLength() view returns (uint256)",
  "function adapters(uint256) view returns (address)",
  "function liquidityAdapter() view returns (address)",
  "function liquidityData() view returns (bytes)",
  "function canSendAssets(address) view returns (bool)",
  "function canReceiveShares(address) view returns (bool)",
  "error CannotSendAssets()", "error CannotReceiveShares()", "error CannotSendShares()", "error CannotReceiveAssets()",
  "error AbsoluteCapExceeded()", "error RelativeCapExceeded()", "error ZeroAbsoluteCap()",
  "error TransferFromReverted()", "error TransferReverted()", "error PenaltyTooHigh()",
];
const VAULT_IFACE = new ethers.Interface(VAULT_ABI);
const ADAPTER_ABI = [
  "function morpho() view returns (address)",
  "function marketIdsLength() view returns (uint256)",
  "function marketIds(uint256) view returns (bytes32)",
  "function expectedSupplyAssets(bytes32) view returns (uint256)",
];
const MORPHO_ABI = [
  "function idToMarketParams(bytes32) view returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv)",
  "function market(bytes32) view returns (uint128 totalSupplyAssets, uint128 totalSupplyShares, uint128 totalBorrowAssets, uint128 totalBorrowShares, uint128 lastUpdate, uint128 fee)",
];
const ERC20 = [
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];
const MP_T = "tuple(address loanToken, address collateralToken, address oracle, address irm, uint256 lltv)";

export class SavingsError extends Error {
  constructor(code, message, details = {}) { super(message); this.name = "SavingsError"; this.code = code; Object.assign(this, details); }
}

/**
 * A contract revert, as opposed to a node or network failure (which is thrown as is). ethers reports any in-band
 * JSON-RPC error on eth_call as CALL_EXCEPTION, so only one that carries revert data or a node message about a revert
 * counts.
 */
const isRevert = (e) => e?.code === "CALL_EXCEPTION" && (e.data != null || /revert/i.test(String(e.info?.error?.message ?? e.error?.message ?? "")));
const noGas = (e) => /insufficient funds|gas required exceeds|intrinsic gas too low/i.test(String(e?.shortMessage || e?.message || ""));
const fmt = (x) => ethers.formatUnits(x, 6);
const revertName = (e) => e?.revert?.name || (() => { try { return VAULT_IFACE.parseError(e?.data)?.name || ""; } catch (_) { return ""; } })();
function explainVaultRevert(e, what) {
  const name = revertName(e);
  if (name === "CannotSendAssets" || name === "CannotReceiveShares") return new SavingsError("DEPOSITS_CLOSED", `the vault does not take deposits from this wallet right now (${name})`);
  if (/Cap/.test(name)) return new SavingsError("VAULT_FULL", `the vault is at its deposit cap (${name})`);
  if (name === "CannotSendShares" || name === "CannotReceiveAssets") return new SavingsError("EXIT_BLOCKED", `the vault does not let this wallet take money out right now (${name})`);
  return new SavingsError("REVERTED", `${what} would revert${name ? ` (${name})` : ""}`);
}

/**
 * Estimate, then send with a margin (30% + 50k). `o.signal` can stop it up to the moment it is sent; `o.sent` is set
 * once it is. A failure to confirm after sending is UNCONFIRMED (with the hash): the transaction may have landed.
 */
async function send(fn, args, what, o) {
  let est;
  try { est = await fn.estimateGas(...args); } catch (e) {
    if (noGas(e)) throw new SavingsError("NO_GAS", `the wallet has no ETH to pay ${what}'s gas`);
    if (isRevert(e)) throw explainVaultRevert(e, what);
    throw e;
  }
  o?.signal?.throwIfAborted?.();
  if (o) o.sending = true; // from here the transaction may reach the node, whatever happens next
  let tx;
  try { tx = await fn(...args, { gasLimit: (est * 13n) / 10n + 50_000n }); } catch (e) {
    if (noGas(e)) throw new SavingsError("NO_GAS", `the wallet has no ETH to pay ${what}'s gas`);
    // it may have reached the node before the answer was lost: treated as on its way, never as not sent
    throw new SavingsError("UNCONFIRMED", `${what} may have been sent (${e?.shortMessage || e?.message || "no answer"}); check the savings before trying again`);
  }
  if (o) o.sent = tx.hash;
  let rc;
  try { rc = await tx.wait(); } catch (e) {
    if (e?.code === "CALL_EXCEPTION" && e.receipt) throw new SavingsError("REVERTED", `${what} reverted on chain (tx ${tx.hash})`, { hash: tx.hash });
    throw new SavingsError("UNCONFIRMED", `${what} was sent (tx ${tx.hash}) but its confirmation could not be read; check the savings before trying again`, { hash: tx.hash });
  }
  return { hash: tx.hash, receipt: rc };
}

/**
 * The vault and USDG contracts, after checking there is a contract at `vault` and its asset is USDG. Reads and
 * simulations go through the runner's provider. The vault setting is never echoed back unless it is an address.
 */
export async function savingsContracts({ runner, vault = DEFAULT_SAVINGS_VAULT, usdg = robinhood.usdg }) {
  if (!ethers.isAddress(vault)) throw new SavingsError("BAD_VAULT", "the savings vault setting is not a 0x address");
  const provider = runner?.provider || runner;
  const address = ethers.getAddress(vault);
  if ((await provider.getCode(address)) === "0x") throw new SavingsError("BAD_VAULT", `there is no contract at ${address}`);
  const v = new ethers.Contract(address, VAULT_ABI, provider);
  let asset;
  try { asset = await v.asset(); } catch (e) {
    if (isRevert(e)) throw new SavingsError("BAD_VAULT", `${address} does not answer asset(): not an ERC-4626 vault`);
    throw e;
  }
  if (ethers.getAddress(asset) !== ethers.getAddress(usdg)) throw new SavingsError("NOT_USDG", `vault ${address} holds ${asset}, not USDG (${usdg})`);
  return { vault: v, usdg: new ethers.Contract(usdg, ERC20, provider), address, provider };
}

/** Would a plain withdrawal of `amount` to `owner` go through now? A revert is "no"; a node failure is thrown. */
async function canWithdraw(c, owner, amount) {
  if (amount <= 0n) return true;
  try { await c.vault.withdraw.staticCall(amount, owner, owner, { from: owner }); return true; } catch (e) { if (isRevert(e)) return false; throw e; }
}

/** The vault's liquidity market (the one a plain withdrawal pulls from): { adapter, data } or null. */
async function liquidityMarket(c) {
  try {
    const [adapter, raw] = await Promise.all([c.vault.liquidityAdapter(), c.vault.liquidityData()]);
    if (adapter === ethers.ZeroAddress) return null;
    let data = String(raw).toLowerCase();
    // compare markets by their canonical encoding, whatever bytes the allocator wrote
    try { const coder = ethers.AbiCoder.defaultAbiCoder(); data = coder.encode([MP_T], coder.decode([MP_T], raw)).toLowerCase(); } catch (_) { /* not a market's params: kept as is */ }
    return { adapter, data };
  } catch (e) { if (isRevert(e)) return null; throw e; }
}

/**
 * The most of `saved` a plain withdrawal pays `owner` now: idle USDG plus what the liquidity market can pay, confirmed
 * by one simulation; if that fails, a short simulated search (to within 0.1% or 0.01 USDG).
 */
export async function withdrawableNow(c, owner, saved) {
  if (saved <= 0n) return 0n;
  if (await canWithdraw(c, owner, saved)) return saved;
  let hi = saved;
  const lm = await liquidityMarket(c);
  if (lm) {
    try {
      const a = new ethers.Contract(lm.adapter, ADAPTER_ABI, c.provider);
      const m = new ethers.Contract(await a.morpho(), MORPHO_ABI, c.provider);
      const id = ethers.keccak256(lm.data);
      const [idle, supplied, mk] = await Promise.all([c.usdg.balanceOf(c.address), a.expectedSupplyAssets(id), m.market(id)]);
      const free = mk.totalSupplyAssets > mk.totalBorrowAssets ? mk.totalSupplyAssets - mk.totalBorrowAssets : 0n;
      const guess = idle + (supplied < free ? supplied : free);
      if (guess < hi) hi = guess;
      if (hi > 0n && (await canWithdraw(c, owner, hi))) return hi;
    } catch (e) { if (!isRevert(e)) throw e; /* not a Morpho market adapter: search */ }
  }
  let lo = 0n;
  const tol = hi / 1000n > 10_000n ? hi / 1000n : 10_000n;
  for (let i = 0; i < 24 && hi - lo > tol; i++) {
    const mid = (lo + hi) / 2n;
    if (await canWithdraw(c, owner, mid)) lo = mid; else hi = mid;
  }
  return lo;
}

/**
 * The vault's OTHER markets that an in-kind exit can use now (the liquidity market is left out: the plain withdrawal
 * already counts it): each with its adapter, encoded market, what it can pay (the vault's supply there, at most the
 * market's free liquidity) and the adapter's penalty. Only Morpho market adapters.
 */
export async function inKindSources(c) {
  const out = [];
  let n = 0;
  try { n = Number(await c.vault.adaptersLength()); } catch (e) { if (!isRevert(e)) throw e; }
  const lm = await liquidityMarket(c);
  for (let i = 0; i < n; i++) {
    const address = await c.vault.adapters(i);
    const a = new ethers.Contract(address, ADAPTER_ABI, c.provider);
    let m, count;
    try { m = new ethers.Contract(await a.morpho(), MORPHO_ABI, c.provider); count = Number(await a.marketIdsLength()); } catch (e) { if (isRevert(e)) continue; throw e; }
    const penalty = await c.vault.forceDeallocatePenalty(address);
    for (let j = 0; j < count; j++) {
      const id = await a.marketIds(j);
      const [supplied, mk, p] = await Promise.all([a.expectedSupplyAssets(id), m.market(id), m.idToMarketParams(id)]);
      const data = ethers.AbiCoder.defaultAbiCoder().encode([MP_T], [[p.loanToken, p.collateralToken, p.oracle, p.irm, p.lltv]]);
      if (lm && address === lm.adapter && data.toLowerCase() === lm.data) continue;
      const free = mk.totalSupplyAssets > mk.totalBorrowAssets ? mk.totalSupplyAssets - mk.totalBorrowAssets : 0n;
      const available = supplied < free ? supplied : free;
      if (available > 0n) out.push({ adapter: address, data, available, penalty });
    }
  }
  return out.sort((x, y) => (y.available > x.available ? 1 : y.available < x.available ? -1 : 0));
}
const roomOf = (s) => (s.penalty === 0n && s.available > 1n ? s.available - s.available / 100n - 1n : 0n);

/**
 * The calls that move `extra` USDG (plus up to `slack`, best effort) from penalty-free markets into idle, largest
 * first, keeping 1% and 1 unit of each market's figure as margin. `calls` is null when those markets cannot cover
 * `extra`; `room` is what they can cover in all.
 */
async function inKindPlan(c, extra, slack = 0n) {
  const sources = await inKindSources(c);
  const room = sources.reduce((a, s) => a + roomOf(s), 0n);
  const calls = [];
  let left = extra + slack;
  for (const s of sources) {
    if (left <= 0n) break;
    const r = roomOf(s);
    if (r <= 0n) continue;
    const x = left < r ? left : r;
    calls.push(VAULT_IFACE.encodeFunctionData("forceDeallocate", [s.adapter, s.data, x, NO_PENALTY_PAYER]));
    left -= x;
  }
  return { calls: left > slack ? null : calls, room };
}

/** What `owner` has saved; what a plain withdrawal pays now (`withdrawable`); and with in-kind exits too (`reachable`). */
export async function savingsOf(c, owner) {
  const [shares, wallet] = await Promise.all([c.vault.balanceOf(owner), c.usdg.balanceOf(owner)]);
  const saved = shares === 0n ? 0n : await c.vault.previewRedeem(shares);
  const withdrawable = await withdrawableNow(c, owner, saved);
  let reachable = withdrawable;
  if (withdrawable < saved) {
    let extra = 0n;
    for (const s of await inKindSources(c)) extra += roomOf(s);
    reachable = withdrawable + extra < saved ? withdrawable + extra : saved;
  }
  return { owner, vault: c.address, shares, saved, withdrawable, reachable, wallet };
}

/**
 * Put `amount` USDG (base units) from the signer's wallet into the vault. Checks the vault's deposit gates before
 * approving; approves `amount` only when the current allowance is lower (a larger existing allowance is reused, not
 * raised), and puts the allowance back if the deposit is then refused (a cap lowered, for example).
 */
export async function save(c, signer, amount, o) {
  amount = BigInt(amount);
  if (amount <= 0n) throw new SavingsError("ZERO", "amount must be above zero");
  const me = await signer.getAddress();
  const bal = await c.usdg.balanceOf(me);
  if (bal < amount) throw new SavingsError("SHORT", `the wallet holds ${fmt(bal)} USDG, less than ${fmt(amount)}`, { balance: bal });
  try {
    if (!(await c.vault.canSendAssets(me)) || !(await c.vault.canReceiveShares(me))) throw new SavingsError("DEPOSITS_CLOSED", "the vault does not take deposits from this wallet right now (a deposit gate)");
  } catch (e) { if (e instanceof SavingsError) throw e; if (!isRevert(e)) throw e; /* not a Vault V2: the deposit's own estimate decides */ }
  const usdg = c.usdg.connect(signer), vault = c.vault.connect(signer);
  const before = await usdg.allowance(me, c.address);
  let approved = false;
  if (before < amount) { await send(usdg.approve, [c.address, amount], "the approval", o); approved = true; }
  try {
    const r = await send(vault.deposit, [amount, me], "the deposit", o);
    return { hash: r.hash, amount };
  } catch (e) {
    // refused before the deposit was sent (an estimate that reverts has no hash): put the allowance back
    if (approved && e instanceof SavingsError && e.code !== "UNCONFIRMED" && !e.hash) {
      try { await send(usdg.approve, [c.address, before], "the allowance reset"); e.allowanceReset = true; } catch (_) { e.allowanceReset = false; }
    }
    throw e;
  }
}

/**
 * Take money out into the signer's wallet: `amount` USDG, or everything with `all: true`. A plain withdrawal when the
 * vault can pay it; otherwise in-kind (other penalty-free markets into idle, then the withdrawal, in one
 * transaction). Refused before any transaction when neither path can pay (VAULT_ILLIQUID, with `withdrawable` and
 * `reachable`). `o.signal` stops it before it sends anything; `o.sent` is the hash once it has.
 */
export async function unsave(c, signer, { amount, all = false } = {}, o) {
  const me = await signer.getAddress();
  const shares = await c.vault.balanceOf(me);
  const saved = shares === 0n ? 0n : await c.vault.previewRedeem(shares);
  if (saved === 0n) throw new SavingsError("NOTHING_SAVED", "nothing is saved in this vault");
  const vault = c.vault.connect(signer);
  let fn, args, want;
  if (all) { fn = "redeem"; args = [shares, me, me]; want = saved; }
  else {
    amount = BigInt(amount ?? 0);
    if (amount <= 0n) throw new SavingsError("ZERO", "amount must be above zero");
    if (amount > saved) throw new SavingsError("MORE_THAN_SAVED", `${fmt(amount)} USDG is more than the ${fmt(saved)} saved (the vault rounds each deposit down by one base unit)`, { saved });
    fn = "withdraw"; args = [amount, me, me]; want = amount;
  }
  // plain
  let plainOk = true;
  try { await vault[fn].staticCall(...args); } catch (e) {
    if (!isRevert(e)) throw e;
    const x = explainVaultRevert(e, "the withdrawal");
    if (x.code === "EXIT_BLOCKED") throw x;
    plainOk = false;
  }
  if (plainOk) {
    const r = await send(vault[fn], args, "the withdrawal", o);
    return { hash: r.hash, amount: want, inKind: false };
  }
  // in-kind: move what the plain path lacks from the other markets into idle first, in the same transaction. Redeeming
  // every share pays what they are worth when it lands, a little more each second: move a small slack too (it stays
  // in the vault's idle if not needed).
  const plain = await withdrawableNow(c, me, want);
  // Best effort, the plain part is moved in-kind too (free at a 0 penalty), so another saver or borrower using the
  // shared liquidity market in the meantime can't make this exit revert; only `want - plain` is required.
  const plan = await inKindPlan(c, want - plain, (all ? want / 10_000n + 10_000n : 0n) + plain);
  const reachable = plain + plan.room < saved ? plain + plan.room : saved;
  if (plan.calls) {
    const calls = [...plan.calls, vault.interface.encodeFunctionData(fn, args)];
    let ok = true;
    try { await vault.multicall.staticCall(calls); } catch (e) { if (!isRevert(e)) throw e; ok = false; }
    if (ok) {
      const r = await send(vault.multicall, [calls], "the withdrawal", o);
      return { hash: r.hash, amount: want, inKind: true };
    }
  }
  if (reachable >= want) throw new SavingsError("EXIT_FAILED", `the vault's markets looked able to pay ${fmt(want)} USDG but the withdrawal would not go through; try a smaller amount`, { withdrawable: plain, reachable, saved });
  throw new SavingsError("VAULT_ILLIQUID", `the vault can pay out ${fmt(reachable)} USDG to this wallet now (${fmt(plain)} by a plain withdrawal), less than ${fmt(want)}`, { withdrawable: plain, reachable, saved });
}

/**
 * Make sure the signer's wallet holds at least `need` USDG, taking the difference out of savings when it is short:
 * only what is missing (everything, by redeeming every share, when that is all of it), and as much as the vault can
 * pay when it cannot pay all of it. `o.signal` stops it before it sends anything; `o.sent` is the hash once it has.
 * @returns {Promise<{withdrawn: bigint, hash: string|null, short: bigint, saved: bigint, inKind: boolean}>}
 */
export async function topUpFromSavings(c, signer, need, o) {
  need = BigInt(need);
  const me = await signer.getAddress();
  const bal = await c.usdg.balanceOf(me);
  if (bal >= need) return { withdrawn: 0n, hash: null, short: 0n, saved: 0n, inKind: false };
  const missing = need - bal;
  const shares = await c.vault.balanceOf(me);
  const saved = shares === 0n ? 0n : await c.vault.previewRedeem(shares);
  if (saved === 0n) return { withdrawn: 0n, hash: null, short: missing, saved: 0n, inKind: false };
  const nothing = { withdrawn: 0n, hash: null, short: missing, saved, inKind: false };
  // Retry smaller only on refusals made before anything was sent; anything sent (UNCONFIRMED, REVERTED on chain) or
  // a node failure goes back to the caller as is.
  const tryTake = async (opt) => { try { return await unsave(c, signer, opt, o); } catch (e) { if ((e?.code === "VAULT_ILLIQUID" || e?.code === "EXIT_FAILED") && !o?.sent) return e; throw e; } };
  let r = await tryTake(missing >= saved ? { all: true } : { amount: missing });
  const tried = new Set([missing >= saved ? saved : missing]);
  for (const cand of r instanceof SavingsError ? [r.reachable, r.withdrawable] : []) {
    const part = cand > missing ? missing : cand;
    if (!(part > 0n) || tried.has(part)) continue;
    tried.add(part);
    r = await tryTake({ amount: part });
    if (!(r instanceof SavingsError)) break;
  }
  if (r instanceof SavingsError) return nothing;
  return { withdrawn: r.amount, hash: r.hash, short: missing > r.amount ? missing - r.amount : 0n, saved, inKind: r.inKind };
}
