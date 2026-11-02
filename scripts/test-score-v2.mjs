// Priors Score v2: the rules that make it hard to fake, each as a case that fails if the rule is removed.
//   node scripts/test-score-v2.mjs
import assert from "node:assert/strict";
import { scoreV2, canonical, weightsFor, leaseRule, DEFAULT_WEIGHTS as W } from "../sdk/score-v2.mjs";
import { buildInputs, scoreAll, repaidByOwn } from "../sdk/score-v2-inputs.mjs";

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

check("own audit SD-8: a v1-era agent sold after its v1 history restarts too, from the registry's transfer (v1 loans carry no owner)", () => {
  const mk = () => ({ meta: { timestamp: NOW }, agents: [agent(1, "0xBUYER", { sponsor: 2 }), agent(2, "0xB", { isRoot: true, enrolledAt: NOW - 400 * DAY })],
    loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 90 - i * 10, 9, { era: "v1", id: 100 + i })),
    events: [0, 1, 2].map((i) => ({ kind: "FeeSplit", era: "v1", loanId: 100 + i, sponsor: 2 })) });
  const before = one(mk(), 1);
  assert.equal(before.flags.ownershipChanged, false, "the premise: v1 loans alone show no change of hands");
  const sold = one(mk(), 1, { ownerSince: { 1: NOW - 5 * DAY } });
  assert.equal(sold.flags.ownershipChanged, true);
  assert.equal(sold.detail.repaidByOthers, 0);
  assert.equal(pts(sold, "age"), 0);
  // its last transfer is its mint, before the v1 loans: nothing changed hands after the history, nothing moves
  assert.deepEqual(one(mk(), 1, { ownerSince: { 1: NOW - 200 * DAY } }), before);
  // a transfer before any v1 loan of a v2-only agent is the v2 loans' business, as before
  const v2 = { meta: { timestamp: NOW }, events: [], agents: [agent(1, "0xA", { sponsor: 2 }), agent(2, "0xB", { isRoot: true, enrolledAt: NOW - 400 * DAY })], loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 90 - i * 10, 9, { owner: "0xA" })) };
  assert.deepEqual(one(v2, 1, { ownerSince: { 1: NOW - 5 * DAY } }), one(v2, 1));
});

check("GHSA-4x5r-f6w5-fhhc: an agent with no loan before its last registry transfer restarts at that transfer when it came after its enrolment (a sold root drops its recourse, income paid before it stops counting); one before its enrolment restarts nothing; back with the owner whose v2 loans it holds, it keeps them (SD-8)", () => {
  for (const v of ["2.0.0", "2.0.1", "2.0.3", "2.0.4"]) {
    const weights = weightsFor(v), meta = { timestamp: NOW, seatVaultV5AgentId: 98 }, SOLD = NOW - 5 * DAY;
    // a root enrolled 90 days ago that paid two debts of agents it vouched for, never borrowed, now with 0xB
    const root = { meta, events: [], loans: [], agents: [agent(1, "0xB", { isRoot: true, enrolledAt: NOW - 90 * DAY, recourseHonored: 2 })] };
    const sold = one(root, 1, { weights, ownerSince: { 1: SOLD } });
    assert.deepEqual([sold.flags.ownershipChanged, pts(sold, "recourse")], [true, 0], `${v}: sold after its enrolment`);
    const never = one(root, 1, { weights });
    assert.deepEqual([never.flags.ownershipChanged, pts(never, "recourse")], [false, 100], `${v}: never transferred`);
    // its last transfer before its enrolment (its mint, or an identity handed to its owner before it joined): nothing moves
    assert.deepEqual(one(root, 1, { weights, ownerSince: { 1: NOW - 95 * DAY } }), never, `${v}: handed over before enrolling`);
    // a loanless agent: a payment before the transfer no longer counts, one after it does
    const lone = { meta, events: [], loans: [], agents: [agent(3, "0xB", { enrolledAt: NOW - 40 * DAY })] };
    const paid = (at) => one(lone, 3, { weights, ownerSince: { 3: SOLD }, agentWallets: { 3: "0xW1" }, income: [{ payer: "0xP1", payTo: "0xW1", amount: $(20), at }] });
    assert.equal(pts(paid(SOLD - DAY), "income"), 0, `${v}: paid before the transfer`);
    assert.ok(pts(paid(SOLD + DAY), "income") > 0, `${v}: paid after it`);
    // v2 loans before the transfer: their owners decide, as before (SD-8): back with the owner of all its loans it keeps
    // its record, and with anyone else it restarts at the change of hands they show
    const v2 = (owner) => ({ meta, events: [], agents: [agent(2, owner, { sponsor: 4 }), agent(4, "0xR", { isRoot: true, enrolledAt: NOW - 400 * DAY })],
      loans: [0, 1, 2].map((i) => repaid(2, 4, 50, 90 - i * 10, 9, { owner: "0xA" })) });
    assert.deepEqual(one(v2("0xA"), 2, { weights, ownerSince: { 2: SOLD } }), one(v2("0xA"), 2, { weights }), `${v}: the round trip, by design`);
    const other = one(v2("0xC"), 2, { weights, ownerSince: { 2: SOLD } });
    assert.deepEqual([other.flags.ownershipChanged, other.detail.repaidByOthers], [true, 0], `${v}: sold to someone else`);
  }
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
check("F16b treasury v5 (where an agent moves for its $25 raise) backs from day one, as the treasury does, once the snapshot names its root; a moved line's loans stay someone else's risk", () => {
  const mk = (meta) => ({ meta: { timestamp: NOW, ...meta }, events: [], agents: [agent(1, "0xA", { sponsor: 2 }), agent(2, "0xT5", { isRoot: true, enrolledAt: NOW - 1 * DAY })],
    loans: [0, 1, 2].map((i) => repaid(1, 2, 50, 25 - i * 8, 7)) });
  assert.equal(one(mk({}), 1).detail.repaidByOthers, 0, "without the snapshot naming it: a root a day old");
  assert.equal(one(mk({ treasuryV5AgentId: 2 }), 1).detail.repaidByOthers, 3, "the snapshot's treasury v5 root: backs from day one");
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

check("Autopay: a repayment through AutoRepay is the agent's own only if every address that paid is", () => {
  const own = new Set(["0x00000000000000000000000000000000000000aa", "0x00000000000000000000000000000000000000bb"]);
  assert.equal(repaidByOwn(own, "0x00000000000000000000000000000000000000AA"), true, "one address, any letter case");
  assert.equal(repaidByOwn(own, ["0x00000000000000000000000000000000000000aa", "0x00000000000000000000000000000000000000bb"]), true, "the wallet and the owner");
  assert.equal(repaidByOwn(own, ["0x00000000000000000000000000000000000000aa", "0x00000000000000000000000000000000000000cc"]), false, "one stranger is enough to lose it");
  for (const none of [undefined, null, [], ""]) assert.equal(repaidByOwn(own, none), false);
});

check("the Autopay mapping changes no weight: the published weights are the same object as before (2.0.x)", () => {
  // the mapping is an input rule only (who repaid); a weight change needs a new version and its 7-day notice
  assert.match(String(W.version), /^2\.0\./);
  assert.equal(W.components.riskTime.incomeRepaidBonus, 0.25);
});

check("receipts show every outside payer at face value, dust and fresh wallets included; only capped, weighted income scores", () => {
  const r = scoreV2(base({ income: [
    { payer: "0xa", amount: $(0.5), at: NOW - 2 * DAY },                  // dust: a receipt, not income
    { payer: "0xb", amount: $(50), at: NOW - 3 * DAY },                   // a fresh wallet: full receipt, capped and half-weighted income
    { payer: "0xc", amount: $(4), at: NOW - 4 * DAY, payerScore: 600 },
  ] }));
  assert.equal(r.detail.receiptPayers, 3);
  assert.equal(r.detail.receiptsUsdg, 54.5);
  assert.equal(r.detail.distinctPayers, 2);
  assert.equal(r.detail.incomeUsdg, 54);
});

// ---- the next rung and how far the agent is on each of its conditions (what an owner can act on) ----
const needOf = (r, key) => r.next.needs.find((n) => n.key === key);
check("next from Unproven: Started, needing 1 backed repayment (self-backed loans count for nothing)", () => {
  const r = scoreV2(base({ loans: [loan(50, 10, { others: false })] }));
  assert.equal(r.rung, 0);
  assert.deepEqual({ rung: r.next.rung, name: r.next.name, blocked: r.next.blocked }, { rung: 1, name: "started", blocked: null });
  assert.deepEqual(r.next.needs, [{ key: "backedRepaid", have: 0, need: 1, met: false }]);
});
check("next from Started: Proven, with the backed repayments, the days they span and no late one", () => {
  const r = scoreV2(base({ loans: [loan(20, 3, { ago: 10 }), loan(20, 3, { ago: 6 })] }));
  assert.equal(r.rung, 1);
  assert.equal(r.next.name, "proven");
  assert.deepEqual(needOf(r, "backedRepaid"), { key: "backedRepaid", have: 2, need: 3, met: false });
  // from the first backed loan's issue (10 days ago) to the last one's repayment (6 - 3 = 3 days ago)
  assert.deepEqual(needOf(r, "spanDays"), { key: "spanDays", have: 7, need: 14, met: false });
  assert.deepEqual(needOf(r, "late"), { key: "late", have: 0, need: 0, met: true });
  assert.equal(r.next.blocked, null);
});
check("a late repayment blocks Proven for good: blocked 'late', and its condition unmet", () => {
  const r = scoreV2(base({ loans: [loan(20, 8, { ago: 40 }), loan(20, 8, { ago: 30 }), loan(20, 8, { ago: 20 }), loan(20, 8, { ago: 10, late: true })] }));
  assert.equal(r.rung, 1, "3 backed over 14+ days, but one late: Started");
  assert.equal(r.next.blocked, "late");
  assert.deepEqual(needOf(r, "late"), { key: "late", have: 1, need: 0, met: false });
  assert.equal(needOf(r, "backedRepaid").met, true);
  assert.equal(needOf(r, "spanDays").met, true);
});
check("next from Proven: Earned, by the record score (income left out) and the days since the first backed loan", () => {
  const r = scoreV2(base({ loans: [loan(20, 8, { ago: 25 }), loan(20, 8, { ago: 18 }), loan(20, 8, { ago: 10 })] }));
  assert.equal(r.rung, 2);
  assert.equal(r.next.name, "earned");
  assert.equal(needOf(r, "recordScore").need, 300);
  assert.equal(needOf(r, "daysSinceFirst").have, 25);
  assert.equal(needOf(r, "daysSinceFirst").need, 30);
});
check("next from Earned: Income-backed, by income points and payers; none at the top and none after a default", () => {
  const earned = scoreV2(base({ loans: Array.from({ length: 5 }, (_, i) => loan(50, 10, { ago: 60 - i * 11 })) }));
  assert.equal(earned.rung, 3);
  assert.equal(earned.next.name, "income-backed");
  assert.deepEqual(earned.next.needs.map((n) => [n.key, n.have, n.need]), [["incomePoints", 0, 50], ["payers", 0, 3]]);
  assert.equal(scoreV2(base({ defaulted: true, loans: [loan(50, 10)] })).next, null);
});
check("next adds nothing to the score: score, rung and components are what they were without it", () => {
  for (const loans of [[], [loan(50, 10)], Array.from({ length: 5 }, (_, i) => loan(50, 10, { ago: 60 - i * 11 }))]) {
    const { next, ...rest } = scoreV2(base({ loans }));
    assert.equal(typeof next, "object");
    assert.deepEqual(Object.keys(rest), ["version", "agentId", "score", "rung", "rungName", "components", "penalties", "detail", "flags"]);
  }
});

// ---- renting: weights 2.0.5 never count what a lease brings (docs/SCORE-v2.md, "Renting (2.0.5)") ----
const W204 = weightsFor("2.0.4"), W205 = weightsFor("2.0.5");
const H = (n) => "0x" + n.toString(16).padStart(40, "0");
const OWNER = H(0xa1), OWNER_WALLET = H(0xa2), RENTER = H(0xb1), RENTER_WALLET = H(0xb3), OTHER = H(0xc1), CLIENT = H(0xd1), CLIENT2 = H(0xd2), LEASE = H(0xe1);
// one lease of agent 1, OWNER's, to RENTER: its window runs from its start to 30 days after its date, both included
const START = NOW - 20 * DAY, UNTIL = NOW - 10 * DAY, END = UNTIL + 30 * DAY;
const LEASES = [{ agentId: 1, owner: OWNER, renter: RENTER, start: START, until: UNTIL }];
// agent 1: the leased agent, paid at OWNER_WALLET; 4: OWNER's root; 2: the renter's own agent, paid at RENTER_WALLET;
// 3: the renter's root; 5: someone else's root. `over` changes an agent
const rentWorld = ({ now = NOW, loans = [], over = {} } = {}) => ({
  meta: { timestamp: now, seatVaultV5AgentId: 98 }, events: [], loans,
  agents: [agent(1, OWNER, over[1]), agent(2, RENTER, over[2]), agent(3, RENTER, { isRoot: true, enrolledAt: NOW - 400 * DAY, ...over[3] }),
    agent(4, OWNER, { isRoot: true, enrolledAt: NOW - 400 * DAY, ...over[4] }), agent(5, OTHER, { isRoot: true, enrolledAt: NOW - 400 * DAY, ...over[5] })],
});
const WALLETS = { 1: OWNER_WALLET, 2: RENTER_WALLET };
const paid = (payer, payTo, usd, at) => ({ payer, payTo, amount: $(usd), at });
const lent = (id, agentId, sponsorId, usd, issuedAt, holdDays, owner) => ({ agentId, sponsorId, era: "v2", id, owner, principal: $(usd), issuedAt, dueAt: issuedAt + 30 * DAY, closedAt: issuedAt + holdDays * DAY, status: "repaid" });
const scoresOf = (s, opts) => scoreAll(s, { links: { clusters: [] }, agentWallets: WALLETS, ...opts });
const of = (all, id) => all.find((x) => x.agentId === id);
const noVersion = (all) => all.map(({ version, ...x }) => x);
const ADDRS = [OWNER, OWNER_WALLET, RENTER, RENTER_WALLET, OTHER, CLIENT, CLIENT2, LEASE, H(0xf1), H(0xf2)];
const OLDER = ["2.0.0", "2.0.1", "2.0.2", "2.0.3", "2.0.4"];
const olderOpts = (v) => ({ weights: weightsFor(v) });
// every kind of event a lease brings, in its window: the renter paid for the leased agent's work (and declared later as
// its own agent's wallet), a payout of the lease, the renter paying the owner's wallet, the owner paying the renter's
// agent, the renter's root backing the leased agent (a loan, and a line now), the owner's root backing the renter's agent
const richWorld = () => rentWorld({ over: { 1: { sponsor: 3, delegatedIn: $(50) } }, loans: [lent(1001, 1, 3, 50, START + DAY, 8, OWNER), lent(2001, 2, 4, 50, START + DAY, 8, RENTER), lent(2002, 2, 5, 10, START + 2 * DAY, 8, RENTER)] });
const richOpts = { agentWallets: { 1: OWNER_WALLET, 2: RENTER }, repayers: { 1001: OWNER, 2001: RENTER, 2002: RENTER },
  income: [paid(CLIENT, RENTER, 20, START + 3 * DAY), paid(LEASE, OWNER_WALLET, 5, START + 2 * DAY), paid(RENTER, OWNER_WALLET, 5, START + 2 * DAY), paid(OWNER, RENTER, 5, START + 4 * DAY), paid(CLIENT2, OWNER_WALLET, 20, START + 5 * DAY)] };

check("2.0.5 is 2.0.4 plus renting's rule (`leases`, 30 days after a lease's date): no weight, rung or penalty number changes; its dev log notice is dated 2026-11-02; the SDK's default stays 2.0.0; every earlier version has no such rule", () => {
  const strip = (w) => { const c = JSON.parse(JSON.stringify(w)); delete c.version; delete c.published; delete c.notes; delete c.leases; return c; };
  assert.deepEqual(strip(W205), strip(W204));
  assert.deepEqual(leaseRule(W205), { afterS: 30 * DAY });
  assert.equal(W205.published, "2026-11-02", "announced on the dev log (priors.trade/updates) on 2026-11-02: Priors' scores use it from 2026-11-10T00:00:00Z");
  assert.equal(W.version, "2.0.0");
  for (const v of OLDER) assert.equal(leaseRule(weightsFor(v)), null, v);
  assert.doesNotMatch(JSON.stringify(W205.leases), /USDG [0-9]|price|ended by|who ended/i, "the rule names no amount and no ender");
});

check("weights without the rule give the same scores with or without the leases input, so a past score recomputes as it was published (2.0.0 to 2.0.4); 2.0.5 on the same inputs differs", () => {
  for (const v of OLDER) {
    const o = { ...richOpts, ...olderOpts(v) };
    assert.deepEqual(scoresOf(richWorld(), { ...o, leases: LEASES, leaseAddress: LEASE }), scoresOf(richWorld(), o), v);
    assert.doesNotThrow(() => scoresOf(richWorld(), o), `${v} never asks for the leases`);
  }
  const w4 = scoresOf(richWorld(), { ...richOpts, weights: W204 }), w5 = scoresOf(richWorld(), { ...richOpts, weights: W205, leases: LEASES, leaseAddress: LEASE });
  assert.ok(of(w5, 1).score < of(w4, 1).score && of(w5, 2).score < of(w4, 2).score, `the leased agent ${of(w4, 1).score} -> ${of(w5, 1).score}, the renter's ${of(w4, 2).score} -> ${of(w5, 2).score}`);
});

check("with no lease, 2.0.5 scores every agent as 2.0.4 does, but the version; and so it does with leases that touch none of them", () => {
  const w4 = scoresOf(richWorld(), { ...richOpts, weights: W204 });
  assert.deepEqual(noVersion(scoresOf(richWorld(), { ...richOpts, weights: W205, leases: [] })), noVersion(w4));
  const elsewhere = [{ agentId: 77, owner: H(0xf1), renter: H(0xf2), start: START, until: UNTIL }];
  assert.deepEqual(noVersion(scoresOf(richWorld(), { ...richOpts, weights: W205, leases: elsewhere, leaseAddress: H(0xe9) })), noVersion(w4));
  assert.ok(scoresOf(richWorld(), { ...richOpts, weights: W205, leases: [] }).every((x) => x.version === "2.0.5"));
});

check("S1: lease-era payments to the renter's address add nothing, for any agent, receipts included, also when that address is declared later (as its own agent's wallet, or as the leased agent's); before the start and after the window they count", () => {
  const work = [paid(CLIENT, RENTER, 20, START + 2 * DAY)];
  // later declared as the renter's own agent's payment wallet
  const own = { agentWallets: { 1: OWNER_WALLET, 2: RENTER }, income: work };
  assert.ok(pts(of(scoresOf(rentWorld(), { ...own, weights: W204 }), 2), "income") > 0, "2.0.4: the lease's work counts for the renter's own agent");
  const r = of(scoresOf(rentWorld(), { ...own, weights: W205, leases: LEASES }), 2);
  assert.deepEqual([pts(r, "income"), r.detail.receiptsUsdg, r.detail.receiptPayers], [0, 0, 0]);
  // later made the leased agent's own payment wallet (its owner and the renter, both signing)
  const leased = { agentWallets: { 1: RENTER, 2: RENTER_WALLET }, income: work };
  assert.ok(pts(of(scoresOf(rentWorld(), { ...leased, weights: W204 }), 1), "income") > 0);
  assert.equal(pts(of(scoresOf(rentWorld(), { ...leased, weights: W205, leases: LEASES }), 1), "income"), 0);
  // at the window's edges, the payment's own time deciding
  for (const [at, now, counts] of [[START - 1, NOW, true], [START, NOW, false], [UNTIL + 5 * DAY, UNTIL + 20 * DAY, false], [END, END + DAY, false], [END + 1, END + DAY, true]]) {
    const got = of(scoresOf(rentWorld({ now }), { agentWallets: { 1: OWNER_WALLET, 2: RENTER }, income: [paid(CLIENT, RENTER, 20, at)], weights: W205, leases: LEASES }), 2);
    assert.equal(pts(got, "income") > 0, counts, `paid ${(at - START) / DAY} days from the start, scored ${(now - START) / DAY} days from it`);
  }
  // a lease that ended early keeps the window of its date: the index gives its until after any days added, never when it ended
  const extended = [{ ...LEASES[0], until: UNTIL + 10 * DAY }];
  const late = of(scoresOf(rentWorld({ now: END + 5 * DAY }), { agentWallets: { 1: OWNER_WALLET, 2: RENTER }, income: [paid(CLIENT, RENTER, 20, END + 2 * DAY)], weights: W205, leases: extended }), 2);
  assert.equal(pts(late, "income"), 0, "days added move the window's end");
});

check("S1: a lease-era payment to the renter's address funds no loan's income bonus", () => {
  const s = rentWorld({ loans: [lent(2002, 2, 5, 10, START + DAY, 8, RENTER)] });
  const o = { agentWallets: { 1: OWNER_WALLET, 2: RENTER }, income: [paid(CLIENT, RENTER, 20, START + 3 * DAY)], repayers: { 2002: RENTER } };
  assert.ok(of(scoresOf(s, { ...o, weights: W204 }), 2).detail.repaidFromIncome > 0, "2.0.4: the lease's work repaid the renter's own loan");
  const r = of(scoresOf(s, { ...o, weights: W205, leases: LEASES }), 2);
  assert.deepEqual([r.detail.repaidFromIncome, r.detail.repaidByOthers], [0, 1], "the loan still counts, with no bonus");
});

check("S3: rent never counts: whatever the lease's own address pays out (or is paid), at any time, and rent the renter sends the owner's side in the window, also when scored after the window", () => {
  const payout = [paid(LEASE, OWNER_WALLET, 5, START + DAY)];
  assert.ok(pts(of(scoresOf(rentWorld(), { income: payout, weights: W204 }), 1), "income") > 0, "2.0.4: a payout the index read would count");
  assert.equal(pts(of(scoresOf(rentWorld(), { income: payout, weights: W205, leases: LEASES, leaseAddress: LEASE }), 1), "income"), 0);
  const later = rentWorld({ now: END + 60 * DAY });
  assert.equal(pts(of(scoresOf(later, { income: [paid(LEASE, OWNER_WALLET, 5, END + 50 * DAY)], weights: W205, leases: LEASES, leaseAddress: LEASE }), 1), "income"), 0, "a claim long after the window: still the lease's");
  assert.equal(pts(of(scoresOf(rentWorld(), { agentWallets: { ...WALLETS, 5: LEASE }, income: [paid(CLIENT, LEASE, 5, START + DAY)], weights: W205, leases: LEASES, leaseAddress: LEASE }), 5), "income"), 0, "paid to it");
  // rent sent straight from the renter to the owner's wallet
  const side = (at, now, w = W205) => pts(of(scoresOf(rentWorld({ now }), { income: [paid(RENTER, OWNER_WALLET, 5, at)], weights: w, leases: LEASES, leaseAddress: LEASE }), 1), "income");
  assert.equal(side(START + DAY, NOW), 0);
  assert.equal(side(UNTIL + 20 * DAY, UNTIL + 35 * DAY), 0, "scored after the window: judged by the payment's own time");
  assert.ok(side(UNTIL + 20 * DAY, UNTIL + 35 * DAY, W204) > 0, "2.0.4 counts it");
  assert.ok(side(START - 2 * DAY, NOW) > 0, "before the start: as today");
  assert.ok(side(END + DAY, END + 5 * DAY) > 0, "after the window: as today");
});

check("S4: no backing and no payment between the two sides counts in the window (a loan by its issue time, a line held now, a payment by its time), in both directions, for good; before the start and after the window, as today", () => {
  const backed = (issuedAt, now, w = W205) => of(scoresOf(rentWorld({ now, loans: [lent(1001, 1, 3, 50, issuedAt, 8, OWNER)] }), { weights: w, leases: LEASES }), 1).detail.repaidByOthers;
  assert.equal(backed(START + DAY, NOW, W204), 1, "2.0.4: the renter's root put someone else's money at risk");
  assert.equal(backed(START + DAY, NOW), 0, "issued in the window: never");
  assert.equal(backed(START + DAY, END + 10 * DAY), 0, "also when scored after the window");
  assert.equal(backed(START - 10 * DAY, NOW), 1, "issued before the start: as today");
  assert.equal(backed(END + DAY, END + 20 * DAY), 1, "issued after the window: as today");
  // the window's edges, both included: its start and its last second
  assert.deepEqual([backed(START - 1, NOW), backed(START, NOW), backed(END, END + 10 * DAY), backed(END + 1, END + 10 * DAY)], [1, 0, 0, 1], "issued a second before the start, at it, at the window's last second, a second after");
  // the other way: the renter's agent, backed by the owner's root
  const back = (w) => of(scoresOf(rentWorld({ loans: [lent(2001, 2, 4, 50, START + DAY, 8, RENTER)] }), { weights: w, leases: LEASES }), 2).detail.repaidByOthers;
  assert.deepEqual([back(W204), back(W205)], [1, 0]);
  // a line held now: the renter's root behind the leased agent
  const line = (now, w) => pts(of(scoresOf(rentWorld({ now, over: { 1: { sponsor: 3, delegatedIn: $(50) } } }), { weights: w, leases: LEASES }), 1), "backing");
  assert.ok(line(NOW, W204) > 0);
  assert.equal(line(NOW, W205), 0, "in the window");
  assert.equal(line(END + DAY, W205), line(END + DAY, W204), "after it, as today");
  // payments from one side to the other: the owner paying the renter's agent, its wallet's own address
  const pays = (at, now, w = W205) => pts(of(scoresOf(rentWorld({ now }), { income: [paid(OWNER, RENTER_WALLET, 20, at)], weights: w, leases: LEASES }), 2), "income");
  assert.ok(pays(START + 3 * DAY, NOW, W204) > 0);
  assert.equal(pays(START + 3 * DAY, NOW), 0);
  assert.equal(pays(UNTIL + 25 * DAY, UNTIL + 35 * DAY), 0, "scored after the window");
  assert.ok(pays(START - DAY, NOW) > 0, "before the start");
  assert.ok(pays(END + DAY, END + 5 * DAY) > 0, "after the window");
  assert.deepEqual([START - 1, START, END, END + 1].map((at) => pays(at, Math.max(NOW, at + DAY)) > 0), [true, false, false, true], "paid a second before the start, at it, at the window's last second, a second after");
  // someone else's root and someone else's money: as today
  assert.equal(of(scoresOf(rentWorld({ loans: [lent(1002, 1, 5, 50, START + DAY, 8, OWNER)] }), { weights: W205, leases: LEASES }), 1).detail.repaidByOthers, 1);
  assert.ok(pts(of(scoresOf(rentWorld(), { income: [paid(CLIENT, OWNER_WALLET, 20, START + DAY)], weights: W205, leases: LEASES }), 1), "income") > 0);
});

check("S4 across a sale on Priors' market (2.0.4's rule, which 2.0.5 carries): a listed agent's seller's loan is judged against the seller's side as at the sale, so one the renter's root backed in the window counts as backed by no one else there either", () => {
  const BUYER = H(0xc7), SOLD = START + 12 * DAY;
  const s = rentWorld({ loans: [lent(1001, 1, 3, 50, START + DAY, 8, OWNER)], over: { 1: { owner: BUYER } } });
  const o = { links: { clusters: [{ agents: [1], wallets: [H(0xf3)] }] }, agentWallets: { 2: RENTER_WALLET }, repayers: { 1001: OWNER },
    sales: [{ agentId: 1, seller: OWNER, buyer: BUYER, at: SOLD, wallet: OWNER_WALLET, block: 1000, index: 0 }], plainTransferAt: { 1: 0 } };
  const r4 = of(scoresOf(s, { ...o, weights: W204 }), 1), r5 = of(scoresOf(s, { ...o, weights: W205, leases: LEASES }), 1);
  assert.deepEqual([r4.flags.keptSale, r5.flags.keptSale], [true, true], "the premise: a kept sale, the agent listed in the clusters list");
  assert.deepEqual([r4.detail.repaidByOthers, r5.detail.repaidByOthers], [1, 0]);
});

check("S4: no cluster is joined: the renter's default leaves the owner's agents alone, and the owner's leaves the renter's", () => {
  const defaulted = (agentId, owner, sponsorId) => ({ agentId, sponsorId, era: "v2", id: 9000 + agentId, owner, principal: $(5), issuedAt: START + DAY, dueAt: START + 8 * DAY, closedAt: 0, status: "defaulted" });
  const byRenter = scoresOf(rentWorld({ loans: [defaulted(2, RENTER, 5)], over: { 2: { defaulted: true } } }), { weights: W205, leases: LEASES });
  assert.deepEqual([of(byRenter, 1).flags.ownerDefaulted, of(byRenter, 4).flags.ownerDefaulted, of(byRenter, 3).flags.ownerDefaulted], [false, false, true], "only the renter's own root, as always");
  const byOwner = scoresOf(rentWorld({ loans: [defaulted(1, OWNER, 5)], over: { 1: { defaulted: true } } }), { weights: W205, leases: LEASES });
  assert.deepEqual([of(byOwner, 2).flags.ownerDefaulted, of(byOwner, 3).flags.ownerDefaulted, of(byOwner, 4).flags.ownerDefaulted], [false, false, true]);
});

check("fails closed: with the rule, no inputs are built without the leases, or with a lease it can't read; earlier weights never ask for them", () => {
  const o = { links: { clusters: [] }, weights: W205 };
  assert.throws(() => buildInputs(rentWorld(), o), /pass `leases`/);
  for (const bad of [{ renter: "" }, { owner: null }, { start: undefined }, { until: "soon" }, { start: -1 }]) {
    assert.throws(() => buildInputs(rentWorld(), { ...o, leases: [{ ...LEASES[0], ...bad }] }), /lease 0 \(agent 1\) has no readable owner, renter, start and until/, JSON.stringify(bad));
  }
  assert.equal(buildInputs(rentWorld(), { ...o, leases: [] }).length, 5);
  assert.equal(buildInputs(rentWorld(), { links: { clusters: [] }, weights: W204 }).length, 5);
});

// a seeded generator: a failure names its seed
const rng = (seed) => () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; };
check("on 200 random histories with random leases: every earlier version scores byte for byte as without the input; 2.0.5 with no lease is 2.0.4 but the version; with leases it only ever takes away (no score, income, receipt or backed repayment above 2.0.4's)", () => {
  for (let seed = 1; seed <= 200; seed++) {
    const r = rng(seed), pick = (xs) => xs[Math.floor(r() * xs.length)], days = () => (Math.floor(r() * 60) - 50) * DAY;
    const loans = Array.from({ length: Math.floor(r() * 6) }, (_, i) => { const id = pick([1, 2]); return lent(5000 + i, id, pick([3, 4, 5]), 5 + Math.floor(r() * 60), NOW + days(), 7 + Math.floor(r() * 5), id === 1 ? OWNER : RENTER); }).filter((l) => l.closedAt <= NOW);
    const income = Array.from({ length: Math.floor(r() * 10) }, () => paid(pick(ADDRS), pick([OWNER_WALLET, RENTER_WALLET, RENTER, OWNER]), 0.5 + r() * 30, NOW + days())).filter((p) => p.at <= NOW);
    const leases = Array.from({ length: Math.floor(r() * 3) }, () => { const start = NOW + days(); return { agentId: pick([1, 2]), owner: pick([OWNER, RENTER, OTHER]), renter: pick([RENTER, OWNER, H(0xf1)]), start, until: start + (1 + Math.floor(r() * 30)) * DAY }; });
    const s = rentWorld({ loans, over: { 1: { sponsor: pick([0, 3, 5]), delegatedIn: $(20) } } });
    const base = { agentWallets: { 1: pick([OWNER_WALLET, RENTER, OWNER]), 2: pick([RENTER_WALLET, RENTER, OWNER_WALLET]) }, income, repayers: Object.fromEntries(loans.map((l) => [l.id, l.owner])) };
    for (const v of OLDER) assert.deepEqual(scoresOf(s, { ...base, ...olderOpts(v), leases, leaseAddress: LEASE }), scoresOf(s, { ...base, ...olderOpts(v) }), `seed ${seed}: ${v}`);
    const w4 = scoresOf(s, { ...base, weights: W204 });
    assert.deepEqual(noVersion(scoresOf(s, { ...base, weights: W205, leases: [] })), noVersion(w4), `seed ${seed}: no lease`);
    scoresOf(s, { ...base, weights: W205, leases, leaseAddress: LEASE }).forEach((x, i) => {
      const y = w4[i];
      for (const [k, a, b] of [["score", x.score, y.score], ["income", x.detail.incomeUsdg, y.detail.incomeUsdg], ["receipts", x.detail.receiptsUsdg, y.detail.receiptsUsdg], ["backed", x.detail.repaidByOthers, y.detail.repaidByOthers]]) {
        assert.ok(a <= b, `seed ${seed}: agent ${x.agentId}'s ${k} ${a} above 2.0.4's ${b}`);
      }
    });
  }
});

console.log(`\n${passed} passed`);
