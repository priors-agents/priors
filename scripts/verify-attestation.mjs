// Verify a Priors note on the ERC-8004 reputation registry (attestation v2, docs/ATTESTATION-v2.md) from the chain
// alone: no Priors server is asked anything.
//
//   node scripts/verify-attestation.mjs <agentId> [--attester 0x…] [--rpc URL] [--from-block N] [--window N] [--json]
//
// It reads the attester's latest entry for the agent (getLastIndex, readFeedback), finds its NewFeedback event, decodes
// the file the feedbackURI carries, and checks:
//   - feedbackHash = keccak256(file bytes), and the file's spec fields (agentRegistry, agentId, clientAddress, value,
//     valueDecimals, tag1, tag2) match the entry on chain; getSummary(agentId, [attester], "priors-score", "") is the
//     file's score;
//   - priors.blockTime is the timestamp of priors.block;
//   - priors.pool and priors.v1Pool are the pools of deployments/4663.v2.json; whatever the file names, every
//     repayment and the payment below are read from those two, never from an address in the file;
//   - each cited repayment (priors.repaid.last): the transaction succeeded before priors.block and carries the pool's
//     Repaid log (the v1 pool's for an "era": "v1" loan) for that loan and agent; the loan (getLoan, today's state, which
//     cannot change once repaid) is the agent's, repaid, and closed by its due date;
//   - proofOfPayment: the borrow transaction carries the pool's Borrowed log for priors.paid.loan, from the pool to
//     toAddress, for priors.paid.usdg;
//   - the line and backing at priors.block (lens creditReport with blockTag = that block: capacity = line.limit,
//     principalOut = line.drawn, available >= line.available (a stock line is capped lower by its vault), sponsor and
//     delegatedIn = backing, defaulted), when the RPC serves state at that block (an archive node; the public endpoint
//     keeps only recent state, so pass --rpc or set RPC_URL to an archive endpoint for an older note).
// What it does not re-derive: the score itself (it needs the x402 income index and every agent's loans; the inputs are
// public and sdk/score-v2.mjs is the engine), and the totals priors.repaid.onTime /
// usdg / late / defaults (counted over the agent's whole history, v1 included; it shows the lens' own figures beside
// them). Exit code 0 when nothing failed, 1 on any failure, 2 when the entry carries no v2 file.
import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { decodeFeedbackURI, usdg, REPUTATION_REGISTRY, IDENTITY_REGISTRY, CHAIN_ID, ATTESTER as PUBLISHED, TAG1, REGISTRY_ABI, NEW_FEEDBACK, BORROWED } from "../sdk/attestation.mjs";

const args = process.argv.slice(2);
const opt = (f) => { const i = args.indexOf(f); return i < 0 ? null : args.splice(i, 2)[1]; };
const flag = (f) => { const i = args.indexOf(f); if (i < 0) return false; args.splice(i, 1); return true; };
const asJson = flag("--json");
const rpcArg = opt("--rpc");
const attesterArg = opt("--attester");
const fromBlockArg = opt("--from-block");
const WINDOW = Number(opt("--window") || 100_000); // the public endpoint answers getLogs over 100k blocks, not 500k
const agentId = Number(args[0]);
if (!(agentId > 0)) { console.error("usage: node scripts/verify-attestation.mjs <agentId> [--attester 0x…] [--rpc URL] [--from-block N] [--window N] [--json]"); process.exit(64); }

const ATTESTER = ethers.getAddress(attesterArg || PUBLISHED);
const DEP = JSON.parse(readFileSync(new URL("../deployments/4663.v2.json", import.meta.url), "utf8"));
const REG_DEPLOY = Number(fromBlockArg || DEP.deployBlock || 0); // no Priors note predates pool v2

// An endpoint URL can carry a token: it is never printed, only where it came from (and the host of a public one).
const src = rpcArg ? { url: rpcArg, source: "--rpc" } : process.env.RPC_URL ? { url: process.env.RPC_URL, source: "RPC_URL" } : { url: "https://rpc.mainnet.chain.robinhood.com", source: "public endpoint" };
const describe = (r) => { let host = "?"; try { host = new URL(r.url.split(",")[0]).host; } catch (_) { /* leave it */ } return `${r.source} (${/(^|\.)chain\.robinhood\.com$/.test(host) ? host : "private host"})`; };
const provider = new ethers.JsonRpcProvider(src.url.split(",")[0], CHAIN_ID, { staticNetwork: true, batchMaxCount: 1 });

const LENS_ABI = ["function creditReport(uint256) view returns (tuple(bool enrolled,bool isRoot,bool defaulted,uint256 sponsor,uint256 capacity,uint256 available,uint256 delegatedIn,uint256 delegatedOut,uint256 earned,uint256 stake,uint256 principalOut,uint256 activeLoans,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint64 enrolledAt,uint256 score,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid))"];
const POOL_ABI = [
  "function getLoan(uint256) view returns (tuple(uint256 agentId,uint256 sponsorId,uint256 principal,uint256 fee,uint256 sponsorCut,uint256 reserveCut,uint256 premium,address owner,uint64 issuedAt,uint64 dueAt,uint64 defaultableAt,uint64 minScoreTerm,uint64 closedAt,uint8 status))",
  "event Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer)",
  BORROWED,
];
const V1_POOL_ABI = [
  "function getLoan(uint256) view returns (tuple(uint256 agentId,uint256 principal,uint256 fee,uint64 issuedAt,uint64 dueAt,uint64 closedAt,uint8 status,bool isRecourse,uint256 recourseFor))",
  "event Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer)",
];
const REPAID = 2; // LoanStatus: none, active, repaid, defaulted (both pools)

const results = [];
const say = (status, what, detail = "") => { results.push({ status, what, detail }); if (!asJson) console.log(`${status.padEnd(4)} ${what}${detail ? ` (${detail})` : ""}`); };
const ok = (c, what, detail) => say(c ? "ok" : "FAIL", what, detail);
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
const finish = (code) => { if (asJson) console.log(JSON.stringify({ agentId, attester: ATTESTER, results }, null, 1)); process.exit(code); };

if (!asJson) console.log(`agent #${agentId}, attester ${ATTESTER}, RPC ${describe(src)}`);
const reg = new ethers.Contract(REPUTATION_REGISTRY, REGISTRY_ABI, provider);
const last = await reg.getLastIndex(agentId, ATTESTER);
if (last === 0n) { say("FAIL", "the attester has no entry for this agent"); finish(1); }
const fb = await reg.readFeedback(agentId, ATTESTER, last);
ok(!fb.isRevoked, `entry ${last} is live`, fb.isRevoked ? "revoked: the agent has no current Priors note" : `value ${fb.value}, ${fb.tag1}, ${fb.tag2}`);

// the event that carries the URI and hash (they are emitted, not stored): searched backwards from the head
const nf = new ethers.Interface([NEW_FEEDBACK]);
const topics = [nf.getEvent("NewFeedback").topicHash, ethers.toBeHex(agentId, 32), ethers.zeroPadValue(ATTESTER, 32)];
let ev = null;
const head = await provider.getBlockNumber();
for (let to = head; to >= REG_DEPLOY && !ev; to -= WINDOW) {
  const logs = await provider.getLogs({ address: REPUTATION_REGISTRY, topics, fromBlock: Math.max(REG_DEPLOY, to - WINDOW + 1), toBlock: to });
  for (const l of logs.reverse()) { const a = nf.parseLog(l).args; if (a.feedbackIndex === last) { ev = { log: l, args: a }; break; } }
}
if (!ev) { say("FAIL", `the NewFeedback event of entry ${last}`, `not found from block ${REG_DEPLOY}; try --from-block or --window`); finish(1); }
const A = ev.args;
say("ok", "NewFeedback event", `block ${ev.log.blockNumber}, tx ${ev.log.transactionHash}`);
if (A.feedbackHash === ethers.ZeroHash) {
  say("skip", "this entry carries no file hash: a v1 note pointing at a live page", A.feedbackURI);
  finish(2);
}

let bytes = decodeFeedbackURI(A.feedbackURI);
if (!bytes && /^https:\/\//.test(A.feedbackURI)) bytes = new Uint8Array(await (await fetch(A.feedbackURI)).arrayBuffer());
if (!bytes) { say("FAIL", "the feedbackURI could not be read", A.feedbackURI.slice(0, 80)); finish(1); }
ok(ethers.keccak256(bytes) === A.feedbackHash, "feedbackHash = keccak256(file bytes)", `${bytes.length} bytes`);
const F = JSON.parse(ethers.toUtf8String(bytes));
const P = F.priors || {};
ok(F.agentRegistry === `eip155:${CHAIN_ID}:${IDENTITY_REGISTRY}`, "agentRegistry", F.agentRegistry);
ok(Number(F.agentId) === agentId, "agentId", String(F.agentId));
ok(same(F.clientAddress, `eip155:${CHAIN_ID}:${ATTESTER}`), "clientAddress is the attester", F.clientAddress);
ok(BigInt(F.value) === fb.value && Number(F.valueDecimals) === Number(fb.valueDecimals) && F.tag1 === fb.tag1 && F.tag2 === fb.tag2, "value, valueDecimals, tag1, tag2 match the entry on chain", `${F.value} ${F.tag1} ${F.tag2}`);
ok(F.tag2 === `rung-${P.rung}/v${P.weights}` && Number(P.score) === Number(F.value), "the file's score, rung and weights are the entry's", `score ${P.score}, rung ${P.rung}, weights ${P.weights}`);
const sum = await reg.getSummary(agentId, [ATTESTER], TAG1, "");
ok(sum.count === 1n && sum.summaryValue === BigInt(F.value), `getSummary(agentId, [attester], "${TAG1}", "") is the file's score`, `count ${sum.count}, value ${sum.summaryValue}`);
say("info", "schema", `priors.v ${P.v}, created ${F.createdAt}, at block ${P.block}`);

const blk = await provider.getBlock(Number(P.block));
ok(blk && Number(blk.timestamp) === Number(P.blockTime), "priors.blockTime is priors.block's timestamp", blk ? `${blk.timestamp}` : "block not found");
ok(ev.log.blockNumber >= Number(P.block), "the note was posted at or after the block it describes");

// The cited repayments and the payment are read from the pools of the deployment record, never from an address the file
// names: a contract the file's author chose can answer anything (GHSA-m5wj-mgcg-x3fv). The file must name the same ones.
const pool = new ethers.Contract(DEP.pool, POOL_ABI, provider);
ok(same(P.pool, DEP.pool), "priors.pool is the credit pool of deployments/4663.v2.json", P.pool);
if (P.v1Pool) ok(same(P.v1Pool, DEP.v1Pool), "priors.v1Pool is the v1 pool of deployments/4663.v2.json", P.v1Pool);
const v1 = P.v1Pool ? new ethers.Contract(DEP.v1Pool, V1_POOL_ABI, provider) : null;

// each cited repayment
for (const c of P.repaid?.last || []) {
  const isV1 = c.era === "v1";
  const c_ = isV1 ? v1 : pool;
  if (!c_) { say("FAIL", `loan v1:${c.loan}`, "no priors.v1Pool to read it from"); continue; }
  const rc = await provider.getTransactionReceipt(c.tx);
  const rep = rc && rc.status === 1 ? rc.logs.find((l) => same(l.address, c_.target) && l.topics[0] === c_.interface.getEvent("Repaid").topicHash && BigInt(l.topics[1]) === BigInt(c.loan)) : null;
  // the v1 pool keeps its loans in an array: getLoan of an id it never issued reverts, which fails the citation
  const l = await c_.getLoan(c.loan).catch((e) => { if (e?.code === "CALL_EXCEPTION") return null; throw e; });
  const good = !!rep && !!l && BigInt(rep.topics[2]) === BigInt(agentId) && rc.blockNumber <= Number(P.block)
    && Number(l.agentId) === agentId && Number(l.status) === REPAID && Number(l.closedAt) <= Number(l.dueAt);
  ok(good, `${isV1 ? "v1 " : ""}loan ${c.loan} repaid on time by this agent before the note's block`, !rep ? `no Repaid log for it in ${c.tx}` : !l ? `the pool has no loan ${c.loan} (getLoan reverted)` : `tx block ${rc.blockNumber}, closed ${l.closedAt} <= due ${l.dueAt}, ${usdg(l.principal)} USDG`);
}
say("info", "totals (from the snapshot, not re-derived)", `on time ${P.repaid?.onTime} (${P.repaid?.usdg} USDG), late ${P.late}, defaults ${P.defaults}`);

// proofOfPayment: the pool's borrow payment to the agent
if (F.proofOfPayment) {
  const pp = F.proofOfPayment;
  const rc = await provider.getTransactionReceipt(pp.txHash);
  const topic = pool.interface.getEvent("Borrowed").topicHash;
  const lg = rc && rc.status === 1 ? rc.logs.find((l) => same(l.address, DEP.pool) && l.topics[0] === topic && BigInt(l.topics[1]) === BigInt(P.paid?.loan ?? -1)) : null;
  const b = lg ? pool.interface.parseLog(lg).args : null;
  ok(!!b && same(pp.fromAddress, DEP.pool) && Number(b.agentId) === agentId && same(b.to, pp.toAddress) && usdg(b.principal) === String(P.paid?.usdg) && Number(pp.chainId) === CHAIN_ID,
    "proofOfPayment: the pool paid this agent's loan to toAddress", b ? `loan ${b.loanId}, ${usdg(b.principal)} USDG to ${b.to}` : `no Borrowed log for loan ${P.paid?.loan} in ${pp.txHash}`);
} else say("info", "no proofOfPayment", "the agent had no loan repaid on time when the note was posted");

// the line and backing at the note's block: needs state at that block
const lens = new ethers.Contract(DEP.lens, LENS_ABI, provider);
let r = null;
try { r = await lens.creditReport(agentId, { blockTag: Number(P.block) }); } catch (e) { r = null; }
if (!r) {
  say("skip", `line and backing at block ${P.block}`, "this RPC keeps no state at that block (not an archive node); pass --rpc <archive endpoint>");
} else {
  const L = P.line || {};
  ok(usdg(r.capacity) === L.limit, "line.limit = the lens' capacity at the block", `${usdg(r.capacity)} USDG`);
  ok(usdg(r.principalOut) === L.drawn, "line.drawn = principalOut at the block", `${usdg(r.principalOut)} USDG`);
  ok(Number(ethers.parseUnits(L.available || "0", 6)) <= Number(r.available), "line.available <= the pool's available at the block (a stock line is capped by its vault)", `${L.available} <= ${usdg(r.available)}`);
  ok(Number(r.sponsor) === Number(P.backing?.sponsor) && usdg(r.delegatedIn) === P.backing?.delegatedIn, "backing: sponsor and delegatedIn at the block", `sponsor #${r.sponsor}, ${usdg(r.delegatedIn)} USDG`);
  ok(r.defaulted === !!P.defaulted, "defaulted at the block", String(r.defaulted));
  say("info", "the lens' own figures at the block", `loansRepaid ${r.loansRepaid} (v1 imports and late ones included), volume ${usdg(r.volumeRepaid)} USDG`);
}
say("info", "not re-derived", "the score (x402 income index and every agent's loans; sdk/score-v2.mjs is the engine)");
finish(results.some((x) => x.status === "FAIL") ? 1 : 0);
