#!/usr/bin/env node
// The Priors CLI: every step an agent needs to build a credit history, one subcommand each.
//
//   npx priors doctor                 what chain am I on, what is deployed, can I sign
//   npx priors register               mint an ERC-8004 identity              -> agentId
//   npx priors first-line <id>        the treasury vouches $5, by rule
//   npx priors quote <usd> <days>     what a loan would cost
//   npx priors borrow <id> <usd> <d>  -> loanId, USDG in your wallet
//   npx priors repay <loanId>         principal + fee
//   npx priors score <id>             0..1000, straight from the contract
//   npx priors report <id>            every input the score is computed from
//   npx priors loans <id>             this agent's loans
//   npx priors raise <id>             lift the line to $50 once the record qualifies
//   npx priors flow                   all of the above, end to end, on one agent
//
// Dev-chain only (they refuse to run anywhere else):
//   npx priors fund                   mock USDG + gas for your wallet
//   npx priors warp <days>            move chain time forward
import { ethers } from "ethers";
import { resolve, isDevChain, NoDeployment } from "../sdk/env.mjs";

const args = process.argv.slice(2);
const cmd = args[0];
// Split once, by position: a value-carrying flag consumes the token after it, everything else is positional.
// (Matching on value rather than index would mis-parse `borrow 5 5 7`, where the same token appears twice.)
const flags = {};
const positional = [];
for (let i = 1; i < args.length; i++) {
  if (args[i].startsWith("--")) flags[args[i].slice(2)] = args[++i];
  else positional.push(args[i]);
}
const flag = (name) => flags[name];

const out = (...a) => console.log(...a);
// Pinned to en-US on purpose: the default locale turns $0.0116 into $0,0116 on a French machine, and a CLI that
// prints money differently depending on who runs it is a CLI whose output nobody can paste into a bug report.
const usd = (n) => `$${Number(n).toLocaleString("en-US", { maximumFractionDigits: 6 })}`;
const die = (msg) => {
  console.error(msg);
  process.exit(1);
};

const USAGE = `priors — credit history for ERC-8004 agents  ·  https://priors.trade

  priors doctor                      chain, deployment and wallet status
  priors register [--uri <uri>]      mint an ERC-8004 identity -> agentId
  priors first-line <agentId>        the treasury vouches $5 (anyone may call it)
  priors quote <dollars> <days>      fee and whether it counts for the score
  priors borrow <agentId> <dollars> <days> [--to <address>]
  priors repay <loanId>
  priors score <agentId>
  priors report <agentId>
  priors loans <agentId>
  priors raise <agentId>             -> $50 after 3 qualified loans, 14 days, clean
  priors flow [--dollars 5] [--days 7]
                                     the whole history on one fresh agent

  dev chain only:
  priors fund [--dollars 100]        mock USDG + gas for your wallet
  priors warp <days>                 move chain time forward

env: RPC_URL (default http://127.0.0.1:8545), PRIVATE_KEY, POOL, TREASURY, USDC
     addresses otherwise come from deployments/<chainId>.json`;

async function ctx(needSigner = true) {
  try {
    return await resolve({ needSigner });
  } catch (e) {
    if (e instanceof NoDeployment) die(e.message);
    die(e.message);
  }
}

/** Mint mock USDG and top up gas. Refuses on any chain that is not a local dev chain. */
async function fund(c, amount) {
  if (!(await isDevChain(c.provider))) die("`fund` only works on a local dev chain. On a real chain, send your wallet real USDG and gas.");
  if (!c.dep.usdcIsMock) die("this deployment uses a real asset, not the mock. Nothing to mint.");
  await c.provider.send("anvil_setBalance", [c.address, "0x" + ethers.parseEther("100").toString(16)]);
  const mock = new ethers.Contract(c.dep.usdc, ["function mint(address,uint256)"], c.signer);
  await (await mock.mint(c.address, BigInt(Math.round(amount * 1e6)))).wait();
  out(`funded ${c.address} with ${usd(amount)} mock USDG and 100 ETH of gas`);
}

async function warp(c, days) {
  if (!(await isDevChain(c.provider))) die("`warp` only works on a local dev chain. Real chains move at their own pace.");
  await c.provider.send("evm_increaseTime", [Math.round(days * 86400)]);
  await c.provider.send("evm_mine", []);
  out(`chain time +${days}d`);
}

async function main() {
  if (!cmd || cmd === "help" || cmd === "--help" || cmd === "-h") return out(USAGE);

  if (cmd === "doctor") {
    const c = await ctx(false);
    out(`chain            ${c.chainId}  ${c.rpc}`);
    out(`CreditPool       ${c.dep.creditPool}`);
    out(`TreasurySponsor  ${c.dep.treasurySponsor || "(none configured — first-line and raise will not work)"}`);
    out(`asset            ${c.dep.usdc}${c.dep.usdcIsMock ? "  (mock, mintable)" : ""}`);
    out(`registry         ${c.dep.registry || "(read from the pool)"}`);
    out(`wallet           ${c.address || "(none — set PRIVATE_KEY)"}${c.derived ? "  (derived dev wallet, dev chain only)" : ""}`);
    if (c.address) {
      const bal = await c.provider.getBalance(c.address);
      const asset = new ethers.Contract(c.dep.usdc, ["function balanceOf(address) view returns (uint256)"], c.provider);
      out(`balances         ${ethers.formatEther(bal)} native · ${usd(Number(await asset.balanceOf(c.address)) / 1e6)} USDG`);
    }
    const p = await c.priors.pool.getParams();
    out(`params           loans ${usd(Number(p.minLoan) / 1e6)}–${usd(Number(p.maxLoan) / 1e6)} · fee ${Number(p.feeBps) / 100}% per 30d · grace ${Number(p.grace) / 86400}d · qualifies at ${Number(p.minScoreTerm) / 86400}d`);
    return;
  }

  if (cmd === "register") {
    const c = await ctx();
    const id = await c.priors.register(flag("uri") || "");
    out(`agentId ${id}   owner ${c.address}`);
    return;
  }

  if (cmd === "first-line") {
    const id = positional[0] || die("usage: priors first-line <agentId>");
    const c = await ctx();
    if (!c.dep.treasurySponsor) die("no TreasurySponsor configured for this chain, so there is nobody to vouch by rule. Ask a root sponsor to vouch() for you instead.");
    try {
      out(`tx ${await c.priors.firstLine(id)}`);
      const r = await c.priors.report(id);
      out(`agent ${id}: line ${usd(r.capacity)}, sponsor #${r.sponsor}, available ${usd(r.available)}`);
    } catch (e) {
      const m = e.shortMessage || e.message;
      if (/AlreadyLined|AlreadyEnrolled/.test(JSON.stringify(e))) die(`agent ${id} already has a line. \`priors report ${id}\` shows it.`);
      if (/EpochCapReached/.test(JSON.stringify(e))) die("the treasury has spent its vouching cap for this 7-day epoch. Wait for the next epoch, or ask a root sponsor to vouch() for you.");
      die(`firstLine failed: ${m}`);
    }
    return;
  }

  if (cmd === "quote") {
    const [d, days] = positional;
    if (!d || !days) die("usage: priors quote <dollars> <days>");
    const c = await ctx(false);
    const q = await c.priors.quote(Number(d), Number(days));
    out(`fee ${usd(q.fee)}  total due ${usd(q.total)}  ${q.qualifiesForScore ? "counts as a qualified loan" : "too short to count for the score"}`);
    return;
  }

  if (cmd === "borrow") {
    const [id, d, days] = positional;
    if (!id || !d || !days) die("usage: priors borrow <agentId> <dollars> <days>");
    const c = await ctx();
    const loanId = await c.priors.borrow(id, Number(d), Number(days), flag("to"));
    out(`loanId ${loanId}   ${usd(d)} for ${days}d -> ${flag("to") || c.address}`);
    return;
  }

  if (cmd === "repay") {
    const loanId = positional[0] || die("usage: priors repay <loanId>");
    const c = await ctx();
    out(`tx ${await c.priors.repay(loanId)}`);
    return;
  }

  if (cmd === "score") {
    const id = positional[0] || die("usage: priors score <agentId>");
    const c = await ctx(false);
    out(await c.priors.score(id));
    return;
  }

  if (cmd === "report" || cmd === "loans") {
    const id = positional[0] || die(`usage: priors ${cmd} <agentId>`);
    const c = await ctx(false);
    out(JSON.stringify(cmd === "report" ? await c.priors.report(id) : await c.priors.loans(id), null, 2));
    return;
  }

  if (cmd === "raise") {
    const id = positional[0] || die("usage: priors raise <agentId>");
    const c = await ctx();
    if (!(await c.priors.canRaise(id))) die(`agent ${id} does not qualify yet: 3 qualified loans (term >= 7d), 14 days since enrolling, score >= 100, no defaults anywhere below it. \`priors report ${id}\` shows where it stands.`);
    out(`tx ${await c.priors.raise(id)}`);
    return;
  }

  if (cmd === "fund") {
    const c = await ctx();
    return fund(c, Number(flag("dollars") || 100));
  }

  if (cmd === "warp") {
    const days = Number(positional[0] || die("usage: priors warp <days>"));
    const c = await ctx(false);
    return warp(c, days);
  }

  if (cmd === "flow") {
    const amount = Number(flag("dollars") || 5);
    const days = Number(flag("days") || 7);
    const c = await ctx();
    const dev = await isDevChain(c.provider);
    out(`chain ${c.chainId} · pool ${c.dep.creditPool} · wallet ${c.address}`);
    if (dev && c.dep.usdcIsMock) await fund(c, 100);

    out("\n1. identity");
    const id = await c.priors.register("https://priors.trade/agent");
    out(`   ERC-8004 agentId ${id}, owned by ${c.address}`);

    out("\n2. first line");
    out(`   tx ${await c.priors.firstLine(id)}`);
    const r0 = await c.priors.report(id);
    out(`   line ${usd(r0.capacity)} from sponsor #${r0.sponsor} — nobody approved this, it is a rule`);

    out("\n3. borrow, hold, repay");
    const q = await c.priors.quote(amount, days);
    out(`   quote ${usd(amount)} for ${days}d: fee ${usd(q.fee)}${q.qualifiesForScore ? ", qualifies" : ", too short to qualify"}`);
    const loanId = await c.priors.borrow(id, amount, days);
    out(`   loanId ${loanId} — ${usd(amount)} is in ${c.address} now`);
    if (dev) {
      await warp(c, days);
      out("   … did work …");
    } else {
      out(`   … do work, then repay before the due date (grace is 3 days, then anyone can default you) …`);
      out(`   run:  npx priors repay ${loanId}`);
      out(`\nstopped here: on a real chain the loan has to be held for ${days} days before repaying is meaningful.`);
      return;
    }
    out(`   tx ${await c.priors.repay(loanId)}`);

    out("\n4. the record");
    const r = await c.priors.report(id);
    out(`   score ${r.score}/1000 · repaid ${r.loansRepaid} (${r.qualifiedRepaid} qualified) · ${r.dollarDaysRepaid} dollar-days · fees paid ${usd(r.feesPaid)}`);
    out(`   earned capacity ${usd(r.earned)} of its own, line now ${usd(r.capacity)}`);
    out(`\nagent #${id} has a credit history. Check it from anywhere: npx priors report ${id}`);
    if (r.score === 0) die("\nscore came back 0 — that is not a working history. Something above did not take effect.");
    return;
  }

  die(`unknown command: ${cmd}\n\n${USAGE}`);
}

main().catch((e) => die(`\n${e.shortMessage || e.message}`));
