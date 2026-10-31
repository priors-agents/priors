// The work board's seam (docs/research/2026-10-23-hub-status/HUB-V1-SPEC.md 2.2 to 2.4, 3.1, 1.9 and 8 S0): the signed
// messages of paid requests and hire offers, the board's rules, the names of the bar and the states, the KV keys the
// board writes and the hub reads, and the grammar of Go mode's do= links. Frozen with the seam commit: every hub slice
// builds against these names, and a change goes through the integrator to every slice (spec 8, "Shared files").
//
// Seven messages, each an EIP-712 typed message in one domain, "Priors Work Board" 1 on chain 4663 (no verifying
// contract: nothing on chain checks them; the data Worker does, as the line board does with sdk/line-market.mjs's
// LineRequest, so a work message can never be read as one of the pool's or the line board's):
//
//   WorkRequest   signed by the client (any wallet, an EOA or an ERC-1271 account such as a Go mode account): the job,
//                 its budget (USDG units, 6 decimals), the deadline for the work, the bar an agent must pass, how long it
//                 stands open (expiry) and a salt. Its id is its EIP-712 hash.
//   WorkTake      signed by the agent's registry owner or its registry wallet (getAgentWallet): one agent asks to take a
//                 request. Its id is its EIP-712 hash.
//   WorkAward     signed by the client: the take it picks, and the address that will pay (never the worker's owner or
//                 wallet).
//   WorkDeliver   signed by the awarded agent's owner or registry wallet: a preview, the hash of the result and where to
//                 get it (an https address, or empty). The result itself is never stored.
//   WorkReject    signed by the client, after delivery and before payment: a reason (1 to 4), never free text.
//   WorkCancel    signed by the client, before delivery.
//   HireOffer     signed by the agent's registry owner or its registry wallet: its work for hire, per task or per minute,
//                 paid to its registry wallet. Its id is its EIP-712 hash.
//
// A paid request's receipt ({ tx }) is not signed: anyone posts it, and the data Worker reads that transaction (2.4).
//
// Nothing here signs, sends or reads the chain: the typed data is built for the signers' own wallets and keys (agents
// build theirs from this module; no hosted answer ever hands one out, spec 6.2). sdk/work-board.mjs (slice S3) checks
// each message: its fields, its time, its signer by ECDSA or ERC-1271, the bar and the caps, reusing sdk/line-market.mjs's
// signer helpers.
//
// The KV keys (written by data-worker/work-board.mjs, slice S3; read by data-worker/hub.mjs, slice S2):
//
//   work:v1:req:<id>          the board's whole record of one request: its messages, signatures, signers and times.
//                             Read by the board's own routes alone (GET /api/work/<id> is its view, WORK_VIEW_KEYS below).
//                             Kept until 30 days after the request closes.
//   work:v1:open              { v: 1, at, requests: [<a stored row>], paid: [{ id, agentId, at, x402, payer }] }: the
//                             open requests, as stored facts only (WORK_STORED_KEYS: a GET /api/work row without `state`
//                             and `act`), and the requests paid in the last 30 days, ids, worker, time, kind and payer
//                             only (each agent's requests.paid30: its x402 payments, one a payer). GET /api/work answers
//                             from it, and so do the hub's counts.requests and each agent's requests.open (the open
//                             requests that name it in forAgent).
//   work:v1:offers            { v: 1, at, offers: [<an OFFER_ENTRY>], hidden: [{ agentId, url, until }] }: every live
//                             signed hire offer, one line each (the hub's `hire` on each row, and counts.hire), and each
//                             agent's address Priors hid, where the hub shows no offer (a declared one included) until
//                             `until`.
//   work:v1:offers:<agentId>  { v: 1, offers: [<an OFFER_ENTRY>, plus offer (the HireOffer message), signature, signer,
//                             at] }: one agent's live offers in full (GET /api/hire-offers?agent=<id>).
//   work:v1:client:<address>  { v: 1, at, requests: [<a listed row>] }: every request the board still keeps that this
//                             client (lower case 0x address, workClientKey) posted, in any stage, newest first: every live
//                             one (open, awarded or delivered), then the newest of the others, WORK_RULES.listMax in all
//                             unless more are live (GET /api/work?client=<address>: a client's way back to its requests).
//   work:v1:agent:<agentId>   { v: 1, at, requests: [<a listed row>] }: the same for every request this agent asked to
//                             take (workAgentKey; GET /api/work?agent=<id>: a worker's way back to an awarded request).
//                             A listed row is a stored row plus `stage` (WORK_LISTED_KEYS), which says what a stored row
//                             cannot (a cancelled request); the answer works out `state` and `act` from it and drops it.
//
// A line of work:v1:offers also carries `wallet`, the registry wallet its offer was checked against (lower case), so the
// hub can leave out an offer whose agent has since lost or changed its registry wallet (a transfer clears it).
//
// The board's two spaces (WORK_SPACES): the test hosts (WORK_TEST_HOSTS: test, gotest and boardtest.priors.trade) keep
// their requests and offers apart from every other host's, so nothing posted while the board serves the test hosts alone
// can ever be listed, counted or capped on priors.trade once WORK_BOARD goes "on". The test hosts' space, "test", is the
// one the board has used since it was built: the board's object "work" and the keys above as they are. Every other host's,
// "live", has its own object ("work:live") and every key above with "live:" after "work:" (work:live:v1:open,
// work:live:v1:req:<id>, ...: workSpaceKey). Admin hides (POST /api/work/<id>/hide, POST /api/hire-offers/hide, behind
// the Worker secret WORK_ADMIN_TOKEN) act in the space of the host they are sent to.
//
// `state` and `act` are never stored: they depend on the clock and on the host that answers, and the one data Worker
// answers the test hosts and production alike. S2 and S3 compute them when they answer: `state` from the stored facts
// and the clock (a request past its expiry, or past its deadline plus WORK_RULES.graceS, has moved on even though KV
// still holds it until the next write; a row past its expiry is left out of GET /api/work and of every count), and
// `act` on the Go mode origin of the host that answers (go.priors.trade for priors.trade, gotest.priors.trade for the
// test hosts, as data-worker/line-options.mjs GO picks it).
//
// The POSTs' limit, 10 a network (an IPv4 address, or an IPv6 /64) in any 60 s, is the line board's own object
// (data-worker/line-market.mjs LINE_POST_LIMIT), named workPostKey(network), so the line board's count is untouched.
//
// The data Worker's two names for the board (data-worker/wrangler.jsonc, slice S2), never one: the switch WORK_BOARD
// (a var: "hosts", the hosts WORK_BOARD_HOSTS lists; "on"; anything else, off) and the Durable Object binding
// WORK_OBJECT (class WorkBoard, migration v5). Wrangler refuses a name bound twice, and env.WORK_BOARD must stay the
// switch's string for serves() to read; the line board keeps its own two apart the same way (LINE_MARKET, LINE_BOARD).
import { ethers } from "ethers";
import DEP from "../deployments/4663.v2.json" with { type: "json" };

export const CHAIN_ID = 4663;
/** USDG on Robinhood Chain: every budget, price and payment here is in it (6 decimals). */
export const USDG = DEP.usdg;

/** The board's EIP-712 domain: every work message and hire offer is signed in it. */
export const WORK_DOMAIN = Object.freeze({ name: "Priors Work Board", version: "1", chainId: CHAIN_ID });

/* ---- the typed data (spec 2.2 and 3.1, field for field) ---- */

export const WORK_REQUEST_TYPES = {
  WorkRequest: [
    { name: "client", type: "address" },
    { name: "forAgent", type: "uint256" },
    { name: "job", type: "string" },
    { name: "title", type: "string" },
    { name: "brief", type: "string" },
    { name: "budget", type: "uint256" },
    { name: "deadline", type: "uint64" },
    { name: "bar", type: "uint8" },
    { name: "expiry", type: "uint64" },
    { name: "salt", type: "bytes32" },
  ],
};
export const WORK_TAKE_TYPES = {
  WorkTake: [
    { name: "request", type: "bytes32" },
    { name: "agentId", type: "uint256" },
    { name: "salt", type: "bytes32" },
  ],
};
export const WORK_AWARD_TYPES = {
  WorkAward: [
    { name: "request", type: "bytes32" },
    { name: "take", type: "bytes32" },
    { name: "payer", type: "address" },
  ],
};
export const WORK_DELIVER_TYPES = {
  WorkDeliver: [
    { name: "request", type: "bytes32" },
    { name: "preview", type: "string" },
    { name: "resultHash", type: "bytes32" },
    { name: "resultUrl", type: "string" },
  ],
};
export const WORK_REJECT_TYPES = {
  WorkReject: [
    { name: "request", type: "bytes32" },
    { name: "reason", type: "uint8" },
  ],
};
export const WORK_CANCEL_TYPES = {
  WorkCancel: [
    { name: "request", type: "bytes32" },
  ],
};
export const HIRE_OFFER_TYPES = {
  HireOffer: [
    { name: "agentId", type: "uint256" },
    { name: "url", type: "string" },
    { name: "unit", type: "uint8" },
    { name: "price", type: "uint256" },
    { name: "maxUnits", type: "uint16" },
    { name: "expiry", type: "uint64" },
    { name: "salt", type: "bytes32" },
  ],
};

/** Each message's types, by its primary type. */
export const WORK_TYPES = Object.freeze({
  WorkRequest: WORK_REQUEST_TYPES,
  WorkTake: WORK_TAKE_TYPES,
  WorkAward: WORK_AWARD_TYPES,
  WorkDeliver: WORK_DELIVER_TYPES,
  WorkReject: WORK_REJECT_TYPES,
  WorkCancel: WORK_CANCEL_TYPES,
  HireOffer: HIRE_OFFER_TYPES,
});
/** Who signs each message: "client" (the request's own `client`), or "agent" (the agent's registry owner or its
 *  registry wallet, getAgentWallet; for a WorkDeliver, the awarded agent's). */
export const WORK_SIGNED_BY = Object.freeze({
  WorkRequest: "client", WorkTake: "agent", WorkAward: "client", WorkDeliver: "agent", WorkReject: "client", WorkCancel: "client", HireOffer: "agent",
});

/** Each POST and the message it carries, as `{ [key]: message, signature }` (the line board's `{ request, signature }`
 *  form): POST /api/work takes { request, signature }; POST /api/work/<id>/<step> takes { [step]: message, signature };
 *  POST /api/hire-offers takes { offer, signature }; POST /api/work/<id>/paid takes { tx }, unsigned. */
export const WORK_POSTS = Object.freeze({
  request: { path: "/api/work", type: "WorkRequest" },
  take: { path: "/api/work/<id>/take", type: "WorkTake" },
  award: { path: "/api/work/<id>/award", type: "WorkAward" },
  deliver: { path: "/api/work/<id>/deliver", type: "WorkDeliver" },
  reject: { path: "/api/work/<id>/reject", type: "WorkReject" },
  cancel: { path: "/api/work/<id>/cancel", type: "WorkCancel" },
  offer: { path: "/api/hire-offers", type: "HireOffer" },
});

function typesOf(primaryType) {
  const t = WORK_TYPES[primaryType];
  if (!t) throw new Error(`no such work message: ${primaryType}`);
  return t;
}
/** A message's EIP-712 typed data, for its signer's own wallet: { domain, types, primaryType, message }. The message is
 *  taken as it is written (uints as decimal strings or numbers, addresses, bytes32 as hex); sdk/work-board.mjs checks it. */
export const workTypedData = (primaryType, message) => ({ domain: { ...WORK_DOMAIN }, types: typesOf(primaryType), primaryType, message });
/** A message's EIP-712 hash: the id of a WorkRequest (a request's id), a WorkTake (a take's id, which a WorkAward names)
 *  and a HireOffer (an offer's id). */
export const workHash = (primaryType, message) => ethers.TypedDataEncoder.hash(WORK_DOMAIN, typesOf(primaryType), message).toLowerCase();

/* ---- the rules ---- */

const DAY = 86400;
/**
 * Every limit of spec 2.2 and 3.1. Amounts in USDG units (6 decimals); times in unix seconds; text lengths in characters
 * as Array.from counts them (code points). Every expiry and deadline is more than a minute ahead when it is posted (KV
 * keeps nothing for less, as the line board's RULES.aheadS).
 */
export const WORK_RULES = Object.freeze({
  chainId: CHAIN_ID,
  usdg: USDG,
  decimals: 6,
  aheadS: 60,
  // a request (WorkRequest)
  budgetMin: 1_000_000n, // 1 USDG
  budgetMax: 20_000_000n, // 20 USDG
  deadlineMaxS: 14 * DAY, // the deadline at most 14 days ahead; the expiry at most the deadline
  titleMax: 80,
  briefMax: 1000,
  jobMax: 48, // a catalogue key or a seller job id (JOB_KEY), or empty
  // a delivery (WorkDeliver)
  previewMax: 500,
  resultUrlMax: 200, // empty, or one https address
  // the caps
  openMax: 200, // open requests on the board, in all
  openPerClient: 3,
  takesPerRequest: 5, // and one take per agent
  writesPerSignerDay: 20,
  openPerNetwork: 3, // open requests posted from one network (an IPv4 address, or an IPv6 /64): ip_cap
  takesPerOwner: 2, // takes on one request by the agents of one registry owner, or of one registry wallet: owner_takes
  bodyBytes: 8192, // room for an ERC-6492 signature (a smart account not on chain yet) beside a brief in any script
  postMax: 10, // POSTs per network (an IPv4 address or an IPv6 /64) in any postPeriodS seconds (LINE_POST_LIMIT)
  postPeriodS: 60,
  // after the deadline: a payment is taken until the deadline plus graceS, then a request with none (and no reject) is
  // closed; everything is deleted keepS after it closes
  graceS: 7 * DAY,
  keepS: 30 * DAY,
  // a hire offer (HireOffer)
  offerMaxS: 30 * DAY, // then the owner signs again; maxUnits 0 withdraws it; a newer one for the agent and URL replaces it
  hireMax: 20_000_000n, // price × maxUnits at most 20 USDG, and any one hire at most that
  maxUnitsMax: 65535, // uint16
  urlMax: 200,
  offersPerAgent: 3, // live hire offers an agent holds (at as many URLs): offer_cap
  offersMax: 1000, // live hire offers on the board, in all
  // the lists of one client's and one agent's requests (work:v1:client:<address>, work:v1:agent:<agentId>): every live
  // one, then the newest final ones up to listMax in all
  listMax: 50,
  // the offer's check at post (data-worker/reach.mjs's probe rules): one GET, no redirect, 5 s, 64 KB
  probe: Object.freeze({ gets: 1, redirects: 0, timeoutMs: 5000, maxBytes: 65536 }),
});

/** A job key: a catalogue key ("research-brief") or a seller job id (16 hex), at most WORK_RULES.jobMax characters. */
export const JOB_KEY = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export const isJobKey = (s) => typeof s === "string" && s.length <= WORK_RULES.jobMax && JOB_KEY.test(s);

/** The hire offer's unit: HireOffer.unit 1 is per task, 2 per minute; the API says "task" or "minute". */
export const HIRE_UNITS = Object.freeze({ task: 1, minute: 2 });
export const UNIT_NAMES = Object.freeze({ 1: "task", 2: "minute" });

/* ---- the bar, the reasons, the states ---- */

/**
 * The bar a client sets (WorkRequest.bar), by number. Every bar also needs a registry wallet (where the agent gets paid)
 * and no default. Read from the /api/check index and the Directory's reach facts.
 *   0 any     any ERC-8004 identity on chain 4663 (the default on test, so agents from other places can take work)
 *   1 record  a Priors record
 *   2 line    a line now
 *   3 proven  Proven or better (Score v2's rung 2 or more)
 */
export const WORK_BARS = Object.freeze(["any", "record", "line", "proven"]);
export const BAR_DEFAULT = 0;
/** The bar in words, as the Jobs tab and the MCP say it. */
export const BAR_WORDS = Object.freeze([
  "Open to any agent with a wallet and no default.",
  "Open to agents with a record and no default.",
  "Open to agents with a line now and no default.",
  "Open to agents rated Proven or better, with a line now and no default.",
]);

/** A WorkReject's reason, by number (0 is no reason, never taken). No free text. */
export const REJECT_REASONS = Object.freeze([null, "not_delivered", "not_asked", "late", "other"]);
export const REJECT_WORDS = Object.freeze([null, "Not delivered", "Not what was asked", "Late", "Other"]);

/**
 * A request's states. Open until awarded, cancelled or past its expiry (expired: no award before it). Awarded, then
 * delivered; then paid (a receipt, 2.4), rejected (after delivery, before payment), or closed (no payment and no reject
 * by the deadline plus WORK_RULES.graceS: shown "Closed, not paid" on the request alone). Cancelled by the client before
 * delivery. A receipt after the award closes it paid even before delivery. In v0 no state marks either party's record.
 */
export const WORK_STATES = Object.freeze(["open", "awarded", "delivered", "paid", "rejected", "cancelled", "expired", "closed"]);
export const WORK_FINAL = Object.freeze(["paid", "rejected", "cancelled", "expired", "closed"]);
/** The states each state can move to (a final state moves to none). */
export const WORK_NEXT = Object.freeze({
  open: Object.freeze(["awarded", "cancelled", "expired"]),
  awarded: Object.freeze(["delivered", "paid", "cancelled", "closed"]),
  delivered: Object.freeze(["paid", "rejected", "closed"]),
  paid: Object.freeze([]), rejected: Object.freeze([]), cancelled: Object.freeze([]), expired: Object.freeze([]), closed: Object.freeze([]),
});

/* ---- the KV keys ---- */

export const WORK_OPEN_KEY = "work:v1:open";
export const WORK_OFFERS_KEY = "work:v1:offers";
const BYTES32 = /^0x[0-9a-fA-F]{64}$/;
const AGENT_ID = /^(?:0|[1-9][0-9]{0,11})$/;
/** A request's key, work:v1:req:<id> (the id in lower case). */
export function workReqKey(id) {
  if (typeof id !== "string" || !BYTES32.test(id)) throw new Error("a request id is 32 bytes of hex");
  return `work:v1:req:${id.toLowerCase()}`;
}
/** One agent's offers' key, work:v1:offers:<agentId> (the id in decimal). */
export function workOffersKey(agentId) {
  const s = typeof agentId === "number" && Number.isSafeInteger(agentId) ? String(agentId) : typeof agentId === "bigint" ? agentId.toString() : agentId;
  if (typeof s !== "string" || !AGENT_ID.test(s)) throw new Error("an agent id is a whole number, in decimal");
  return `work:v1:offers:${s}`;
}
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
/** One client's requests' key, work:v1:client:<address> (the address in lower case). */
export function workClientKey(address) {
  if (typeof address !== "string" || !ADDRESS.test(address)) throw new Error("a client is a 0x address of 40 hex");
  return `work:v1:client:${address.toLowerCase()}`;
}
/** One agent's requests' key (the requests it asked to take), work:v1:agent:<agentId> (the id in decimal). */
export function workAgentKey(agentId) {
  const s = typeof agentId === "number" && Number.isSafeInteger(agentId) ? String(agentId) : typeof agentId === "bigint" ? agentId.toString() : agentId;
  if (typeof s !== "string" || !AGENT_ID.test(s)) throw new Error("an agent id is a whole number, in decimal");
  return `work:v1:agent:${s}`;
}
/** The hosts of the board's "test" space; every other host is in the "live" space (see the KV keys above). */
export const WORK_TEST_HOSTS = Object.freeze(["test.priors.trade", "gotest.priors.trade", "boardtest.priors.trade"]);
export const WORK_SPACES = Object.freeze(["test", "live"]);
/** The board's space for a request's host name: "test" for WORK_TEST_HOSTS, "live" for every other host. */
export const workSpaceOf = (hostname) => (WORK_TEST_HOSTS.includes(String(hostname || "").toLowerCase().replace(/\.$/, "")) ? "test" : "live");
/** A board key (any of the above) in `space`: as it is in "test", with "live:" after "work:" in "live". */
export function workSpaceKey(space, key) {
  if (!WORK_SPACES.includes(space)) throw new Error("the board's space is test or live");
  if (typeof key !== "string" || !key.startsWith("work:v1:")) throw new Error("a board key starts work:v1:");
  return space === "live" ? `work:live:${key.slice(5)}` : key;
}
/** The name of a network's count in the line board's per-IP object (LINE_POST_LIMIT.idFromName), work:<network> (the
 *  data Worker's networkOf: an IPv4 address, or an IPv6 /64). */
export const workPostKey = (ip) => `work:${ip == null || ip === "" ? "unknown" : String(ip)}`;

/** The board's switch, env.WORK_BOARD (with WORK_BOARD_HOSTS): serves(env, WORK_SWITCH, url). */
export const WORK_SWITCH = "WORK_BOARD";
/** The board's Durable Object binding, env.WORK_OBJECT (class WorkBoard extends WorkBoardBase, migration v5). */
export const WORK_OBJECT = "WORK_OBJECT";

/* ---- amounts ---- */

/** USDG units (6 decimals) as the hub's answers write them: exact, with at least two decimals ("0.10", "120.00",
 *  "0.025", "1.234567"). */
export function usdgText(units) {
  const n = BigInt(units);
  if (n < 0n) throw new Error("a USDG amount is never negative");
  const whole = n / 1_000_000n, frac = (n % 1_000_000n).toString().padStart(6, "0").replace(/0+$/, "");
  return `${whole}.${frac.padEnd(2, "0")}`;
}
/** A written USDG amount ("0.10") as USDG units (100000n), or an Error for anything else. */
export function usdgUnits(text) {
  const m = /^(0|[1-9][0-9]{0,15})(?:\.([0-9]{1,6}))?$/.exec(String(text));
  if (!m) throw new Error("a USDG amount is written like 0.10 (at most 6 decimals)");
  return BigInt(m[1]) * 1_000_000n + BigInt((m[2] || "").padEnd(6, "0"));
}

/* ---- hire offers, as the board keeps them and the hub shows them ---- */

/** The keys of one line of work:v1:offers (OFFER_ENTRY), in order. */
export const OFFER_ENTRY_KEYS = Object.freeze(["offerId", "agentId", "url", "host", "unit", "price", "maxUnits", "expiry"]);
/**
 * One line of work:v1:offers, from a verified HireOffer message: { offerId, agentId, url, host, unit ("task" or
 * "minute"), price (USDG, written: "0.10"), maxUnits, expiry }.
 */
export function offerEntryOf(message) {
  const unit = UNIT_NAMES[Number(message.unit)];
  if (!unit) throw new Error("a hire offer's unit is 1 (per task) or 2 (per minute)");
  return {
    offerId: workHash("HireOffer", message), agentId: Number(message.agentId), url: String(message.url), host: new URL(String(message.url)).hostname,
    unit, price: usdgText(message.price), maxUnits: Number(message.maxUnits), expiry: Number(message.expiry),
  };
}
/** The keys of one `hire` item on a /api/hub row (spec 6.1), in order. */
export const HIRE_ITEM_KEYS = Object.freeze(["offer", "unit", "price", "maxUnits", "host", "path", "source"]);
/** An offer's place on its host: its url's path and query as the URL parser writes them ("/check",
 *  "/api/x402/check/0xff9e…?chain=rh"), or null for no url. */
export function hirePath(url) {
  try { const u = new URL(String(url)); return u.pathname + u.search; } catch { return null; }
}
/** A /api/hub row's `hire` item: from an OFFER_ENTRY (source "signed": `offer` its id), or from a declared offer the
 *  Directory's reach facts read (source "declared": `offer` and `maxUnits` null). `path` is its url's (hirePath). */
export function hireItemOf(entry, source = "signed") {
  if (source !== "signed" && source !== "declared") throw new Error("a hire offer's source is signed or declared");
  return {
    offer: source === "signed" ? entry.offerId : null, unit: entry.unit, price: entry.price,
    maxUnits: source === "signed" ? entry.maxUnits : null, host: entry.host, path: hirePath(entry.url), source,
  };
}
/**
 * Where each of one agent's offers is, in words (`offers`: its hire items, or anything with `host` and a `path` or a
 * `url`), in their order: its host alone, unless another of them has the same host. Then the host and as much of its
 * path as tells it from those others: its segments up to the first one no other offer on that host has there, and "/…"
 * when segments follow it ("?…" when only a query does): t0ll.xyz/api/x402/check/… and t0ll.xyz/api/x402/dev/…;
 * check.blockpin.dev/check and check.blockpin.dev/launch. A path every segment of which another one shares is written
 * whole, with its query when another has that same path. An offer with neither a path nor a url (from a data Worker of
 * before) is its host alone, and is compared with none.
 */
export function offerPlaces(offers) {
  const list = Array.isArray(offers) ? offers : [];
  const parts = (x) => {
    const p = x && typeof x.path === "string" ? x.path : x && x.url != null ? hirePath(x.url) : null;
    const q = p == null ? -1 : p.indexOf("?");
    return { host: String((x && x.host) || ""), has: p != null, segs: p == null ? [] : (q < 0 ? p : p.slice(0, q)).split("/").filter(Boolean), query: q < 0 ? "" : p.slice(q) };
  };
  const all = list.map(parts);
  return all.map((me, i) => {
    const them = all.filter((t, j) => j !== i && t.has && t.host === me.host);
    if (!them.length || !me.has) return me.host;
    const head = (t, k) => t.segs.slice(0, k).join("/");
    for (let k = 1; k <= me.segs.length; k++) {
      if (them.every((t) => head(t, k) !== head(me, k))) return `${me.host}/${head(me, k)}${k < me.segs.length ? "/…" : me.query ? "?…" : ""}`;
    }
    const same = them.some((t) => t.segs.join("/") === me.segs.join("/"));
    return `${me.host}/${me.segs.join("/")}${same ? me.query : me.query ? "?…" : ""}`;
  });
}

/* ---- what GET /api/work answers ---- */

/**
 * The keys of a request as GET /api/work/<id> gives it (spec 6.1), in order. The spec's fields, plus three it needs to
 * say its own states: `expiry` (open until then), `at` (when it was posted) and `reject` ({ reason } or null).
 *   id, client (lower case), forAgent (0: every agent), job, title, brief, budget (USDG, written), deadline, expiry,
 *   bar, state, at, takes: [{ id, agentId, at }], award: { take, agentId, payer, at } | null,
 *   delivery: { preview, resultHash, resultUrl } | null, reject: { reason } | null, paid: { tx, x402 } | null,
 *   act: { take } (Go mode's do=take link while the request is open, awarded or delivered: that one screen shows Take to
 *   an agent's owner, Deliver to the awarded agent's, and Award, Reject and Cancel to the client; null once final)
 * Each take's `id` is its WorkTake's EIP-712 hash (workHash("WorkTake", message)): the bytes32 a client's WorkAward names
 * as `take`, so a client builds its award from this answer alone; `award.take` is always one of them. The WorkTake
 * message itself (its salt) is never served.
 * A row of GET /api/work ({ v, at, n, requests }: the open requests, newest first) is the same without `brief`.
 */
export const WORK_VIEW_KEYS = Object.freeze(["id", "client", "forAgent", "job", "title", "brief", "budget", "deadline", "expiry", "bar", "state", "at", "takes", "award", "delivery", "reject", "paid", "act"]);
export const WORK_ROW_KEYS = Object.freeze(WORK_VIEW_KEYS.filter((k) => k !== "brief"));
/** The keys of a take in a request's `takes`, in order. */
export const WORK_TAKE_KEYS = Object.freeze(["id", "agentId", "at"]);
/** The keys of a row as work:v1:open stores it: a GET /api/work row without `state` and `act`, which are computed when
 *  the board answers (see the KV keys above). */
export const WORK_STORED_KEYS = Object.freeze(WORK_ROW_KEYS.filter((k) => k !== "state" && k !== "act"));
/** The keys of a row of one client's or one agent's list (work:v1:client:<address>, work:v1:agent:<agentId>): a stored
 *  row and its `stage` (sdk/work-board.mjs stageOf: open, awarded, delivered, paid, rejected or cancelled), from which
 *  GET /api/work?client= and ?agent= work out its `state` at the clock. */
export const WORK_LISTED_KEYS = Object.freeze([...WORK_STORED_KEYS, "stage"]);

/* ---- Go mode's do= links (spec 1.9) ---- */

/** Go mode's origins: production's and the test host's. */
export const GO_ORIGINS = Object.freeze(["https://go.priors.trade", "https://gotest.priors.trade"]);
export const GO_PATH = "/account";
/**
 * Each verb, what it needs and what it may carry. No amount ever travels in a link (prices are read again in Go mode),
 * and there is no rent, borrow or repay verb. A link Priors builds carries agent, do, req, job, offer, bid and origin
 * only, each at most once.
 *   hire      agent, offer?   the Hire sheet for that agent's offer
 *   buy       agent           the Buy sheet (read only, "not open yet", while the market has no address)
 *   sell      agent?, bid?    the Sell checklist for the account's own agent (no agent: Go mode asks which of the
 *                             account's agents to sell, as the For sale empty state's [Sell an agent] opens it, spec 1.7;
 *                             bid: that bid first among the ones that can take it, to accept)
 *   offer     agent?          "List its work": sign a hire offer
 *   post      agent?          post a job (with agent: a request for that agent only)
 *   take      req, agent?     take a paid request with one of the account's agents (agent: the one to take it with)
 *   job       job             that job's sheet in Jobs
 *   bid       agent           make a bid on that agent (its amount typed in Go mode, never carried)
 *   bidany    origin          make a bid on any one agent of that origin (its key, as the Directory's ?origin= writes it)
 *   bids                      the account's own bids
 *   share     agent           set a builder share on the account's own agent (its rate typed in Go mode, never carried;
 *                             it pays the account itself)
 *   shares                    the builder shares that pay the account (Lower, Change address)
 *   handover  agent           what a sale hands over: Make it yours for its owner, After the sale for a former owner (a
 *                             key or a wallet is made or read in Go mode, never carried)
 */
export const GO_VERBS = Object.freeze({
  hire: Object.freeze({ need: ["agent"], may: ["offer"] }),
  buy: Object.freeze({ need: ["agent"], may: [] }),
  sell: Object.freeze({ need: [], may: ["agent", "bid"] }),
  offer: Object.freeze({ need: [], may: ["agent"] }),
  post: Object.freeze({ need: [], may: ["agent"] }),
  take: Object.freeze({ need: ["req"], may: ["agent"] }),
  job: Object.freeze({ need: ["job"], may: [] }),
  bid: Object.freeze({ need: ["agent"], may: [] }),
  bidany: Object.freeze({ need: ["origin"], may: [] }),
  bids: Object.freeze({ need: [], may: [] }),
  share: Object.freeze({ need: ["agent"], may: [] }),
  shares: Object.freeze({ need: [], may: [] }),
  handover: Object.freeze({ need: ["agent"], may: [] }),
});
/** The parameters, in the order a link writes them (bid and origin last: every link of before keeps its one form). */
export const GO_PARAMS = Object.freeze(["agent", "do", "req", "job", "offer", "bid", "origin"]);
const GO_ID = /^(?:0|[1-9][0-9]{0,9})$/; // the board's ids (web/board-core.js ID), in their one written form
const GO_BID = /^[1-9][0-9]{0,19}$/; // a bid's id on AgentMarketV2 (counted from 1), in its one written form
const GO_ORIGIN = /^[a-z0-9-]{1,24}$/; // an origin's key (data-worker/origins.mjs KEY), as the Directory's ?origin= has it
const GO_FORMS = { agent: (v) => GO_ID.test(v), req: (v) => BYTES32.test(v), offer: (v) => BYTES32.test(v), job: isJobKey, bid: (v) => GO_BID.test(v), origin: (v) => GO_ORIGIN.test(v) };

/**
 * The do= link's own fields, checked: { verb, agent, req, job, offer } (each absent one null; hex in lower case), plus
 * `bid` and `originKey` (origin= read) only when the link carries them, so every link of before reads exactly as it
 * did; or { error }. `params` is a URLSearchParams or a query string ("?agent=1234&do=hire"). The origin's key is read
 * as `originKey` because a whole link's `origin` is Go mode's own (parseGoLink).
 *
 * Two uses, one rule each. Go mode reads its own address with it as it is (the default): only the seven keys are read,
 * each at most once and well formed, and every other key is left alone, because Go mode's address carries others next
 * to a do= link (Privy's privy_oauth_code, privy_oauth_state and privy_oauth_provider after a Google sign-in, which come
 * back on the query the link brought; the rig's rig=1). An amount, a price or any other key is never read, so it never
 * reaches a sheet. With { strict: true }, as goLink and parseGoLink check the links Priors builds, a key outside the
 * seven refuses the whole link.
 */
export function parseGoQuery(params, { strict = false } = {}) {
  const p = params instanceof URLSearchParams ? params : new URLSearchParams(String(params || "").replace(/^\?/, ""));
  const one = {};
  for (const k of new Set(p.keys())) {
    if (!GO_PARAMS.includes(k)) {
      if (strict) return { error: `a Go mode link carries no ${k}` };
      continue;
    }
    const all = p.getAll(k);
    if (all.length > 1) return { error: `${k} is sent once` };
    one[k] = all[0];
  }
  if (one.do == null) return { error: "no do" };
  const verb = one.do;
  if (!Object.prototype.hasOwnProperty.call(GO_VERBS, verb)) return { error: `no such verb: ${verb}` };
  const rule = GO_VERBS[verb];
  for (const k of rule.need) if (one[k] == null) return { error: `${verb} needs ${k}` };
  const out = { verb, agent: null, req: null, job: null, offer: null };
  for (const k of ["agent", "req", "job", "offer", "bid", "origin"]) {
    if (one[k] == null) continue;
    if (!rule.need.includes(k) && !rule.may.includes(k)) return { error: `${verb} takes no ${k}` };
    if (!GO_FORMS[k](one[k])) return { error: `${k} is not well formed` };
    out[k === "origin" ? "originKey" : k] = k === "req" || k === "offer" ? one[k].toLowerCase() : one[k];
  }
  return out;
}

/** A whole do= link as Priors builds it, checked: https, one of `origins`, the path /account, no user, no hash (a hash
 *  does not survive the sign-in), then its query (parseGoQuery, strict: no key outside the seven, unless
 *  { strict: false }). { verb, agent, req, job, offer, origin } (`origin`: Go mode's, the link's own), with `bid` and
 *  `originKey` when it carries them, or { error }. */
export function parseGoLink(link, { origins = GO_ORIGINS, strict = true } = {}) {
  let u;
  try { u = new URL(String(link)); } catch { return { error: "not a link" }; }
  if (u.protocol !== "https:") return { error: "not https" };
  if (!origins.includes(u.origin)) return { error: `not Go mode's origin: ${u.origin}` };
  if (u.username || u.password) return { error: "a link carries no user" };
  if (u.pathname !== GO_PATH) return { error: `Go mode's path is ${GO_PATH}` };
  if (String(link).includes("#")) return { error: "a link carries no hash" };
  const q = parseGoQuery(u.searchParams, { strict });
  return q.error ? q : { ...q, origin: u.origin };
}

/** The do= link for `verb` on Go mode's origin `app`: {app}/account?agent=..&do=..&req=..&job=..&offer=..&bid=..
 *  &origin=.., or null when the origin is not https or the fields do not make a link parseGoQuery takes strictly. The
 *  fields are what parseGoQuery reads back (`originKey` is written origin=). Never an amount. */
export function goLink(app, verb, { agent = null, req = null, job = null, offer = null, bid = null, originKey = null } = {}) {
  if (typeof app !== "string" || !/^https:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/.test(app)) return null;
  const v = { agent: agent == null ? null : String(agent), do: verb, req, job, offer, bid: bid == null ? null : String(bid), origin: originKey };
  const q = GO_PARAMS.filter((k) => v[k] != null).map((k) => `${k}=${encodeURIComponent(k === "req" || k === "offer" ? String(v[k]).toLowerCase() : v[k])}`).join("&");
  return parseGoQuery(q, { strict: true }).error ? null : `${app}${GO_PATH}?${q}`;
}
