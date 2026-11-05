// Payer side: check who gets paid before an agent pays, with Toll's free pre-sign check, in one line.
//
//   import { createPayer } from "@priors/x402";
//   import { tollCheck } from "@priors/x402/toll";
//   const payer = createPayer({ signer, agentId, pool, maxBorrow, beforePay: tollCheck() });
//
// Toll (t0ll.xyz, ERC-8004 agent #20030 on Robinhood Chain) answers POST https://t0ll.xyz/api/tx/check with an ERC-8265
// RiskAssessment: ALLOW / WARN / BLOCK and the reasons. For an x402 payment it reads the seller's ERC-8004 identity and
// checks payTo against its registered agentWallet or a payee delegation (the ERC-8478 draft), the asset and the amount;
// a payTo that is not the seller's is BLOCK (x402-payee-mismatch). Free, keyless; nothing is signed or sent to it but
// the 402's requirement and the URL bought.
//
// What it does in `beforePay` (payer.mjs), so before anything is read, topped up, borrowed or signed:
//   - an action in `refuse` (default ["BLOCK"]; add "WARN" for a strict agent): PayError TOLL_REFUSED, with Toll's
//     warning codes (Toll's words, never the merchant's) and the link to read more;
//   - an answer Toll could not give (timeout, HTTP error, not JSON): PayError TOLL_UNREAD, which refuses the payment
//     (fails closed), or lets it go on with `failOpen: true`;
//   - every answer read is handed to `onResult` first, when given (a log, a counter).
import { PayError } from "./credit.mjs";

export const TOLL_CHECK_URL = "https://t0ll.xyz/api/tx/check";
export const TOLL_TIMEOUT_MS = 8_000;
const ACTIONS = new Set(["ALLOW", "WARN", "BLOCK"]);
const CODE = /^[a-z0-9][a-z0-9-]{0,63}$/;

/**
 * A `beforePay` that asks Toll about the payment and refuses what it says to refuse.
 * @param {{ url?: string, refuse?: string[], agentId?: number|bigint|string, timeoutMs?: number, failOpen?: boolean,
 *   fetchImpl?: typeof fetch, onResult?: (r: { action: string, codes: string[], link: string|null }) => any }} [o]
 */
export function tollCheck(o = {}) {
  const url = o.url ?? TOLL_CHECK_URL;
  const refuse = new Set((o.refuse ?? ["BLOCK"]).map((a) => String(a).toUpperCase()));
  for (const a of refuse) if (!ACTIONS.has(a) || a === "ALLOW") throw new PayError("BAD_TOLL_OPTION", "tollCheck: `refuse` takes \"BLOCK\" and \"WARN\" only");
  const timeoutMs = o.timeoutMs ?? TOLL_TIMEOUT_MS;
  const fetchImpl = o.fetchImpl ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") throw new PayError("NO_FETCH", "tollCheck: no fetch implementation");
  const agentId = o.agentId === undefined || o.agentId === null ? null : Number(o.agentId);
  if (agentId !== null && (!Number.isSafeInteger(agentId) || agentId < 0)) throw new PayError("BAD_TOLL_OPTION", "tollCheck: `agentId` is the seller's ERC-8004 id, a whole number");

  return async function tollBeforePay({ requirement, x402Version, resource }) {
    const x402 = x402Version === 2 ? { x402Version: 2, resource: { url: resource }, accepts: [requirement] } : { ...requirement, resource };
    const body = JSON.stringify({ x402, ...(agentId !== null ? { agentId } : {}) });
    let a;
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), timeoutMs);
      let r;
      try { r = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json" }, body, signal: ctl.signal }); }
      finally { clearTimeout(timer); }
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      a = await r.json();
      if (!a || !ACTIONS.has(a.action)) throw new Error("no action in the answer");
    } catch (e) {
      if (o.failOpen) return;
      throw new PayError("TOLL_UNREAD", `pay: Toll's payee check did not answer (${e?.name === "AbortError" ? `no answer in ${timeoutMs / 1000} s` : String(e?.message ?? e).slice(0, 80)}); nothing was read, borrowed or signed. Pass failOpen: true to pay without it.`);
    }
    const codes = (Array.isArray(a.warnings) ? a.warnings : []).map((w) => w?.code).filter((c) => typeof c === "string" && CODE.test(c)).slice(0, 10);
    const link = typeof a["x-toll"]?.link === "string" && a["x-toll"].link.startsWith("https://t0ll.xyz/") ? a["x-toll"].link : null;
    if (typeof o.onResult === "function") await o.onResult({ action: a.action, codes, link });
    if (refuse.has(a.action)) {
      throw new PayError("TOLL_REFUSED", `pay: Toll's payee check answered ${a.action}${codes.length ? ` (${codes.join(", ")})` : ""}; nothing was read, borrowed or signed${link ? `. Read more: ${link}` : ""}`, { action: a.action, codes, link });
    }
  };
}
