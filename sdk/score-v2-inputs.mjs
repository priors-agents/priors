// Builds Priors Score v2 inputs from public data: the site snapshot (priors.trade/api/snapshot: agents, loans,
// events), known links between agents and wallets (`links`: Priors' clusters list, not published) and x402 income read from the
// chain (sdk/x402-income.mjs: signed USDG payments to agent wallets from any facilitator, the payment wallet each
// agent declared in the ERC-8004 registry, transfers sent back to payers, and who repaid each loan).
// Pure: no network, no clock.
//
// Clusters. A loan counts toward the score only if its backer sits in a different cluster from the borrower, and
// income counts only from payers outside the agent's cluster. An agent's cluster joins its owner, the payment wallet
// it declared (agentWallet: that wallet signed to accept it, so it is under the same control) and every agent and
// wallet linked through them, plus the links of the clusters file. Funding-source clustering (wallets paid for by
// the same source) plugs in here later. Clusters shape the computation only: no output names them.
//
// Income. A payment counts for the agents that declared the paid wallet as their payment wallet (the registry sets
// it to the owner at registration, clears it when the agent changes hands, and changing it needs the wallet's
// signature), shared evenly between them: an agent pushed onto someone's address can't take a share of their income
// (2.0.4: and for an agent sold on Priors' market, as its seller declared it at the sale, for a while: below).
// Money an agent's cluster sent to a payer (before or after) is netted out of that payer's payments to it: USDG that
// goes back where it came from is not income. A loan that counts (backed by someone else, repaid on time by the
// agent's own wallets, since its last change of hands) is marked as repaid from income (`incomeShare`, 0..1) by the
// counted income that arrived during it, each payment weighted like income, capped per payer and loan, and spent
// once.
//
// Defaults. A default zeroes the other agents of the wallet that defaulted: the loan's owner when it was taken, and
// the defaulted agent's declared payment wallet. Never whoever holds its NFT today: sending a defaulted agent to
// someone can't harm them.
//
// Fails closed: a backer the snapshot doesn't know, or one enrolled for less than `backers.minAgeDays` when the loan
// was issued, counts as the agent's own money.
//
// A change of hands restarts the record: loans, age and recourse count from the first loan of the new owner. With
// weights 2.0.4 (`changeOfHands.keepAtMarketSale`), a change of hands that was a sale on Priors' agent market keeps it,
// as if no change of hands had happened (the owner's rule: an agent's score does not change because it was sold):
//   - which sales: the `sales` the data Worker reads from Priors' markets (AgentMarket's and AgentMarketV2's Sold, V2's
//     BidTaken), each with the payment wallet the agent declared at it (`wallet`). Every hop from the owner the loans
//     name to the next must be one of them, seller to buyer in turn; a gap in that chain is a plain transfer, and a
//     plain transfer restarts the record as before. v1 loans carry no owner: for them the last transfer that was no
//     such sale (`plainTransferAt`, else the last transfer, `ownerSince`) restarts it as before;
//   - a sale counts as a plain transfer, on either path, while its `wallet` is not read yet (fails closed), and when
//     its seller or that wallet was already in default at it (a loan of theirs past its defaultable time, marked or
//     not, or the declared wallet of such a loan's agent): the market refuses a seller the pool marked, and an unmarked
//     default can't be carried away to a fresh wallet either;
//   - the record goes on as it was counted: each loan judged against its owner's cluster when it was taken (the wallet
//     the agent declared at the sale stays in the seller's cluster: the registry clears it at the transfer, and a sale
//     must not unlink it; an agent the clusters file lists takes its listing to the buyer, so its seller's side is
//     built again as it was at the sale: `judgeOf`), its late repayments, recourse, child defaults, age and the rungs'
//     day counts. A default after
//     the sale is the new owner's: a default zeroes the wallet that owned the loan, so the seller's later defaults never
//     reach the agent and its new owner's never reach the seller;
//   - the income window goes on too: the wallet the agent declared at the sale stays the agent's for its income until
//     the window's length (income.windowDays) after the sale, its payments judged against the seller's side as it was
//     at the sale, netted and shared as they were, none from whoever owned the agent when paid after the sale (its own
//     agent), and the seller's loans keep the income bonus they earned from it (each loan draws only on what was paid
//     to its own owner's wallet: `route`). A payer's weight leaves out the agent it pays (`payerAgents`), so a payer
//     that came to own it weighs what it did. Payments to the wallet the new owner declares count from the
//     sale on, never one from before it (`incomeSince`), and a payment both reach counts once. The income index keeps
//     reading the wallet at each sale (sdk/x402-income.mjs `soldWallets`); backing is what is at risk behind the agent
//     now, as always.
//
// Own collateral (weights 2.0.1, `backers.ownCollateralRoots`): the stock vault's root (snapshot meta.stockVaultAgentId)
// counts as the borrower's own money too. The vault backs a line with the borrower's own stock tokens, which it seizes
// on a default: loans on them are no risk someone else took. Weights 2.0.2 add SeatVaultV5's roots ("seatVaultV5":
// meta.seatVaultV5AgentId, and meta.seatVaultV5RetiredAgentId when named): V5 sizes a line by the owner's own $PRIORS
// behind the agent and burns 75% of it on a default, so a bigger stake is no more risk someone else took. Fails closed:
// with "seatVaultV5" and no meta.seatVaultV5AgentId, no inputs are built.
import { scoreV2, payerWeight, repaidLate, keepsAtMarketSale, DEFAULT_WEIGHTS } from "./score-v2.mjs";

const lc = (a) => String(a || "").toLowerCase();
/** Whether a loan was repaid by the agent's own wallets: `r` is the one address that repaid, or the addresses that paid
 *  through AutoRepay (sdk/x402-income.mjs readRepayers), each of which must be one of `own`. */
export const repaidByOwn = (own, r) => { const all = [].concat(r ?? []); return all.length > 0 && all.every((a) => own.has(lc(a))); };
const ZERO = "0x0000000000000000000000000000000000000000";
const isAddr = (a) => { const x = lc(a).trim(); return x !== "" && x !== ZERO && x !== "null" && x !== "undefined"; }; // a usable wallet key
const DAY = 86400;
const USDG = 1e6;

/** A small union-find over string keys. */
function unionFind() {
  const parent = new Map();
  const find = (x) => {
    if (!parent.has(x)) parent.set(x, x);
    let r = x;
    while (parent.get(r) !== r) r = parent.get(r);
    while (parent.get(x) !== r) { const n = parent.get(x); parent.set(x, r); x = n; }
    return r;
  };
  const union = (a, b) => { const ra = find(a), rb = find(b); if (ra !== rb) parent.set(ra > rb ? ra : rb, ra > rb ? rb : ra); };
  return { find, union, keys: () => [...parent.keys()] };
}

/** The roots `weights` count as backers from day one besides the pool's own (`backers.dayOneRoots`, 2.0.3): "ethosRoot",
 *  the Ethos lane's root (meta.ethosRootAgentId, when named; without it, an ordinary backer, as before). */
export function dayOneRoots(snapshot, weights = DEFAULT_WEIGHTS) {
  const m = snapshot.meta || {}, keys = weights.backers.dayOneRoots || [], ids = [];
  if (keys.includes("ethosRoot") && Number(m.ethosRootAgentId) > 0) ids.push(Number(m.ethosRootAgentId));
  return new Set(ids);
}

/** The roots whose loans are the borrower's own money under `weights` (`backers.ownCollateralRoots`): "stockVault",
 *  the stock vault's root (meta.stockVaultAgentId, when named); "seatVaultV5" (2.0.2), V5's root (meta.seatVaultV5AgentId,
 *  required: throws without it) and the retired V5 root (meta.seatVaultV5RetiredAgentId, when named). */
export function ownCollateralRoots(snapshot, weights = DEFAULT_WEIGHTS) {
  const m = snapshot.meta || {}, keys = weights.backers.ownCollateralRoots || [], ids = [];
  if (keys.includes("stockVault") && Number(m.stockVaultAgentId) > 0) ids.push(Number(m.stockVaultAgentId));
  if (keys.includes("seatVaultV5")) {
    if (!(Number(m.seatVaultV5AgentId) > 0)) throw new Error(`score-v2 inputs: weights ${weights.version} count SeatVaultV5's root as the owner's own collateral: the snapshot must name it (meta.seatVaultV5AgentId)`);
    ids.push(Number(m.seatVaultV5AgentId));
    if (Number(m.seatVaultV5RetiredAgentId) > 0) ids.push(Number(m.seatVaultV5RetiredAgentId));
  }
  return new Set(ids);
}

/**
 * Clusters of agents and wallets. `agentWallets`: { [agentId]: address | null } (ERC-8004 getAgentWallet).
 * A cluster joins an agent's owner, its declared payment wallet and the links of the clusters file, transitively.
 * `declaredBy` maps a wallet to the agents that declared it as their payment wallet (income goes to them only);
 * `walletsOf` maps an agent to its own wallets (owner and declared wallet: who can repay "from its pocket").
 * `listed`: the agents the clusters file names (their listing goes with them when they change hands).
 */
export function makeClusters(snapshot, links = { clusters: [] }, agentWallets = {}) {
  const byId = new Map(snapshot.agents.map((a) => [Number(a.id), a]));
  const cluster = unionFind();
  const walletsOf = new Map(); // agentId -> [wallets]
  const declaredBy = new Map(); // wallet -> [agentIds that declared it]
  const push = (m, k, v) => { if (!m.has(k)) m.set(k, []); if (!m.get(k).includes(v)) m.get(k).push(v); };
  for (const a of snapshot.agents) {
    const id = Number(a.id);
    // an agent whose owner is unknown stands alone (never merged with other ownerless agents) and has no wallet
    const o = isAddr(a.owner) ? lc(a.owner) : `none:${id}`;
    if (isAddr(a.owner)) push(walletsOf, id, o);
    cluster.union(`a:${id}`, `w:${o}`);
    const aw = lc(agentWallets[id]);
    if (isAddr(aw)) {
      push(walletsOf, id, aw);
      push(declaredBy, aw, id);
      cluster.union(`w:${o}`, `w:${aw}`);
    }
  }
  (links.clusters || []).forEach((c, i) => {
    const hub = `l:${i}`;
    for (const id of c.agents || []) cluster.union(hub, `a:${Number(id)}`);
    for (const w of c.wallets || []) cluster.union(hub, `w:${lc(w)}`);
  });
  const listed = new Set((links.clusters || []).flatMap((c) => (c.agents || []).map(Number)));

  /** The cluster of an agent; `owner` is its owner when a loan was taken, if that differs from today's. */
  const clusterOfAgent = (id, owner) => {
    const a = byId.get(Number(id));
    if (!a) return `unknown:${id}`;
    if (owner && lc(owner) !== lc(a.owner) && !listed.has(Number(id))) return cluster.find(`w:${lc(owner)}`);
    return cluster.find(`a:${Number(id)}`);
  };
  const clusterOfWallet = (w) => cluster.find(`w:${lc(w)}`);
  return { byId, walletsOf, declaredBy, clusterOfAgent, clusterOfWallet, listed };
}

/**
 * When the agent's current owner took it over: the first loan after the last one taken under another owner. v1 loans
 * carry no owner, so a sale after v1 history is read from `transferredAt` (the agent's last registry transfer) when a
 * v1 loan came before it; a transfer before every v1 loan (its mint) moves nothing (own audit 2026-10-01).
 */
function ownershipChangedAt(agent, loans, now, transferredAt) {
  const byIssue = [...loans].sort((x, y) => Number(x.issuedAt) - Number(y.issuedAt));
  const withOwner = byIssue.filter((l) => l.owner);
  let lastOther = -1;
  withOwner.forEach((l, i) => { if (lc(l.owner) !== lc(agent.owner)) lastOther = i; });
  const next = withOwner[lastOther + 1];
  const fromLoans = lastOther < 0 ? 0 : next ? Number(next.issuedAt) : now; // not borrowed since the change: the record starts now
  const sold = Number(transferredAt) || 0;
  if (!(sold > 0) || !byIssue.some((l) => l.era === "v1" && Number(l.issuedAt) < sold)) return fromLoans;
  const after = byIssue.find((l) => Number(l.issuedAt) >= sold);
  return Math.max(fromLoans, after ? Number(after.issuedAt) : now);
}

/** The sales `buildInputs` takes, by agent: [{ seller, buyer, at, wallet }] in chain order (time, then block and log
 *  index). `wallet`: the payment wallet the agent declared at the sale, null for none, undefined while not read. */
function salesByAgent(sales) {
  const by = new Map();
  for (const x of sales || []) {
    const id = Number(x && x.agentId), at = Number(x && x.at);
    if (!(id > 0) || !Number.isFinite(at) || at <= 0 || !isAddr(x.seller) || !isAddr(x.buyer)) continue;
    if (!by.has(id)) by.set(id, []);
    const wallet = x.wallet === undefined ? undefined : isAddr(x.wallet) ? lc(x.wallet) : null;
    by.get(id).push({ seller: lc(x.seller), buyer: lc(x.buyer), at, wallet, block: Number(x.block) || 0, index: Number(x.index) || 0 });
  }
  for (const list of by.values()) list.sort((a, b) => a.at - b.at || a.block - b.block || a.index - b.index);
  return by;
}

/** The time of the last sale of a chain of Priors sales that took the agent from `from` to `to` between `after` and
 *  `until` (both included), every hop one of them and each one a sale that can keep the record (`keeps`: read, and no
 *  seller in default at it); null when there is none, or a gap (a plain transfer) in it. */
function saleChain(list, from, to, after, until, keeps) {
  const hops = (list || []).filter((s) => s.at >= after && s.at <= until);
  if (!hops.length || hops[0].seller !== from || hops[hops.length - 1].buyer !== to) return null;
  for (let i = 0; i < hops.length; i++) {
    if (i > 0 && hops[i].seller !== hops[i - 1].buyer) return null;
    if (!keeps(hops[i])) return null;
  }
  return hops[hops.length - 1].at;
}

/**
 * Weights 2.0.4: when the current owner's record starts (`since`, as ownershipChangedAt), when its own income starts
 * (`incomeSince`) and the sales whose sellers' income goes on (`hops`).
 * A sale can keep the record once the wallet the agent declared at it is read, and when neither its seller nor that
 * wallet was in default at it (`defaultAt`: wallet -> the earliest time it was); any other sale is a plain transfer.
 * The loans' owners, in issue order, give the changes of hands; each one is kept when a chain of such sales made it
 * (saleChain), and restarts the record at the new owner's first loan (or now) otherwise, exactly as ownershipChangedAt
 * does. v1 loans carry no owner: a transfer that was no sale (`plainAt`), or a sale that can't keep the record, after
 * one of them restarts it, as before. Income paid to the wallet the current owner declares counts from the sale it took
 * the agent in, the last one that can keep the record, when its buyer owns the agent now. `hops`: the sales that took
 * the agent to its current owner, oldest first: from the last sale back, each one that can keep the record, seller to
 * buyer in turn, none before `since` (the newest sale must be to the current owner, and a gap, or a sale that can't keep
 * it, ends them). Each one's seller's income, paid to the wallet the agent declared at it, goes on (buildInputs).
 */
function keptOwnership(agent, loans, now, allSales, plainAt, defaultAt) {
  const inDefault = (w, at) => !!w && defaultAt.has(w) && defaultAt.get(w) <= at;
  const keeps = (s) => s.wallet !== undefined && !inDefault(s.seller, s.at) && !inDefault(s.wallet, s.at);
  const sales = allSales.filter(keeps); // the last sale below is the last one that can keep the record
  const plainSale = allSales.reduce((m, s) => (keeps(s) ? m : Math.max(m, s.at)), 0); // the last one that can't
  const byIssue = [...loans].sort((x, y) => Number(x.issuedAt) - Number(y.issuedAt));
  const runs = []; // the owners the loans name, in turn: { owner, first, last } (issue times)
  for (const l of byIssue) {
    if (!l.owner) continue;
    const o = lc(l.owner), t = Number(l.issuedAt), r = runs[runs.length - 1];
    if (r && r.owner === o) r.last = t; else runs.push({ owner: o, first: t, last: t });
  }
  const cur = lc(agent.owner);
  const changes = runs.slice(1).map((r, i) => ({ from: runs[i].owner, to: r.owner, after: runs[i].last, until: r.first }));
  const tail = runs[runs.length - 1];
  if (tail && tail.owner !== cur) changes.push({ from: tail.owner, to: cur, after: tail.last, until: now }); // not borrowed since
  let since = 0, incomeSince = 0;
  for (const c of changes) {
    const soldAt = saleChain(allSales, c.from, c.to, c.after, c.until, keeps);
    if (soldAt != null) incomeSince = Math.max(incomeSince, soldAt); // a sale on the market: the record goes on
    else since = c.until; // a plain transfer: the record starts again at the new owner's first loan, or now
  }
  const plain = Math.max(plainAt > 0 ? plainAt : 0, plainSale);
  if (plain > 0 && byIssue.some((l) => l.era === "v1" && Number(l.issuedAt) < plain)) {
    const after = byIssue.find((l) => Number(l.issuedAt) >= plain);
    since = Math.max(since, after ? Number(after.issuedAt) : now);
  }
  const last = (sales || [])[(sales || []).length - 1];
  if (last && last.buyer === cur) incomeSince = Math.max(incomeSince, last.at);
  const hops = [];
  for (let i = allSales.length - 1, who = cur; i >= 0; i--) {
    const s = allSales[i];
    if (s.buyer !== who || !keeps(s) || s.at < since) break;
    hops.unshift(s);
    who = s.seller;
  }
  return { since, incomeSince, hops };
}

/** When each wallet was first in default: the earlier of a defaulted loan's defaultable time and its close, and the
 *  defaultable time of a loan still open past it (a loss, marked or not: markDefault can take it from then on), for
 *  the loan's owner when it was taken, and for the declared payment wallet of a defaulted agent or of an agent with
 *  such a loan (the agent's earliest; 0 when the record gives no time, so it counts as in default before any sale). */
function defaultTimes(snapshot, agentWallets, now) {
  const at = new Map(), of = new Map();
  const when = (l) => {
    const t = [Number(l.defaultableAt), Number(l.closedAt)].filter((x) => Number.isFinite(x) && x > 0);
    return t.length ? Math.min(...t) : Number(l.dueAt) > 0 ? Number(l.dueAt) : 0;
  };
  const note = (w, t) => { if (isAddr(w) && !(at.get(lc(w)) <= t)) at.set(lc(w), t); };
  for (const l of snapshot.loans || []) {
    const unmarked = l.status === "active" && Number(l.defaultableAt) > 0 && Number(l.defaultableAt) <= now;
    if (l.status !== "defaulted" && !unmarked) continue;
    const t = unmarked ? Number(l.defaultableAt) : when(l);
    note(l.owner, t);
    const id = Number(l.agentId);
    if (!(of.get(id) <= t)) of.set(id, t);
  }
  for (const a of snapshot.agents) if (a.defaulted || of.has(Number(a.id))) note(agentWallets[a.id], of.get(Number(a.id)) ?? 0);
  return at;
}

/**
 * Inputs for every agent in the snapshot.
 *   income        [{ payer, payTo, amount, at }]  signed USDG payments (amount: atomic USDG, number or string)
 *   agentWallets  { [agentId]: address | null }    declared payment wallets (ERC-8004 getAgentWallet); income is
 *                                                  matched on these only
 *   transfers     [{ from, to, amount, at }]       USDG sent from agent-side wallets to payers (netted out)
 *   repayers      { [loanId]: address | [address] } who repaid each v2 loan (Repaid.payer; for a repayment
 *                                                  through AutoRepay, the address or addresses that paid through it:
 *                                                  all of them must be the agent's own); v2 loan ids only, never
 *                                                  applied to a v1 loan with the same id
 *   payerScores   { [address]: score }             a payer's own v2 score (scoreAll fills it)
 *   payerAgents   { [address]: { [agentId]: score } } 2.0.4: the score of each agent a payer owns or declared (scoreAll
 *                                                  fills it): a payment weighs its payer by the best of them other than
 *                                                  the agent it pays. Absent: payerScores
 *   backerOwnerSince { [agentId]: seconds }        the last registry transfer of each backer id (sdk/x402-income.mjs
 *                                                  updateBackerTenure): a backer's 30 days count from then when it is
 *                                                  later than its enrolment. Absent: from its enrolment.
 *   ownerSince    { [agentId]: seconds }           the last registry transfer of an agent id (same reader): a sale
 *                                                  after its v1 loans restarts its record, as v2 loans' owners show
 *                                                  a sale after v2 loans. Absent: from the loans alone.
 *   pending       { payers: [...], wallets: [...] } netting still being read (sdk/x402-income.mjs): payments from
 *                                                  those payers, or to a cluster holding one of those wallets, wait
 *   sales         [{ agentId, seller, buyer, at, wallet, block?, index? }] the sales on Priors' agent market (the
 *                                                  data Worker's read of AgentMarket's and AgentMarketV2's Sold and V2's
 *                                                  BidTaken; never a price), `wallet` the payment wallet the agent
 *                                                  declared at the sale (getAgentWallet at the block before it; null for
 *                                                  none; absent while not read: that sale keeps nothing yet; payments to
 *                                                  it count for the agent until the income window's length after the
 *                                                  sale, so `income` must hold them: x402-income.mjs `soldWallets`): read
 *                                                  by weights 2.0.4 (`changeOfHands`), unused before. Absent: no sale is
 *                                                  known, and every change of hands restarts
 *   plainTransferAt { [agentId]: seconds }         2.0.4, agents with v1 loans: the last registry transfer since pool
 *                                                  v2's launch that was no sale on the market (0: none). Absent for an
 *                                                  agent: its last transfer (`ownerSince`), as before
 */
export function buildInputs(snapshot, { links, income = [], agentWallets = {}, transfers = [], repayers = {}, payerScores = {}, payerAgents = null, pending = {}, backerOwnerSince = {}, ownerSince = {}, sales, plainTransferAt = {}, now, weights = DEFAULT_WEIGHTS } = {}) {
  const t = Number(now ?? snapshot.meta?.timestamp);
  if (!Number.isFinite(t) || t <= 0) throw new TypeError("score-v2 inputs: pass `now` (or a snapshot with meta.timestamp)");
  // 2.0.4: a change of hands by a sale on Priors' market keeps the record (keptOwnership), unless the sale isn't read yet
  // or its seller was in default at it (defaultTimes). The payment wallet the agent declared at a sale stays in its
  // seller's cluster: the registry clears it at the transfer, and the seller's loans the sale carries are judged against
  // the cluster they were taken in (the owner and that wallet), so a sale, to someone else or to one's own second
  // wallet, never unlinks them
  const keeps = keepsAtMarketSale(weights);
  const soldBy = keeps ? salesByAgent(sales) : null;
  const saleLinks = keeps ? [...soldBy.values()].flat().filter((s) => isAddr(s.wallet)).map((s) => ({ wallets: [s.seller, s.wallet] })) : [];
  const linksIn = saleLinks.length ? { ...links, clusters: [...((links && links.clusters) || []), ...saleLinks] } : links;
  const K = makeClusters(snapshot, linksIn, agentWallets);
  const minBackerAge = weights.backers.minAgeDays * DAY;
  // the pool's treasury (and treasury v5, once the snapshot names it: a line moved there is the treasury's as before)
  // and seat vaults (V3, and the growth vault V4) count as backers from day one (public ids in the snapshot's meta)
  const protocolBackers = new Set([snapshot.meta?.treasuryAgentId, snapshot.meta?.treasuryV5AgentId, snapshot.meta?.seatVaultAgentId, snapshot.meta?.seatVaultV4AgentId, snapshot.meta?.archive?.treasuryAgentId].filter((x) => x != null).map(Number));
  // weights 2.0.3 add the Ethos lane's root (dayOneRoots): Priors' own, as the treasury is
  for (const id of dayOneRoots(snapshot, weights)) protocolBackers.add(id);
  // roots that lend against the borrower's own collateral: never someone else's risk
  const ownRoots = ownCollateralRoots(snapshot, weights);
  // v1 loans predate the loan's own sponsorId: their backer is in the FeeSplit event of the repayment
  const v1Backer = new Map();
  for (const e of snapshot.events || []) if (e.kind === "FeeSplit" && e.era === "v1") v1Backer.set(Number(e.loanId), Number(e.sponsor));

  // a loan the snapshot can't describe (missing or negative numbers) is left out: it counts for nothing, and it can't
  // stop every other agent from being scored
  const fine = (v) => Number.isFinite(Number(v)) && Number(v) >= 0 && v !== null && v !== "";
  const readable = (l) => fine(l.principal) && fine(l.issuedAt) && fine(l.dueAt) && (l.status !== "repaid" || fine(l.closedAt));
  const loansBy = new Map();
  for (const l of snapshot.loans || []) {
    if (!readable(l)) continue;
    if (!loansBy.has(l.agentId)) loansBy.set(l.agentId, []);
    loansBy.get(l.agentId).push(l);
  }

  // `C`: the clusters `borrowerCluster` is of (2.0.4: a listed agent's clusters as at a sale, below), K by default
  const backerCounts = (backerId, issuedAt, borrowerCluster, C = K) => {
    const b = K.byId.get(Number(backerId));
    if (!b || !(Number(backerId) > 0)) return false;               // unknown backer: fail closed
    if (ownRoots.has(Number(backerId))) return false;              // the borrower's own collateral
    if (C.clusterOfAgent(backerId) === borrowerCluster) return false;
    if (protocolBackers.has(Number(backerId))) return true;
    // its age counts from when its current owner took the id, if later than its enrolment: a bought aged id is a new
    // backer (private report GHSA-6f8j). `backerOwnerSince`: id -> the last registry transfer of that id, in seconds.
    const since = Math.max(Number(b.enrolledAt) || 0, Number(backerOwnerSince?.[Number(backerId)]) || 0);
    return Number(b.enrolledAt) > 0 && Number(issuedAt) - since >= minBackerAge;
  };

  // a default zeroes the other agents of the wallet that defaulted: the defaulted loan's owner when it was taken (v2
  // loans record it) and the defaulted agent's declared payment wallet (the registry clears it when the NFT moves, so
  // it is its current owner's own, signed choice). Never whoever holds a defaulted NFT: anyone can send one to anyone.
  // A v1 default (no owner recorded) zeroes only the agent itself.
  const defaultedWallets = new Set();
  for (const l of snapshot.loans || []) if (l.status === "defaulted" && isAddr(l.owner)) defaultedWallets.add(lc(l.owner));
  for (const a of snapshot.agents) if (a.defaulted && isAddr(agentWallets[a.id])) defaultedWallets.add(lc(agentWallets[a.id]));
  const defaultAt = keeps ? defaultTimes(snapshot, agentWallets, t) : null; // 2.0.4: who was in default when
  // 2.0.4: each agent's record across sales (keptOwnership), read before the income: a sold agent's seller's income goes
  // on for a while (`carried` below)
  const keptOf = new Map();
  if (keeps) {
    for (const a of snapshot.agents) {
      const id = Number(a.id);
      const plainAt = Object.prototype.hasOwnProperty.call(plainTransferAt || {}, id) ? Number(plainTransferAt[id]) || 0 : Number(ownerSince?.[id]) || 0;
      keptOf.set(id, keptOwnership(a, loansBy.get(a.id) || [], t, soldBy.get(id) || [], plainAt, defaultAt));
    }
  }
  // 2.0.4: the wallet the agent declared at each sale that took it to its current owner (keptOwnership's hops) stays its
  // own for its income, from its seller's start (the sale before, else the record's) to the income window's length
  // after the sale: payments to it count for the agent as they did, netted, shared and capped as any payment. Each is a
  // `route`: hop i is its seller's, and hops.length the current owner's (the wallet it declares, from incomeSince on)
  const carryS = weights.components.income.windowDays * DAY;
  const carried = new Map(); // wallet -> [{ id, route, from, until }]
  for (const [id, k] of keptOf) {
    k.hops.forEach((h, i) => {
      if (!isAddr(h.wallet)) return;
      if (!carried.has(h.wallet)) carried.set(h.wallet, []);
      carried.get(h.wallet).push({ id, route: i, from: i ? k.hops[i - 1].at : 0, until: h.at + carryS });
    });
  }
  // 2.0.4: whom each route is judged against (its payers, its netting, and for a listed agent its loans' backers): the
  // agent's cluster as it was the second before the sale that ended the route, and its cluster now for the current
  // owner's route: `{ C, self }`, the clusters and the agent's cluster in them. That is its seller's cluster (the wallet
  // at the sale stays in it: saleLinks), but for an agent the clusters file lists: its listing goes with it to the buyer
  // (makeClusters `listed`), so its cluster as at each sale is built again, the agent owned by the seller and declaring
  // the wallet it declared then: the wallets the file joins with it stay its own on the seller's side of the sale
  const routesOf = new Map(); // agentId -> [{ C, self }] by route
  for (const [id, k] of keptOf) {
    if (!k.hops.length) continue;
    const routes = k.hops.map((h) => {
      if (!K.listed.has(id)) return { C: K, self: K.clusterOfWallet(h.seller) };
      const asAt = { ...snapshot, agents: snapshot.agents.map((a) => (Number(a.id) === id ? { ...a, owner: h.seller } : a)) };
      const C = makeClusters(asAt, linksIn, { ...agentWallets, [id]: h.wallet });
      return { C, self: C.clusterOfAgent(id) };
    });
    routes.push({ C: K, self: K.clusterOfAgent(id) });
    routesOf.set(id, routes);
  }
  const judgeOf = (id, route) => { const r = routesOf.get(id); return r ? r[route] : { C: K, self: K.clusterOfAgent(id) }; };
  /** The route of the owner that held agent `id` at `at`: the sales that took it to its current owner made before then */
  const ownerRoute = (id, at) => (keptOf.get(id)?.hops || []).filter((h) => h.at <= at).length;

  // ---- income: payments to declared payment wallets, netted per (cluster, payer) against what the cluster sent back
  // income whose netting is still being read waits (fails closed): from a payer not yet read back, or to a cluster
  // holding a wallet not yet read
  const waitPayers = new Set((pending.payers || []).map(lc));
  const waitClusters = new Set((pending.wallets || []).map((w) => K.clusterOfWallet(w)));
  const pay = income
    .map((p) => ({ payer: lc(p.payer), payTo: lc(p.payTo), amount: Number(p.amount), at: Number(p.at) }))
    .filter((p) => (K.declaredBy.has(p.payTo) || carried.has(p.payTo)) && Number.isFinite(p.amount) && p.amount > 0 && Number.isFinite(p.at)
      && !waitPayers.has(p.payer) && !waitClusters.has(K.clusterOfWallet(p.payTo)));
  const pairKey = (c, payer) => c + "|" + payer;
  // the share of a payer's payments into a cluster of `C` that the cluster did not send back to it (per clusters, once)
  const netters = new Map();
  const netRatio = (C, payTo, payer) => {
    if (!netters.has(C)) {
      const inBy = new Map(), backBy = new Map();
      for (const p of pay) {
        const k = pairKey(C.clusterOfWallet(p.payTo), p.payer);
        inBy.set(k, (inBy.get(k) || 0) + p.amount);
      }
      for (const x of transfers) {
        const amount = Number(x.amount);
        if (!Number.isFinite(amount) || amount <= 0) continue;
        const k = pairKey(C.clusterOfWallet(x.from), lc(x.to));
        if (inBy.has(k)) backBy.set(k, (backBy.get(k) || 0) + amount);
      }
      netters.set(C, (k) => { const i = inBy.get(k) || 0; return i > 0 ? Math.max(0, i - (backBy.get(k) || 0)) / i : 0; });
    }
    return netters.get(C)(pairKey(C.clusterOfWallet(payTo), payer));
  };
  // a payer's own score: the best among the agents it owns or declared. 2.0.4 (`payerAgents`): other than the agent it
  // pays, so a payer that came to own it (its buyer, or a wash sale's second wallet) weighs what it weighed before. Before
  // 2.0.4 a payer that owns the agent it pays is in its cluster, never counted, so there it is the same either way
  const perPayee = keeps && !!payerAgents && typeof payerAgents === "object";
  const walletScore = (w, id) => {
    if (!perPayee) return payerScores[w];
    let best;
    for (const [a, sc] of Object.entries(payerAgents[w] || {})) if (Number(a) !== id) best = Math.max(best ?? 0, Number(sc));
    return best;
  };
  /** The weight's score of payer `w` paying agent `id` */
  const scoreOf = (w, id) => (perPayee ? walletScore(w, id) : payerScores[w]);
  // per agent: its share of each counted payment. A payment counts for the agents that declared the wallet (2.0.4: from
  // the sale that took each to its current owner) and for those whose seller had declared it at a sale (carried), each
  // once, on its latest route, shared evenly between them; judged against that route's cluster (judgeOf). A payment on a
  // seller's route made after its sale never counts from whoever owned the agent when it was made: that is the owner
  // paying its own agent, which the second before the next sale did not count either
  const incomeOf = new Map();
  for (const p of pay) {
    const to = [];
    for (const id of K.declaredBy.get(p.payTo) || []) {
      const k = keptOf.get(id);
      if (!k || p.at >= k.incomeSince) to.push({ id, route: k ? k.hops.length : 0 });
    }
    for (const c of carried.get(p.payTo) || []) {
      if (p.at < c.from || p.at > c.until) continue;
      const x = to.find((y) => y.id === c.id);
      if (!x) to.push({ id: c.id, route: c.route });
      else x.route = Math.max(x.route, c.route);
    }
    for (const x of to) {
      const J = judgeOf(x.id, x.route);
      if (J.C.clusterOfWallet(p.payer) === J.self) continue; // paying itself: never income
      const o = routesOf.has(x.id) ? ownerRoute(x.id, p.at) : x.route;
      if (o > x.route) { const H = judgeOf(x.id, o); if (H.C.clusterOfWallet(p.payer) === H.self) continue; }
      const r = netRatio(J.C, p.payTo, p.payer);
      if (r <= 0) continue;
      if (!incomeOf.has(x.id)) incomeOf.set(x.id, []);
      incomeOf.get(x.id).push({ payer: p.payer, amount: (p.amount * r) / to.length, at: p.at, route: x.route });
    }
  }
  const capPerPayer = weights.components.income.perPayerCapUsdg * USDG;

  return snapshot.agents.map((a) => {
    const id = Number(a.id);
    const mine = K.clusterOfAgent(id);
    const raw = loansBy.get(a.id) || [];
    const kept = keeps ? keptOf.get(id) : null;
    const since = kept ? kept.since : ownershipChangedAt(a, raw, t, ownerSince?.[id]);
    const inc = (incomeOf.get(id) || []).sort((x, y) => x.at - y.at || (x.payer < y.payer ? -1 : x.payer > y.payer ? 1 : 0) || x.amount - y.amount);
    const hops = kept ? kept.hops : [];
    const routeOf = (l) => { const k = hops.findIndex((h) => Number(l.issuedAt) < h.at); return k < 0 ? hops.length : k; };

    // 2.0.4: a loan of an agent the clusters file lists is judged against its cluster as at the sale that ended its
    // owner's time (judgeOf): the listing goes with the agent, and its seller's own backers must stay its own
    const asAtSale = routesOf.has(id) && K.listed.has(id);
    const loans = raw.map((l) => {
      const backer = l.era === "v1" ? v1Backer.get(Number(l.id)) : l.sponsorId;
      const J = asAtSale ? judgeOf(id, routeOf(l)) : null;
      const borrowerCluster = J ? J.self : K.clusterOfAgent(id, l.owner);
      return { principal: l.principal, issuedAt: l.issuedAt, dueAt: l.dueAt, closedAt: l.closedAt, status: l.status,
        backedByOthers: backer != null && backerCounts(backer, l.issuedAt, borrowerCluster, J ? J.C : K), incomeShare: 0 };
    });

    // loans repaid from income: only loans that count (v2, backed by someone else, repaid on time by the agent's own
    // wallets, since its last change of hands), funded by counted income that arrived during the loan, oldest first.
    // Income is weighted by its payer's record like the income component, capped per payer and loan, spent once.
    // 2.0.4: a loan of a seller (issued before a sale the record went on across, `hops`) is its seller's: repaid by that
    // seller or the wallet the agent declared at the sale, and funded only by what was paid to that wallet (its route),
    // as the seller earned it; the current owner's loans by the current owner's own
    const own = new Set(K.walletsOf.get(id) || []);
    const ownOf = (route) => (route < hops.length ? new Set([hops[route].seller, hops[route].wallet].filter(isAddr)) : own);
    const left = inc.map((p) => p.amount * payerWeight(scoreOf(p.payer, id) ?? null, weights));
    const order = raw.map((_, i) => i).filter((i) => {
      const l = raw[i];
      return l.era !== "v1" && l.status === "repaid" && loans[i].backedByOthers && !repaidLate(l.closedAt, l.dueAt, weights)
        && Number(l.issuedAt) >= since && repaidByOwn(ownOf(routeOf(l)), repayers[l.id]);
    }).sort((x, y) => Number(raw[x].closedAt) - Number(raw[y].closedAt) || Number(raw[x].id) - Number(raw[y].id));
    for (const i of order) {
      const l = raw[i], route = routeOf(l);
      const due = Number(l.principal) + Number(l.fee || 0);
      let need = due;
      const fromPayer = new Map();
      for (let j = 0; j < inc.length && need > 0; j++) {
        if (inc[j].at < Number(l.issuedAt) || inc[j].at > Number(l.closedAt) || left[j] <= 0) continue;
        if (inc[j].route !== route) continue; // 2.0.4: paid to another owner's wallet
        const room = capPerPayer - (fromPayer.get(inc[j].payer) || 0);
        if (room <= 0) continue;
        const take = Math.min(left[j], need, room);
        left[j] -= take; need -= take;
        fromPayer.set(inc[j].payer, (fromPayer.get(inc[j].payer) || 0) + take);
      }
      if (due > 0 && need < due) loans[i].incomeShare = Math.min(1, (due - need) / due);
    }
    const first = raw.reduce((m, l) => Math.min(m, Number(l.issuedAt) || Infinity), Infinity);

    // backing by others now: delegation from a sponsor in another cluster, held to the same backer rule
    const backingByOthers = backerCounts(a.sponsor, t, mine) ? Number(a.delegatedIn || 0) : 0;
    const aw = agentWallets[id];

    return {
      agentId: a.id, now: t, defaulted: !!a.defaulted,
      ownerDefaulted: !a.defaulted && (defaultedWallets.has(lc(a.owner)) || (isAddr(aw) && defaultedWallets.has(lc(aw)))),
      recordStart: Number.isFinite(first) ? first : null,
      ownershipChangedAt: since,
      // 2.0.4: its current owner took it by a sale on Priors' market that kept its record (keptOwnership's hops), so a
      // restart the score shows (ownershipChangedAt) came before, with an earlier owner
      ...(hops.length ? { keptSale: true } : {}),
      childrenDefaulted: a.childrenDefaulted || 0, recourseHonored: a.recourseHonored || 0,
      backingByOthers, loans,
      income: inc.map((p) => ({ payer: p.payer, amount: p.amount, at: p.at, payerScore: scoreOf(p.payer, id) })),
    };
  });
}

/** Scores for every agent; income payers that are themselves scored agents get their weight from a first pass. */
export function scoreAll(snapshot, opts = {}) {
  const first = buildInputs(snapshot, opts).map((i) => scoreV2(i, opts.weights));
  const byId = new Map(snapshot.agents.map((a) => [Number(a.id), a]));
  const payerScores = {}, payerAgents = {};
  for (const s of first) {
    const a = byId.get(Number(s.agentId));
    if (!a) continue;
    // a wallet pays with the best record among the agents it belongs to (as owner or declared payment wallet; 2.0.4:
    // other than the one it pays, payerAgents)
    for (const w of [a.owner, (opts.agentWallets || {})[a.id]]) {
      if (!isAddr(w)) continue;
      payerScores[lc(w)] = Math.max(payerScores[lc(w)] ?? 0, s.score);
      (payerAgents[lc(w)] ||= {})[Number(s.agentId)] = s.score;
    }
  }
  return buildInputs(snapshot, { ...opts, payerScores, payerAgents }).map((i) => scoreV2(i, opts.weights));
}
