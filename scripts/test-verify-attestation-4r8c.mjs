// GHSA-4r8c-f8q3-4r67 (AT-2, AT-3 in docs/SECURITY-v2.md): the reporter's network-free harness (a JSON-RPC mock and the
// real verifier run as `node scripts/verify-attestation.mjs <agentId> --json`), with his four notes and honest controls.
//   node scripts/test-verify-attestation-4r8c.mjs
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { encodeFile, REPUTATION_REGISTRY, IDENTITY_REGISTRY, ATTESTER, NEW_FEEDBACK, BORROWED, TAG1 } from "../sdk/attestation.mjs";
import DEP from "../deployments/4663.v2.json" with { type: "json" };

const CHAIN = 4663, AGENT = 7634, SCORE = 42;
const BLOCK = 83_100_000, BLOCK_TIME = 1_791_500_400;
const POOL = ethers.getAddress(DEP.pool), V1 = ethers.getAddress(DEP.v1Pool), LENS = ethers.getAddress(DEP.lens);
const OWNER = ethers.getAddress("0x00000000000000000000000000000000000a0001");
const coder = ethers.AbiCoder.defaultAbiCoder();
const sel = (sig) => ethers.id(sig).slice(0, 10);
const SEL = {
  getLastIndex: sel("getLastIndex(uint256,address)"),
  readFeedback: sel("readFeedback(uint256,address,uint64)"),
  getSummary: sel("getSummary(uint256,address[],string,string)"),
  getLoan: sel("getLoan(uint256)"),
  creditReport: sel("creditReport(uint256)"),
};
const LOAN_V1 = "tuple(uint256 agentId,uint256 principal,uint256 fee,uint64 issuedAt,uint64 dueAt,uint64 closedAt,uint8 status,bool isRecourse,uint256 recourseFor)";
const LOAN_V2 = "tuple(uint256 agentId,uint256 sponsorId,uint256 principal,uint256 fee,uint256 sponsorCut,uint256 reserveCut,uint256 premium,address owner,uint64 issuedAt,uint64 dueAt,uint64 defaultableAt,uint64 minScoreTerm,uint64 closedAt,uint8 status)";
const REPORT_TUPLE = "tuple(bool enrolled,bool isRoot,bool defaulted,uint256 sponsor,uint256 capacity,uint256 available,uint256 delegatedIn,uint256 delegatedOut,uint256 earned,uint256 stake,uint256 principalOut,uint256 activeLoans,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint64 enrolledAt,uint256 score,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid)";
const NF = new ethers.Interface([NEW_FEEDBACK]);
const BOR = new ethers.Interface([BORROWED]);
const REPAID_TOPIC = ethers.id("Repaid(uint256,uint256,uint256,uint256,address)");
const hx = (n) => "0x" + Number(n).toString(16);
const txh = (s) => ethers.keccak256(ethers.toUtf8Bytes(s));
const lc = (a) => String(a || "").toLowerCase();

let W;
const reset = ({ block = BLOCK, blockTime = BLOCK_TIME } = {}) => {
  W = { note: null, receipts: new Map(), loans: new Map(), block, blockTime, tag2: null };
};
const makeLoan = (shape, { principal = 5_000_000n, status = 2, lateBy = null } = {}) => {
  const T = W.blockTime;
  const issued = lateBy == null ? T - 3 * 86400 : T - 10 * 86400;
  const due = issued + 7 * 86400;
  const closed = status === 1 ? 0 : (lateBy == null ? T - 60 : due + lateBy);
  return shape === "v1"
    ? [AGENT, principal, 0n, issued, due, closed, status, false, 0n]
    : [AGENT, 6191n, principal, 3800n, 0n, 0n, 0n, OWNER, issued, due, due + 3 * 86400, issued + 7 * 86400, closed, status];
};
const zeroLoan = (shape) => shape === "v1" ? [0n, 0n, 0n, 0n, 0n, 0n, 0, false, 0n] : [0n, 0n, 0n, 0n, 0n, 0n, 0n, ethers.ZeroAddress, 0n, 0n, 0n, 0n, 0n, 0];

function addLog(tx, block, log) {
  const r = W.receipts.get(tx) || {
    transactionHash: tx, transactionIndex: "0x0", blockHash: txh("b" + block), blockNumber: hx(block), from: OWNER, to: log.address,
    cumulativeGasUsed: "0x5208", gasUsed: "0x5208", contractAddress: null, logs: [], logsBloom: "0x" + "00".repeat(256), status: "0x1", type: "0x2", effectiveGasPrice: "0x1",
  };
  r.logs.push({ ...log, blockNumber: hx(block), blockHash: r.blockHash, transactionHash: tx, transactionIndex: "0x0", removed: false, logIndex: hx(r.logs.length) });
  W.receipts.set(tx, r);
}
function repayment(at, loanId, tx, { lateBy = null, status = 2, block = W.block - 10 } = {}) {
  const shape = lc(at) === lc(V1) ? "v1" : "v2";
  W.loans.set(`${lc(at)}:${loanId}`, makeLoan(shape, { lateBy, status }));
  addLog(tx, block, { address: at, topics: [REPAID_TOPIC, ethers.toBeHex(loanId, 32), ethers.toBeHex(AGENT, 32)], data: coder.encode(["uint256", "uint256", "address"], [5_000_000n, 3800n, OWNER]) });
}
function borrow(at, loanId, tx, { status = 2, lateBy = null, block = W.block - 20 } = {}) {
  const shape = lc(at) === lc(V1) ? "v1" : "v2";
  W.loans.set(`${lc(at)}:${loanId}`, makeLoan(shape, { status, lateBy }));
  const e = BOR.encodeEventLog("Borrowed", [loanId, AGENT, 6191, 5_000_000n, 3800n, W.blockTime + 7 * 86400, OWNER]);
  addLog(tx, block, { address: at, topics: e.topics, data: e.data });
}
function post({ pool = POOL, v1Pool, last = [], paid, proofOfPayment, line = { limit: "0", available: "0", drawn: "0" }, backing = { sponsor: 0, delegatedIn: "0" }, defaulted = false, weights = "2.0.1", noteBlock = W.block + 1 }) {
  const TAG2 = (W.tag2 = `rung-2/v${weights}`);
  const priors = {
    v: 2, block: W.block, blockTime: W.blockTime, pool, ...(v1Pool ? { v1Pool } : {}), score: SCORE, rung: 2, weights,
    line, repaid: { onTime: last.length, usdg: String(5 * last.length), late: 0, last }, late: 0, defaults: 0,
    ...(defaulted ? { defaulted: true } : {}), backing, income: { usdg: "0", payers: 0, points: 0 }, ...(paid ? { paid } : {}),
    about: "https://github.com/priors-agents/priors/blob/main/docs/ATTESTATION-v2.md",
  };
  const file = {
    agentRegistry: `eip155:${CHAIN}:${IDENTITY_REGISTRY}`, agentId: AGENT, clientAddress: `eip155:${CHAIN}:${ATTESTER}`,
    createdAt: "2026-10-08T23:00:00Z", value: SCORE, valueDecimals: 0, tag1: TAG1, tag2: TAG2,
    ...(proofOfPayment ? { proofOfPayment } : {}), priors,
  };
  const e = encodeFile(file);
  const ev = NF.encodeEventLog("NewFeedback", [AGENT, ATTESTER, 1n, BigInt(SCORE), 0, TAG1, TAG1, TAG2, "", e.feedbackURI, e.feedbackHash]);
  W.note = { address: REPUTATION_REGISTRY, topics: ev.topics, data: ev.data, blockNumber: hx(noteBlock), blockHash: txh("b" + noteBlock), transactionHash: txh("note"), transactionIndex: "0x0", removed: false, logIndex: "0x0" };
}
function call({ to, data }, blockTag) {
  const t_ = lc(to), s = String(data || "").slice(0, 10);
  if (t_ === lc(REPUTATION_REGISTRY)) {
    if (s === SEL.getLastIndex) return coder.encode(["uint64"], [W.note ? 1n : 0n]);
    if (s === SEL.readFeedback) return coder.encode(["int128", "uint8", "string", "string", "bool"], [BigInt(SCORE), 0n, TAG1, W.tag2, false]);
    if (s === SEL.getSummary) return coder.encode(["uint64", "int128", "uint8"], [1n, BigInt(SCORE), 0n]);
  }
  if (s === SEL.getLoan && (t_ === lc(POOL) || t_ === lc(V1))) {
    const id = coder.decode(["uint256"], "0x" + data.slice(10))[0];
    const known = W.loans.get(`${t_}:${id}`);
    const shape = t_ === lc(V1) ? "v1" : "v2";
    if (!known && shape === "v1") throw Object.assign(new Error("execution reverted"), { data: "0x4e487b71" + "32".padStart(64, "0") });
    return coder.encode([shape === "v1" ? LOAN_V1 : LOAN_V2], [known || zeroLoan(shape)]);
  }
  if (t_ === lc(LENS) && s === SEL.creditReport) {
    const bn = blockTag === "latest" ? BLOCK + 5 : Number(blockTag);
    if (bn < Number(DEP.deployBlock)) return "0x"; // Archive node before DEP.deployBlock: lens contract not deployed yet
    return coder.encode([REPORT_TUPLE], [[true, false, true, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 0n, 1n, 0n, 0n, 0n]]);
  }
  throw new Error("execution reverted");
}
function rpc(method, params) {
  switch (method) {
    case "eth_chainId": return hx(CHAIN);
    case "eth_blockNumber": return hx(BLOCK + 5);
    case "eth_getLogs": return lc(params[0]?.address) === lc(REPUTATION_REGISTRY) && W.note ? [W.note] : [];
    case "eth_getTransactionReceipt": return W.receipts.get(params[0]) || null;
    case "eth_getBlockByNumber": {
      const n = Number(params[0]);
      return { number: hx(n), hash: txh("b" + n), parentHash: txh("b" + (n - 1)), timestamp: hx(W.blockTime + (n - W.block)), nonce: "0x0000000000000000", difficulty: "0x0", gasLimit: "0x1c9c380", gasUsed: "0x0", miner: OWNER, extraData: "0x", transactions: [], baseFeePerGas: "0x1", logsBloom: "0x" + "00".repeat(256), sha3Uncles: txh("u"), stateRoot: txh("s"), receiptsRoot: txh("r"), transactionsRoot: txh("t"), uncles: [], mixHash: txh("m") };
    }
    case "eth_call": return call(params[0] || {}, params[1]);
    default: return null;
  }
}

const server = createServer((req, res) => {
  let body = "";
  req.on("data", (d) => (body += d));
  req.on("end", () => {
    const one = (m) => {
      try { return { jsonrpc: "2.0", id: m.id, result: rpc(m.method, m.params || []) }; }
      catch (e) { return { jsonrpc: "2.0", id: m.id, error: { code: 3, message: e.message, ...(e.data ? { data: e.data } : {}) } }; }
    };
    const q = JSON.parse(body);
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(Array.isArray(q) ? q.map(one) : one(q)));
  });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const URL_ = `http://127.0.0.1:${server.address().port}`;
const verifierPath = fileURLToPath(new URL("./verify-attestation.mjs", import.meta.url));
const verify = (fromBlock = BLOCK - 100) => new Promise((resolvePromise) => execFile(
  process.execPath,
  [verifierPath, String(AGENT), "--rpc", URL_, "--from-block", String(fromBlock), "--json"],
  { timeout: 60_000 },
  (e, stdout) => resolvePromise({ code: e ? e.code : 0, results: JSON.parse(stdout).results })
));


let pass = 0, fail = 0;
const fails = (r) => r.results.filter((x) => x.status === "FAIL").map((x) => `${x.what}${x.detail ? ` (${x.detail})` : ""}`);
const check = (name, cond, r) => { if (cond) { pass++; console.log(`ok - ${name}`); } else { fail++; console.log(`not ok - ${name}\n    exit ${r.code}; FAIL lines: ${JSON.stringify(fails(r))}`); } };
const has = (r, re) => r.results.some((x) => x.status === "FAIL" && re.test(`${x.what} ${x.detail}`));
const HONEST_PP = (tx) => ({ fromAddress: POOL, toAddress: OWNER, chainId: String(CHAIN), txHash: tx });

try {
  // AV-1a: priors.paid names loan 999999 (never issued), no proofOfPayment
  reset();
  post({ paid: { loan: 999999, usdg: "10000" }, defaulted: true });
  let r = await verify();
  check("AV-1a: priors.paid without proofOfPayment, citing a loan never issued, fails", r.code === 1 && has(r, /paid/i), r);

  // AV-1a control: neither paid nor proofOfPayment (an agent with no loan repaid on time) passes
  reset();
  post({ defaulted: true });
  r = await verify();
  check("control: a note with no payment at all passes, as before", r.code === 0, r);

  // AV-1a edge: priors.paid naming a real loan repaid on time, without proofOfPayment (the builder omits proofOfPayment
  // when it could not read the borrow's recipient): true, so it passes
  reset();
  borrow(POOL, 31003, txh("borrow no pp"), { status: 2 });
  post({ paid: { loan: 31003, usdg: "5" }, defaulted: true });
  r = await verify();
  check("control: priors.paid alone, naming the agent's loan repaid on time, passes", r.code === 0, r);

  // AV-1b: proofOfPayment + paid citing a defaulted loan, borrowed after priors.block (the report's case)
  reset();
  borrow(POOL, 31000, txh("borrow defaulted"), { status: 3, block: BLOCK + 2 });
  post({ paid: { loan: 31000, usdg: "5" }, proofOfPayment: HONEST_PP(txh("borrow defaulted")), defaulted: true });
  r = await verify();
  check("AV-1b: a payment whose loan defaulted and was borrowed after priors.block fails", r.code === 1 && has(r, /paid/i), r);

  // AV-1b, each half alone: a defaulted loan borrowed before the block; an active loan; a late repayment; a loan
  // repaid on time but borrowed after the block
  for (const [label, opts] of [["defaulted, borrowed before the block", { status: 3 }], ["still active", { status: 1 }], ["repaid a day late", { status: 2, lateBy: 86400 }], ["repaid on time, borrowed after the block", { status: 2, block: BLOCK + 2 }]]) {
    reset();
    borrow(POOL, 31001, txh("borrow " + label), opts);
    post({ paid: { loan: 31001, usdg: "5" }, proofOfPayment: HONEST_PP(txh("borrow " + label)), defaulted: true });
    r = await verify();
    check(`AV-1b: a payment whose loan is ${label} fails`, r.code === 1, r);
  }

  // AV-1b control: the honest payment (a loan repaid on time, borrowed before the block) passes
  reset();
  borrow(POOL, 31002, txh("borrow honest"), { status: 2 });
  post({ paid: { loan: 31002, usdg: "5" }, proofOfPayment: HONEST_PP(txh("borrow honest")), defaulted: true });
  r = await verify();
  check("control: an honest payment passes", r.code === 0 && r.results.some((x) => x.status === "ok" && /proofOfPayment/.test(x.what)), r);

  // AV-2: one repayment cited five times
  reset();
  repayment(POOL, 21000, txh("repay once"));
  post({ last: Array(5).fill({ loan: 21000, tx: txh("repay once") }), defaulted: true });
  r = await verify();
  check("AV-2: a repayment cited twice fails", r.code === 1 && has(r, /again|twice|once/i), r);

  // AV-2 control: two different repayments pass
  reset();
  repayment(POOL, 21001, txh("repay a"));
  repayment(POOL, 21002, txh("repay b"));
  post({ last: [{ loan: 21001, tx: txh("repay a") }, { loan: 21002, tx: txh("repay b") }], defaulted: true });
  r = await verify();
  check("control: two distinct cited repayments pass", r.code === 0, r);

  // AV-3: priors.block before the v2 deploy block, the lens answering "0x" there (no code), as an archive node does
  const preV2Block = Number(DEP.deployBlock) - 100;
  reset({ block: preV2Block });
  repayment(V1, 42, txh("repay v1 early"), { block: preV2Block - 10 });
  post({ v1Pool: V1, last: [{ loan: 42, era: "v1", tx: txh("repay v1 early") }], line: { limit: "100000", available: "100000", drawn: "0" }, backing: { sponsor: 6191, delegatedIn: "100000" }, defaulted: false, noteBlock: BLOCK + 1 });
  r = await verify(preV2Block - 50);
  check("AV-3: a note whose block is before the v2 deploy block fails", r.code === 1 && has(r, /deploy/i), r);
  const skip = r.results.find((x) => x.status === "skip");
  check("AV-3: the skip no longer says the RPC is not an archive node", !skip || !/not an archive node/.test(skip.detail), r);

  // AV-3 control: the same false line at a v2 block, read by an archive node, fails as before
  reset();
  post({ line: { limit: "100000", available: "100000", drawn: "0" }, backing: { sponsor: 6191, delegatedIn: "100000" }, defaulted: false });
  r = await verify();
  check("control: a false line at a v2 block fails on an archive node, as before", r.code === 1 && has(r, /line\.limit/), r);
} finally {
  server.close();
}
console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
