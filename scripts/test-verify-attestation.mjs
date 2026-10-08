// scripts/verify-attestation.mjs against a small in-process JSON-RPC mock, network-free: the verifier runs as the
// documented command (`node scripts/verify-attestation.mjs <agentId> --json`) and reads one note, its cited
// repayments and its payment from the mock. What it checks: a cited repayment and the payment are read from the pools of
// deployments/4663.v2.json, never from a contract the note names (GHSA-m5wj-mgcg-x3fv: a note's own priors.v1Pool was
// the contract its v1 citations were checked against, so the attester's key, leaked, could make a fabricated history
// pass). The chain side, against a fork of the real registry, is scripts/test-attest-fork.mjs.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { ethers } from "ethers";
import { encodeFile, REPUTATION_REGISTRY, IDENTITY_REGISTRY, ATTESTER, NEW_FEEDBACK, BORROWED, TAG1 } from "../sdk/attestation.mjs";
import DEP from "../deployments/4663.v2.json" with { type: "json" };

let passed = 0;
const failed = [];
const t = async (name, fn) => {
  try { await fn(); passed++; console.log(`ok - ${name}`); } catch (e) { failed.push(name); console.log(`not ok - ${name}\n  ${String(e?.message || e).slice(0, 3000).split("\n").join("\n  ")}`); }
};

const CHAIN = 4663, AGENT = 7634, SCORE = 42, TAG2 = "rung-2/v2.0.1";
const BLOCK = 83_100_000, BLOCK_TIME = 1_791_500_400;
const POOL = ethers.getAddress(DEP.pool), V1 = ethers.getAddress(DEP.v1Pool);
const FAKE_V1 = ethers.getAddress("0x00000000000000000000000000000000deaf00f1"); // a contract the note's author deployed
const FAKE_V2 = ethers.getAddress("0x00000000000000000000000000000000deaf00f2");
const OWNER = ethers.getAddress("0x00000000000000000000000000000000000a0001");
const coder = ethers.AbiCoder.defaultAbiCoder();
const sel = (sig) => ethers.id(sig).slice(0, 10);
const SEL = { getLastIndex: sel("getLastIndex(uint256,address)"), readFeedback: sel("readFeedback(uint256,address,uint64)"), getSummary: sel("getSummary(uint256,address[],string,string)"), getLoan: sel("getLoan(uint256)") };
const LOAN_V1 = "tuple(uint256 agentId,uint256 principal,uint256 fee,uint64 issuedAt,uint64 dueAt,uint64 closedAt,uint8 status,bool isRecourse,uint256 recourseFor)";
const LOAN_V2 = "tuple(uint256 agentId,uint256 sponsorId,uint256 principal,uint256 fee,uint256 sponsorCut,uint256 reserveCut,uint256 premium,address owner,uint64 issuedAt,uint64 dueAt,uint64 defaultableAt,uint64 minScoreTerm,uint64 closedAt,uint8 status)";
const NF = new ethers.Interface([NEW_FEEDBACK]);
const BOR = new ethers.Interface([BORROWED]);
const REPAID_TOPIC = ethers.id("Repaid(uint256,uint256,uint256,uint256,address)");
const hx = (n) => "0x" + Number(n).toString(16);
const txh = (s) => ethers.keccak256(ethers.toUtf8Bytes(s));
const lc = (a) => String(a || "").toLowerCase();

// ---- the mock chain: one note, the receipts it cites, and getLoan at the contracts it knows (shape by contract) ----
const SHAPE = { [lc(POOL)]: "v2", [lc(FAKE_V2)]: "v2", [lc(V1)]: "v1", [lc(FAKE_V1)]: "v1" };
let W;
const reset = () => { W = { note: null, receipts: new Map(), loans: new Map() }; };

const repaidOnTime = (shape, principal = 5_000_000n) => {
  const issued = BLOCK_TIME - 3 * 86400, due = issued + 7 * 86400, closed = BLOCK_TIME - 60;
  return shape === "v1"
    ? [AGENT, principal, 0n, issued, due, closed, 2, false, 0n]
    : [AGENT, 6191n, principal, 3800n, 0n, 0n, 0n, OWNER, issued, due, due + 3 * 86400, issued + 7 * 86400, closed, 2];
};
const zeroLoan = (shape) => shape === "v1" ? [0n, 0n, 0n, 0n, 0n, 0n, 0, false, 0n] : [0n, 0n, 0n, 0n, 0n, 0n, 0n, ethers.ZeroAddress, 0n, 0n, 0n, 0n, 0n, 0];
/** A loan the contract at `at` answers for getLoan, repaid on time by AGENT, with its Repaid log in transaction `tx`. */
function repayment(at, loanId, tx) {
  W.loans.set(`${lc(at)}:${loanId}`, repaidOnTime(SHAPE[lc(at)]));
  addLog(tx, BLOCK - 10, { address: at, topics: [REPAID_TOPIC, ethers.toBeHex(loanId, 32), ethers.toBeHex(AGENT, 32)], data: coder.encode(["uint256", "uint256", "address"], [5_000_000n, 3800n, OWNER]) });
}
/** The contract at `at` paying loan `loanId` to OWNER in transaction `tx` (a Borrowed log). */
function borrow(at, loanId, tx) {
  const e = BOR.encodeEventLog("Borrowed", [loanId, AGENT, 6191, 5_000_000n, 3800n, BLOCK_TIME + 7 * 86400, OWNER]);
  addLog(tx, BLOCK - 20, { address: at, topics: e.topics, data: e.data });
}
function addLog(tx, block, log) {
  const r = W.receipts.get(tx) || { transactionHash: tx, transactionIndex: "0x0", blockHash: txh("b" + block), blockNumber: hx(block), from: OWNER, to: log.address,
    cumulativeGasUsed: "0x5208", gasUsed: "0x5208", contractAddress: null, logs: [], logsBloom: "0x" + "00".repeat(256), status: "0x1", type: "0x2", effectiveGasPrice: "0x1" };
  r.logs.push({ ...log, blockNumber: hx(block), blockHash: r.blockHash, transactionHash: tx, transactionIndex: "0x0", removed: false, logIndex: hx(r.logs.length) });
  W.receipts.set(tx, r);
}

/** The note's file, in the shape of docs/ATTESTATION-v2.md (sdk/attestation.mjs attestationFile), and its NewFeedback log. */
function post({ pool = POOL, v1Pool, last, pay }) {
  const priors = { v: 2, block: BLOCK, blockTime: BLOCK_TIME, pool, ...(v1Pool ? { v1Pool } : {}), score: SCORE, rung: 2, weights: "2.0.1",
    line: { limit: "0", available: "0", drawn: "0" }, repaid: { onTime: last.length, usdg: String(5 * last.length), late: 0, last }, late: 0, defaults: 0,
    backing: { sponsor: 0, delegatedIn: "0" }, income: { usdg: "0", payers: 0, points: 0 }, ...(pay ? { paid: { loan: pay.loan, usdg: "5" } } : {}),
    about: "https://github.com/priors-agents/priors/blob/main/docs/ATTESTATION-v2.md" };
  const file = { agentRegistry: `eip155:${CHAIN}:${IDENTITY_REGISTRY}`, agentId: AGENT, clientAddress: `eip155:${CHAIN}:${ATTESTER}`, createdAt: "2026-10-08T23:00:00Z",
    value: SCORE, valueDecimals: 0, tag1: TAG1, tag2: TAG2,
    ...(pay ? { proofOfPayment: { fromAddress: pay.from, toAddress: OWNER, chainId: String(CHAIN), txHash: pay.tx } } : {}), priors };
  const e = encodeFile(file);
  const ev = NF.encodeEventLog("NewFeedback", [AGENT, ATTESTER, 1n, BigInt(SCORE), 0, TAG1, TAG1, TAG2, "", e.feedbackURI, e.feedbackHash]);
  W.note = { address: REPUTATION_REGISTRY, topics: ev.topics, data: ev.data, blockNumber: hx(BLOCK + 1), blockHash: txh("b" + (BLOCK + 1)), transactionHash: txh("note"), transactionIndex: "0x0", removed: false, logIndex: "0x0" };
}

function call({ to, data }) {
  const t_ = lc(to), s = String(data || "").slice(0, 10);
  if (t_ === lc(REPUTATION_REGISTRY)) {
    if (s === SEL.getLastIndex) return coder.encode(["uint64"], [W.note ? 1n : 0n]);
    if (s === SEL.readFeedback) return coder.encode(["int128", "uint8", "string", "string", "bool"], [BigInt(SCORE), 0n, TAG1, TAG2, false]);
    if (s === SEL.getSummary) return coder.encode(["uint64", "int128", "uint8"], [1n, BigInt(SCORE), 0n]);
  }
  if (s === SEL.getLoan && SHAPE[t_]) {
    const id = coder.decode(["uint256"], "0x" + data.slice(10))[0];
    const known = W.loans.get(`${t_}:${id}`);
    // as on chain: the v1 pool keeps its loans in an array, so an id it never issued reverts (Panic 0x32); v2 answers an
    // empty loan
    if (!known && t_ === lc(V1)) throw Object.assign(new Error("execution reverted"), { data: "0x4e487b71" + "32".padStart(64, "0") });
    return coder.encode([SHAPE[t_] === "v1" ? LOAN_V1 : LOAN_V2], [known || zeroLoan(SHAPE[t_])]);
  }
  throw new Error("execution reverted"); // the lens at an old block: the verifier says it could not check (skip)
}
function rpc(method, params) {
  switch (method) {
    case "eth_chainId": return hx(CHAIN);
    case "eth_blockNumber": return hx(BLOCK + 5);
    case "eth_getLogs": return lc(params[0]?.address) === lc(REPUTATION_REGISTRY) && W.note ? [W.note] : [];
    case "eth_getTransactionReceipt": return W.receipts.get(params[0]) || null;
    case "eth_getBlockByNumber": { const n = Number(params[0]); return { number: hx(n), hash: txh("b" + n), parentHash: txh("b" + (n - 1)), timestamp: hx(BLOCK_TIME + (n - BLOCK)), nonce: "0x0000000000000000", difficulty: "0x0", gasLimit: "0x1c9c380", gasUsed: "0x0", miner: OWNER, extraData: "0x", transactions: [], baseFeePerGas: "0x1", logsBloom: "0x" + "00".repeat(256), sha3Uncles: txh("u"), stateRoot: txh("s"), receiptsRoot: txh("r"), transactionsRoot: txh("t"), uncles: [], mixHash: txh("m") }; }
    case "eth_call": return call(params[0] || {});
    default: return null;
  }
}
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const one = (m) => { try { return { jsonrpc: "2.0", id: m.id, result: rpc(m.method, m.params || []) }; } catch (e) { return { jsonrpc: "2.0", id: m.id, error: { code: 3, message: e.message, ...(e.data ? { data: e.data } : {}) } }; } };
    const q = JSON.parse(body);
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(Array.isArray(q) ? q.map(one) : one(q)));
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const URL_ = `http://127.0.0.1:${server.address().port}`;

/** The documented command, --json: { code, results: [{ status, what, detail }] }. */
const verify = () => new Promise((resolve) => execFile(process.execPath,
  [new URL("./verify-attestation.mjs", import.meta.url).pathname, String(AGENT), "--rpc", URL_, "--from-block", String(BLOCK - 100), "--json"],
  { timeout: 60_000 }, (e, stdout, stderr) => {
    let results = null;
    try { results = JSON.parse(stdout).results; } catch (_) { /* the verifier threw: reported below */ }
    resolve({ code: e ? e.code : 0, results, raw: `${stdout}${stderr}` });
  }));
const line = (r, re) => r.results?.find((x) => re.test(x.what));
const show = (r) => (r.results || []).map((x) => `${x.status} ${x.what}${x.detail ? ` (${x.detail})` : ""}`).join("\n") || r.raw;

try {
  await t("an honest note passes: a v2 and a v1 repayment and the payment, each read from the record's pools", async () => {
    reset();
    repayment(POOL, 21000, txh("repay v2")); repayment(V1, 42, txh("repay v1")); borrow(POOL, 21000, txh("borrow v2"));
    post({ v1Pool: V1, last: [{ loan: 21000, tx: txh("repay v2") }, { loan: 42, era: "v1", tx: txh("repay v1") }], pay: { loan: 21000, from: POOL, tx: txh("borrow v2") } });
    const r = await verify();
    assert.equal(r.code, 0, show(r));
    assert.deepEqual(r.results.filter((x) => x.status === "FAIL"), []);
    for (const re of [/^loan 21000 repaid on time/, /^v1 loan 42 repaid on time/, /^proofOfPayment/]) assert.equal(line(r, re)?.status, "ok", `${re}\n${show(r)}`);
  });

  await t("a note that names its own v1 pool fails: its v1 citations are read from the record's v1 pool (GHSA-m5wj)", async () => {
    reset();
    repayment(FAKE_V1, 9001, txh("fabricated")); // the author's contract: a Repaid log and a getLoan answer, no funds
    post({ v1Pool: FAKE_V1, last: [{ loan: 9001, era: "v1", tx: txh("fabricated") }] });
    const r = await verify();
    assert.equal(r.code, 1, `a note naming its own v1 pool exits ${r.code}:\n${show(r)}`);
    assert.ok(r.results, `the verifier answers with its checks, not a crash (the v1 pool reverts for loan 9001):\n${r.raw}`);
    assert.equal(line(r, /^priors\.v1Pool is the v1 pool of deployments\/4663\.v2\.json/)?.status, "FAIL", show(r));
    assert.equal(line(r, /^v1 loan 9001 repaid on time/)?.status, "FAIL", `the fabricated citation is not read from the record's v1 pool:\n${show(r)}`);
    // the reporter's control: the same fabrication, the note naming the real v1 pool, fails too
    post({ v1Pool: V1, last: [{ loan: 9001, era: "v1", tx: txh("fabricated") }] });
    const c = await verify();
    assert.equal(c.code, 1, show(c));
    assert.ok(c.results, c.raw);
    assert.equal(line(c, /^v1 loan 9001 repaid on time/)?.status, "FAIL", show(c));
  });

  await t("a note that names another credit pool fails on every line it cites: repayments and payment are read from the record's pool", async () => {
    reset();
    repayment(FAKE_V2, 777, txh("fabricated v2")); borrow(FAKE_V2, 777, txh("fabricated borrow"));
    post({ pool: FAKE_V2, last: [{ loan: 777, tx: txh("fabricated v2") }], pay: { loan: 777, from: FAKE_V2, tx: txh("fabricated borrow") } });
    const r = await verify();
    assert.equal(r.code, 1, show(r));
    assert.equal(line(r, /^priors\.pool is the credit pool of deployments/)?.status, "FAIL", show(r));
    assert.equal(line(r, /^loan 777 repaid on time/)?.status, "FAIL", `a citation read from the pool the note names:\n${show(r)}`);
    assert.equal(line(r, /^proofOfPayment/)?.status, "FAIL", `a payment from the pool the note names:\n${show(r)}`);
  });
} finally {
  server.close();
}

console.log(`\n${passed} passed${failed.length ? `, ${failed.length} failed: ${failed.join("; ")}` : ""}`);
process.exit(failed.length ? 1 : 0);
