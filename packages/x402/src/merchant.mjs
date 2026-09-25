// Merchant side: price routes in dollars on Robinhood Chain and settle through the Priors facilitator, with the
// official @x402/* packages doing all the protocol work.
//
//   import { ExactEvmScheme } from "@x402/evm/exact/server";
//   import { x402ResourceServer, HTTPFacilitatorClient } from "@x402/core/server";
//   const server = new x402ResourceServer(new HTTPFacilitatorClient(priorsFacilitator({ apiKey })))
//     .register(robinhood.network, registerUsdg(new ExactEvmScheme()));
import { HTTPFacilitatorClient, x402ResourceServer } from "@x402/core/server";
import { ExactEvmScheme } from "@x402/evm/exact/server";
import { robinhood } from "./robinhood.mjs";

/**
 * Teach an `ExactEvmScheme` (server side, from `@x402/evm/exact/server`) that a Money price ("$0.05", "0.05", 0.05)
 * on `eip155:4663` means USDG: 6 decimals, EIP-712 domain "Global Dollar" / "1" in `extra`, which the client needs
 * to sign EIP-3009. Other networks are untouched (the parser answers null, so the next parser or the scheme's
 * default runs). A price finer than one USDG unit (6 decimals) is refused rather than rounded.
 * @template {{ registerMoneyParser: Function }} S
 * @param {S} scheme
 * @param {{ asset?: string }} [opts]  a different USDG address (a fork or test token); default: mainnet USDG
 * @returns {S} the same scheme, for chaining
 */
export function registerUsdg(scheme, { asset = robinhood.usdg } = {}) {
  if (!scheme || typeof scheme.registerMoneyParser !== "function") {
    throw new TypeError("registerUsdg: pass an ExactEvmScheme from @x402/evm/exact/server (it has registerMoneyParser)");
  }
  scheme.registerMoneyParser(async (amount, network) => {
    if (network !== robinhood.network) return null;
    return { amount: dollarsToUnits(amount), asset, extra: { name: robinhood.eip712.name, version: robinhood.eip712.version } };
  });
  return scheme;
}

/** "0.05" (the decimal string ExactEvmScheme hands a money parser) → "50000". */
function dollarsToUnits(amount) {
  const s = typeof amount === "number" ? numberToPlain(amount) : String(amount).trim();
  const m = /^(\d+)(?:\.(\d+))?$/.exec(s);
  if (!m) throw new Error(`USDG price: not a dollar amount: ${JSON.stringify(s)}`);
  const frac = (m[2] || "").replace(/0+$/, "");
  if (frac.length > robinhood.usdgDecimals) throw new Error(`USDG price ${s} has more than ${robinhood.usdgDecimals} decimals (smaller than one USDG unit)`);
  const units = (BigInt(m[1]) * 10n ** BigInt(robinhood.usdgDecimals) + BigInt(frac.padEnd(robinhood.usdgDecimals, "0") || "0")).toString();
  if (units === "0") throw new Error("USDG price must be above zero");
  return units;
}
function numberToPlain(n) {
  if (!Number.isFinite(n) || n < 0) throw new Error(`USDG price: not a dollar amount: ${n}`);
  return n.toFixed(12).replace(/\.?0+$/, "");
}

/**
 * Config for the official `HTTPFacilitatorClient` (`@x402/core/server`) pointed at the Priors facilitator.
 * With an `apiKey` (the merchant key from POST /merchants/register), `createAuthHeaders` returns
 * `Authorization: Bearer <apiKey>` keyed by path ({verify, settle, supported}), as HTTPFacilitatorClient requires:
 * a flat headers object makes it throw. The key lives in a closure, not in an enumerable property, so logging or
 * JSON-serialising the config does not print it.
 * @param {{ url?: string, apiKey?: string, timeoutMs?: number }} [opts]
 * @returns {import("@x402/core/server").FacilitatorConfig}
 */
export function priorsFacilitator({ url = robinhood.facilitatorUrl, apiKey, timeoutMs } = {}) {
  let u;
  try { u = new URL(url); } catch (_) { throw new TypeError(`priorsFacilitator: not a URL: ${JSON.stringify(url)}`); }
  const local = u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "::1" || u.hostname === "[::1]";
  if (u.protocol !== "https:" && !(local && u.protocol === "http:")) throw new TypeError("priorsFacilitator: the facilitator URL must be https (http only for localhost)");
  /** @type {import("@x402/core/server").FacilitatorConfig} */
  const config = { url: u.toString().replace(/\/+$/, "") };
  if (timeoutMs !== undefined) config.timeoutMs = timeoutMs;
  if (apiKey !== undefined && apiKey !== null && apiKey !== "") {
    // A key with whitespace or control characters would split or corrupt the header: refuse it.
    if (typeof apiKey !== "string" || !/^[\x21-\x7e]{8,512}$/.test(apiKey)) throw new TypeError("priorsFacilitator: apiKey must be a printable string without spaces (8 to 512 characters)");
    const key = apiKey;
    config.createAuthHeaders = async () => {
      const h = () => ({ Authorization: `Bearer ${key}` });
      return { verify: h(), settle: h(), supported: h() };
    };
  }
  return config;
}

/** `new HTTPFacilitatorClient(priorsFacilitator(opts))`. */
export function priorsFacilitatorClient(opts = {}) {
  return new HTTPFacilitatorClient(priorsFacilitator(opts));
}

/**
 * An `x402ResourceServer` that settles through the Priors facilitator and prices `eip155:4663` in USDG: the
 * three lines of the README's merchant snippet in one call. Pass it to `paymentMiddleware` (@x402/express,
 * @x402/hono, @x402/next) or `createPaymentWrapper` (@x402/mcp).
 * @param {{ url?: string, apiKey?: string, timeoutMs?: number, asset?: string, facilitatorClient?: any }} [opts]
 */
export function createResourceServer({ asset, facilitatorClient, ...facilitator } = {}) {
  return new x402ResourceServer(facilitatorClient || priorsFacilitatorClient(facilitator)).register(robinhood.network, registerUsdg(new ExactEvmScheme(), { asset }));
}
