#!/usr/bin/env node
// priors-v2: onboard an agent on Priors v2 (CreditPoolV2, treasury v4, seats v2) and run its line, from a shell.
// The v1 CLI (`priors`, bin/priors.mjs) stays for reading v1 history; the v1 pool is paused.
//
//   priors-v2 join                        register an ERC-8004 identity for this key if it owns none; print its id
//   priors-v2 join --invite <code>        ... then redeem a treasury v4 invite for a first line
//   priors-v2 join --seat <staker>        ... then accept that staker's seat offer on the agent
//   priors-v2 borrow <amount> [--days N]  borrow USDG (default 7 days) to the key's address
//   priors-v2 repay [--all]               repay the oldest open loan, or every open loan
//   priors-v2 status                      identity, sponsor, line, loans, balances
//
// Environment (the key is never read from argv and never printed; .env is loaded like the v1 tools):
//   PRIORS_KEY        the agent owner's private key (PRIVATE_KEY is accepted too)
//   PRIORS_RPC        JSON-RPC endpoint(s), comma-separated failover (else RPC_URL, else Robinhood Chain's official RPC)
//   PRIORS_ADDRESSES  path to a v2 addresses JSON (default: deployments/<chainId>.v2.json in this package)
//   PRIORS_AGENT_ID   which identity to use, when the key owns more than one or it predates the v2 deploy
//
// Exit codes: 0 done, 1 failed, 2 usage or configuration error, 3 registered but waiting on someone else
// (a seat offer that does not exist yet).
import { ethers } from "ethers";
import { fmtUsdg, toUnits } from "../sdk/priors-v2.mjs";
import { resolveV2 } from "../sdk/env.mjs";

const USAGE = `usage:
  priors-v2 join [--invite <code> | --seat <staker>] [--uri <agentURI>]
  priors-v2 borrow <amount> [--days N]
  priors-v2 repay [--all]
  priors-v2 status
env: PRIORS_KEY [, PRIORS_RPC, PRIORS_ADDRESSES, PRIORS_AGENT_ID]
     addresses default to deployments/<chainId>.v2.json; the RPC to Robinhood Chain mainnet`;

class UsageError extends Error {}
class Pending extends Error {}

function parseArgs(argv) {
  const pos = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--all") flags.all = true;
    else if (a === "-h" || a === "--help") flags.help = true;
    else if (a.startsWith("--")) {
      const k = a.slice(2);
      if (!["invite", "seat", "days", "uri", "agent"].includes(k)) throw new UsageError(`unknown option ${a}`);
      if (i + 1 >= argv.length) throw new UsageError(`${a} needs a value`);
      flags[k] = argv[++i];
    } else pos.push(a);
  }
  return { cmd: pos[0], pos: pos.slice(1), flags };
}

// A private key on the command line lands in shell history and `ps`: refuse it outright.
const looksLikeKey = (s) => /^(0x)?[0-9a-fA-F]{64}$/.test(String(s).trim());

async function config() {
  const key = process.env.PRIORS_KEY || process.env.PRIVATE_KEY;
  if (!key || key === "0x") throw new UsageError("PRIORS_KEY is not set (the agent owner's private key, from the environment only)");
  let r;
  try {
    r = await resolveV2({ privateKey: key, needSigner: true });
  } catch (e) {
    if (/not a valid|invalid private key|invalid BytesLike/i.test(String(e.message))) throw new UsageError("PRIORS_KEY is not a valid private key");
    throw new UsageError(e.message);
  }
  for (const k of ["pool", "treasuryV4", "seatVault"]) if (!r.addresses[k]) throw new UsageError(`the v2 addresses have no "${k}"`);
  return { sdk: r.priors, wallet: r.signer, addresses: r.addresses };
}

const usd = (u) => `${fmtUsdg(u)} USDG`;
const when = (t) => new Date(t * 1000).toISOString().replace(".000Z", "Z");

/**
 * The identity this key acts for: PRIORS_AGENT_ID, else the one the invite names if the key owns it, else the one
 * identity it holds that was minted to it since the v2 deploy. null if it holds none.
 */
async function findAgent(sdk, me, addresses, hint) {
  const reg = await sdk._registry();
  const owns = async (id) => (await reg.ownerOf(id).catch(() => ethers.ZeroAddress)).toLowerCase() === me.toLowerCase();
  const env = process.env.PRIORS_AGENT_ID;
  if (env) {
    if (!/^\d+$/.test(env)) throw new UsageError("PRIORS_AGENT_ID must be a decimal id");
    if (!(await owns(env))) throw new Error(`PRIORS_AGENT_ID #${env} is not owned by ${me}`);
    return Number(env);
  }
  if (hint != null && (await owns(hint))) return Number(hint);
  if ((await reg.balanceOf(me)) === 0n) return null;
  // the registry is not enumerable: find mints to this key in the logs since the v2 deploy, then keep what it still owns
  const T = ethers.id("Transfer(address,address,uint256)");
  const latest = await sdk.provider.getBlockNumber();
  const from = Number(addresses.deployBlock || Math.max(0, latest - 50_000));
  const ids = new Set();
  for (let b = from; b <= latest; b += 50_000) {
    const logs = await sdk.provider.getLogs({ address: await reg.getAddress(), topics: [T, null, ethers.zeroPadValue(me, 32)], fromBlock: b, toBlock: Math.min(latest, b + 49_999) });
    for (const l of logs) ids.add(BigInt(l.topics[3]));
  }
  const mine = [];
  for (const id of ids) if (await owns(id)) mine.push(Number(id));
  if (mine.length === 1) return mine[0];
  if (mine.length > 1) throw new UsageError(`this key owns identities ${mine.map((i) => "#" + i).join(", ")}: set PRIORS_AGENT_ID to pick one`);
  throw new UsageError("this key owns an identity minted before the v2 deploy: set PRIORS_AGENT_ID to its id");
}

async function needAgent(sdk, me, addresses) {
  const id = await findAgent(sdk, me, addresses);
  if (id == null) throw new UsageError(`${me} owns no agent identity yet: run \`priors-v2 join\` first`);
  return id;
}

async function printStatus(sdk, id) {
  const s = await sdk.status(id);
  const lines = [
    `agent #${s.agentId}  owner ${s.owner}`,
    `  sponsor   ${s.sponsor ? `#${s.sponsor} (${s.sponsorKind})${s.premiumBps ? `, premium ${s.premiumBps} bps` : ""}` : "none: no line yet"}${s.frozen ? " [frozen]" : ""}${s.defaulted ? " [DEFAULTED]" : ""}`,
    `  line      ${usd(s.line)}  (drawn ${usd(s.principalOut)}, available ${usd(s.available)})`,
    `  record    ${s.loansRepaid} repaid (${s.qualifiedRepaid} qualified), volume ${usd(s.volumeRepaid)}, fees ${usd(s.feesPaid)}`,
  ];
  if (s.seat) lines.push(`  seat      ${s.seat.status}${s.seat.closing ? " (closing)" : ""}, staker ${s.seat.staker}`);
  if (s.openLoans.length === 0) lines.push("  loans     none open");
  for (const l of s.openLoans) lines.push(`  loan #${l.loanId}  ${usd(l.principal)} + fee ${usd(l.fee)} = ${usd(l.due)} due ${when(l.dueAt)}`);
  lines.push(`  wallet    ${usd(s.ownerUsdg)}`);
  console.log(lines.join("\n"));
  return s;
}

async function join(flags) {
  if (flags.invite && flags.seat) throw new UsageError("give --invite or --seat, not both");
  const { sdk, wallet, addresses } = await config();
  const me = wallet.address;
  let hint = null;
  if (flags.invite) {
    const m = /^priors-invite:(\d{1,10}):/.exec(String(flags.invite).trim());
    if (!m) throw new UsageError("not an invite code (expected priors-invite:<agentId>:<expiry>:<signature>)");
    hint = Number(m[1]);
  }
  if (flags.seat && !ethers.isAddress(flags.seat)) throw new UsageError("--seat takes the staker's address");

  let id = await findAgent(sdk, me, addresses, hint);
  if (id == null) {
    id = await sdk.register(flags.uri || `priors:agent:${me.toLowerCase()}`);
    console.log(`registered agent #${id} for ${me}`);
  } else {
    console.log(`using agent #${id} owned by ${me}`);
  }

  const a = await sdk.pool.getAgent(id);
  if (flags.invite) {
    if (hint !== id) throw new Error(`this invite is for agent #${hint}, but this key's agent is #${id}: ask for an invite for #${id}`);
    const r = await sdk.redeemInvite(id, flags.invite);
    console.log(`first line opened by treasury v4 (root #${r.sponsorId}), tx ${r.hash}`);
  } else if (flags.seat) {
    if ((await sdk.vault.offers(id, flags.seat)) === 0n) {
      await printStatus(sdk, id);
      throw new Pending(`no seat offer from ${flags.seat} on agent #${id} yet: ask them to offer on #${id}, then run this again`);
    }
    const r = await sdk.acceptSeat(id, flags.seat);
    console.log(`seat accepted: the seat vault (root #${r.sponsorId}) backs agent #${id}, tx ${r.hash}`);
  } else if (a.sponsor === 0n) {
    console.log(`no line yet. next: \`priors-v2 join --invite <code>\` with an invite for #${id} (ask at https://priors.trade/invite), or \`priors-v2 join --seat <staker>\` once a staker offers on #${id}`);
  }
  await printStatus(sdk, id);
}

async function borrow(pos, flags) {
  if (pos.length !== 1) throw new UsageError("borrow takes one amount, e.g. `priors-v2 borrow 5`");
  const amount = toUnits(pos[0]);
  const days = flags.days == null ? 7 : Number(flags.days);
  if (!Number.isFinite(days) || days <= 0) throw new UsageError("--days must be a positive number");
  const { sdk, wallet, addresses } = await config();
  const id = await needAgent(sdk, wallet.address, addresses);
  const term = BigInt(Math.round(days * 86400));
  const q = await sdk.quoteFee(id, amount, term);
  const r = await sdk.borrow(id, amount, term);
  console.log(`borrowed ${usd(r.principal)} as loan #${r.loanId} for agent #${id}: fee ${usd(r.fee)} (quoted ${usd(q.fee)}), due ${when(r.dueAt)}, tx ${r.hash}`);
  await printStatus(sdk, id);
}

async function repay(flags) {
  const { sdk, wallet, addresses } = await config();
  const id = await needAgent(sdk, wallet.address, addresses);
  const open = (await sdk.openLoans(id)).sort((x, y) => x.dueAt - y.dueAt || x.loanId - y.loanId);
  if (open.length === 0) { console.log(`agent #${id} has no open loan`); return; }
  for (const l of flags.all ? open : open.slice(0, 1)) {
    const r = await sdk.repay(l.loanId);
    console.log(`repaid loan #${l.loanId}: ${usd(r.paid)}, tx ${r.hash}`);
  }
  await printStatus(sdk, id);
}

async function status() {
  const { sdk, wallet, addresses } = await config();
  const id = await findAgent(sdk, wallet.address, addresses);
  if (id == null) { console.log(`${wallet.address} owns no agent identity yet: run \`priors-v2 join\``); return; }
  await printStatus(sdk, id);
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.some(looksLikeKey)) throw new UsageError("a private key was passed on the command line: refused. Put it in PRIORS_KEY instead (and rotate it; it is now in your shell history)");
  const { cmd, pos, flags } = parseArgs(argv);
  if (flags.help || !cmd) { console.log(USAGE); return; }
  if (cmd === "join") return join(flags);
  if (cmd === "borrow") return borrow(pos, flags);
  if (cmd === "repay") return repay(flags);
  if (cmd === "status") return status();
  throw new UsageError(`unknown command "${cmd}"`);
}

// Errors are printed as their message only: an ethers error object carries the request, which carries the RPC URL.
const scrub = (s) => {
  let out = String(s).replace(/(https?|wss?):\/\/\S+/g, "<rpc>");
  const k = (process.env.PRIORS_KEY || process.env.PRIVATE_KEY || "").trim().replace(/^0x/i, "");
  if (k.length >= 32) out = out.split(new RegExp(k, "gi")).join("<key>");
  for (const v of [process.env.PRIORS_RPC, process.env.RPC_URL]) if (v) for (const u of v.split(",")) if (u.trim()) out = out.split(u.trim()).join("<rpc>");
  return out;
};
main().then(
  () => process.exit(0),
  (e) => {
    if (e instanceof UsageError) { console.error(`priors-v2: ${scrub(e.message)}\n\n${USAGE}`); process.exit(2); }
    if (e instanceof Pending) { console.error(`priors-v2: ${scrub(e.message)}`); process.exit(3); }
    console.error(`priors-v2: ${scrub(e.shortMessage || e.message || e)}`);
    process.exit(1);
  }
);
