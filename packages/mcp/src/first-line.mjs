// first_line's reading of what the invite bot answers (server.mjs, with PRIORS_JOIN=on; docs/growth/mcp-first-line.md).
// Pure: the bot's proof text rebuilt from its own start-page form, the bot's proof answer judged against it before
// anything is signed, an invite code read, and the bot's check reasons in the invite page's words (web/bond.js shutText).

/** How long the bot's proof lasts (bot/worker.mjs PROOF_TTL): an answer whose expiry is further away is not its form. */
export const PROOF_TTL_S = 1800;
const NONCE_RE = /^[0-9a-f]{32}$/;
/** An invite code as the bot writes it (bot/worker.mjs CODE_RE): priors-invite:<agent id>:<expiry>:<signature>. */
export const CODE_RE = /^priors-invite:(\d{1,10}):(\d{1,12}):(0x[0-9a-fA-F]{130})$/;

/**
 * The text the bot asks an agent's owner to sign from the site's start page: bot/worker.mjs proofMessage(agentId,
 * nonce, exp, null, true), rebuilt here line for line, never taken from the bot. A bot release that changes its form
 * makes first_line refuse to sign until this copy follows (scripts/test-mcp-first-line.mjs holds the two equal).
 */
export function proofText(agentId, nonce, exp) {
  return [
    "priors.trade seat request",
    "",
    `I own agent #${agentId} on Robinhood Chain and I am asking for a seat.`,
    "Asked from the priors.trade start page",
    "",
    "This signature only proves ownership. It sends no transaction and moves no funds.",
    "",
    `request: ${nonce}`,
    `expires: ${new Date(exp * 1000).toISOString().replace(".000", "")}`,
  ].join("\n");
}

/** A value the bot sent, for an answer: a string or a number as written (cut), anything else by its type. */
const shown = (v) => (typeof v === "string" ? JSON.stringify(v.length > 80 ? `${v.slice(0, 80)}…` : v) : typeof v === "number" ? String(v) : v === null ? "null" : typeof v);

/**
 * The bot's answer to POST /prove {agentId} (webStart: { ok, n, agentId, owner, message, exp }), judged for agent
 * `agentId` and this wallet (`owner`) at `now` (unix seconds). { ok: true, n, exp, message } when the message is
 * exactly the rebuilt text for that agent, request and expiry, the answer names this wallet as the owner and the
 * expiry is ahead and within the bot's 30 minutes; else { ok: false, why } (a sentence), with `refused: true` when it
 * is the bot's own refusal (`why` then its words). Nothing it returns has been signed.
 */
export function judgeProof(a, { agentId, owner, now }) {
  const no = (why) => ({ ok: false, why });
  if (!a || typeof a !== "object" || Array.isArray(a)) return no("its answer is not the bot's form");
  if (a.ok !== true) return { ok: false, refused: true, why: typeof a.error === "string" && a.error ? a.error : "it answered no, with no reason" };
  if ((typeof a.agentId !== "string" && typeof a.agentId !== "number") || String(a.agentId) !== String(agentId)) return no(`it is for agent ${shown(a.agentId)}, not agent #${agentId}`);
  if (typeof a.owner !== "string" || a.owner.toLowerCase() !== String(owner).toLowerCase()) return no(`it names ${shown(a.owner)} as the agent's owner, not this wallet (${owner})`);
  if (typeof a.n !== "string" || !NONCE_RE.test(a.n)) return no(`its request ${shown(a.n)} is not the bot's form (32 hex digits)`);
  if (!Number.isSafeInteger(a.exp)) return no(`its expiry ${shown(a.exp)} is not a time`);
  if (a.exp <= now) return no(`its expiry (${new Date(a.exp * 1000).toISOString()}) has already passed`);
  if (a.exp > now + PROOF_TTL_S + 300) return no(`its expiry (${new Date(a.exp * 1000).toISOString()}) is further away than the bot's ${PROOF_TTL_S / 60} minutes`);
  const want = proofText(agentId, a.n, a.exp);
  if (typeof a.message !== "string") return no("it carries no message");
  if (a.message !== want) {
    let i = 0;
    while (i < want.length && a.message[i] === want[i]) i++;
    return no(`its message is not the text rebuilt from the bot's own form for agent #${agentId}, request ${a.n} and that expiry: the two first differ at character ${i + 1} of ${want.length}`);
  }
  return { ok: true, n: a.n, exp: a.exp, message: want };
}

/** An invite code for `agentId` read at `now`: { ok: true, expiry, signature } or { ok: false, why }. */
export function readInvite(code, agentId, now) {
  const m = CODE_RE.exec(typeof code === "string" ? code : "");
  if (!m) return { ok: false, why: "it is not an invite code (priors-invite:<id>:<expiry>:<signature>)" };
  if (m[1] !== String(agentId)) return { ok: false, why: `it is for agent #${m[1]}, not agent #${agentId}` };
  const expiry = Number(m[2]);
  if (expiry <= now) return { ok: false, why: `it expired at ${new Date(expiry * 1000).toISOString()}` };
  return { ok: true, expiry, signature: m[3] };
}

const utc = (t) => new Date(t * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC";
/**
 * Why the bot's check (POST /prove {check: true, owner}) says no automatic invite is open, in the invite page's words
 * (web/bond.js shutText), for an agent that posts the bond itself: `c` is the bot's answer ({ reason, reopensAt, held,
 * perOwner }).
 */
export function shutText(c) {
  const at = Number.isSafeInteger(c.reopensAt) && c.reopensAt > 0 ? c.reopensAt : null;
  switch (c.reason) {
    case "default": return "A default on this wallet's record stops new lines for its agents, so a bond would bring no invite.";
    case "day": return "Today's automatic invites are taken. New ones open at 00:00 UTC: call first_line again after that.";
    case "room":
      if (c.held === true && at) return `This week's first lines are held by invites that haven't been used yet. One may be free after ${utc(at)}: call first_line again then.`;
      return "This week's first lines are taken." + (at ? ` New ones open after ${utc(at)}: call first_line again then.` : " Come back next week.");
    case "owner": return `This wallet already used its ${Number.isSafeInteger(c.perOwner) && c.perOwner > 0 ? c.perOwner : 2} automatic invites, so a bond would bring no invite.`;
    case "waiting": return "Another agent of this wallet has an invite waiting. Use it, or let it expire, before asking for this one.";
    case "backing": return "The treasury can't back a new line right now. Try again later.";
    default: return "Automatic invites aren't open right now, so a bond would bring no invite. Try again later.";
  }
}
