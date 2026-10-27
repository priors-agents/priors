#!/usr/bin/env node
// `priors-v2 status`, and the status printed after `priors-v2 join`, show the agent's declared payment wallet, read from the
// ERC-8004 registry (getAgentWallet on the addresses file's registry, a read only):
//   - this key: one plain line, "declared: x402 income paid to it counts toward Score v2";
//   - another address: it says so, and that x402 income counts only when paid to that address;
//   - none (a transfer clears it): income does not count until one is declared, and the fix, `priors-mcp link-wallet
//     --agent <id>` (@priors/mcp 0.12.0, packages/mcp/src/link-wallet.mjs);
//   - a registry that cannot answer (no getAgentWallet, a failed request): the wallet line as before, exit 0.
// A `join` that registers declares its caller, as the live registry's register() does, and the
// status after it says this key is declared.
// `priors-v2 borrow`: 14 days unless --days says otherwise, and, before it borrows, a note on stderr when the term is the
// pool's minimum scoring term or less (sdk/priors-v2.mjs termNote, minScoreTerm read from the pool's getParams, never a
// constant; a failed read adds nothing) (priors-agents/priors#16).
// Its term against the backer's own cap: with no --days, 14 days, or the backer's longest term when it lends for less
// (the growth seat vault's maxLoanTerm, read on chain; SeatVaultV5's fixed 10 days), with termNote when that term is the
// pool's minScoreTerm; a --days over the cap is refused before anything is sent (SeatVaultV5's refresh included); a
// --days within it goes through as given.
// Offline: a local JSON-RPC stub plays the pool, the registry, USDG, treasury v4, the seat vaults and SeatVaultV5, and
// applies the writes (register, borrow, V5's refresh; the pool refuses a term over the backer's cap, as
// CreditPoolV2's BorrowBlockedByBacker does); throwaway keys, the CLI run as a user runs it (its own HOME, the key in the
// environment only).
//   node scripts/test-cli-wallet.mjs
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ethers } from "ethers";
import { POOL_V2_ABI, SEAT_VAULT_V2_ABI, TREASURY_V4_ABI } from "../sdk/priors-v2.mjs";
import { SEAT_VAULT_V5_ABI } from "../sdk/float.mjs";

const CLI = new URL("../bin/priors-v2.mjs", import.meta.url).pathname;
const at = (b) => ethers.getAddress("0x" + b.repeat(20)); // stand-ins: no real address is assumed
const POOL = at("a1"), REG = at("8e"), USDG = at("c0"), T4 = at("74"), SEAT = at("5e"), SEAT4 = at("54"), V5 = at("55");
const ADDRESSES = { pool: POOL, registry: REG, usdg: USDG, treasuryV4: T4, seatVault: SEAT };
const AGENT = 6448n, NEW_ID = 9001n, V4_ROOT = 6574n, SEAT_ROOT = 7000n, SEAT4_ROOT = 6466n, V5_ROOT = 8762n, U = 1_000_000n, BLOCK = 90_000_000, NOW = 1_800_000_000, DAY = 86400n;
const ZERO = ethers.ZeroAddress;
const owner = ethers.Wallet.createRandom(), other = ethers.Wallet.createRandom().address;
const poolI = new ethers.Interface(POOL_V2_ABI), t4I = new ethers.Interface(TREASURY_V4_ABI), seatI = new ethers.Interface(SEAT_VAULT_V2_ABI);
const seat4I = new ethers.Interface([...SEAT_VAULT_V2_ABI, "function maxLoanTerm() view returns (uint64)"]), v5I = new ethers.Interface(SEAT_VAULT_V5_ABI);
const regI = new ethers.Interface([
  "function ownerOf(uint256) view returns (address)", "function balanceOf(address) view returns (uint256)",
  "function register(string) returns (uint256)", "function getAgentWallet(uint256) view returns (address)",
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)", "error ERC721NonexistentToken(uint256 tokenId)",
]);
const erc20I = new ethers.Interface(["function balanceOf(address) view returns (uint256)"]);
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
// the pool's agent record (CreditPoolV2 getAgent): #6448 on a 5 USDG line (treasury v4's unless `sponsor` says
// otherwise) with 7 loans repaid; any other id (a new identity) not enrolled, no record
const agentTuple = (id, sponsor = V4_ROOT) => (String(id) === String(AGENT)
  ? [true, false, false, false, false, BigInt(NOW - 30 * 86400), 0n, 0n, sponsor, 5n * U, 0n, 0n, 0n, 0n, 0n, 7n, 50n * U, U, 0n, 0n, 4n, 10n ** 12n]
  : [false, false, false, false, false, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n]);

/**
 * A JSON-RPC stub for agent #6448 owned by `owner`, on treasury v4's 5 USDG line, its owner holding 20 USDG.
 * `declared`: what getAgentWallet answers (an address, ZERO for none), or "revert" (a registry without it) or
 * "rpc-error" (the request fails). `ids`: the identities and their owners. `asked`: every call as "contract.fn".
 * `minScoreTerm`: the pool's getParams figure, or "revert" (a pool that does not answer it). `terms`: every term the pool
 * was asked to quote or borrow for. `sponsor`: the line's root (V4_ROOT treasury v4, SEAT4_ROOT the growth seat vault,
 * V5_ROOT SeatVaultV5). `maxLoanTerm`: the growth seat vault's. The pool's borrow refuses a term over the backer's cap
 * (BorrowBlockedByBacker), as CreditPoolV2 does when the backer's canBorrow is false.
 */
function chain({ declared = owner.address, ids = { [AGENT]: owner.address }, minScoreTerm = 7n * DAY, sponsor = V4_ROOT, maxLoanTerm = 7n * DAY } = {}) {
  const st = { declared: Object.fromEntries(Object.keys(ids).map((id) => [id, declared])), owners: { ...ids }, asked: [], sent: [], receipts: new Map(), nonces: new Map(), terms: [] };
  const cap = sponsor === SEAT4_ROOT ? maxLoanTerm : sponsor === V5_ROOT ? 10n * DAY : null; // treasuries: none of their own
  const q = (n) => ethers.toQuantity(n);
  const H = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
  function exec({ to, data, from }, send) {
    const named = [[POOL, "pool", poolI], [REG, "registry", regI], [USDG, "usdg", erc20I], [T4, "v4", t4I], [SEAT, "seat", seatI], [SEAT4, "seat4", seat4I], [V5, "v5", v5I]].find(([a]) => same(a, to));
    if (!named) return { unknown: `no contract here answers ${to}` };
    const [, c, iface] = named;
    const f = iface.parseTransaction({ data });
    st.asked.push(`${c}.${f.name}`);
    const ok = (vals, logs = []) => ({ result: iface.encodeFunctionResult(f.name, vals), gas: 90_000n, logs, name: `${c}.${f.name}` });
    const x = f.args;
    if (c === "pool") switch (f.name) {
      case "getAgent": return ok([agentTuple(x[0], sponsor)]);
      case "loansOf": return ok([[]]);
      // CreditPoolV2's params: minLoan, maxLoan, minTerm, maxTerm, grace, minScoreTerm, feeBps, sponsorFeeBps,
      // protocolFeeBps, minStake, maxUtilizationBps, keeperBounty
      case "getParams":
        if (minScoreTerm === "revert") return { revert: "0x" };
        return ok([[5n * U, 500n * U, DAY, 30n * DAY, 3n * DAY, minScoreTerm, 100n, 2500n, 1500n, 10n * U, 9000n, 0n]]);
      case "quoteFee": st.terms.push(["quote", x[2]]); return ok([23_333n, 0n, 0n, 0n]);
      case "borrow":
        if (cap != null && x[2] > cap) return { revert: poolI.encodeErrorResult("BorrowBlockedByBacker", [sponsor]) };
        if (send) st.terms.push(["borrow", x[2]]);
        return ok([7n], [{ address: POOL, ...poolI.encodeEventLog("Borrowed", [7n, x[0], sponsor, x[1], 23_333n, BigInt(NOW) + x[2], x[3]]) }]);
      case "registry": return ok([REG]);
      case "usdg": return ok([USDG]);
      // status's available: no default marked on the owner's account (GHSA-qcrq-x8xg-25vg)
      case "ownerDefaults": return ok([0n]);
      case "custodian": return ok([false]);
    }
    if (c === "registry") switch (f.name) {
      case "ownerOf": {
        const o = st.owners[String(x[0])];
        return o ? ok([o]) : { revert: regI.encodeErrorResult("ERC721NonexistentToken", [x[0]]) };
      }
      case "balanceOf": return ok([BigInt(Object.values(st.owners).filter((o) => same(o, x[0])).length)]);
      case "getAgentWallet": {
        const d = st.declared[String(x[0])] ?? ZERO;
        if (d === "revert") return { revert: "0x" };
        if (d === "rpc-error") return { rpcError: true };
        return ok([d]);
      }
      case "register":
        // the live registry (IdentityRegistryUpgradeable 2.0.0): mints to the caller and declares it the agent's wallet
        if (send) { st.owners[String(NEW_ID)] = from; st.declared[String(NEW_ID)] = from; }
        return ok([NEW_ID], [{ address: REG, ...regI.encodeEventLog("Transfer", [ZERO, from || ZERO, NEW_ID]) }]);
    }
    if (c === "usdg") return ok([same(x[0], owner.address) ? 20n * U : 0n]);
    if (c === "v4" && f.name === "agentId") return ok([V4_ROOT]);
    if (c === "seat" && f.name === "agentId") return ok([SEAT_ROOT]);
    if (c === "seat4" && f.name === "agentId") return ok([SEAT4_ROOT]);
    if (c === "seat4" && f.name === "getSeat") return ok([[ZERO, 0n, false, 0, 0n, 0n, 0n, 0n]]);
    if (c === "seat4" && f.name === "maxLoanTerm") return ok([maxLoanTerm]);
    if (c === "v5" && f.name === "refresh") return ok([]);
    if (c === "seat" && f.name === "getSeat") return ok([[ZERO, 0n, false, 0, 0n, 0n, 0n, 0n]]);
    return { unknown: `${c}.${f.name} is not stubbed` };
  }
  const block = () => ({ number: q(BLOCK), hash: H(1), parentHash: H(0), timestamp: q(NOW), nonce: "0x0000000000000000", difficulty: "0x0", gasLimit: q(30_000_000), gasUsed: "0x0", miner: ZERO, extraData: "0x", baseFeePerGas: q(1_000_000_000), transactions: [] });
  function answer(r) {
    const ok = (result) => ({ jsonrpc: "2.0", id: r.id, result });
    const err = (code, message, data) => ({ jsonrpc: "2.0", id: r.id, error: { code, message, ...(data ? { data } : {}) } });
    switch (r.method) {
      case "eth_chainId": return ok("0x1237");
      case "net_version": return ok("4663");
      case "eth_blockNumber": return ok(q(BLOCK));
      case "eth_getBlockByNumber": return ok(block());
      case "eth_gasPrice": case "eth_maxPriorityFeePerGas": return ok(q(1_000_000_000));
      case "eth_getTransactionCount": return ok(q(st.nonces.get(String(r.params[0]).toLowerCase()) || 0));
      case "eth_call": case "eth_estimateGas": {
        const x = exec(r.params[0], false);
        if (x.unknown) return err(-32601, x.unknown);
        if (x.rpcError) return err(-32000, "header not found");
        if (x.revert) return err(3, "execution reverted", x.revert);
        return ok(r.method === "eth_call" ? x.result : q(x.gas));
      }
      case "eth_sendRawTransaction": {
        const tx = ethers.Transaction.from(r.params[0]);
        const x = exec({ to: tx.to, data: tx.data, from: tx.from }, true);
        if (x.unknown || x.revert) return err(3, "execution reverted", x.revert);
        st.sent.push(x.name);
        st.nonces.set(tx.from.toLowerCase(), (st.nonces.get(tx.from.toLowerCase()) || 0) + 1);
        const logs = (x.logs || []).map((l, i) => ({ ...l, blockNumber: q(BLOCK), blockHash: H(1), transactionHash: tx.hash, transactionIndex: "0x0", logIndex: q(i), removed: false }));
        st.receipts.set(tx.hash, { transactionHash: tx.hash, blockHash: H(1), blockNumber: q(BLOCK), transactionIndex: "0x0", from: tx.from, to: tx.to, contractAddress: null, cumulativeGasUsed: q(x.gas), gasUsed: q(x.gas), effectiveGasPrice: q(1_000_000_000), logs, logsBloom: "0x" + "00".repeat(256), status: "0x1", type: "0x2" });
        return ok(tx.hash);
      }
      case "eth_getTransactionReceipt": return ok(st.receipts.get(r.params[0]) || null);
      default: return err(-32601, `unexpected ${r.method}`);
    }
  }
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => { const msg = JSON.parse(body); const out = [].concat(msg).map(answer); res.setHeader("content-type", "application/json"); res.end(JSON.stringify(Array.isArray(msg) ? out : out[0])); });
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok({ st, url: `http://127.0.0.1:${server.address().port}`, close: () => { server.closeAllConnections(); server.close(); } })));
}

const scratch = []; // every directory this test makes, removed at the end
const tempDir = (prefix) => { const d = mkdtempSync(join(tmpdir(), prefix)); scratch.push(d); return d; };
const home = tempDir("priors-cli-wallet-");
const addrFile = join(home, "addresses.json");
writeFileSync(addrFile, JSON.stringify(ADDRESSES));
/** The CLI as a user runs it: its own HOME, the key in the environment only; PRIORS_AGENT_ID unless `agentId` is null.
 *  The stub's addresses are not the published ones, so the shell exports PRIORS_ALLOW_CUSTOM_ADDRESSES=1, as a user
 *  pointing priors-v2 at another deployment would. */
const cli = (args, url, { agentId = AGENT, addresses = addrFile, home: h = home } = {}) => new Promise((done) => {
  const env = { PATH: process.env.PATH, HOME: h, PRIORS_KEY: owner.privateKey, PRIORS_RPC: url, PRIORS_ADDRESSES: addresses, PRIORS_ALLOW_CUSTOM_ADDRESSES: "1", ...(agentId == null ? {} : { PRIORS_AGENT_ID: String(agentId) }) };
  const p = spawn(process.execPath, [CLI, ...args], { env });
  let out = "";
  p.stdout.on("data", (d) => { out += d; }); p.stderr.on("data", (d) => { out += d; });
  const t = setTimeout(() => p.kill(), 60_000);
  p.on("close", (code) => { clearTimeout(t); done({ code, out }); });
});

let passed = 0, failed = 0;
async function check(name, over, fn) {
  const c = await chain(over);
  try { await fn(c); passed++; console.log("  ok  ", name); } catch (e) { failed++; console.log("  FAIL", name, "\n       ", e?.stack?.split("\n").slice(0, 6).join("\n        ") || e); } finally { c.close(); }
}
const noKey = (r) => assert.ok(!r.out.toLowerCase().includes(owner.privateKey.slice(2).toLowerCase()), "the key is not printed");
const walletPart = (r) => r.out.slice(r.out.indexOf("  wallet    "));
const DECLARED = `  wallet    20.0 USDG at ${owner.address} (declared: x402 income paid to it counts toward Score v2)\n`;
const FIX = (id) => `            to declare this key: \`npx -y @priors/mcp@0.12.0 link-wallet --agent ${id}\` (priors-mcp link-wallet) signs with PRIORS_KEY; send the setAgentWallet call it prints from this key, the owner, within 4 minutes\n`;
const NONE = (id) => `  wallet    20.0 USDG at ${owner.address} (no wallet declared, a transfer clears it: x402 income does not count toward Score v2 until one is)\n${FIX(id)}`;

console.log("priors-v2 status: the agent's declared wallet (ERC-8004 getAgentWallet)");

await check("this key declared: one plain line, exit 0, read on the addresses file's registry", {}, async (c) => {
  const r = await cli(["status"], c.url);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, new RegExp(`^agent #6448  owner ${owner.address}\n  sponsor   #6574 \\(treasury v4\\)\n`));
  assert.equal(walletPart(r), DECLARED);
  assert.ok(c.st.asked.includes("registry.getAgentWallet"), "getAgentWallet was read on the registry");
  assert.doesNotMatch(r.out, /link-wallet/);
  assert.deepEqual(c.st.sent, [], "a read only");
  noKey(r);
});

await check("another address declared: it says so, and that income counts only when paid there, exit 0", { declared: other }, async (c) => {
  const r = await cli(["status"], c.url);
  assert.equal(r.code, 0, r.out);
  assert.equal(walletPart(r), `  wallet    20.0 USDG at ${owner.address} (not the declared wallet, which is ${ethers.getAddress(other)}: x402 income counts toward Score v2 only when paid to that address)\n`);
  assert.doesNotMatch(r.out, /link-wallet/);
  noKey(r);
});

await check("none declared (after a transfer): income does not count until one is, and the fix (priors-mcp link-wallet), exit 0", { declared: ZERO }, async (c) => {
  const r = await cli(["status"], c.url);
  assert.equal(r.code, 0, r.out);
  assert.equal(walletPart(r), NONE(6448));
  noKey(r);
});

for (const [what, declared] of [["a registry without getAgentWallet (it reverts)", "revert"], ["a failed request", "rpc-error"]]) {
  await check(`${what}: nothing extra, the wallet line as before, exit 0`, { declared }, async (c) => {
    const r = await cli(["status"], c.url);
    assert.equal(r.code, 0, r.out);
    assert.ok(c.st.asked.includes("registry.getAgentWallet"), "it was asked");
    assert.equal(walletPart(r), "  wallet    20.0 USDG\n");
    assert.doesNotMatch(r.out, /declared|link-wallet/);
  });
}

await check("`priors-v2 join` that registers: the registry declares its caller, and the status after it says this key is declared, exit 0", { ids: {} }, async (c) => {
  const r = await cli(["join"], c.url, { agentId: null });
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(c.st.sent, ["registry.register"]);
  assert.match(r.out, new RegExp(`^registered agent #9001 for ${owner.address}\nno line yet\\. next: `));
  assert.match(r.out, new RegExp(`agent #9001  owner ${owner.address}\n  sponsor   none: no line yet\n`));
  assert.equal(walletPart(r), DECLARED);
  noKey(r);
});

await check("`priors-v2 join` on an identity whose wallet was cleared: the status after it gives the fix, exit 0", { declared: ZERO }, async (c) => {
  const r = await cli(["join"], c.url);
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(c.st.sent, []);
  assert.match(r.out, new RegExp(`^using agent #6448 owned by ${owner.address}\n`));
  assert.equal(walletPart(r), NONE(6448));
  noKey(r);
});

console.log("priors-v2 borrow: 14 days by default, and the note on a term of the pool's minimum scoring term or less");
// the addresses of a deployment with the growth seat vault and SeatVaultV5, as deployments/4663.v2.json names them
const FULL = { ...ADDRESSES, seatVaultV4: SEAT4, seatVaultV5: V5, seatVaultV5AgentId: Number(V5_ROOT) };
/** A fresh HOME (its own record of transactions) and its own addresses file: FULL unless `addresses` says otherwise. */
const fresh = (addresses = FULL) => {
  const h = tempDir("priors-cli-borrow-"), f = join(h, "addresses.json");
  writeFileSync(f, JSON.stringify(addresses));
  return { home: h, addresses: f };
};
// every term the pool was asked for, once each (the CLI quotes, then the SDK quotes again for its maxFee)
const termsOf = (c) => [...new Set(c.st.terms.map(([k, t]) => `${k} ${Number(t) / 86400}d`))];
const NOTE = /priors-v2: note: a [\d.]+-day loan/;
const CAPPED = /backer lends for at most/;

await check("no --days on a treasury line (no cap of its own, the capped vaults in the addresses): 14 days, past the pool's minimum scoring term (7 days); no note; the loan is borrowed, exit 0", {}, async (c) => {
  const r = await cli(["borrow", "5"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 14d", "borrow 14d"]);
  assert.deepEqual(c.st.sent, ["pool.borrow"]);
  assert.match(r.out, /borrowed 5\.0 USDG as loan #7 for agent #6448/);
  assert.doesNotMatch(r.out, CAPPED);
  assert.doesNotMatch(r.out, NOTE);
  noKey(r);
});

await check("--days 7, the pool's minimum scoring term: the note says it counts only when repaid at or after its due time (from 2.0.3, 24 hours more), then it borrows for 7 days", {}, async (c) => {
  const r = await cli(["borrow", "5", "--days", "7"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 7d", "borrow 7d"]);
  assert.match(r.out, /priors-v2: note: a 7-day loan counts toward the record only when repaid at or after its due time, which is when Score v2 starts counting a repayment as late \(from weights 2\.0\.3, 2026-11-02, after 24 hours more\)\. A 14-day term leaves 7 days to repay on time\.\n/);
  assert.ok(r.out.indexOf("note:") < r.out.indexOf("borrowed "), "said before it borrows");
  assert.ok(c.st.asked.includes("pool.getParams"), "the term is read from the pool's params");
});

await check("--days 3, under it: the note says the loan never counts, then it borrows as asked", {}, async (c) => {
  const r = await cli(["borrow", "5", "--days", "3"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 3d", "borrow 3d"]);
  assert.match(r.out, /priors-v2: note: a 3-day loan never counts toward the agent's record: the pool counts a repayment once the loan is held 7 days\. A 14-day term does\.\n/);
});

await check("the note follows the pool's minScoreTerm, not a constant: at 10 days, --days 10 gets it and --days 14 does not", { minScoreTerm: 10n * DAY }, async (c) => {
  const a = await cli(["borrow", "5", "--days", "10"], c.url, fresh());
  assert.equal(a.code, 0, a.out);
  assert.match(a.out, /note: a 10-day loan counts toward the record only when repaid at or after its due time.*A 20-day term leaves 10 days to repay on time\./);
  const b = await cli(["borrow", "5", "--days", "14"], c.url, fresh());
  assert.equal(b.code, 0, b.out);
  assert.doesNotMatch(b.out, NOTE);
});

await check("a pool whose params cannot be read: no note, and the borrow goes ahead as asked", { minScoreTerm: "revert" }, async (c) => {
  const r = await cli(["borrow", "5", "--days", "7"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.ok(c.st.asked.includes("pool.getParams"), "it was asked");
  assert.deepEqual(termsOf(c), ["quote 7d", "borrow 7d"]);
  assert.doesNotMatch(r.out, /note:/);
});

console.log("priors-v2 borrow: the term against the backer's own cap (the backer's longest when it lends for less than 14 days)");

await check("a growth seat line (maxLoanTerm 7 days, read on chain), no --days: 7 days, saying why, with termNote (7 days is the pool's minScoreTerm); borrowed, exit 0", { sponsor: SEAT4_ROOT }, async (c) => {
  const r = await cli(["borrow", "5"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 7d", "borrow 7d"]);
  assert.deepEqual(c.st.sent, ["pool.borrow"]);
  assert.ok(c.st.asked.includes("seat4.maxLoanTerm"), "the cap is read from the vault");
  assert.match(r.out, /priors-v2: note: agent #6448's backer lends for at most 7 days: borrowing for 7 days \(the default is 14 days; --days sets the term\)\n/);
  assert.match(r.out, /priors-v2: note: a 7-day loan counts toward the record only when repaid at or after its due time/);
  assert.ok(r.out.indexOf("note:") < r.out.indexOf("borrowed "), "said before it borrows");
});

await check("the growth seat vault's cap is its own on-chain figure: at 5 days, no --days borrows for 5 days, with termNote (under minScoreTerm)", { sponsor: SEAT4_ROOT, maxLoanTerm: 5n * DAY }, async (c) => {
  const r = await cli(["borrow", "5"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 5d", "borrow 5d"]);
  assert.match(r.out, /backer lends for at most 5 days: borrowing for 5 days/);
  assert.match(r.out, /priors-v2: note: a 5-day loan never counts toward the agent's record/);
});

await check("a SeatVaultV5 line (10 days at most, a constant), no --days: 10 days, saying why; no termNote (10 days is over minScoreTerm); V5's refresh, then the borrow", { sponsor: V5_ROOT }, async (c) => {
  const r = await cli(["borrow", "5"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 10d", "borrow 10d"]);
  assert.deepEqual(c.st.sent, ["v5.refresh", "pool.borrow"]);
  assert.match(r.out, /priors-v2: note: agent #6448's backer lends for at most 10 days: borrowing for 10 days/);
  assert.doesNotMatch(r.out, NOTE);
});

for (const [line, sponsor, days, cap] of [["SeatVaultV5", V5_ROOT, "12", "10 days"], ["growth seat", SEAT4_ROOT, "8", "7 days"]]) {
  await check(`a ${line} line, --days ${days} over its cap: refused up front with the cap, nothing sent (no V5 refresh either), exit 1`, { sponsor }, async (c) => {
    const r = await cli(["borrow", "5", "--days", days], c.url, fresh());
    assert.equal(r.code, 1, r.out);
    assert.deepEqual(c.st.sent, [], "no transaction at all");
    assert.ok(!c.st.asked.includes("v5.refresh"), "V5's refresh is not even simulated");
    assert.deepEqual(termsOf(c), [], "nor quoted");
    assert.match(r.out, new RegExp(`priors-v2: agent #6448's backer lends for at most ${cap}: --days ${days} is longer, so it would refuse the loan \\(BorrowBlockedByBacker\\); nothing was sent\\. Borrow for ${cap.replace(" days", "")} days or less`));
    assert.doesNotMatch(r.out, /borrowed /);
    noKey(r);
  });
}

await check("a SeatVaultV5 line, --days 8 within its cap: as given, no cap note, no termNote; V5's refresh, then the borrow", { sponsor: V5_ROOT }, async (c) => {
  const r = await cli(["borrow", "5", "--days", "8"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 8d", "borrow 8d"]);
  assert.deepEqual(c.st.sent, ["v5.refresh", "pool.borrow"]);
  assert.doesNotMatch(r.out, CAPPED);
  assert.doesNotMatch(r.out, NOTE);
});

await check("a treasury line, --days 30: as given (the pool's own maxTerm decides), no cap note", {}, async (c) => {
  const r = await cli(["borrow", "5", "--days", "30"], c.url, fresh());
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(termsOf(c), ["quote 30d", "borrow 30d"]);
  assert.doesNotMatch(r.out, CAPPED);
});

for (const d of scratch) rmSync(d, { recursive: true, force: true });
console.log(`\ncli wallet: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
