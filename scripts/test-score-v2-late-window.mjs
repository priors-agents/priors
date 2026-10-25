// Priors Score v2 2.0.3: a 24-hour on-time window after a loan's due time (public issue priors-agents/priors#16).
// CreditPoolV2 counts a repayment toward the record once the loan was held its minScoreTerm (7 days), held time capped
// at the term; 2.0.0 to 2.0.2 count a repayment after the due time as late. So a 7-day loan, the shortest that counts,
// could be both counted and on time only when repaid at its exact due second. 2.0.3 is 2.0.2 plus
// penalties.lateAfterSeconds (86400): a repayment within 24 hours of the due time is on time; and the Ethos lane's root
// counts as a backer from day one (backers.dayOneRoots, the snapshot's meta.ethosRootAgentId).
//   - the weights: 2.0.2 plus the window and the Ethos root, nothing else; published 2026-10-25, 7+ days before Priors'
//     scores use it (2026-11-02 00:00 UTC); not the SDK's default;
//   - the rule (sdk/score-v2.mjs repaidLate) at its edges, and the issue's own loan: a 7-day loan repaid an hour after
//     its due time is late, unseasoned and blocks Proven under 2.0.2; on time and seasoned under 2.0.3;
//   - the attestation's evidence (sdk/attestation.mjs evidenceIndex, `lateAfter`) counts late as the score does;
//   - on a ledger of many agents, 2.0.3 moves only the agents with a repayment inside the window, and only up;
//   - the Ethos lane's root, and the income bonus inside the window;
//   - the CLI's term note (sdk/priors-v2.mjs termNote): a term under 7 days never counts, exactly 7 counts only at or
//     after its due time (scripts/test-cli-wallet.mjs runs the CLI itself).
// SDK only, no network.
//   node scripts/test-score-v2-late-window.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { scoreV2, weightsFor, WEIGHTS_BY_VERSION, DEFAULT_WEIGHTS, lateAfterSeconds, repaidLate } from "../sdk/score-v2.mjs";
import { scoreAll, buildInputs, dayOneRoots } from "../sdk/score-v2-inputs.mjs";
import { evidenceIndex } from "../sdk/attestation.mjs";
import { termNote } from "../sdk/priors-v2.mjs";

const DEP = JSON.parse(readFileSync(new URL("../deployments/4663.v2.json", import.meta.url), "utf8"));
const MCP_DEP = JSON.parse(readFileSync(new URL("../packages/mcp/deployments/4663.v2.json", import.meta.url), "utf8"));
let passed = 0;
const check = (name, fn) => { fn(); passed++; console.log("  ok  ", name); };
const DAY = 86400, HOUR = 3600, W202 = weightsFor("2.0.2"), W203 = weightsFor("2.0.3");
const T0 = 1_792_000_000; // 2026-10-15
const OTHER = 6228; // a backer that is not the agent's own (the treasury)
const SWITCH = Date.parse("2026-11-02T00:00:00Z") / 1000;
// the snapshot names V5's roots, as 2.0.2 and 2.0.3 require (scripts/test-score-v2-priors-stake.mjs)
const V5_META = { seatVaultV5AgentId: Number(DEP.seatVaultV5AgentId), seatVaultV5RetiredAgentId: 8641 };

console.log("Priors Score v2 2.0.3: a repayment within 24 hours of its due time is on time");

check("2.0.3 is 2.0.2 plus penalties.lateAfterSeconds 86400 and the Ethos lane's root as a backer from day one: no other number changes; published 2026-10-25, 7+ days before 2026-11-02; not the SDK's default", () => {
  assert.equal(W203.version, "2.0.3");
  assert.equal(W203.penalties.lateAfterSeconds, 86400);
  assert.deepEqual(W203.backers.dayOneRoots, ["ethosRoot"]);
  assert.equal(W202.backers.dayOneRoots, undefined);
  const strip = (w) => {
    const c = JSON.parse(JSON.stringify(w));
    for (const k of ["version", "published", "notes"]) delete c[k];
    delete c.penalties.lateAfterSeconds; delete c.penalties.lateWhy;
    for (const k of ["why", "dayOneRoots", "dayOneWhy"]) delete c.backers[k];
    c.rungs = c.rungs.map(({ rule, ...r }) => r); // rung 2's rule text names the window
    return c;
  };
  assert.deepEqual(strip(W203), strip(W202), "every weight, rung number and penalty as 2.0.2's");
  assert.match(W203.rungs[2].rule, /none late \(more than 24 hours after its due time\)/);
  assert.equal(W203.published, "2026-10-25");
  assert.ok(SWITCH - Date.parse(W203.published) / 1000 >= 7 * DAY, "announced on the dev log 7 days ahead");
  assert.match(W203.notes, /priors-agents\/priors#16/);
  assert.deepEqual(W203.backers.ownCollateralRoots, ["stockVault", "seatVaultV5"], "2.0.2's V5 rule kept");
  assert.equal(DEFAULT_WEIGHTS.version, "2.0.0");
  assert.ok(WEIGHTS_BY_VERSION["2.0.3"] === W203);
});

check("lateAfterSeconds: 0 for every earlier version, 86400 for 2.0.3", () => {
  for (const v of ["2.0.0", "2.0.1", "2.0.2"]) assert.equal(lateAfterSeconds(weightsFor(v)), 0, v);
  assert.equal(lateAfterSeconds(W203), 86400);
  assert.equal(lateAfterSeconds(), 0, "the default weights");
  assert.equal(lateAfterSeconds(null), 0);
});

check("repaidLate at its edges: at the due second on time under both; one second after, late under 2.0.2 and on time under 2.0.3 up to 24 hours; one second more, late", () => {
  const due = T0 + 7 * DAY;
  const rows = [[due - 1, false, false], [due, false, false], [due + 1, true, false], [due + HOUR, true, false], [due + DAY, true, false], [due + DAY + 1, true, true], [due + 3 * DAY, true, true]];
  for (const [closed, l202, l203] of rows) {
    assert.equal(repaidLate(closed, due, W202), l202, `2.0.2 at due${closed - due >= 0 ? "+" : ""}${closed - due}`);
    assert.equal(repaidLate(closed, due, W203), l203, `2.0.3 at due${closed - due >= 0 ? "+" : ""}${closed - due}`);
  }
  // strings, as snapshots carry them
  assert.equal(repaidLate(String(due + DAY), String(due), W203), false);
});

// the issue's loan: a 7-day loan backed by someone else, held its whole term, repaid an hour after its due time
const issueLoan = (over = {}) => ({ status: "repaid", issuedAt: T0, dueAt: T0 + 7 * DAY, closedAt: T0 + 7 * DAY + HOUR, principal: 5_000_000, backedByOthers: true, ...over });
const input = (loans, now = T0 + 30 * DAY) => ({ agentId: 8811, now, recordStart: T0, loans });

check("the issue's loan (7 days, repaid an hour after its due time): 2.0.2 counts it late and unseasoned, and it earns nothing; 2.0.3 counts it on time and seasoned, held its whole term", () => {
  const a = scoreV2(input([issueLoan()]), W202), b = scoreV2(input([issueLoan()]), W203);
  assert.deepEqual([a.detail.lateRepayments, a.detail.seasonedLoans, a.detail.repaidByOthers, a.penalties.late], [1, 0, 0, W202.penalties.lateRepayment]);
  assert.equal(a.rung, 0, "2.0.2: nothing backed by someone else counts");
  assert.deepEqual([b.detail.lateRepayments, b.detail.seasonedLoans, b.detail.repaidByOthers, b.penalties.late], [0, 1, 1, 0]);
  assert.equal(b.detail.dollarDays, 35, "held its whole term: 7 days x $5, as the pool counts it (capped at the due time)");
  assert.equal(b.next.blocked, null);
  assert.ok(b.score > a.score, `2.0.2 ${a.score}, 2.0.3 ${b.score}`);
  assert.equal(b.rung, 1, "started");
});

check("2.0.3 leaves the rest as 2.0.2 scores it: on time before the due time, late past the 24 hours (penalised, earning nothing)", () => {
  const early = [issueLoan({ closedAt: T0 + 7 * DAY - HOUR })];
  assert.deepEqual({ ...scoreV2(input(early), W203), version: null }, { ...scoreV2(input(early), W202), version: null });
  const past = [issueLoan({ closedAt: T0 + 8 * DAY + 1 })];
  assert.deepEqual({ ...scoreV2(input(past), W203), version: null }, { ...scoreV2(input(past), W202), version: null });
  assert.equal(scoreV2(input(past), W203).detail.lateRepayments, 1);
});

check("Proven under 2.0.3: three 7-day loans over 14+ days, each repaid inside its window, reach rung 2; one past its window keeps it closed", () => {
  const three = [0, 8, 16].map((d) => issueLoan({ issuedAt: T0 + d * DAY, dueAt: T0 + (d + 7) * DAY, closedAt: T0 + (d + 7) * DAY + 6 * HOUR }));
  const now = T0 + 60 * DAY;
  assert.equal(scoreV2(input(three, now), W203).rung, 2);
  assert.equal(scoreV2(input(three, now), W202).rung, 0, "2.0.2: all three late");
  const oneOut = [...three.slice(0, 2), { ...three[2], closedAt: three[2].dueAt + DAY + 1 }];
  const r = scoreV2(input(oneOut, now), W203);
  assert.equal(r.rung, 1);
  assert.equal(r.next.blocked, "late");
});

// ---- the attestation's evidence: late as the score counts it ----
const AGENT = 8811, OWNER = "0x" + "b1".repeat(20);
const snapAt = (ts) => ({
  meta: { version: 2, timestamp: ts, blockNumber: 9_000_000, chainId: 4663, pool: "0x" + "11".repeat(20) },
  agents: [
    { id: AGENT, owner: OWNER, name: "bucks", sponsor: OTHER, isRoot: false, loansRepaid: 3, enrolledAt: T0 - DAY, delegatedIn: "25000000", collateral: { capacity: "25000000", borrowRoom: "25000000" } },
    { id: OTHER, owner: "0x" + "c2".repeat(20), name: "treasury", isRoot: true, loansRepaid: 0, enrolledAt: T0 - 90 * DAY },
  ],
  loans: [
    // inside the window, past it, before the due time
    { id: 1, era: "v2", agentId: AGENT, sponsorId: OTHER, owner: OWNER, principal: "5000000", fee: "50000", issuedAt: T0, dueAt: T0 + 7 * DAY, closedAt: T0 + 7 * DAY + HOUR, status: "repaid" },
    { id: 2, era: "v2", agentId: AGENT, sponsorId: OTHER, owner: OWNER, principal: "5000000", fee: "50000", issuedAt: T0 + 8 * DAY, dueAt: T0 + 15 * DAY, closedAt: T0 + 16 * DAY + 1, status: "repaid" },
    { id: 3, era: "v2", agentId: AGENT, sponsorId: OTHER, owner: OWNER, principal: "5000000", fee: "50000", issuedAt: T0 + 17 * DAY, dueAt: T0 + 31 * DAY, closedAt: T0 + 30 * DAY, status: "repaid" },
  ],
  events: [],
});
const NOW = T0 + 40 * DAY;

check("the attestation's evidence (sdk/attestation.mjs evidenceIndex): with the window, late, on time and the on-time USDG as the score counts them; without it, as before", () => {
  const s = snapAt(NOW);
  const a = evidenceIndex(s).agents[AGENT], b = evidenceIndex(s, { lateAfter: lateAfterSeconds(W203) }).agents[AGENT];
  assert.deepEqual([a.repaid.onTime, a.repaid.late], [1, 2]);
  assert.deepEqual([b.repaid.onTime, b.repaid.late], [2, 1]);
  assert.deepEqual([a.repaid.usdg, b.repaid.usdg], ["5", "10"], "the on-time USDG the attestation states takes the window's loan in");
  // the same counts the score reaches under each version
  const late = (w) => scoreAll({ ...s, meta: { ...s.meta, ...V5_META } }, { links: { clusters: [] }, weights: weightsFor(w), now: NOW }).find((x) => x.agentId === AGENT).detail.lateRepayments;
  assert.deepEqual([late("2.0.2"), late("2.0.3")], [a.repaid.late, b.repaid.late]);
});

check("a ledger of many agents: 2.0.3 changes only the agents with a repayment inside the window, never down, and each by that many fewer late repayments", () => {
  // 12 agents on the treasury's line, each with four repaid loans: before the due time, at the due second, and for
  // some agents 2 hours or 23 hours past it (inside the window), or 25 hours or 3 days past it (outside)
  const offsets = [[0, -HOUR], [0, 0], [0, 2 * HOUR], [0, 23 * HOUR], [0, 25 * HOUR], [0, 3 * DAY], [2 * HOUR, 25 * HOUR], [2 * HOUR, 3 * HOUR], [-DAY, -HOUR], [DAY, 0], [DAY + 1, -1], [0, DAY - 1]];
  const agents = [{ id: OTHER, owner: "0x" + "c2".repeat(20), sponsor: 0, isRoot: true, delegatedIn: 0, enrolledAt: T0 - 90 * DAY }];
  const loans = [];
  offsets.forEach(([x, y], i) => {
    const id = 7000 + i, owner = "0x" + (i + 16).toString(16).padStart(2, "0").repeat(20);
    agents.push({ id, owner, sponsor: OTHER, isRoot: false, delegatedIn: 25_000_000, enrolledAt: T0 - DAY });
    [-HOUR, 0, x, y].forEach((past, k) => {
      const issuedAt = T0 + k * 9 * DAY, dueAt = issuedAt + 7 * DAY;
      loans.push({ id: id * 10 + k, era: "v2", agentId: id, sponsorId: OTHER, owner, principal: 10_000_000, fee: 100_000, issuedAt, dueAt, closedAt: dueAt + past, status: "repaid" });
    });
  });
  const now = T0 + 60 * DAY;
  const snap = { meta: { timestamp: now, treasuryAgentId: OTHER, ...V5_META }, agents, loans, events: [] };
  const o = (w) => ({ links: { clusters: [] }, weights: weightsFor(w), now });
  const a = scoreAll(snap, o("2.0.2")), b = scoreAll(snap, o("2.0.3"));
  assert.deepEqual(a.map((x) => x.agentId), b.map((x) => x.agentId));
  const inWindow = new Map();
  for (const l of loans) {
    const past = l.closedAt - l.dueAt;
    if (past > 0 && past <= DAY) inWindow.set(l.agentId, (inWindow.get(l.agentId) || 0) + 1);
  }
  let moved = 0;
  for (let i = 0; i < a.length; i++) {
    const x = a[i], y = b[i], k = inWindow.get(x.agentId) || 0;
    if (!k) { assert.deepEqual({ ...y, version: null }, { ...x, version: null }, `agent ${x.agentId}`); continue; }
    moved++;
    assert.ok(y.score > x.score && y.rung >= x.rung, `agent ${x.agentId}: ${x.score} -> ${y.score}`);
    assert.equal(y.detail.lateRepayments, x.detail.lateRepayments - k, `agent ${x.agentId}: ${k} in the window`);
  }
  assert.equal(moved, 6, "the six agents with a repayment 1 second to 24 hours past its due time (24 hours exactly included)");
  console.log(`        ${moved} of ${a.length - 1} agents move, each up; the rest score as under 2.0.2`);
});

// ---- the Ethos lane's root (2.0.3 backers.dayOneRoots): Priors' own, as the treasury is ----
const ETHOS = Number(MCP_DEP.ethosRoot), LANE = 9195, LANE_OWNER = "0x" + "e7".repeat(20), E0 = 1_792_143_000; // the root enrolled 2026-10-16
const laneSnap = (meta = {}) => ({
  meta: { timestamp: E0 + 25 * DAY, treasuryAgentId: OTHER, ...V5_META, ...meta }, events: [],
  agents: [
    { id: ETHOS, owner: "0x" + "fd".repeat(20), sponsor: 0, isRoot: true, delegatedIn: 0, enrolledAt: E0 },
    { id: LANE, owner: LANE_OWNER, sponsor: ETHOS, isRoot: false, delegatedIn: 25_000_000, enrolledAt: E0 + DAY },
  ],
  // a 14-day loan on the lane's line, issued on the root's second day, repaid on time after 8 days
  loans: [{ id: 47001, agentId: LANE, sponsorId: ETHOS, era: "v2", owner: LANE_OWNER, principal: 20_000_000, fee: 200_000, issuedAt: E0 + 2 * DAY, dueAt: E0 + 16 * DAY, closedAt: E0 + 10 * DAY, status: "repaid" }],
});
const laneScore = (snap, w) => scoreAll(snap, { links: { clusters: [] }, weights: weightsFor(w), now: snap.meta.timestamp }).find((x) => x.agentId === LANE);
const NAMED = { ethosRootAgentId: ETHOS };

check("the Ethos lane's root (#8823): under 2.0.2 a fresh backer (its loans build nothing until it is 30 days old); under 2.0.3, with the snapshot naming it (meta.ethosRootAgentId), Priors' own from day one; unnamed, as before", () => {
  assert.equal(ETHOS, 8823, "the published deployment record's ethosRoot (packages/mcp/deployments/4663.v2.json)");
  const named = laneSnap(NAMED);
  assert.deepEqual([...dayOneRoots(named, W203)], [ETHOS]);
  assert.deepEqual([...dayOneRoots(named, W202)], []);
  assert.deepEqual([...dayOneRoots(laneSnap(), W203)], [], "a snapshot that does not name it");
  const a = laneScore(named, "2.0.2"), b = laneScore(named, "2.0.3"), c = laneScore(laneSnap(), "2.0.3");
  assert.deepEqual([a.detail.repaidByOthers, a.rung], [0, 0], "2.0.2: a backer 2 days old counts for nothing");
  assert.deepEqual([b.detail.repaidByOthers, b.detail.seasonedLoans, b.rung], [1, 1, 1], "2.0.3: on the lane's line, a repayment backed by someone else");
  assert.ok(b.score > a.score, `2.0.2 ${a.score}, 2.0.3 ${b.score}`);
  assert.deepEqual({ ...c, version: null }, { ...laneScore(laneSnap(), "2.0.2"), version: null }, "a snapshot that does not name the root: as 2.0.2");
  // the root's own owner borrowing on it: its own cluster, so nothing counts
  const self = laneSnap(NAMED);
  self.agents[1].owner = self.agents[0].owner; self.loans[0].owner = self.agents[0].owner;
  assert.equal(laneScore(self, "2.0.3").detail.repaidByOthers, 0, "the root's owner borrowing on it: its own cluster");
});

check("2.0.3 keeps 2.0.2's fail-closed rule: without meta.seatVaultV5AgentId no inputs are built", () => {
  const s = laneSnap(NAMED);
  delete s.meta.seatVaultV5AgentId;
  assert.throws(() => buildInputs(s, { links: { clusters: [] }, weights: W203, now: s.meta.timestamp }), /seatVaultV5AgentId/);
});

check("the income bonus (loans repaid from income, sdk/score-v2-inputs.mjs) takes a loan repaid inside the window as on time under 2.0.3, as the score does", () => {
  const snap = laneSnap(NAMED);
  snap.loans[0].closedAt = snap.loans[0].dueAt + 2 * HOUR; // inside the window
  const wallet = "0x" + "7a".repeat(20);
  const opts = (w) => ({ links: { clusters: [] }, weights: weightsFor(w), now: snap.meta.timestamp, agentWallets: { [LANE]: wallet },
    income: [{ payer: "0x" + "99".repeat(20), payTo: wallet, amount: 30_000_000, at: E0 + 5 * DAY }], repayers: { 47001: wallet } });
  const share = (w) => buildInputs(snap, opts(w)).find((x) => x.agentId === LANE).loans[0].incomeShare;
  assert.equal(share("2.0.2"), 0, "2.0.2: late, so no bonus (and no backing: the root is fresh)");
  assert.ok(share("2.0.3") > 0, `2.0.3: on time, repaid from the income that came during the loan (${share("2.0.3")})`);
});

check("the CLI's note (sdk/priors-v2.mjs termNote): under the pool's minScoreTerm a loan never counts; exactly it counts only at or after its due time; longer, nothing to say", () => {
  const M = 7 * DAY;
  assert.match(termNote(3 * DAY, M), /^a 3-day loan never counts toward the agent's record: .*held 7 days\. A 14-day term does\.$/);
  assert.match(termNote(7 * DAY, M), /^a 7-day loan counts toward the record only when repaid at or after its due time, .*24 hours.*A 14-day term leaves 7 days to repay on time\.$/);
  assert.match(termNote(BigInt(7 * DAY), BigInt(M)), /^a 7-day loan/, "bigints, as the CLI passes the term");
  for (const t of [7 * DAY + 1, 14 * DAY, 30 * DAY]) assert.equal(termNote(t, M), null);
  assert.equal(termNote(7 * DAY, 0), null, "the pool's figure unread: nothing said");
});

console.log(`\n${passed} passed`);
