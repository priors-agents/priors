#!/usr/bin/env node
// Regression checks for the parts of this repo that are not Solidity.
//
//   npm run selfcheck        (also runs as part of `npm test`)
//
// `forge test` covers the contracts. Nothing covered the CLI, the unit conversions, or the publish guard — and
// those are exactly the pieces a stranger hits first and a maintainer breaks silently. Each check below asserts a
// behaviour the README or the skill promises, and fails loudly.
//
// The end-to-end check needs Foundry and starts a throwaway anvil on port 8547 so it cannot collide with a devnet
// you are already using. Skip it with `--no-chain` if Foundry is not installed.
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ROOT, toUnits, fromUnits, formatUsd } from "../sdk/env.mjs";

const RPC = "http://127.0.0.1:8547";
const skipChain = process.argv.includes("--no-chain");
let failures = 0;

function check(name, fn) {
  try {
    fn();
    console.log(`  ok   ${name}`);
  } catch (e) {
    console.log(`  FAIL ${name}\n         ${e.message}`);
    failures++;
  }
}

const eq = (actual, expected, what) => {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
};

const sh = (cmd, args, opts = {}) => spawnSync(cmd, args, { cwd: ROOT, encoding: "utf8", ...opts });

console.log("money helpers");
check("whole dollars round-trip through 6-decimal units", () => {
  eq(toUnits(5), 5_000_000n, "toUnits(5)");
  eq(toUnits(0.011666), 11_666n, "toUnits(0.011666)");
  eq(fromUnits(11_666n), 0.011666, "fromUnits(11666)");
});
check("sub-cent amounts are not rounded away in display", () => {
  // The fee on the README's own example loan. A default toLocaleString drops this to $0.012.
  eq(formatUsd(0.011666), "$0.011666", "formatUsd(0.011666)");
});
check("money formatting does not follow the machine locale", () => {
  // Pinned to en-US: on a fr-FR machine an unpinned formatter prints $20 000 and $0,011666.
  const before = process.env.LC_ALL;
  process.env.LC_ALL = "fr_FR.UTF-8";
  try {
    eq(formatUsd(20000), "$20,000", "formatUsd(20000) under fr_FR");
  } finally {
    if (before === undefined) delete process.env.LC_ALL;
    else process.env.LC_ALL = before;
  }
});

console.log("contract suite");
check("forge test is exactly 64 passed / 1 failed, and the failure is the retained lender-loss regression", () => {
  // The README, AGENTS.md and the skill all state this count, and the whole disclosure rests on that one test
  // still failing for its documented reason. So: a new failure breaks this check, and so does anyone "fixing" the
  // suite green by skipping or weakening the regression. If the exposure accounting is genuinely corrected, this
  // check is what tells you to update the disclosure — deliberately, not silently.
  const r = sh("forge", ["test"], { timeout: 600_000 });
  if (r.error) throw new Error(`could not run forge: ${r.error.message} (is Foundry installed?)`);
  const summary = /(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)/.exec(r.stdout);
  if (!summary) {
    // No summary usually means the suite never ran — a compile error, which forge reports on stderr. Showing only
    // stdout here would print an empty diagnostic and send the reader hunting for a phantom test-count problem.
    const detail = (r.stdout.slice(-600) + r.stderr.slice(-900)).trim();
    throw new Error(`forge produced no test summary, so the suite did not run (compile error?):\n${detail || "(no output)"}`);
  }
  const [, passed, failed, , total] = summary;
  eq(total, "65", "total tests");
  eq(passed, "64", "passing tests");
  eq(failed, "1", "failing tests (the retained regression)");
  if (!/test_multipleDefaultsKeepLendersWholeWithoutEarnedExposure/.test(r.stdout)) {
    throw new Error("the one failing test is not the documented lender-loss regression. Do not weaken or skip that test; see the Status section of the README.");
  }
  if (!/must not cost lenders principal/.test(r.stdout)) {
    throw new Error("the regression failed, but not on its documented assertion");
  }
});

console.log("publish guard");
check("check-public.sh passes on the real tree", () => {
  const r = sh("bash", ["scripts/check-public.sh"]);
  if (r.status !== 0) throw new Error(`exit ${r.status}:\n${r.stdout}`);
});
check("check-public.sh fails on a planted private key", () => {
  // Inside docs/ on purpose: a top-level file would be caught by the inventory rule, which would hide whether the
  // credential shape rule still matches anything. A guard that silently stops matching still exits 0.
  const planted = join(ROOT, "docs", "selfcheck-planted.md");
  writeFileSync(planted, `PRIVATE_KEY=0x${"7".repeat(64)}\n`);
  try {
    sh("git", ["add", "-f", "docs/selfcheck-planted.md"]);
    const r = sh("bash", ["scripts/check-public.sh"]);
    if (r.status === 0) throw new Error("guard exited 0 with a private key staged in docs/");
    if (!/assigned EVM private key/.test(r.stdout)) throw new Error(`guard failed, but not for the key:\n${r.stdout}`);
  } finally {
    sh("git", ["rm", "-q", "--cached", "--", "docs/selfcheck-planted.md"]);
    rmSync(planted, { force: true });
  }
});
check("check-public.sh fails on tracked agent working state", () => {
  const dir = join(ROOT, "docs", "builds");
  const planted = join(dir, "selfcheck-planted.md");
  sh("mkdir", ["-p", dir]);
  writeFileSync(planted, "# not for publication\n");
  try {
    sh("git", ["add", "-f", "docs/builds/selfcheck-planted.md"]);
    const r = sh("bash", ["scripts/check-public.sh"]);
    if (r.status === 0) throw new Error("guard exited 0 with docs/builds tracked");
    if (!/docs\/builds/.test(r.stdout)) throw new Error(`guard failed, but not for docs/builds:\n${r.stdout}`);
  } finally {
    sh("git", ["rm", "-q", "--cached", "--", "docs/builds/selfcheck-planted.md"]);
    rmSync(dir, { recursive: true, force: true });
  }
});

console.log("CLI");
check("refuses a chain it cannot reach instead of guessing", () => {
  const r = sh(process.execPath, ["bin/priors.mjs", "doctor"], { env: { ...process.env, RPC_URL: "http://127.0.0.1:9" } });
  if (r.status === 0) throw new Error("doctor exited 0 with no chain listening");
  if (!/cannot reach/.test(r.stderr + r.stdout)) throw new Error(`wrong failure:\n${r.stderr}${r.stdout}`);
});
check("rejects an unknown subcommand", () => {
  const r = sh(process.execPath, ["bin/priors.mjs", "definitely-not-a-command"]);
  if (r.status === 0) throw new Error("exited 0 on an unknown command");
});
check("parses repeated positional values correctly", () => {
  // `borrow 5 5 7` is the case a value-matching parser gets wrong. Reaching the chain error proves the three
  // positionals were read, since a parse failure would print usage instead.
  const r = sh(process.execPath, ["bin/priors.mjs", "borrow", "5", "5", "7"], { env: { ...process.env, RPC_URL: "http://127.0.0.1:9" } });
  const output = r.stderr + r.stdout;
  if (/usage: priors borrow/.test(output)) throw new Error("parsed `borrow 5 5 7` as missing an argument");
  if (!/cannot reach/.test(output)) throw new Error(`expected to get as far as the chain:\n${output}`);
});

if (!skipChain) {
  console.log("end to end (throwaway chain on 8547)");
  const env = { ...process.env, RPC_URL: RPC };
  const tmpHome = mkdtempSync(join(tmpdir(), "priors-selfcheck-"));
  try {
    check("a fresh agent reaches a repaid loan and a non-zero score", () => {
      const dev = sh(process.execPath, ["scripts/devnet.mjs"], { env, timeout: 180_000 });
      if (dev.status !== 0) throw new Error(`devnet failed:\n${dev.stdout}${dev.stderr}`);
      const flow = sh(process.execPath, ["bin/priors.mjs", "flow"], { env, timeout: 180_000 });
      if (flow.status !== 0) throw new Error(`flow failed:\n${flow.stdout}${flow.stderr}`);
      const score = /score (\d+)\/1000/.exec(flow.stdout);
      if (!score) throw new Error(`no score in flow output:\n${flow.stdout}`);
      if (Number(score[1]) <= 0) throw new Error(`score came back ${score[1]}; a repaid loan must score above zero`);
      if (!/loanId \d+/.test(flow.stdout)) throw new Error("flow never reported a loanId");
    });
    check("dev-only commands refuse a chain that is not a dev chain", () => {
      // Point warp at a real chain: it must refuse on the cheat-method probe, not on a transaction.
      const r = sh(process.execPath, ["bin/priors.mjs", "warp", "1"], {
        env: { ...process.env, RPC_URL: "https://rpc.mainnet.chain.robinhood.com", POOL: "0x0000000000000000000000000000000000000001" },
        timeout: 60_000,
      });
      if (r.status === 0) throw new Error("warp exited 0 against a real chain");
      if (!/only works on a local dev chain/.test(r.stderr + r.stdout)) throw new Error(`refused for the wrong reason:\n${r.stderr}${r.stdout}`);
    });
  } finally {
    // Only ever kill the chain this script started, on its own port, never a devnet the user is using.
    sh("pkill", ["-f", "anvil --silent --port 8547"]);
    rmSync(tmpHome, { recursive: true, force: true });
    rmSync(join(ROOT, "deployments", "31337.json"), { force: true });
  }
} else {
  console.log("end to end: skipped (--no-chain)");
}

console.log("");
if (failures) {
  console.log(`${failures} check(s) failed`);
  process.exit(1);
}
console.log("selfcheck: all good");
