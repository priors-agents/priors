#!/usr/bin/env node
// One command, from an empty machine to an agent with a credit history:
//
//   npm run quickstart
//
// Starts a local chain, deploys the pool, and walks one fresh ERC-8004 identity through the whole record:
// register -> the treasury's $5 first line -> borrow -> hold -> repay -> a score anyone can read.
//
// Everything it does, it does with real transactions against a real EVM. The only thing that is local is the
// chain; the contracts, the accounting and the score are the ones that run in production.
import { spawn } from "node:child_process";
import { ROOT } from "../sdk/env.mjs";
import { devnet } from "./devnet.mjs";

const line = (s = "") => console.log(s);

function cli(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["bin/priors.mjs", ...args], { cwd: ROOT, stdio: "inherit" });
    child.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`priors ${args.join(" ")} exited ${code}`))));
  });
}

line("╭─ priors quickstart ──────────────────────────────────────────────");
line("│  a local chain, the real contracts, and one agent earning credit");
line("╰──────────────────────────────────────────────────────────────────");
line();

await devnet();
await cli(["flow"]);

line();
line("that record is now on the chain. Two things to try next:");
line("  npx priors report <agentId>     every input the score is computed from");
line("  npx priors borrow <agentId> 5 7 again, and watch the line grow as it is earned");
line();
line("to give your own agent this history for real, read skills/priors/SKILL.md — or hand it to your coding");
line("agent and say: give my agent a credit history on Priors.");
