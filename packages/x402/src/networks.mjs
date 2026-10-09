// The networks and tokens a Priors payer may sign for, and the bridge contracts and hosts it may talk to: a frozen
// allowlist, matched by full address only (never by symbol or name). Every value here was read on chain or from the
// live APIs on 2026-10-08 (docs/X402-BASE-PLAN.md, "Built (phase 1)").
//
// Robinhood Chain USDG (eip155:4663) is the default and the only network a payer signs for unless the caller enables
// another. Base USDC (eip155:8453) is signed for only when the caller passes it (`networks` in createPayer and
// createUsdgClient; PRIORS_PAY_NETWORKS in @priors/mcp): an agent pays it from a small USDC balance it keeps on Base,
// the Base float, which bridge.mjs fills from its Priors line on Robinhood Chain and empties back.
//
// Lookalike USDG: two tokens on Robinhood Chain copy USDG's address prefix and suffix and call themselves "USDG"
// (0x5fc591225f1f20C08C3c59Fe25826F6a36e1d168 and 0x5fc54b6CbC5ccD9B112ddfF3326Caeeaba33d168, each in a pool that shows
// huge fake reserves). Only the full addresses below are accepted, anywhere a token, a spoke or a receiver is read
// from a 402, a quote or a bridge's answer.

/** One payment network: its CAIP-2 id, chain id, the one token paid there, and that token's EIP-712 domain. */
const net = (o) => Object.freeze({ ...o, eip712: Object.freeze(o.eip712) });

/** Every network a payer can sign for, by CAIP-2 id. A network not listed here is never signed for. */
export const NETWORKS = Object.freeze({
  "eip155:4663": net({
    network: "eip155:4663", chainId: 4663, name: "Robinhood Chain",
    /** USDG (Global Dollar): its DOMAIN_SEPARATOR matches "Global Dollar" / "1" (it has no version() function). */
    asset: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", symbol: "USDG", decimals: 6,
    eip712: { name: "Global Dollar", version: "1" },
    rpcUrl: "https://rpc.mainnet.chain.robinhood.com",
  }),
  "eip155:8453": net({
    network: "eip155:8453", chainId: 8453, name: "Base",
    /** Circle's USDC on Base: name() "USD Coin", version() "2", and its DOMAIN_SEPARATOR matches both. */
    asset: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", symbol: "USDC", decimals: 6,
    eip712: { name: "USD Coin", version: "2" },
    rpcUrl: "https://mainnet.base.org",
  }),
});

/** Robinhood Chain and Base, by name. */
export const ROBINHOOD_USDG = NETWORKS["eip155:4663"];
export const BASE_USDC = NETWORKS["eip155:8453"];

/** What a payer signs for unless told otherwise: Robinhood Chain USDG only. */
export const DEFAULT_PAY_NETWORKS = Object.freeze(["eip155:4663"]);

/** The network entry for a CAIP-2 id, or null. Own keys only: "constructor" or "__proto__" is not a network. */
export function networkOf(id) {
  return typeof id === "string" && Object.prototype.hasOwnProperty.call(NETWORKS, id) ? NETWORKS[id] : null;
}

/**
 * The networks a caller enabled, checked against the allowlist: a list of CAIP-2 ids (an array, or a comma-separated
 * string such as PRIORS_PAY_NETWORKS), duplicates dropped, order kept. Empty or missing: DEFAULT_PAY_NETWORKS. An id
 * not in NETWORKS throws (a typo must not leave the caller believing a network is on).
 * @param {string | string[] | undefined | null} list
 * @returns {readonly string[]}
 */
export function payNetworks(list) {
  const items = (Array.isArray(list) ? list : typeof list === "string" ? list.split(",") : []).map((s) => String(s).trim()).filter(Boolean);
  if (items.length === 0) return DEFAULT_PAY_NETWORKS;
  const out = [];
  for (const id of items) {
    if (!networkOf(id)) throw new RangeError(`not a network this package pays on: ${JSON.stringify(id.slice(0, 40))} (known: ${Object.keys(NETWORKS).join(", ")})`);
    if (!out.includes(id)) out.push(id);
  }
  return Object.freeze(out);
}

/**
 * Across (app.across.to): the route from Robinhood Chain USDG to Base USDC. Its SpokePool on each chain, pinned: every
 * quote naming another spoke, token or chain is refused. Both spokes allow a quote at most `quoteTimeBuffer` seconds
 * old (depositQuoteTimeBuffer) and a fill deadline at most `fillDeadlineBuffer` seconds ahead (fillDeadlineBuffer),
 * read on chain 2026-10-08.
 */
export const ACROSS = Object.freeze({
  api: "https://app.across.to",
  spokes: Object.freeze({ 4663: "0xD29C85F15DF544bA632C9E25829fd29d767d7978", 8453: "0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64" }),
  quoteTimeBuffer: 3600,
  fillDeadlineBuffer: 21600,
});

/**
 * Relay (api.relay.link): the way back, Base USDC to Robinhood Chain USDG, with one EIP-3009 ReceiveWithAuthorization
 * and no gas on Base. The authorization goes to Relay's approval proxy, the same address on both chains (it has code
 * on both), and nowhere else. Relay's quotes are valid about 10 minutes; one asking for a longer authorization than
 * `maxValiditySeconds` is refused.
 */
export const RELAY = Object.freeze({
  api: "https://api.relay.link",
  receiver: "0xCcC88a9d1B4ED6b0EABA998850414b24f1c315bE",
  maxValiditySeconds: 900,
});
