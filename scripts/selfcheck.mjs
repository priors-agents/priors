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
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
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

/* `check` only handles synchronous bodies: a promise-returning fn resolves after the try block has already
   printed "ok", so a failing async assertion would be reported as passing. The SDK checks below are async,
   hence this. */
async function checkAsync(name, fn) {
  try {
    await fn();
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
check("forge test is fully green, and the lender-loss regression is still in it and still passing", () => {
  // This check used to assert 64 passed / 1 failed, because the lender-loss defect was open and its regression
  // was deliberately retained as a failing test. The exposure accounting is fixed now, so the assertion inverts:
  // the suite must be green, AND the test that proved the bug must still exist and pass. Deleting the regression
  // would otherwise turn a real guarantee back into an untested claim while the suite stayed reassuringly green.
  // On CI the full suite is the `contracts` job's (`forge test -vvv`, no time limit): running all of it again here,
  // from a cold compile on a small runner, outgrew any sane timeout once the suite passed 500 tests (every CI run
  // from 2026-09-23 failed on `spawnSync forge ETIMEDOUT`). There, this check keeps what only it asserts: the named
  // regression and the DefaultAccounting suite below. Locally it still runs the whole suite first.
  const T = 1_200_000; // a cold compile of the via-IR pool alone takes minutes on a CI runner
  if (!process.env.CI) {
    const r = sh("forge", ["test"], { timeout: T });
    if (r.error) throw new Error(`could not run forge: ${r.error.message} (is Foundry installed?)`);
    const summary = /(\d+) tests passed, (\d+) failed, (\d+) skipped \((\d+) total tests\)/.exec(r.stdout);
    if (!summary) {
      // No summary usually means the suite never ran — a compile error, which forge reports on stderr. Showing only
      // stdout here would print an empty diagnostic and send the reader hunting for a phantom test-count problem.
      const detail = (r.stdout.slice(-600) + r.stderr.slice(-900)).trim();
      throw new Error(`forge produced no test summary, so the suite did not run (compile error?):\n${detail || "(no output)"}`);
    }
    const [, passed, failed] = summary;
    eq(failed, "0", "failing tests");
    if (Number(passed) < 74) throw new Error(`expected at least the 74 tests this repo documents, got ${passed}`);
  }

  // The regression must still be present and green. `forge test` prints only failures by default, so ask for it
  // by name: a green run tells you nothing about a test that no longer exists.
  const named = sh("forge", ["test", "--match-test", "test_multipleDefaultsKeepLendersWholeWithoutEarnedExposure", "-v"], { timeout: T });
  if (!/1 passed|\[PASS\]/.test(named.stdout)) {
    throw new Error(`the lender-loss regression is missing or not passing. Do not delete it: it is the test that proved the defect this protocol had.\n${named.stdout.slice(-400)}`);
  }
  // Same for the coverage added alongside the fix: partial defaults, repay-after-default, multiple children,
  // sub-sponsor recourse, dead sponsor, root defaults, reserve lock.
  const suite = sh("forge", ["test", "--match-contract", "DefaultAccounting"], { timeout: T });
  const suiteSummary = /(\d+) tests passed, (\d+) failed/.exec(suite.stdout);
  if (!suiteSummary || suiteSummary[2] !== "0" || Number(suiteSummary[1]) < 5) {
    throw new Error(`the DefaultAccounting suite is missing or not green:\n${suite.stdout.slice(-400)}`);
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

check("--history catches a credential that was committed and then deleted", () => {
  // The history scan once used its own shorter pattern list, so an OpenAI or AWS key committed and later removed
  // passed clean while staying permanently retrievable from a public repo.
  //
  // Asserted by execution, not by reading the script: a source-text check on this exact bug passed while the
  // behaviour was still broken. Runs in a throwaway repo so the real one is never committed to.
  const dir = mkdtempSync(join(tmpdir(), "priors-history-"));
  const git = (...a) => spawnSync("git", a, { cwd: dir, encoding: "utf8" });
  try {
    spawnSync("mkdir", ["-p", join(dir, "scripts"), join(dir, "docs")]);
    writeFileSync(join(dir, "scripts", "check-public.sh"), readFileSync(join(ROOT, "scripts", "check-public.sh"), "utf8"));
    git("init", "-q", "-b", "main");
    git("config", "user.email", "selfcheck@example.invalid");
    git("config", "user.name", "selfcheck");
    git("add", "-A");
    git("commit", "-q", "-m", "base");
    // One per credential class that a shorter history pattern list would have missed.
    //
    // Assembled from fragments on purpose: written out whole, these fixtures are themselves credential-shaped, so
    // check-public.sh would flag this very file and the guard would be unusable on its own repo. (It does exactly
    // that if you inline them — which is a fair demonstration that the scanner works.)
    const fixtures = [
      ["aws", "AKIA" + "IOSFODNN7EXAMPLE"],
      ["openai", "sk-" + "proj-" + "A1b2C3d4".repeat(5)],
    ];
    for (const [name, secret] of fixtures) {
      // git removes a directory once its last tracked file goes, so recreate it each round.
      spawnSync("mkdir", ["-p", join(dir, "docs")]);
      writeFileSync(join(dir, "docs", `leak-${name}.txt`), `leaked=${secret}\n`);
      git("add", "-f", `docs/leak-${name}.txt`);
      git("commit", "-q", "-m", `oops ${name}`);
      git("rm", "-q", `docs/leak-${name}.txt`);
      git("commit", "-q", "-m", `remove ${name}`);
    }
    const r = spawnSync("bash", ["scripts/check-public.sh", "--history"], { cwd: dir, encoding: "utf8" });
    if (r.status === 0) throw new Error(`--history exited 0 with credentials in history:\n${r.stdout}`);
    if (!/historical blob/.test(r.stdout)) {
      // Something else failed it (e.g. the inventory rule), which would hide a broken history scan.
      throw new Error(`--history failed, but not on the historical blobs:\n${r.stdout}`);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

console.log("configuration");
check(".env is actually loaded, not just documented", () => {
  // Every doc says `cp .env.example .env` and put RPC_URL there. Nothing read it until sdk/env.mjs did, so the
  // documented real-chain path silently talked to localhost. Run in a temp cwd so the repo's own .env is not used.
  const dir = mkdtempSync(join(tmpdir(), "priors-dotenv-"));
  try {
    writeFileSync(join(dir, ".env"), "# comment\nRPC_URL=http://127.0.0.1:9911\n");
    const r = spawnSync(process.execPath, [join(ROOT, "bin", "priors.mjs"), "doctor"], {
      cwd: dir,
      encoding: "utf8",
      // Strip an inherited RPC_URL so this proves the file was read, not the environment.
      env: Object.fromEntries(Object.entries(process.env).filter(([k]) => k !== "RPC_URL")),
    });
    const output = r.stdout + r.stderr;
    if (!/127\.0\.0\.1:9911/.test(output)) throw new Error(`doctor ignored the .env RPC_URL:\n${output}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
check("an exported variable still beats the .env file", () => {
  const dir = mkdtempSync(join(tmpdir(), "priors-dotenv-"));
  try {
    writeFileSync(join(dir, ".env"), "RPC_URL=http://127.0.0.1:9911\n");
    const r = spawnSync(process.execPath, [join(ROOT, "bin", "priors.mjs"), "doctor"], {
      cwd: dir,
      encoding: "utf8",
      env: { ...process.env, RPC_URL: "http://127.0.0.1:9922" },
    });
    const output = r.stdout + r.stderr;
    if (!/127\.0\.0\.1:9922/.test(output)) throw new Error(`the .env file overrode an explicit environment variable:\n${output}`);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
check("the .env.example placeholder key is treated as unset", () => {
  // `PRIVATE_KEY=0x` copied and left unfilled must read as "no key yet", not reach ethers as a malformed one.
  const dir = mkdtempSync(join(tmpdir(), "priors-dotenv-"));
  try {
    writeFileSync(join(dir, ".env"), "PRIVATE_KEY=0x\nRPC_URL=http://127.0.0.1:9911\n");
    const r = spawnSync(process.execPath, [join(ROOT, "bin", "priors.mjs"), "doctor"], { cwd: dir, encoding: "utf8", env: Object.fromEntries(Object.entries(process.env).filter(([k]) => k !== "PRIVATE_KEY" && k !== "RPC_URL")) });
    const output = r.stdout + r.stderr;
    if (/invalid BytesLike|invalid private key|value=/.test(output)) throw new Error(`the placeholder key reached ethers:\n${output}`);
  } finally {
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
  // Start from nothing. An interrupted earlier run can leave a chain on this port whose deployed contracts
  // predate the ones in the working tree, and `devnet` would reuse it — so the suite would test yesterday's
  // bytecode and say so in no way at all. Clearing both here makes the check independent of how it last ended.
  sh("pkill", ["-f", `anvil --silent --port ${new URL(RPC).port}`]);
  rmSync(join(ROOT, "deployments", "31337.json"), { force: true });
  try {
    check("a fresh agent reaches a repaid loan and a non-zero score", () => {
      // Generous timeouts: the first run after a contract change pays for a full solc compile inside devnet.
      const dev = sh(process.execPath, ["scripts/devnet.mjs"], { env, timeout: 600_000 });
      if (dev.status !== 0) throw new Error(`devnet failed (exit ${dev.status}${dev.signal ? `, signal ${dev.signal}` : ""}):\n${dev.stdout}${dev.stderr}`);
      const flow = sh(process.execPath, ["bin/priors.mjs", "flow"], { env, timeout: 600_000 });
      if (flow.status !== 0) throw new Error(`flow failed (exit ${flow.status}${flow.signal ? `, signal ${flow.signal} — timed out?` : ""}):\n${flow.stdout}${flow.stderr}`);
      const score = /score (\d+)\/1000/.exec(flow.stdout);
      if (!score) throw new Error(`no score in flow output:\n${flow.stdout}`);
      if (Number(score[1]) <= 0) throw new Error(`score came back ${score[1]}; a repaid loan must score above zero`);
      if (!/loanId \d+/.test(flow.stdout)) throw new Error("flow never reported a loanId");
    });
    await checkAsync("the SDK quotes a fee the contract agrees with, rather than re-deriving it", async () => {
      const { ethers } = await import("ethers");
      const { Priors } = await import("../sdk/priors.mjs");
      const dep = JSON.parse(readFileSync(join(ROOT, "deployments", "31337.json"), "utf8"));
      const s = new Priors({ rpc: RPC, pool: dep.creditPool, treasury: dep.treasurySponsor });
      const pool = new ethers.Contract(dep.creditPool, ["function quoteFee(uint256,uint64) view returns (uint256)"], s.provider);
      // A spread of sizes and terms, including ones where integer division truncates.
      for (const [dollars, days] of [[5, 7], [11, 3], [1, 1], [7, 13], [99, 17]]) {
        const q = await s.quote(dollars, days);
        const onChain = await pool.quoteFee(BigInt(Math.round(dollars * 1e6)), BigInt(days * 86400));
        eq(Math.round(q.fee * 1e6), Number(onChain), `fee for $${dollars} over ${days}d`);
      }
    });

    await checkAsync("a reverting call names the rule it broke, instead of a bare selector", async () => {
      const { Priors } = await import("../sdk/priors.mjs");
      const dep = JSON.parse(readFileSync(join(ROOT, "deployments", "31337.json"), "utf8"));
      const { ethers } = await import("ethers");
      // Any funded dev wallet: repay() has no controller gate, so this needs no identity and no balance.
      const signer = ethers.HDNodeWallet.fromPhrase("test test test test test test test test test test test junk");
      const s = new Priors({ rpc: RPC, pool: dep.creditPool, treasury: dep.treasurySponsor, signer });
      // Loan 0 is the constructor's sentinel: it exists, so this is LoanNotActive rather than a panic.
      let msg = "";
      try {
        await s.repay(0);
        throw new Error("repay(0) was expected to revert and did not");
      } catch (e) {
        msg = e.message;
      }
      if (/^0x[0-9a-f]{8}/i.test(msg.trim())) throw new Error(`error surfaced as a raw selector: ${msg}`);
      if (!/LoanNotActive/.test(msg)) throw new Error(`expected the decoded custom error, got: ${msg}`);
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
