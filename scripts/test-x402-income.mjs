// x402 income in Priors Score v2: reading payments from the chain and turning them into score. Each rule is a case
// that fails if the rule is removed.
//   node scripts/test-x402-income.mjs
import assert from "node:assert/strict";
import { ethers } from "ethers";
import { pairPayments, scanPayments, scanTransfers, TOPICS, getLogsAdaptive, DeadlineError, readAgentWallets, readRepayers, updateIncome } from "../sdk/x402-income.mjs";
import { scoreV2, DEFAULT_WEIGHTS as W } from "../sdk/score-v2.mjs";
import { buildInputs, scoreAll } from "../sdk/score-v2-inputs.mjs";

const DAY = 86400, NOW = 1_800_000_000, $ = (n) => Math.round(n * 1e6);
let passed = 0;
const check = async (name, fn) => { await fn(); passed++; console.log("  ok  ", name); };
const pts = (r, k) => r.components.find((c) => c.key === k).points;
const A = (n) => "0x" + n.toString(16).padStart(40, "0"); // a readable fake address
const topic = (a) => ethers.zeroPadValue(a, 32);
const auth = (tx, index, payer, block = 100) => ({ transactionHash: tx, index, blockNumber: block, topics: [TOPICS.AUTH_USED, topic(payer), ethers.id("nonce" + tx + index)], data: "0x" });
const xfer = (tx, index, from, to, amount, block = 100) => ({ transactionHash: tx, index, blockNumber: block, topics: [TOPICS.TRANSFER, topic(from), topic(to)], data: ethers.toBeHex(amount, 32) });

console.log("x402 income");

// ---------------------------------------------------------------- reading the chain
await check("a signed payment is the authorization plus the transfer right after it, from the same payer", () => {
  const p = pairPayments([auth("0x01", 4, A(1))], [xfer("0x01", 5, A(1), A(9), 30000)]);
  assert.deepEqual(p.map((x) => [x.payer, x.payTo, x.amount]), [[A(1), A(9), "30000"]]);
});

await check("an unrelated transfer in the same transaction is never taken for the payment", () => {
  // the authorized transfer went elsewhere (not in the list); a later plain transfer from the payer is not it
  assert.deepEqual(pairPayments([auth("0x02", 4, A(1))], [xfer("0x02", 9, A(1), A(9), 50)]), []);
  // a transfer right after, but from someone else
  assert.deepEqual(pairPayments([auth("0x03", 4, A(1))], [xfer("0x03", 5, A(2), A(9), 50)]), []);
});

await check("a transaction settling two authorizations yields two payments", () => {
  const p = pairPayments([auth("0x04", 0, A(1)), auth("0x04", 2, A(2))], [xfer("0x04", 1, A(1), A(9), 10), xfer("0x04", 3, A(2), A(9), 20)]);
  assert.deepEqual(p.map((x) => x.amount), ["10", "20"]);
});

await check("the scan asks only for transfers from the block range's payers to agent wallets, chunk by chunk, and stops at a deadline", async () => {
  const calls = [];
  const provider = {
    async getLogs(f) {
      calls.push(f);
      if (f.topics[0] === TOPICS.AUTH_USED) return f.fromBlock <= 150 && 150 <= f.toBlock ? [auth("0x05", 0, A(1), 150)] : [];
      assert.deepEqual(f.topics[1], [topic(A(1))]);
      assert.deepEqual(f.topics[2], [topic(A(9))]);
      return [xfer("0x05", 1, A(1), A(9), 7, 150)];
    },
    async getBlock(n) { return { timestamp: 1000 + n }; },
  };
  const r = await scanPayments(provider, { usdg: A(7), wallets: [A(9)], fromBlock: 1, toBlock: 300, chunk: 100 });
  assert.equal(r.scannedTo, 300);
  assert.deepEqual(r.payments.map((x) => [x.amount, x.at]), [["7", 1150]]);
  assert.equal(calls.filter((c) => c.topics[0] === TOPICS.AUTH_USED).length, 3);
  const stopped = await scanPayments(provider, { usdg: A(7), wallets: [A(9)], fromBlock: 1, toBlock: 300, chunk: 100, deadline: Date.now() - 1 });
  assert.equal(stopped.scannedTo, 0); // nothing done, resume from block 1
});

await check("transfers sent back to payers are read the same way, with no block lookups (only amounts matter)", async () => {
  let blocks = 0;
  const provider = {
    async getLogs(f) { assert.equal(f.topics[0], TOPICS.TRANSFER); return [xfer("0x06", 3, A(9), A(1), 5, 42)]; },
    async getBlock() { blocks++; return { timestamp: 5 }; },
  };
  const r = await scanTransfers(provider, { usdg: A(7), from: [A(9)], to: [A(1)], fromBlock: 1, toBlock: 10 });
  assert.deepEqual(r.transfers.map((x) => [x.from, x.to, x.amount]), [[A(9), A(1), "5"]]);
  assert.equal(blocks, 0);
});

// ---------------------------------------------------------------- scoring income
const agent = (id, owner, over = {}) => ({ id, owner, sponsor: 0, isRoot: false, delegatedIn: 0, enrolledAt: NOW - 100 * DAY, defaulted: false, ...over });
const pay = (payer, payTo, usd, daysAgo = 1) => ({ payer, payTo, amount: $(usd), at: NOW - daysAgo * DAY });
const world = (agents, loans = []) => ({ meta: { timestamp: NOW }, events: [], agents, loans });
// every agent declared its owner as its payment wallet (the registry's default at registration) unless a test says otherwise
const one = (s, id, opts = {}) => scoreAll(s, { links: { clusters: [] }, ...opts, agentWallets: { ...Object.fromEntries(s.agents.map((a) => [a.id, a.owner])), ...opts.agentWallets } }).find((x) => x.agentId === id);
const OWNER = A(0xa), WALLET = A(0xb), CLIENT = A(0xc), OTHER = A(0xd);

await check("income paid to the agent's declared payment wallet counts for that agent", () => {
  const s = world([agent(1, OWNER), agent(2, OTHER)]);
  const withWallet = one(s, 1, { income: [pay(CLIENT, WALLET, 10)], agentWallets: { 1: WALLET } });
  const without = one(s, 1, { income: [pay(CLIENT, WALLET, 10)] });
  assert.ok(pts(withWallet, "income") > 0);
  assert.equal(pts(without, "income"), 0);
});

await check("a wallet two agents declare links them: they can't pay each other income or back each other", () => {
  // agent 1 (owner A) and agent 2 (owner B) both declared WALLET, which signed for both: one party
  const s = world([agent(1, OWNER, { sponsor: 2, delegatedIn: $(100) }), agent(2, OTHER, { isRoot: true, enrolledAt: NOW - 400 * DAY })]);
  const linked = one(s, 1, { income: [pay(OTHER, WALLET, 20)], agentWallets: { 1: WALLET, 2: WALLET } });
  assert.equal(pts(linked, "income"), 0);
  assert.equal(pts(linked, "backing"), 0);
  const apart = one(s, 1, { income: [pay(OTHER, OWNER, 20)] });
  assert.ok(pts(apart, "income") > 0 && pts(apart, "backing") > 0);
});

await check("USDG the agent's side sent to a payer is netted out of that payer's income", () => {
  const s = world([agent(1, OWNER)]);
  const full = one(s, 1, { income: [pay(CLIENT, OWNER, 20)] });
  const roundTrip = one(s, 1, { income: [pay(CLIENT, OWNER, 20)], transfers: [{ from: OWNER, to: CLIENT, amount: $(20), at: NOW - 3 * DAY }] });
  const partly = one(s, 1, { income: [pay(CLIENT, OWNER, 20)], transfers: [{ from: OWNER, to: CLIENT, amount: $(5), at: NOW - 3 * DAY }] });
  assert.equal(pts(roundTrip, "income"), 0);
  assert.equal(roundTrip.detail.distinctPayers, 0);
  assert.ok(pts(partly, "income") < pts(full, "income") && pts(partly, "income") > 0);
});

await check("funding sent from the agent's declared wallet counts as its side too", () => {
  const s = world([agent(1, OWNER)]);
  const r = one(s, 1, { income: [pay(CLIENT, OWNER, 20)], agentWallets: { 1: WALLET }, transfers: [{ from: WALLET, to: CLIENT, amount: $(20), at: NOW - 9 * DAY }] });
  assert.equal(pts(r, "income"), 0);
});

// a backed loan (another owner's aged root) repaid by the agent's owner
const backed = (id, usd, issuedDaysAgo, holdDays) => ({ agentId: 1, sponsorId: 2, era: "v2", id, principal: $(usd), fee: $(usd * 0.01),
  issuedAt: NOW - issuedDaysAgo * DAY, dueAt: NOW - (issuedDaysAgo - 30) * DAY, closedAt: NOW - (issuedDaysAgo - holdDays) * DAY, status: "repaid" });
const lender = () => [agent(1, OWNER, { sponsor: 2 }), agent(2, OTHER, { isRoot: true, enrolledAt: NOW - 400 * DAY })];

// five distinct clients paying 20.2 USDG each: at half weight (unknown wallets), 10.1 each, 50.5 in all: one loan's due
const clients = (n, usd, daysAgo = 15) => Array.from({ length: n }, (_, k) => pay(A(0x500 + k), OWNER, usd, daysAgo));

await check("a loan repaid from income earns more risk time than one repaid from the owner's pocket", () => {
  const s = world(lender(), [backed(501, 50, 20, 10)]);
  const opts = { income: clients(5, 20.2), repayers: { 501: OWNER } };
  const fromIncome = one(s, 1, opts);
  const fromPocket = one(s, 1, { ...opts, income: [] });
  assert.equal(fromIncome.detail.repaidFromIncome, 1);
  assert.equal(pts(fromIncome, "riskTime"), Math.round(pts(fromPocket, "riskTime") * (1 + W.components.riskTime.incomeRepaidBonus) * 10) / 10);
});

await check("one payment funds at most its own amount: two loans share it", () => {
  const s = world(lender(), [backed(601, 50, 20, 10), backed(602, 50, 19, 10)]);
  const r = one(s, 1, { income: clients(5, 20.2), repayers: { 601: OWNER, 602: OWNER } });
  assert.equal(r.detail.repaidFromIncome, 1); // 50.5 of weighted income covers one loan's 50.5 due, not two
  const small = one(world(lender(), [backed(603, 50, 20, 10)]), 1, { income: clients(1, 20.2), repayers: { 603: OWNER } });
  assert.equal(small.detail.repaidFromIncome, 0.2); // 10.1 of 50.5 due: a fifth of the loan
});

await check("audit F5: a loan's income is weighted and capped per payer, so one big (or recycled) payment can't fund it", () => {
  const s = world(lender(), [backed(611, 120, 20, 10)]);
  const r = one(s, 1, { income: [pay(CLIENT, OWNER, 121.2, 15)], repayers: { 611: OWNER } });
  assert.equal(r.detail.repaidFromIncome, 0.2, `repaidFromIncome ${r.detail.repaidFromIncome}`); // 20 of 121.2 (0.165), not 1
  // a payer with a strong record counts in full: the same five clients, scored 1000, fund the loan twice as fast
  const base = { links: { clusters: [] }, income: clients(5, 10.1), repayers: { 612: OWNER }, agentWallets: { 1: OWNER, 2: OTHER } };
  const s2 = world(lender(), [backed(612, 50, 20, 10)]);
  const unknown = buildInputs(s2, base).find((x) => x.agentId === 1).loans[0].incomeShare;
  const scored = buildInputs(s2, { ...base, payerScores: Object.fromEntries(clients(5, 1).map((p) => [p.payer, 1000])) }).find((x) => x.agentId === 1).loans[0].incomeShare;
  assert.ok(Math.abs(scored - 2 * unknown) < 1e-9 && unknown > 0, `${unknown} ${scored}`);
});

await check("audit F5: income is spent only on loans that count (not late, not self-backed)", () => {
  const late = { ...backed(621, 50, 20, 10), dueAt: NOW - 12 * DAY, closedAt: NOW - 10 * DAY }; // repaid after its due date
  const self = { ...backed(622, 50, 20, 9), sponsorId: 3 }; // backed by its owner's own root
  const good = backed(623, 50, 20, 11);
  const s = world([...lender(), agent(3, OWNER, { isRoot: true, enrolledAt: NOW - 400 * DAY })], [late, self, good]);
  const i = buildInputs(s, { links: { clusters: [] }, income: clients(5, 20.2, 15), repayers: { 621: OWNER, 622: OWNER, 623: OWNER }, agentWallets: { 1: OWNER, 2: OTHER, 3: null } }).find((x) => x.agentId === 1);
  assert.deepEqual(i.loans.map((l) => l.incomeShare), [0, 0, 1]);
});

await check("audit F3: a v1 loan with the same id as a funded v2 loan gets no income share", () => {
  // the same id on both pools, the same dates, and the v1 loan backed by someone else too (its FeeSplit names the root)
  const v2 = backed(701, 50, 20, 10);
  const v1 = { ...backed(701, 50, 20, 10), era: "v1", sponsorId: undefined };
  const s = { ...world(lender(), [v1, v2]), events: [{ kind: "FeeSplit", era: "v1", loanId: 701, sponsor: 2 }] };
  const i = buildInputs(s, { links: { clusters: [] }, income: clients(5, 20.2), repayers: { 701: OWNER }, agentWallets: { 1: OWNER, 2: OTHER } }).find((x) => x.agentId === 1);
  assert.deepEqual(i.loans.map((l) => [l.incomeShare]), [[0], [1]]);
});

await check("income arriving outside the loan, from the agent's own side, or a loan repaid by someone else, funds nothing", () => {
  const s = world(lender(), [backed(701, 50, 20, 10)]);
  const before = one(s, 1, { income: [pay(CLIENT, OWNER, 60, 25)], repayers: { 701: OWNER } }); // paid before the loan
  const self = one(s, 1, { income: [pay(OWNER, OWNER, 60, 15)], repayers: { 701: OWNER } }); // its own money
  const thirdParty = one(s, 1, { income: [pay(CLIENT, OWNER, 60, 15)], repayers: { 701: OTHER } }); // repaid by another wallet
  const unknown = one(s, 1, { income: [pay(CLIENT, OWNER, 60, 15)] }); // repayer not known
  for (const r of [before, self, thirdParty, unknown]) assert.equal(r.detail.repaidFromIncome, 0);
});

await check("a default spreads to agents linked through a declared wallet", () => {
  const s = world([agent(1, OWNER, { sponsor: 3 }), agent(2, OTHER, { defaulted: true }), agent(3, A(0xe), { isRoot: true, enrolledAt: NOW - 400 * DAY })],
    [{ agentId: 1, sponsorId: 3, era: "v2", id: 801, principal: $(50), issuedAt: NOW - 40 * DAY, dueAt: NOW - 10 * DAY, closedAt: NOW - 30 * DAY, status: "repaid" }]);
  assert.ok(one(s, 1).score > 0);
  const linked = one(s, 1, { agentWallets: { 1: WALLET, 2: WALLET } });
  assert.equal(linked.score, 0);
  assert.equal(linked.flags.ownerDefaulted, true);
});

await check("a payer's weight follows the best record of the agents it pays for, declared wallet included", () => {
  const snap = world([agent(1, OWNER), agent(2, OTHER)]);
  const i = buildInputs(snap, { income: [pay(WALLET, OWNER, 10)], agentWallets: { 1: OWNER, 2: WALLET }, payerScores: { [WALLET]: 400 } }).find((x) => x.agentId === 1);
  assert.equal(i.income[0].payerScore, 400);
});

await check("the engine refuses an income share over 1 and never depends on the order of income", () => {
  const base = { agentId: 1, now: NOW, recordStart: NOW - 60 * DAY, loans: [], income: [] };
  assert.throws(() => scoreV2({ ...base, loans: [{ principal: $(5), issuedAt: NOW - 10 * DAY, dueAt: NOW, closedAt: NOW - 5 * DAY, status: "repaid", backedByOthers: true, incomeShare: 1.5 }] }), /incomeShare/);
  const inc = Array.from({ length: 40 }, (_, i) => ({ payer: A(100 + (i % 7)), amount: 333_333 + i * 1_111, at: NOW - (i % 5) * DAY, payerScore: (i * 37) % 1000 }));
  assert.deepEqual(scoreV2({ ...base, income: inc }), scoreV2({ ...base, income: [...inc].reverse() }));
});

await check("audit F1: sending a defaulted agent to an honest owner harms nobody", () => {
  const HONEST = A(0x1001), ATTACKER = A(0x3003);
  const loans = [0, 1, 2, 3].map((k) => ({ ...backed(100 + k, 50, 80 - k * 16, 10), owner: HONEST }));
  const dead = { agentId: 9, sponsorId: 2, era: "v2", id: 990, owner: ATTACKER, principal: $(5), fee: 0, issuedAt: NOW - 50 * DAY, dueAt: NOW - 43 * DAY, closedAt: 0, status: "defaulted" };
  const agents = (holder) => [agent(1, HONEST, { sponsor: 2, delegatedIn: $(100), enrolledAt: NOW - 200 * DAY }), agent(2, OTHER, { isRoot: true, enrolledAt: NOW - 400 * DAY }), agent(9, holder, { defaulted: true })];
  const before = one(world(agents(ATTACKER), [...loans, dead]), 1);
  const after = one(world(agents(HONEST), [...loans, dead]), 1, { agentWallets: { 9: null } }); // the registry clears its wallet on transfer
  assert.ok(before.score > 0);
  assert.equal(after.score, before.score);
  assert.equal(after.flags.ownerDefaulted, false);
  // the defaulting wallet's own other agents are still zeroed
  const sibling = one(world([...agents(ATTACKER), agent(4, ATTACKER, { sponsor: 2 })], [...loans, dead, { ...backed(401, 50, 30, 10), agentId: 4, owner: ATTACKER }]), 4);
  assert.equal(sibling.score, 0);
  assert.equal(sibling.flags.ownerDefaulted, true);
});

await check("audit F2: agents pushed onto someone's address can't take a share of its income", () => {
  const s = world([agent(1, OWNER), ...[11, 12, 13].map((k) => agent(k, OWNER))]); // three agents sent to OWNER
  const alone = one(world([agent(1, OWNER)]), 1, { income: [pay(CLIENT, OWNER, 20)] });
  const pushed = one(s, 1, { income: [pay(CLIENT, OWNER, 20)], agentWallets: { 11: null, 12: null, 13: null } });
  assert.equal(pts(pushed, "income"), pts(alone, "income"));
});

await check("audit F4: income can't lift a thin record to the earned rung", () => {
  // a proven record just under 300 on its own, plus plenty of income: score over 300, rung stays 2 (proven)
  const loans = [0, 1, 2].map((k) => backed(800 + k, 50, 50 - k * 10, 9));
  const s = world(lender(), loans);
  const r = one(s, 1, { income: Array.from({ length: 10 }, (_, k) => pay(A(0x900 + k), OWNER, 20, 2)) });
  const record = r.score - pts(r, "income");
  assert.ok(r.score >= 300 && record < 300, `score ${r.score}, record ${record}`);
  assert.equal(r.rung, 2);
});

// ---------------------------------------------------------------- the index (resumable, incremental)
/** A tiny chain: signed payments and plain transfers of one token, declared wallets, receipts. Records every query. */
function fakeChain({ payments = [], transfers = [], wallets = {}, failWallets = new Set(), receipts = {} } = {}) {
  const calls = [];
  const hex = (a) => ethers.zeroPadValue(a, 32).toLowerCase();
  const inSet = (want, t) => want == null || (Array.isArray(want) ? want.map((x) => x.toLowerCase()) : [want.toLowerCase()]).includes(t.toLowerCase());
  const logs = [];
  payments.forEach((p, i) => { logs.push(auth("0xp" + i, 0, p.payer, p.block)); logs.push(xfer("0xp" + i, 1, p.payer, p.payTo, p.amount, p.block)); });
  transfers.forEach((x, i) => logs.push(xfer("0xt" + i, 0, x.from, x.to, x.amount, x.block)));
  const mc = new ethers.Interface(["function aggregate3((address target, bool allowFailure, bytes callData)[] calls) payable returns ((bool success, bytes returnData)[] returnData)"]);
  const reg = new ethers.Interface(["function getAgentWallet(uint256) view returns (address)"]);
  return {
    calls,
    async getLogs(f) {
      calls.push({ kind: f.topics[0] === TOPICS.AUTH_USED ? "auth" : "transfer", from: f.fromBlock, to: f.toBlock, t1: f.topics[1], t2: f.topics[2] });
      return logs.filter((l) => l.topics[0] === f.topics[0] && l.blockNumber >= f.fromBlock && l.blockNumber <= f.toBlock
        && inSet(f.topics[1], l.topics[1]) && (f.topics[2] === undefined || inSet(f.topics[2], l.topics[2])));
    },
    async getBlock(n) { return { timestamp: NOW - 1000 + n }; },
    async call(tx) {
      const [list] = mc.decodeFunctionData("aggregate3", tx.data);
      return mc.encodeFunctionResult("aggregate3", [list.map((c) => {
        const id = Number(reg.decodeFunctionData("getAgentWallet", c.callData)[0]);
        if (failWallets.has(id)) return [false, "0x"];
        return [true, reg.encodeFunctionResult("getAgentWallet", [wallets[id] || ethers.ZeroAddress])];
      })]);
    },
    async getTransactionReceipt(h) { return receipts[h] || null; },
  };
}
const W1 = A(0xe1), W2 = A(0xe2), P1 = A(0xf1), P2 = A(0xf2);
const snapOf = (agents, loans = [], events = []) => ({ meta: { timestamp: NOW }, agents, loans, events });
const opts = (snapshot, head, extra = {}) => ({ usdg: A(7), registry: A(8), pool: A(0x99), snapshot, fromBlock: 10, head, now: NOW, ...extra });

await check("index: a new payment wallet is backfilled on its own while the main cursor keeps moving", async () => {
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }, { payer: P2, payTo: W2, amount: 2_000_000, block: 60 }], wallets: { 1: W1, 2: W2 } });
  let r = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100));
  assert.equal(r.complete, true);
  assert.deepEqual(r.state.payments.map((p) => p.payTo), [W1.toLowerCase()]);
  chain.calls.length = 0;
  r = await updateIncome(chain, r.state, opts(snapOf([agent(1, W1), agent(2, W2)]), 120));
  const tr = chain.calls.filter((c) => c.kind === "transfer" && c.t2 && c.t2.length && ethers.zeroPadValue(W2, 32).toLowerCase() === String(c.t2[0]).toLowerCase() && c.t2.length === 1);
  assert.ok(tr.some((c) => c.from === 10 && c.to === 100), "the new wallet alone, from the start to the old cursor");
  assert.ok(!chain.calls.some((c) => c.kind === "auth" && c.from < 101 && c.to > 100 && c.from !== 10), "no full rescan");
  assert.ok(chain.calls.some((c) => c.kind === "auth" && c.from === 101 && c.to === 120), "the main cursor moved on");
  assert.deepEqual(r.state.payments.map((p) => p.payTo).sort(), [W1, W2].map((x) => x.toLowerCase()).sort());
  assert.equal(r.complete, true);
});

await check("index: a new payer backfills only its own netting transfers", async () => {
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }], transfers: [{ from: W1, to: P2, amount: 500_000, block: 20 }], wallets: { 1: W1 } });
  let r = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100));
  assert.equal(r.state.transfersTo, 100);
  chain.calls.length = 0;
  chain.logsAdd = null;
  const chain2 = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }, { payer: P2, payTo: W1, amount: 1_000_000, block: 110 }], transfers: [{ from: W1, to: P2, amount: 500_000, block: 20 }], wallets: { 1: W1 } });
  r = await updateIncome(chain2, r.state, opts(snapOf([agent(1, W1)]), 120));
  const nets = chain2.calls.filter((c) => c.kind === "transfer" && Array.isArray(c.t1) && c.t1.length && c.from === 1);
  assert.ok(nets.length && nets.every((c) => c.t2.length === 1 && c.t2[0].toLowerCase() === ethers.zeroPadValue(P2, 32).toLowerCase()), "only the new payer from the start");
  assert.deepEqual(r.state.transfers.map((x) => [x.from, x.to, x.amount]), [[W1.toLowerCase(), P2.toLowerCase(), "500000"]]);
  assert.equal(r.complete, true);
});

await check("index: agent-side wallets for netting include the clusters file's wallets", async () => {
  const X = A(0xabc);
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }], wallets: { 1: W1 } });
  await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100, { extraWallets: [X] }));
  assert.ok(chain.calls.some((c) => c.kind === "transfer" && Array.isArray(c.t1) && c.t1.map((t) => t.toLowerCase()).includes(ethers.zeroPadValue(X, 32).toLowerCase())));
});

await check("index: a failed wallet read keeps the wallet known before; an agent never read keeps the index incomplete", async () => {
  const chain = fakeChain({ wallets: { 1: W1 } });
  let r = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100));
  assert.equal(r.state.agentWallets[1], W1.toLowerCase());
  const failing = fakeChain({ wallets: { 1: W1, 2: W2 }, failWallets: new Set([1, 2]) });
  r = await updateIncome(failing, r.state, opts(snapOf([agent(1, W1), agent(2, W2)]), 100, { walletsEvery: 0 }));
  assert.equal(r.state.agentWallets[1], W1.toLowerCase(), "kept");
  assert.equal(2 in r.state.agentWallets, false);
  assert.equal(r.complete, false, "agent 2 was never read");
});

await check("index: the zero address is never a declared wallet, and a failed read is not a declaration", async () => {
  const chain = fakeChain({ wallets: { 1: ethers.ZeroAddress }, failWallets: new Set([2]) });
  const got = await readAgentWallets(chain, A(8), [1, 2]);
  assert.deepEqual([got[1], got[2]], [null, undefined]);
});

await check("index: log windows are split only when refused as too wide or slow, and never past the deadline", async () => {
  let n = 0;
  const slow = { async getLogs(f) { n++; if (f.toBlock - f.fromBlock > 10) throw Object.assign(new Error("could not coalesce"), { error: { message: "log query timed out" } }); return [{ blockNumber: f.fromBlock }]; } };
  const got = await getLogsAdaptive(slow, {}, 1, 40, { minSpan: 5 });
  assert.equal(got.length, 4);
  const broken = { async getLogs() { n++; throw new Error("execution reverted"); } };
  n = 0;
  await assert.rejects(() => getLogsAdaptive(broken, {}, 1, 1000, { minSpan: 5 }), /reverted/);
  assert.equal(n, 1, "no split on other errors");
  await assert.rejects(() => getLogsAdaptive(slow, {}, 1, 40, { deadline: Date.now() - 1 }), DeadlineError);
});

await check("index: a Repaid log counts only from the pool itself", async () => {
  const repaid = new ethers.Interface(["event Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer)"]);
  const log = (address) => ({ address, ...repaid.encodeEventLog("Repaid", [7, 1, 5, 0, W1]) });
  const chain = { async getTransactionReceipt(h) { return { logs: [log(h === "0xgood" ? A(0x99) : A(0x66))] }; } };
  const got = await readRepayers(chain, A(0x99), [{ loanId: 7, tx: "0xgood" }]);
  const fake = await readRepayers(chain, A(0x99), [{ loanId: 7, tx: "0xbad" }]);
  assert.deepEqual([got[7], fake[7]], [W1.toLowerCase(), null]);
});

await check("index: complete waits for the netting scan and the repayers", async () => {
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }], wallets: { 1: W1 } });
  const real = Date.now;
  let clock = real();
  Date.now = () => clock;
  const t0 = chain.getBlock.bind(chain);
  chain.getBlock = async (n) => { const r = await t0(n); clock += 10_000; return r; }; // time runs out as the payments chunk ends
  try {
    const r = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100, { deadline: clock + 5_000 }));
    assert.equal(r.state.paymentsTo, 100);
    assert.ok(r.state.transfersTo < 100);
    assert.equal(r.complete, false);
  } finally { Date.now = real; }
  const loan = { agentId: 1, era: "v2", id: 5, principal: 1, fee: 0, issuedAt: NOW - 1000 + 40, dueAt: NOW + DAY, closedAt: NOW - 1000 + 60, status: "repaid" };
  const r2 = await updateIncome(fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }], wallets: { 1: W1 } }), null,
    opts(snapOf([agent(1, W1)], [loan], [{ kind: "Repaid", era: "v2", loanId: 5, tx: "0xr" }]), 100, { maxRepayerReads: 0 }));
  assert.equal(r2.complete, false, "a wanted repayer not read yet");
});

await check("index: old payments leave after the retention; the size guard prunes, then refuses", async () => {
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 1_000_000, block: 50 }], wallets: { 1: W1 } });
  const kept = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100));
  assert.equal(kept.state.payments.length, 1);
  const later = await updateIncome(chain, kept.state, { ...opts(snapOf([agent(1, W1)]), 100), now: NOW + 400 * DAY });
  assert.equal(later.state.payments.length, 0, "past 365 days");
  await assert.rejects(() => updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100, { maxStateBytes: 50 })), /too large/);
});

await check("index: a new paying client every run never holds scores back; its income waits until its netting is read", async () => {
  // audit p07: a fresh payer each run used to restart the netting scan from block 1, so the index never completed
  let state = null;
  const pays = [];
  const head = (run) => 100 + run * 100;
  for (let run = 0; run < 5; run++) {
    pays.push({ payer: A(0x700 + run), payTo: W1, amount: 2_000_000, block: head(run) - 5 });
    const chain = fakeChain({ payments: pays, wallets: { 1: W1 } });
    const t0 = chain.getLogs.bind(chain);
    let fromStart = 0;
    chain.getLogs = async (f) => { if (f.topics[0] === TOPICS.TRANSFER && Array.isArray(f.topics[1]) && f.fromBlock === 1) fromStart++; return t0(f); };
    const r = await updateIncome(chain, state, opts(snapOf([agent(1, W1)]), head(run)));
    state = r.state;
    assert.equal(r.complete, true, `run ${run}: complete while the new payer's netting is read`);
    assert.equal(r.state.transfersTo, head(run), "the main netting cursor keeps up");
    if (run) assert.ok(fromStart >= 1, "only the new payer is read from the start");
    assert.deepEqual(r.pending.payers, [], "read within the run");
  }
  // when there is no time for the new payer's backfill, the index is still complete and that payer's income waits
  pays.push({ payer: A(0x7ff), payTo: W1, amount: 2_000_000, block: head(5) - 5 });
  const slow = fakeChain({ payments: pays, wallets: { 1: W1 } });
  const t1 = slow.getLogs.bind(slow);
  const real = Date.now;
  let clock = real();
  Date.now = () => clock;
  const fromW1 = (f) => Array.isArray(f.topics[1]) && f.topics[1].map((t) => t.toLowerCase()).includes(ethers.zeroPadValue(W1, 32).toLowerCase());
  slow.getLogs = async (f) => { const r = await t1(f); if (f.topics[0] === TOPICS.TRANSFER && fromW1(f) && f.fromBlock > 1) clock += 60_000; return r; }; // the main netting scan uses the time up
  try {
    const r = await updateIncome(slow, state, opts(snapOf([agent(1, W1)]), head(5), { deadline: clock + 30_000 }));
    assert.equal(r.complete, true);
    assert.deepEqual(r.pending.payers, [A(0x7ff).toLowerCase()]);
  } finally { Date.now = real; }
  const snap = world([agent(1, W1)]);
  const waiting = scoreAll(snap, { links: { clusters: [] }, income: [pay(P1, W1, 20)], agentWallets: { 1: W1 }, pending: { payers: [P1] } }).find((x) => x.agentId === 1);
  const read = scoreAll(snap, { links: { clusters: [] }, income: [pay(P1, W1, 20)], agentWallets: { 1: W1 } }).find((x) => x.agentId === 1);
  assert.equal(pts(waiting, "income"), 0);
  assert.ok(pts(read, "income") > 0);
});

await check("index: a payer under 1 USDG costs no netting scan and counts for nothing", async () => {
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 900_000, block: 50 }], wallets: { 1: W1 } });
  const r = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100));
  assert.deepEqual(r.state.payers, []);
  assert.equal(chain.calls.filter((c) => c.kind === "transfer" && Array.isArray(c.t1) && c.t1.length && c.t2 && c.t2.map((t) => t.toLowerCase()).includes(ethers.zeroPadValue(P1, 32).toLowerCase()) && c.from === 1).length, 0);
  const s = scoreAll(world([agent(1, W1)]), { links: { clusters: [] }, income: [pay(P1, W1, 0.9)], agentWallets: { 1: W1 } }).find((x) => x.agentId === 1);
  assert.equal(pts(s, "income"), 0);
});

await check("index (live stall): a payment window too slow for one run gets smaller until the index moves, then grows back", async () => {
  // a node that answers wide authorization windows only after the run's time is up, as seen from the Worker
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 2_000_000, block: 500 }, { payer: P2, payTo: W1, amount: 2_000_000, block: 1500 }], wallets: { 1: W1 } });
  const inner = chain.getLogs.bind(chain);
  chain.getLogs = async (f) => { if (f.topics[0] === TOPICS.AUTH_USED && f.toBlock - f.fromBlock > 300) await new Promise((res) => setTimeout(res, 40)); return inner(f); };
  const o = (extra) => opts(snapOf([agent(1, W1)]), 2000, { paymentsChunk: 1000, minPaymentsChunk: 10, ...extra });
  let r = await updateIncome(chain, null, o({ deadline: Date.now() + 20 }));
  assert.equal(r.state.paymentsTo, 9, "the first run reads no whole window");
  assert.equal(r.scan.stopped, "deadline");
  assert.equal(r.state.paymentsChunk, 250, "so the next window is 4x smaller");
  let runs = 1;
  while (r.state.paymentsTo < 2000 && runs < 20) { r = await updateIncome(chain, r.state, o({ deadline: Date.now() + 200 })); runs++; }
  assert.equal(r.state.paymentsTo, 2000, `the index reached the head in ${runs} runs`);
  assert.deepEqual(r.state.payments.map((p) => p.block), [500, 1500]);
  assert.ok(r.state.paymentsChunk > 250, "and the window grew back once windows went through");
});

await check("index (live stall): a node rate-limiting us stops the run without splitting, and the next run resumes", async () => {
  const chain = fakeChain({ payments: [{ payer: P1, payTo: W1, amount: 2_000_000, block: 50 }], wallets: { 1: W1 } });
  const inner = chain.getLogs.bind(chain);
  let limited = true, authCalls = 0;
  chain.getLogs = async (f) => { if (f.topics[0] === TOPICS.AUTH_USED) { authCalls++; if (limited) throw Object.assign(new Error("server response 429 Too Many Requests"), { error: { code: 429 } }); } return inner(f); };
  let r = await updateIncome(chain, null, opts(snapOf([agent(1, W1)]), 100));
  assert.equal(authCalls, 1, "a rate limit is not split into more calls");
  assert.equal(r.scan.stopped, "rate-limited");
  assert.equal(r.state.paymentsTo, 9);
  assert.equal(r.complete, false);
  limited = false;
  r = await updateIncome(chain, r.state, opts(snapOf([agent(1, W1)]), 100));
  assert.equal(r.state.paymentsTo, 100);
  assert.equal(r.scan.stopped, null);
  assert.deepEqual(r.state.payments.map((p) => p.payTo), [W1.toLowerCase()]);
});

await check("agents with no known owner stand alone: one can back another", () => {
  const s = world([agent(1, undefined, { sponsor: 2 }), agent(2, undefined, { isRoot: true, enrolledAt: NOW - 400 * DAY })], [backed(901, 50, 40, 10)]);
  assert.equal(one(s, 1, { agentWallets: {} }).detail.repaidByOthers, 1);
});

await check("a payer's weight comes from the record of the agent that declared it as its payment wallet (through scoreAll)", () => {
  // agent 2 has a real record and declared WALLET; WALLET pays agent 1: it weighs more than an unknown wallet paying the same
  const X = A(0xabc);
  const rich = [0, 1, 2, 3, 4].map((k) => ({ ...backed(950 + k, 200, 90 - k * 15, 12), agentId: 2, sponsorId: 3 }));
  const agents = [agent(1, OWNER), agent(2, OTHER, { sponsor: 3 }), agent(3, X, { isRoot: true, enrolledAt: NOW - 400 * DAY })];
  const known = one(world(agents, rich), 1, { income: [pay(WALLET, OWNER, 20)], agentWallets: { 1: OWNER, 2: WALLET, 3: X } });
  const stranger = one(world(agents, rich), 1, { income: [pay(A(0xdead), OWNER, 20)], agentWallets: { 1: OWNER, 2: WALLET, 3: X } });
  assert.ok(pts(known, "income") > pts(stranger, "income"), `${pts(known, "income")} vs ${pts(stranger, "income")}`);
});

console.log(`\n${passed} passed`);
