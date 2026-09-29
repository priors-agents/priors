// Priors Score v2: the rules that make it hard to fake, each as a case that fails if the rule is removed.
//   node scripts/test-score-v2.mjs
import assert from "node:assert/strict";
import { scoreV2, canonical, DEFAULT_WEIGHTS as W } from "../sdk/score-v2.mjs";
import { buildInputs, scoreAll } from "../sdk/score-v2-inputs.mjs";

const DAY = 86400, NOW = 1_800_000_000, $ = (n) => Math.round(n * 1e6);
let passed = 0;
const check = (name, fn) => { fn(); passed++; console.log("  ok  ", name); };
const loan = (usd, holdDays, { termDays = 30, late = false, others = true, ago = 40 } = {}) => {
  const issuedAt = NOW - ago * DAY, dueAt = issuedAt + termDays * DAY;
  return { principal: $(usd), issuedAt, dueAt, closedAt: late ? dueAt + DAY : issuedAt + holdDays * DAY, status: "repaid", backedByOthers: others };
};
const base = (over = {}) => ({ agentId: 1, now: NOW, defaulted: false, recordStart: NOW - 60 * DAY, childrenDefaulted: 0, recourseHonored: 0, backingByOthers: 0, loans: [], income: [], ...over });
const pts = (r, k) => r.components.find((c) => c.key === k).points;

console.log("Priors Score v2");

check("the weights add up to the published maximum", () => {
  assert.equal(Object.values(W.components).reduce((a, c) => a + c.max, 0), W.max);
});

check("quick flips barely count: 300 loans held 30 minutes earn under 10 points of risk time and no seasoned loans", () => {
  const r = scoreV2(base({ loans: Array.from({ length: 300 }, () => loan(8, 30 / 1440)) }));
  assert.ok(pts(r, "riskTime") < 10, `riskTime ${pts(r, "riskTime")}`);
  assert.equal(pts(r, "seasoned"), 0);
});

check("money held for weeks counts: five $50 loans held 10 days give 250 risk-time points, 100 seasoned, and reach 'earned'", () => {
  const r = scoreV2(base({ loans: Array.from({ length: 5 }, (_, i) => loan(50, 10, { ago: 60 - i * 11 })) }));
  assert.equal(pts(r, "riskTime"), 250);
  assert.equal(pts(r, "seasoned"), 100);
  assert.equal(r.score, 410);
  assert.equal(r.rung, 3);
});

check("self-backed loans build nothing: the same loans backed by the agent's own cluster score zero and stay unproven", () => {
  const r = scoreV2(base({ loans: Array.from({ length: 5 }, () => loan(50, 10, { others: false })) }));
  assert.equal(pts(r, "riskTime"), 0);
  assert.equal(pts(r, "seasoned"), 0);
  assert.equal(r.rung, 0);
});

check("a late repayment earns nothing and costs points", () => {
  const onTime = scoreV2(base({ loans: [loan(50, 10), loan(50, 10)] }));
  const oneLate = scoreV2(base({ loans: [loan(50, 10), loan(50, 10, { late: true })] }));
  assert.ok(oneLate.score < onTime.score - W.penalties.lateRepayment);
  assert.equal(oneLate.detail.lateRepayments, 1);
});

check("a default is zero, whatever else the record holds", () => {
  const r = scoreV2(base({ defaulted: true, loans: Array.from({ length: 10 }, () => loan(100, 20)), backingByOthers: $(1000) }));
  assert.equal(r.score, 0);
  assert.equal(r.rung, 0);
});

check("a change of hands resets the record: old loans and old age stop counting", () => {
  const r = scoreV2(base({ ownershipChangedAt: NOW - 2 * DAY, loans: Array.from({ length: 5 }, () => loan(50, 10)) }));
  assert.equal(pts(r, "riskTime"), 0);
  assert.equal(pts(r, "age"), 2);
});

check("income is capped per payer: one payer sending $1,000 counts like $20 at half weight, plus breadth", () => {
  const r = scoreV2(base({ income: [{ payer: "0xa", amount: $(1000), at: NOW - DAY }] }));
  assert.equal(pts(r, "income"), 20 * W.components.income.unknownPayerWeight + W.components.income.breadthPointsPerPayer);
});

check("income rewards breadth: ten distinct payers score far more than one payer sending the same total", () => {
  const one = scoreV2(base({ income: [{ payer: "0xa", amount: $(100), at: NOW - DAY }] }));
  const ten = scoreV2(base({ income: Array.from({ length: 10 }, (_, i) => ({ payer: "0x" + i, amount: $(10), at: NOW - DAY })) }));
  assert.ok(pts(ten, "income") > 3 * pts(one, "income"));
});

check("income from a payer with a strong record weighs more than income from an unknown wallet", () => {
  const unknown = scoreV2(base({ income: [{ payer: "0xa", amount: $(20), at: NOW - DAY }] }));
  const trusted = scoreV2(base({ income: [{ payer: "0xa", amount: $(20), at: NOW - DAY, payerScore: 900 }] }));
  assert.ok(pts(trusted, "income") > pts(unknown, "income"));
});

check("income older than the window is ignored", () => {
  const r = scoreV2(base({ income: [{ payer: "0xa", amount: $(20), at: NOW - 40 * DAY }] }));
  assert.equal(pts(r, "income"), 0);
});

// ---- the builder: clusters and sock-puppet income ----
const snap = {
  meta: { timestamp: NOW, treasuryAgentId: 10 },
  agents: [
    { id: 10, owner: "0xH1", sponsor: 0, isRoot: true, delegatedIn: 0, enrolledAt: NOW - 30 * DAY },           // root, in a listed cluster
    { id: 11, owner: "0xH2", sponsor: 10, isRoot: false, delegatedIn: $(10), enrolledAt: NOW - 30 * DAY },     // agent in the same listed cluster
    { id: 20, owner: "0xOUT", sponsor: 10, isRoot: false, delegatedIn: $(10), enrolledAt: NOW - 30 * DAY },    // another owner's agent, backed by that root
    { id: 30, owner: "0xSELF", sponsor: 31, isRoot: false, delegatedIn: $(10), enrolledAt: NOW - 30 * DAY },   // backed by its own root
    { id: 31, owner: "0xSELF", sponsor: 0, isRoot: true, delegatedIn: 0, enrolledAt: NOW - 30 * DAY },
  ],
  loans: [
    ...[11, 20, 30].flatMap((agentId) => Array.from({ length: 3 }, (_, i) => ({ agentId, sponsorId: agentId === 30 ? 31 : 10, principal: $(50), issuedAt: NOW - (25 - i * 8) * DAY, dueAt: NOW - (25 - i * 8 - 20) * DAY, closedAt: NOW - (25 - i * 8 - 9) * DAY, status: "repaid" }))),
  ],
};
const links = { clusters: [{ agents: [10, 11], wallets: ["0xH1", "0xH2"] }] };
const income = [
  { payer: "0xH2", payTo: "0xOUT", amount: $(20), at: NOW - DAY },     // another cluster paying: counts
  { payer: "0xSELF", payTo: "0xSELF", amount: $(20), at: NOW - DAY },  // paying itself: never counts
  { payer: "0xOUT", payTo: "0xH2", amount: $(20), at: NOW - DAY },     // another cluster paying: counts
];

check("agents in one listed cluster backed by their own root build no score, and no output names a cluster", () => {
  const all = scoreAll(snap, { links, income });
  const s = all.find((x) => x.agentId === 11);
  assert.ok(all.every((x) => !JSON.stringify(x).includes("list:") && !("cluster" in x)));
  assert.equal(pts(s, "riskTime"), 0);
  assert.equal(s.rung, 0);
});

check("another owner's agent backed by that root is building a real record (someone else's money)", () => {
  const s = scoreAll(snap, { links, income }).find((x) => x.agentId === 20);
  assert.ok(pts(s, "riskTime") > 0);
  assert.equal(s.detail.repaidByOthers, 3);
});

check("an agent backed by its owner's own root builds nothing, and paying itself earns no income", () => {
  const s = scoreAll(snap, { links, income }).find((x) => x.agentId === 30);
  assert.equal(pts(s, "riskTime"), 0);
  assert.equal(pts(s, "income"), 0);
  assert.equal(pts(s, "backing"), 0);
});

check("the same inputs always give the same score, and inputs hash the same in any key order", () => {
  const a = buildInputs(snap, { links, income });
  assert.deepEqual(a.map((i) => scoreV2(i)), buildInputs(snap, { links, income }).map((i) => scoreV2(i)));
  assert.equal(canonical({ b: 1, a: [2, { d: 3, c: 4 }] }), canonical({ a: [2, { c: 4, d: 3 }], b: 1 }));
});

// ---- the audit of 2026-09-26 (findings F1-F21) ----
const agent = (id, owner, over = {}) => ({ id, owner, sponsor: 0, isRoot: false, delegatedIn: 0, enrolledAt: NOW - 100 * DAY, defaulted: false, ...over });
const repaid = (agentId, sponsorId, usd, issuedDaysAgo, holdDays, over = {}) => ({ agentId, sponsorId, era: "v2", id: agentId * 100 + issuedDaysAgo, principal: $(usd),
  issuedAt: NOW - issuedDaysAgo * DAY, dueAt: NOW - (issuedDaysAgo - 30) * DAY, closedAt: NOW - (issuedDaysAgo - holdDays) * DAY, status: "repaid", ...over });
const one = (s, id, opts = {}) => scoreAll(s, { links: { clusters: [] }, ...opts }).find((x) => x.agentId === id);

check("F1 a sold agent restarts: loans taken under the previous owner stop counting, and so does its age", () => {
  const s = { meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xNEW", { sponsor: 2 }), agent(2, "0xB", { isRoot: true, enrolledAt: NOW - 400 * DAY })],
    loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 90 - i * 10, 9, { owner: "0xOLD" })) };
  const r = one(s, 1);
  assert.equal(r.flags.ownershipChanged, true);
  assert.equal(r.detail.repaidByOthers, 0);
  assert.equal(pts(r, "age"), 0);
});

check("F2 a fresh second wallet can't vouch its way up: a backer enrolled under 30 days before the loan counts as the agent's own", () => {
  const mk = (backerAge) => ({ meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA", { sponsor: 2 }), agent(2, "0xSOCK", { isRoot: true, enrolledAt: NOW - backerAge * DAY })],
    loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 25 - i * 8, 7)) });
  assert.equal(one(mk(26), 1).detail.repaidByOthers, 0);
  assert.equal(one(mk(80), 1).detail.repaidByOthers, 3);
});

check("F17 a bought backer is new: its 30 days count from when its current owner took the id, not from its enrolment (GHSA-6f8j)", () => {
  const mk = () => ({ meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA", { sponsor: 2 }), agent(2, "0xBUYER", { isRoot: true, enrolledAt: NOW - 100 * DAY })],
    loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 25 - i * 8, 7)) });
  assert.equal(one(mk(), 1, { backerOwnerSince: { 2: NOW - 26 * DAY } }).detail.repaidByOthers, 0, "bought 26 days ago: the agent's own money");
  assert.equal(one(mk(), 1, { backerOwnerSince: { 2: NOW - 80 * DAY } }).detail.repaidByOthers, 3, "held 80 days: counts");
  assert.equal(one(mk(), 1).detail.repaidByOthers, 3, "no transfer history given: from its enrolment, as before");
});

check("F2 rungs need time: 3 backed loans inside two weeks stay 'started', and 'earned' needs 30 days since the first", () => {
  const quick = scoreV2(base({ loans: [loan(50, 7, { ago: 12 }), loan(50, 7, { ago: 11 }), loan(50, 7, { ago: 10 })] }));
  assert.equal(quick.rung, 1);
  const big = Array.from({ length: 10 }, (_, i) => loan(200, 8, { ago: 26 - i }));
  const young = scoreV2(base({ loans: big }));
  assert.ok(young.score >= 300 && young.rung === 2, `score ${young.score} rung ${young.rung}`);
});

check("F3 seasoned loans count by size: a 1 USDG loan held a week is worth 1/50 of a full one", () => {
  const r = scoreV2(base({ loans: Array.from({ length: 10 }, () => loan(1, 8)) }));
  assert.equal(pts(r, "seasoned"), 4);
  assert.equal(r.detail.seasonedLoans, 10);
});

check("F4 dust, zero, negative and future payments add nothing: no breadth under 1 USDG per payer", () => {
  const r = scoreV2(base({ income: [
    ...Array.from({ length: 10 }, (_, i) => ({ payer: "0xd" + i, amount: 1000, at: NOW - DAY })),
    { payer: "0xz", amount: 0, at: NOW - DAY }, { payer: "0xn", amount: -$(50), at: NOW - DAY }, { payer: "0xf", amount: $(20), at: NOW + DAY }] }));
  assert.equal(r.detail.distinctPayers, 0);
  assert.ok(pts(r, "income") < 0.1, `income ${pts(r, "income")}`);
});

check("F16 the growth seat vault (V4) backs from day one, as V3 and the treasury do: its young root is not a fresh second wallet", () => {
  const mk = (meta) => ({ meta: { timestamp: NOW, ...meta }, events: [], agents: [agent(1, "0xA", { sponsor: 2 }), agent(2, "0xV4", { isRoot: true, enrolledAt: NOW - 1 * DAY })],
    loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 25 - i * 8, 7)) });
  assert.equal(one(mk({}), 1).detail.repaidByOthers, 0, "a root a day old, not a protocol backer: the agent's own");
  assert.equal(one(mk({ seatVaultV4AgentId: 2 }), 1).detail.repaidByOthers, 3, "the snapshot's V4 root: backs from day one");
});

check("F6 a v1 loan's backer comes from its FeeSplit event, not from the agent's sponsor today", () => {
  const s = { meta: { timestamp: NOW }, agents: [agent(1, "0xA", { sponsor: 3 }), agent(2, "0xA", { isRoot: true }), agent(3, "0xB", { isRoot: true })],
    loans: [{ agentId: 1, era: "v1", id: 7, principal: $(50), issuedAt: NOW - 40 * DAY, dueAt: NOW - 10 * DAY, closedAt: NOW - 30 * DAY, status: "repaid" }],
    events: [{ kind: "FeeSplit", era: "v1", loanId: 7, sponsor: 2 }] };
  assert.equal(one(s, 1).detail.repaidByOthers, 0); // backed by its own owner's root at the time
  s.events[0].sponsor = 3;
  assert.equal(one(s, 1).detail.repaidByOthers, 1);
});

check("F9 age runs from the first loan: an agent that never borrowed has no age", () => {
  const s = { meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA")], loans: [] };
  assert.equal(pts(one(s, 1), "age"), 0);
});

check("F10 an unknown backer fails closed", () => {
  const s = { meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA")], loans: [repaid(1, 999, 50, 20, 8)] };
  assert.equal(one(s, 1).detail.repaidByOthers, 0);
});

check("F11 bad input is refused, and the clock is never read", () => {
  assert.throws(() => scoreV2({ ...base(), now: undefined }), /now/);
  assert.throws(() => scoreV2(base({ loans: [{ ...loan(50, 8), principal: -1 }] })), /principal/);
  assert.throws(() => scoreV2(base({ backingByOthers: NaN })), /backingByOthers/);
  assert.throws(() => buildInputs({ meta: {}, agents: [], loans: [] }, {}), /now/);
});

check("F12 income to a payment wallet several agents declared is shared, not counted once per agent", () => {
  const s = { meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA"), agent(2, "0xA")], loans: [] };
  const inc = [{ payer: "0xP", payTo: "0xA", amount: $(10), at: NOW - DAY }];
  const solo = one({ ...s, agents: [agent(1, "0xA")] }, 1, { income: inc, agentWallets: { 1: "0xA" } });
  assert.ok(Math.abs(pts(one(s, 1, { income: inc, agentWallets: { 1: "0xA", 2: "0xA" } }), "income") - (pts(solo, "income") - 5) / 2 - 5) < 0.11);
});

check("F13 a default zeroes the defaulting owner's other agents too", () => {
  const s = { meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA", { sponsor: 3 }), agent(2, "0xA", { defaulted: true }), agent(3, "0xB", { isRoot: true, enrolledAt: NOW - 400 * DAY })],
    loans: [...[0, 1, 2].map((i) => repaid(1, 3, 50, 60 - i * 10, 9)),
      { agentId: 2, sponsorId: 3, era: "v2", id: 900, owner: "0xA", principal: $(5), issuedAt: NOW - 20 * DAY, dueAt: NOW - 13 * DAY, closedAt: 0, status: "defaulted" }] };
  const r = one(s, 1);
  assert.equal(r.score, 0);
  assert.equal(r.rung, 0);
  assert.equal(r.flags.ownerDefaulted, true);
});

check("F14 recourse honored under a previous owner doesn't carry over", () => {
  assert.equal(pts(scoreV2(base({ recourseHonored: 2 })), "recourse"), 100);
  assert.equal(pts(scoreV2(base({ recourseHonored: 2, ownershipChangedAt: NOW - DAY })), "recourse"), 0);
});

check("F15 the score doesn't depend on the order of loans", () => {
  const loans = Array.from({ length: 50 }, (_, i) => ({ ...loan(3.33 + i * 0.07, 1 / 3 + i / 17), issuedAt: NOW - (40 + i / 7) * DAY }));
  const a = scoreV2(base({ loans })), b = scoreV2(base({ loans: [...loans].reverse() }));
  assert.deepEqual(a, b);
});

console.log(`\n${passed} passed`);
