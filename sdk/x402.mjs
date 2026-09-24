// x402 v1 "exact" scheme constants for USDG on Robinhood Chain (chain 4663): the client half of what the Priors
// facilitator (https://facilitator.priors.trade) verifies. No I/O.
//
// Payload format follows the x402 reference, x402 v1 "exact" EVM scheme (https://github.com/x402-foundation/x402):
//
//   X-PAYMENT = base64(JSON {
//     x402Version: 1, scheme: "exact", network: "robinhood",
//     payload: { signature: "0x…65 bytes", authorization: { from, to, value, validAfter, validBefore, nonce } }
//   })
//
// The signature is EIP-712 TransferWithAuthorization (EIP-3009) on USDG's own domain: name "Global Dollar",
// version "1", chainId 4663, verifyingContract = USDG (matched against USDG's DOMAIN_SEPARATOR).
import { ethers } from "ethers";

export const NETWORK = "robinhood";
export const CHAIN_ID = 4663;
export const CAIP2 = `eip155:${CHAIN_ID}`;
export const NETWORKS = new Set([NETWORK, CAIP2]);
export const USDG_MAINNET = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
export const USDG_DOMAIN = { name: "Global Dollar", version: "1" };
/** The public Priors facilitator. GET /health is open; POST /settle needs a merchant API key. */
export const FACILITATOR_URL = "https://facilitator.priors.trade";

export const TRANSFER_WITH_AUTHORIZATION_TYPES = {
  TransferWithAuthorization: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "validAfter", type: "uint256" },
    { name: "validBefore", type: "uint256" },
    { name: "nonce", type: "bytes32" },
  ],
};

export const domainFor = (asset, chainId = CHAIN_ID) => ({ ...USDG_DOMAIN, chainId, verifyingContract: ethers.getAddress(asset) });

/** Decode the base64 X-PAYMENT header. Returns null on anything malformed. */
export function decodePaymentHeader(header) {
  if (typeof header !== "string" || header.length === 0 || header.length > 8192) return null;
  try {
    const p = JSON.parse(Buffer.from(header, "base64").toString("utf8"));
    return p && typeof p === "object" ? p : null;
  } catch (_) {
    return null;
  }
}

export const encodePaymentHeader = (payment) => Buffer.from(JSON.stringify(payment)).toString("base64");
