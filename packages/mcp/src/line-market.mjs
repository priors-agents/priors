// Line requests and offers (docs/growth/line-requests.md): one agent, or any root, backs another through the pool's own
// consent. Three signed messages, each recovered and checked against the chain:
//
//   a LineRequest   signed by the agent's ERC-8004 owner: the line it asks (USDG, 6 decimals), the most premium it takes
//                   (bps per 30 days, at most the pool's MAX_PREMIUM_BPS), the term it means to borrow for (days), how
//                   long it stands and a salt. Its id is its EIP-712 hash. Domain "Priors Line Market" 1 on chain 4663:
//                   a board message can never be read as one of the pool's.
//   a LineOffer     signed by a root's ERC-8004 owner, against a request's id: the root (sponsorId), the amount, the
//                   premium, how long it stands. The id is a root (the pool's getAgent(id).isRoot).
//   the acceptance  exactly CreditPoolV2's own Consent for the offer's root (agentId, sponsorId, owner, maxPremiumBps,
//                   nonce, deadline), with the agent's current nonce, signed by the agent's owner in the pool's domain
//                   ("Priors Credit" 2): what vouchWithConsent checks on chain, so it can be used once, by that root's
//                   owner alone.
//
// For an accepted offer, vouchCall gives the exact vouchWithConsent call the root's owner sends from its own wallet:
// target, function, args and calldata. Nothing here sends, signs or holds a key: the typed data is built for the owners'
// own wallets to sign, and the chain is read only through the `reads` the caller passes (ownerOf, isRoot, nonces,
// isValidSignature).
//
// CONSENT_TYPES is the pool's Consent as sdk/priors-v2.mjs gives it (and integrations/bankr's priors-calls.mjs), held to
// that module and to src/CreditPoolV2.sol's CONSENT_TYPEHASH by scripts/test-line-market.mjs. It is written here rather
// than imported because the data Worker bundles this module, and sdk/priors-v2.mjs would bring its whole client (x402,
// PT-USDG, viem) into that Worker.
//
// Owners that are contracts (ERC-1271) sign too, as Go mode's accounts do (smart accounts: 18 of the 20 agents enrolled in
// the week to 2026-10-22 are owned by an address with code). Each message is checked the way the pool's SignatureChecker
// checks the Consent, and the Ethos lane its owners (ethos-worker/lane.mjs consentSigned):
//   - a 65-byte ECDSA signature (low s, v 27 or 28) that recovers to the owner the message names, or to the root's
//     registry owner for an offer, is that owner's, as before; it asks no contract;
//   - any other is put to the registry owner's isValidSignature(hash, signature), `reads.isValidSignature`, with the
//     message's EIP-712 hash (the pool's consentDigest for the Consent). Only the ERC-1271 magic word takes it, the
//     signer then being the contract. An owner with no code answers no word, so a signature that is not its own ECDSA
//     one is refused as before, with the words it got before. That holds for a signature in ERC-6492's wrapper (a smart
//     account not on chain yet) too: the line board's reads (data-worker/line-market.mjs chainReads, as production runs
//     them) put it to the account's isValidSignature as any other, so it is refused as it always was. Only the work
//     board asks for reads that check the wrapper (chainReads with { erc6492: true }); the pool's SignatureChecker reads
//     none, so a Consent so wrapped would fail on chain anyway.
// A caller that passes no isValidSignature read takes EOA signatures only, as this module did before. The one place
// the board and the pool can read a signature differently is an owner with an EIP-7702 delegation: the board takes its
// key's own ECDSA signature, while the pool asks its delegate's isValidSignature (2 of the board's 282 owners, read
// 2026-10-22); for a Consent the root's owner should simulate vouchWithConsent first, as for every other reason the pool
// can refuse.
//
// The field and signer helpers (uintOf, idOf, addressOf, bytes32Of, exactly, bytesOf, ecdsa, contractSigned, chainRead,
// ahead) are exported for the work board (sdk/work-board.mjs), which checks its own messages the same way.
import { ethers } from "ethers";
import DEP from "../deployments/4663.v2.json" with { type: "json" };

export const CHAIN_ID = 4663;
export const POOL = DEP.pool;
export const REGISTRY = DEP.registry;

/** The board's rules. maxPremiumBps is the pool's MAX_PREMIUM_BPS (a root's premium per 30 days). Amounts in USDG units
 *  (6 decimals). Every expiry and deadline is unix seconds, more than a minute ahead (KV keeps nothing for less). */
export const RULES = Object.freeze({
  maxPremiumBps: 200,
  lineMin: 1_000_000n, // 1 USDG
  lineMax: 1_000_000_000_000n, // 1,000,000 USDG
  termDaysMin: 1, termDaysMax: 90,
  aheadS: 60,
  standS: 30 * 86400, // a request stands at most 30 days, an offer no longer than its request
  consentS: 7 * 86400, // a consent's deadline at most 7 days ahead
});

export const MARKET_DOMAIN = Object.freeze({ name: "Priors Line Market", version: "1", chainId: CHAIN_ID });
export const REQUEST_TYPES = {
  LineRequest: [
    { name: "agentId", type: "uint256" },
    { name: "owner", type: "address" },
    { name: "line", type: "uint256" },
    { name: "maxPremiumBps", type: "uint256" },
    { name: "termDays", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "salt", type: "bytes32" },
  ],
};
export const OFFER_TYPES = {
  LineOffer: [
    { name: "requestId", type: "bytes32" },
    { name: "sponsorId", type: "uint256" },
    { name: "amount", type: "uint256" },
    { name: "premiumBps", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
};
/** CreditPoolV2's Consent (EIP712("Priors Credit", "2")), as sdk/priors-v2.mjs CONSENT_TYPES. */
export const CONSENT_TYPES = {
  Consent: [
    { name: "agentId", type: "uint256" },
    { name: "sponsorId", type: "uint256" },
    { name: "owner", type: "address" },
    { name: "maxPremiumBps", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
/** The pool's EIP-712 domain. */
export const consentDomain = ({ pool = POOL, chainId = CHAIN_ID } = {}) => ({ name: "Priors Credit", version: "2", chainId, verifyingContract: pool });

/** vouchWithConsent, as sdk/priors-v2.mjs POOL_V2_ABI declares it. */
export const VOUCH_WITH_CONSENT = "function vouchWithConsent(uint256 sponsorId, uint256 agentId, uint256 amount, uint256 premiumBps, tuple(uint256 agentId,uint256 sponsorId,address owner,uint256 maxPremiumBps,uint256 nonce,uint256 deadline) c, bytes sig)";
const VOUCH_IFACE = new ethers.Interface([VOUCH_WITH_CONSENT]);
const VOUCH_SIGNATURE = VOUCH_IFACE.getFunction("vouchWithConsent").format("sighash");

/** A refusal: `status` the HTTP status the board answers with, `code` a short word a client can test. */
export class LineError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = "LineError";
    this.status = status;
    this.code = code;
  }
}
const bad = (message) => new LineError(400, "bad_request", message);
const expired = (message) => new LineError(400, "expired", message);

/* ---- fields ---- */

const UINT = /^(0|[1-9][0-9]{0,77})$/;
/** A whole number as its decimal string (a safe integer or a decimal string with no sign, point or leading zero). */
export function uintOf(v, what) {
  const s = typeof v === "number" ? (Number.isSafeInteger(v) && v >= 0 ? String(v) : null) : typeof v === "string" && UINT.test(v) ? v : null;
  if (s == null) throw bad(`${what} must be a whole number, written in decimal`);
  return s;
}
/** An ERC-8004 id: 1 to 12 digits, never 0. */
export function idOf(v, what) {
  const s = uintOf(v, what);
  if (s === "0" || s.length > 12) throw bad(`${what} must be an agent id (1 to 12 digits, not 0)`);
  return s;
}
export function addressOf(v, what) {
  if (typeof v !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(v)) throw bad(`${what} must be an address`);
  try { return ethers.getAddress(v); } catch { throw bad(`${what} has a wrong checksum`); }
}
export function bytes32Of(v, what) {
  if (typeof v !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(v)) throw bad(`${what} must be 32 bytes of hex`);
  return v.toLowerCase();
}
/** `o` is a plain object with exactly these keys. */
export function exactly(o, keys, what) {
  if (!o || typeof o !== "object" || Array.isArray(o)) throw bad(`${what} must be an object`);
  const have = Object.keys(o);
  const extra = have.filter((k) => !keys.includes(k)), missing = keys.filter((k) => !(k in o));
  if (extra.length || missing.length) throw bad(`${what} takes exactly ${keys.join(", ")}${extra.length ? ` (not ${extra.join(", ")})` : ""}${missing.length ? ` (${missing.join(", ")} missing)` : ""}`);
}
const within = (s, lo, hi, what) => { const n = BigInt(s); if (n < BigInt(lo) || n > BigInt(hi)) throw bad(`${what} must be from ${lo} to ${hi}`); return s; };

/** A request in its one written form (decimal strings, the owner checksummed, the salt in lower case), or a 400. */
export function requestOf(r) {
  exactly(r, REQUEST_TYPES.LineRequest.map((f) => f.name), "a request");
  return {
    agentId: idOf(r.agentId, "agentId"),
    owner: addressOf(r.owner, "owner"),
    line: within(uintOf(r.line, "line"), RULES.lineMin, RULES.lineMax, "line (USDG units, 6 decimals)"),
    maxPremiumBps: within(uintOf(r.maxPremiumBps, "maxPremiumBps"), 0, RULES.maxPremiumBps, "maxPremiumBps"),
    termDays: within(uintOf(r.termDays, "termDays"), RULES.termDaysMin, RULES.termDaysMax, "termDays"),
    expiry: uintOf(r.expiry, "expiry"),
    salt: bytes32Of(r.salt, "salt"),
  };
}
/** An offer in its one written form, or a 400. */
export function offerOf(f) {
  exactly(f, OFFER_TYPES.LineOffer.map((x) => x.name), "an offer");
  return {
    requestId: bytes32Of(f.requestId, "requestId"),
    sponsorId: idOf(f.sponsorId, "sponsorId"),
    amount: within(uintOf(f.amount, "amount"), RULES.lineMin, RULES.lineMax, "amount (USDG units, 6 decimals)"),
    premiumBps: within(uintOf(f.premiumBps, "premiumBps"), 0, RULES.maxPremiumBps, "premiumBps"),
    expiry: uintOf(f.expiry, "expiry"),
  };
}
/** A pool Consent in its one written form, or a 400. */
export function consentOf(c) {
  exactly(c, CONSENT_TYPES.Consent.map((x) => x.name), "a consent");
  return {
    agentId: idOf(c.agentId, "agentId"),
    sponsorId: idOf(c.sponsorId, "sponsorId"),
    owner: addressOf(c.owner, "owner"),
    maxPremiumBps: uintOf(c.maxPremiumBps, "maxPremiumBps"),
    nonce: uintOf(c.nonce, "nonce"),
    deadline: uintOf(c.deadline, "deadline"),
  };
}

/* ---- typed data, for the owners' own wallets to sign ---- */

/** A request's EIP-712 typed data: { domain, types, primaryType, message }. */
export const requestTypedData = (r) => ({ domain: { ...MARKET_DOMAIN }, types: REQUEST_TYPES, primaryType: "LineRequest", message: requestOf(r) });
/** An offer's EIP-712 typed data. */
export const offerTypedData = (f) => ({ domain: { ...MARKET_DOMAIN }, types: OFFER_TYPES, primaryType: "LineOffer", message: offerOf(f) });
/** The pool's own Consent typed data (what the agent's owner signs to accept an offer for its root). */
export const consentTypedData = (c, { pool = POOL, chainId = CHAIN_ID } = {}) => ({ domain: consentDomain({ pool, chainId }), types: CONSENT_TYPES, primaryType: "Consent", message: consentOf(c) });
/** A request's id: its EIP-712 hash. */
export const requestId = (r) => ethers.TypedDataEncoder.hash(MARKET_DOMAIN, REQUEST_TYPES, requestOf(r));
/** An offer's id: its EIP-712 hash. */
export const offerId = (f) => ethers.TypedDataEncoder.hash(MARKET_DOMAIN, OFFER_TYPES, offerOf(f));

/* ---- signatures ---- */

const HALF_N = ethers.N / 2n;
/** A 65-byte ECDSA signature the pool's SignatureChecker takes from an EOA (r, s in the lower half, v 27 or 28), in
 *  lower case, or a 400. */
function signatureOf(s) {
  if (typeof s !== "string") throw bad("signature must be a string");
  if (!/^0x[0-9a-fA-F]{130}$/.test(s)) throw new LineError(400, "bad_signature", "the signature must be 65 bytes of hex (r, s, v)");
  const r = BigInt("0x" + s.slice(2, 66)), sv = BigInt("0x" + s.slice(66, 130)), v = parseInt(s.slice(130, 132), 16);
  if (r === 0n || sv === 0n || sv > HALF_N || (v !== 27 && v !== 28)) throw new LineError(400, "bad_signature", "the signature must have s in the lower half of the curve's order and v 27 or 28");
  return s.toLowerCase();
}
function signerOf(domain, types, message, signature) {
  try { return ethers.verifyTypedData(domain, types, message, signature); } catch { throw new LineError(400, "bad_signature", "the signature does not recover"); }
}
const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
/** A signature's bytes, as an ERC-1271 owner may write them (any length; the body's 4 KB bounds it), in lower case, or a
 *  400. A string that is not hex is refused before anything is read. */
export function bytesOf(s) {
  if (typeof s !== "string") throw bad("signature must be a string");
  if (!/^0x(?:[0-9a-fA-F]{2}){1,2048}$/.test(s)) throw new LineError(400, "bad_signature", "the signature must be bytes, in hex");
  return s.toLowerCase();
}
/** `signature` over the typed data as an EOA's: { signer } (the address it recovers to), or { why } (the 400 an EOA's
 *  signature of another form gets: its length, its s or v, no recovery). */
export function ecdsa(domain, types, message, signature) {
  try { signatureOf(signature); return { signer: signerOf(domain, types, message, signature) }; } catch (e) { if (e instanceof LineError) return { why: e }; throw e; }
}
/** ERC-6492's magic suffix: the last 32 bytes of a signature wrapped for a smart account not on chain yet (the work
 *  board's reads check such a signature; the line board's do not). */
export const ERC6492_SUFFIX = "6492".repeat(16);
/** Whether `signature` (hex) is in ERC-6492's wrapper. */
export const isErc6492 = (signature) => typeof signature === "string" && signature.length > 2 + 64 && signature.toLowerCase().endsWith(ERC6492_SUFFIX);
/** Whether `owner`, a contract, takes `signature` for the typed data: its ERC-1271 isValidSignature of the data's EIP-712
 *  hash, through `reads.isValidSignature` (true only for the magic word; an address with no code never, unless the reads
 *  check ERC-6492's wrapper, as the work board's do, and its deployless validator finds the account at `owner` takes it).
 *  False without that read (a caller of EOA owners only); a read that fails is a 503, never a pass. */
export async function contractSigned(owner, domain, types, message, signature, reads) {
  if (!owner || typeof reads.isValidSignature !== "function") return false;
  return (await chainRead(reads.isValidSignature(owner, ethers.TypedDataEncoder.hash(domain, types, message), signature))) === true;
}
/** A chain read, any failure a 503 (never read as a pass). */
export async function chainRead(p) {
  try { return await p; } catch { throw new LineError(503, "chain", "the chain could not be read just now; try again in a minute"); }
}
/** `expiry` (unix seconds) more than a minute ahead of `now` and at most `maxS` ahead; `what` names it. */
export function ahead(expiry, now, maxS, what) {
  const e = BigInt(expiry), t = BigInt(now);
  if (e <= t) throw expired(`${what} has passed`);
  if (e <= t + BigInt(RULES.aheadS)) throw bad(`${what} must be more than a minute ahead`);
  if (maxS != null && e > t + BigInt(maxS)) throw bad(`${what} must be at most ${Math.round(maxS / 86400)} days ahead`);
}

/* ---- verification ---- */

/**
 * A request ({ request, signature }) checked: its fields, its time, its signer, and that signer the agent's owner in the
 * ERC-8004 registry now (`reads.ownerOf`): the owner it names, by its ECDSA signature, or by its ERC-1271
 * isValidSignature when it is a contract (`reads.isValidSignature`). { id, request, signature, signer }, or a LineError.
 */
export async function verifyRequest(body, reads, { now = Math.floor(Date.now() / 1000) } = {}) {
  exactly(body, ["request", "signature"], "the body");
  const request = requestOf(body.request);
  ahead(request.expiry, now, RULES.standS, "the request's expiry");
  const signature = bytesOf(body.signature);
  const id = ethers.TypedDataEncoder.hash(MARKET_DOMAIN, REQUEST_TYPES, request);
  const e = ecdsa(MARKET_DOMAIN, REQUEST_TYPES, request, signature);
  if (same(e.signer, request.owner)) {
    const owner = await chainRead(reads.ownerOf(request.agentId));
    if (!same(owner, e.signer)) throw new LineError(403, "not_owner", `agent #${request.agentId} is not owned by ${e.signer} in the ERC-8004 registry`);
    return { id, request, signature, signer: e.signer };
  }
  // not the named owner's own ECDSA signature: taken only from the agent's registry owner, a contract that validates it
  const refusal = e.why || new LineError(403, "not_owner", "the request is not signed by the owner it names");
  if (typeof reads.isValidSignature !== "function") throw refusal;
  const owner = await chainRead(reads.ownerOf(request.agentId));
  if (!same(owner, request.owner) || !(await contractSigned(request.owner, MARKET_DOMAIN, REQUEST_TYPES, request, signature, reads))) throw refusal;
  return { id, request, signature, signer: request.owner };
}

/** That `sponsorId` is a root of the pool and `signer` its owner in the registry now (`reads.ownerOf`, `reads.isRoot`). */
async function standingRoot(sponsorId, signer, reads) {
  const [owner, isRoot] = await chainRead(Promise.all([reads.ownerOf(sponsorId), reads.isRoot(sponsorId)]));
  if (!same(owner, signer)) throw new LineError(403, "not_root_owner", `#${sponsorId} is not owned by ${signer} in the ERC-8004 registry`);
  if (isRoot !== true) throw new LineError(403, "not_root", `#${sponsorId} is not a root of the pool: only a root backs a line`);
}

/** The signer of a message a root's owner signs (an offer, which names no signer): the address its ECDSA signature
 *  recovers to when that is the root's registry owner, else the root's registry owner when it is a contract that
 *  validates it (ERC-1271); and that `sponsorId` a root. The signer, or the LineError an EOA's signature gets. */
async function rootSigner(sponsorId, domain, types, message, signature, reads) {
  const e = ecdsa(domain, types, message, signature);
  if (e.signer) {
    const [owner, isRoot] = await chainRead(Promise.all([reads.ownerOf(sponsorId), reads.isRoot(sponsorId)]));
    if (same(owner, e.signer) || !(await contractSigned(owner, domain, types, message, signature, reads))) {
      if (!same(owner, e.signer)) throw new LineError(403, "not_root_owner", `#${sponsorId} is not owned by ${e.signer} in the ERC-8004 registry`);
      if (isRoot !== true) throw new LineError(403, "not_root", `#${sponsorId} is not a root of the pool: only a root backs a line`);
      return e.signer;
    }
    if (isRoot !== true) throw new LineError(403, "not_root", `#${sponsorId} is not a root of the pool: only a root backs a line`);
    return ethers.getAddress(owner);
  }
  if (typeof reads.isValidSignature !== "function") throw e.why;
  const [owner, isRoot] = await chainRead(Promise.all([reads.ownerOf(sponsorId), reads.isRoot(sponsorId)]));
  if (!(await contractSigned(owner, domain, types, message, signature, reads))) throw e.why;
  if (isRoot !== true) throw new LineError(403, "not_root", `#${sponsorId} is not a root of the pool: only a root backs a line`);
  return ethers.getAddress(owner);
}

/**
 * An offer ({ offer, signature }) on the request `req` (verifyRequest's answer, as the board keeps it) checked: its
 * fields against the request's, its time, its signer (the root's registry owner, by its ECDSA signature or, a contract,
 * by its ERC-1271 isValidSignature), and that id a root now. { id, offer, signature, signer }, or a LineError.
 */
export async function verifyOffer(body, req, reads, { now = Math.floor(Date.now() / 1000) } = {}) {
  exactly(body, ["offer", "signature"], "the body");
  const offer = offerOf(body.offer);
  const r = req.request;
  if (offer.requestId !== req.id) throw new LineError(400, "wrong_request", "the offer names another request");
  if (offer.sponsorId === r.agentId) throw bad("an agent does not back itself");
  if (BigInt(offer.amount) > BigInt(r.line)) throw bad(`an offer is at most the line asked (${r.line} units)`);
  if (BigInt(offer.premiumBps) > BigInt(r.maxPremiumBps)) throw bad(`an offer's premium is at most the request's (${r.maxPremiumBps} bps)`);
  if (BigInt(r.expiry) <= BigInt(now)) throw expired("the request has expired");
  ahead(offer.expiry, now, null, "the offer's expiry");
  if (BigInt(offer.expiry) > BigInt(r.expiry)) throw bad("an offer stands no longer than its request");
  const signature = bytesOf(body.signature);
  const signer = await rootSigner(offer.sponsorId, MARKET_DOMAIN, OFFER_TYPES, offer, signature, reads);
  return { id: ethers.TypedDataEncoder.hash(MARKET_DOMAIN, OFFER_TYPES, offer), offer, signature, signer };
}

/**
 * An acceptance ({ offerId, consent, signature }) of the offer `offer` on the request `request` (as verifyOffer and
 * verifyRequest answered) checked: the pool's own Consent naming that one root, for that agent, a premium cap from the
 * offer's premium to the request's, the agent's current nonce (`reads.nonces`), a deadline ahead, signed in the pool's
 * domain by the agent's owner in the registry now (its ECDSA signature or, a contract, its ERC-1271 isValidSignature of
 * the pool's consentDigest, as vouchWithConsent checks it); and the offer still standing (its root still a root, still its
 * signer's). { consent, signature, signer, call: vouchCall's }, or a LineError.
 */
export async function verifyAcceptance(body, { request, offer }, reads, { now = Math.floor(Date.now() / 1000), pool = POOL, chainId = CHAIN_ID } = {}) {
  exactly(body, ["offerId", "consent", "signature"], "the body");
  if (bytes32Of(body.offerId, "offerId") !== offer.id) throw bad("the acceptance names another offer");
  const consent = consentOf(body.consent);
  const r = request.request, f = offer.offer;
  if (BigInt(r.expiry) <= BigInt(now)) throw expired("the request has expired");
  if (BigInt(f.expiry) <= BigInt(now)) throw expired("the offer has expired");
  ahead(consent.deadline, now, RULES.consentS, "the consent's deadline");
  if (consent.agentId !== r.agentId) throw new LineError(400, "consent_mismatch", "the consent names another agent than the request's");
  if (consent.sponsorId !== f.sponsorId) throw new LineError(400, "consent_mismatch", `the consent names another root than the offer's (#${f.sponsorId})`);
  const cap = BigInt(consent.maxPremiumBps);
  if (cap < BigInt(f.premiumBps) || cap > BigInt(r.maxPremiumBps)) throw new LineError(400, "consent_mismatch", `the consent's maxPremiumBps must be from the offer's premium (${f.premiumBps}) to the request's (${r.maxPremiumBps})`);
  const signature = bytesOf(body.signature);
  const domain = consentDomain({ pool, chainId });
  const e = ecdsa(domain, CONSENT_TYPES, consent, signature);
  // not the named owner's own ECDSA signature: taken only from the agent's registry owner, a contract that validates it
  const refusal = e.why || new LineError(403, "not_consent", "the signature is not the pool's Consent signed by the owner it names");
  const own = same(e.signer, consent.owner);
  if (!own && typeof reads.isValidSignature !== "function") throw refusal;
  const [owner, nonce] = await chainRead(Promise.all([reads.ownerOf(consent.agentId), reads.nonces(consent.agentId)]));
  if (own && !same(owner, consent.owner)) throw new LineError(403, "not_consent", `agent #${consent.agentId} is not owned by ${consent.owner} in the ERC-8004 registry`);
  if (!own && (!same(owner, consent.owner) || !(await contractSigned(consent.owner, domain, CONSENT_TYPES, consent, signature, reads)))) throw refusal;
  if (BigInt(nonce) !== BigInt(consent.nonce)) throw new LineError(400, "wrong_nonce", `the consent's nonce must be the agent's current one (${nonce})`);
  await standingRoot(f.sponsorId, offer.signer, reads);
  return { consent, signature, signer: own ? e.signer : consent.owner, call: vouchCall({ request, offer, consent, signature, pool, chainId }) };
}

/**
 * The call the root's owner sends itself for an accepted offer: { chainId, to (the pool), from (the root's owner, the
 * one address the pool lets use the consent), value, function, args, calldata }. Built, never sent.
 */
export function vouchCall({ request, offer, consent, signature, pool = POOL, chainId = CHAIN_ID }) {
  const r = request.request, f = offer.offer, c = consent;
  const calldata = VOUCH_IFACE.encodeFunctionData("vouchWithConsent", [f.sponsorId, r.agentId, f.amount, f.premiumBps, [c.agentId, c.sponsorId, c.owner, c.maxPremiumBps, c.nonce, c.deadline], signature]);
  return {
    chainId, to: pool, from: offer.signer, value: "0", function: VOUCH_SIGNATURE,
    args: { sponsorId: f.sponsorId, agentId: r.agentId, amount: f.amount, premiumBps: f.premiumBps, c, sig: signature },
    calldata,
  };
}
