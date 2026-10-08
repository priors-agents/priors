#!/usr/bin/env node
// The v2 CLI refuses a private key anywhere on its command line, glued to other text too (GHSA-w247): a 64-hex run
// that is not part of a longer one, in any argument, as @priors/mcp's looksLikeKey reads it. The refusal comes before
// anything runs (no RPC request), says to rotate the key, and never repeats it. Offline: a throwaway key, a local stub
// RPC that only counts requests.
//   node scripts/test-cli-key-guard.mjs
// PRIORS_CLI=/path/to/cli.mjs runs it against another copy (before/after a fix).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CLI = process.env.PRIORS_CLI || join(ROOT, "bin/priors-v2.mjs");

let passed = 0, failed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log("  ok  ", name); } catch (e) { failed++; console.log("  FAIL", name, "\n       ", e?.stack?.split("\n").slice(0, 4).join("\n        ") || e); }
}

let requests = 0;
const rpc = createServer((req, res) => { requests++; req.resume(); res.writeHead(500).end(); });
await new Promise((ok) => rpc.listen(0, "127.0.0.1", ok));
const RPC = `http://127.0.0.1:${rpc.address().port}`;
const cwd = mkdtempSync(join(tmpdir(), "priors-cli-key-"));

const pasted = ethers.Wallet.createRandom().privateKey; // the key a user pasted on the command line
const K = pasted.slice(2);
const run = (args) => new Promise((ok) => {
  const before = requests;
  const c = spawn(process.execPath, [CLI, ...args], { cwd, env: { PATH: process.env.PATH, HOME: cwd, PRIORS_KEY: ethers.Wallet.createRandom().privateKey, PRIORS_RPC: RPC, PRIORS_ADDRESSES: join(ROOT, "deployments/4663.v2.json") } });
  let out = "";
  c.stdout.on("data", (d) => { out += d; }); c.stderr.on("data", (d) => { out += d; });
  const t = setTimeout(() => c.kill(), 20_000);
  c.on("close", (code) => { clearTimeout(t); ok({ code, out, rpcRequests: requests - before }); });
});
const REFUSED = /a private key was passed on the command line: refused\. Put it in PRIORS_KEY instead \(and rotate it/;

console.log(`${CLI.replace(ROOT + "/", "")}: a private key on the command line (GHSA-w247)`);

const glued = {
  "status PRIORS_KEY=0x<key> (an env assignment typed after the command)": ["status", `PRIORS_KEY=${pasted}`],
  "PRIORS_KEY=0x<key> status": [`PRIORS_KEY=${pasted}`, "status"],
  "join --uri key:0x<key> (it would be registered on chain as the agent's URI)": ["join", "--uri", `key:${pasted}`],
  "join --uri <url>?key=<key, no 0x>": ["join", "--uri", `https://agent.example/card?key=${K}`],
  "join --invite=0x<key>": ["join", `--invite=${pasted}`],
  "one argument \"0x<key> --invite\"": ["join", `${pasted} --invite`],
  "the key alone (as before)": ["join", "--invite", pasted],
};
for (const [name, args] of Object.entries(glued)) {
  await test(`refused before anything runs: ${name}`, async () => {
    const r = await run(args);
    assert.equal(r.code, 2, `exit ${r.code}: ${r.out.slice(0, 200)}`);
    assert.match(r.out, REFUSED);
    assert.ok(!r.out.toLowerCase().includes(K.toLowerCase()), "the key is not repeated");
    assert.equal(r.rpcRequests, 0, "no RPC request");
  });
}

await test("not a key: an invite code (its 65-byte signature), an address, a URL with a short hex id", async () => {
  const sig = "0x" + "ab".repeat(65);
  for (const args of [["join", "--invite", `priors-invite:6574:1791500000:${sig}`], ["join", "--seat", ethers.Wallet.createRandom().address], ["join", "--uri", "https://agent.example/0x1234"]]) {
    const r = await run(args);
    assert.doesNotMatch(r.out, REFUSED, `${args.join(" ")} was refused as a key`);
    assert.ok(r.rpcRequests > 0, `${args.join(" ")} did not get as far as the RPC: ${r.out.slice(0, 200)}`);
  }
});

rpc.close();
console.log(`\ncli key guard: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
