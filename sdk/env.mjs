// Resolving "which chain, which pool, which wallet" is the part every agent gets wrong first, so it lives here
// instead of in each script. Nothing is stored anywhere but the chain and your own .env.
//
//   import { resolve } from "./sdk/env.mjs";
//   const { priors, agentWallet, dep, chainId } = await resolve();
//
// Order of precedence, highest first:
//   POOL / TREASURY / USDC env vars   -> explicit addresses, any chain
//   deployments/<chainId>.json        -> whatever `npm run devnet` or a real deployment wrote
//
// The signer comes from PRIVATE_KEY. On a local dev chain (31337) a deterministic throwaway wallet is derived
// instead, so `npm run quickstart` works with no setup at all; that fallback never applies to a real chain.
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";
import { Priors } from "./priors.mjs";

export const ROOT = resolvePath(dirname(fileURLToPath(import.meta.url)), "..");
export const DEV_CHAIN = 31337;
/// anvil's own published test mnemonic. Public by design, worthless by design, and never used off chain 31337.
export const DEV_MNEMONIC = "test test test test test test test test test test test junk";
/// wallet 0 of that mnemonic: anvil pre-funds it, and `npm run devnet` deploys and lends from it.
export const devWallet = (index) => ethers.HDNodeWallet.fromPhrase(DEV_MNEMONIC, undefined, `m/44'/60'/0'/0/${index}`);

export const deploymentPath = (chainId) => join(ROOT, "deployments", `${chainId}.json`);

// --- money ---------------------------------------------------------------------------------------------------
// USDG has 6 decimals on chain and the SDK speaks whole dollars, so this conversion happens in a dozen places.
// It lives here once: a second implementation that rounds differently is how $0.011666 becomes $0.012.
export const USDG_DECIMALS = 6n;
const UNIT = 10n ** USDG_DECIMALS;
/** Whole dollars (number or bigint) -> 6-decimal units. */
export const toUnits = (dollars) => (typeof dollars === "bigint" ? dollars * UNIT : BigInt(Math.round(Number(dollars) * Number(UNIT))));
/** 6-decimal units -> dollars as a number. Fine for display; do not do arithmetic on the result. */
export const fromUnits = (units) => Number(units) / Number(UNIT);
/**
 * Money, formatted for a human, identically everywhere.
 * Pinned to en-US on purpose: the default locale renders $0.0116 as $0,0116 on a French machine, and a CLI whose
 * output depends on who ran it is a CLI whose output nobody can paste into a bug report.
 */
export const formatUsd = (dollars) => `$${Number(dollars).toLocaleString("en-US", { maximumFractionDigits: Number(USDG_DECIMALS) })}`;
/** Same, from raw on-chain units. */
export const formatUnits = (units) => formatUsd(fromUnits(units));

export function readDeployment(chainId) {
  const p = deploymentPath(chainId);
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, "utf8"));
}

export class NoDeployment extends Error {
  constructor(chainId) {
    super(
      `no deployment for chain ${chainId}.\n` +
        (chainId === DEV_CHAIN
          ? "  run `npm run devnet` first (it starts a local chain and deploys the pool)."
          : "  the CreditPool is not deployed on this chain yet. Set POOL and TREASURY explicitly, or run\n" +
            "  `npm run devnet` for a local chain. See the Status section of the README.")
    );
    this.chainId = chainId;
  }
}

/**
 * @param {{rpc?: string, privateKey?: string, needSigner?: boolean}} [opts]
 */
export async function resolve(opts = {}) {
  const rpc = opts.rpc || process.env.RPC_URL || "http://127.0.0.1:8545";
  // cacheTimeout off: on chains that mine instantly, ethers' 250 ms result cache hands back stale nonces
  const provider = new ethers.JsonRpcProvider(rpc, undefined, { cacheTimeout: -1 });
  let chainId;
  try {
    chainId = Number((await provider.getNetwork()).chainId);
  } catch (e) {
    throw new Error(`cannot reach ${rpc}: ${e.shortMessage || e.message}\n  is the chain running? \`npm run devnet\` starts a local one.`);
  }

  const file = readDeployment(chainId) || {};
  const dep = {
    chainId,
    creditPool: process.env.POOL || file.creditPool,
    treasurySponsor: process.env.TREASURY || file.treasurySponsor,
    usdc: process.env.USDC || file.usdc,
    registry: file.registry,
    usdcIsMock: process.env.USDC ? false : Boolean(file.usdcIsMock),
    treasuryAgentId: file.treasuryAgentId,
  };
  if (!dep.creditPool) throw new NoDeployment(chainId);

  const pk = opts.privateKey || process.env.PRIVATE_KEY;
  let signer = null;
  let derived = false;
  if (pk) {
    signer = new ethers.NonceManager(new ethers.Wallet(pk, provider));
  } else if (chainId === DEV_CHAIN) {
    // a wallet outside the range devnet.mjs and the demos fund, so a quickstart never collides with them
    signer = new ethers.NonceManager(devWallet(50).connect(provider));
    derived = true;
  } else if (opts.needSigner) {
    throw new Error("PRIVATE_KEY is not set. This chain is not a dev chain, so no wallet can be derived for you.\n  cp .env.example .env and put in the key that owns (or will own) your ERC-8004 identity.");
  }

  const priors = new Priors({ provider, pool: dep.creditPool, treasury: dep.treasurySponsor, signer });
  return { provider, signer, derived, dep, chainId, rpc, priors, address: signer ? await signer.getAddress() : null };
}

/** True when the chain answers anvil/hardhat cheat methods, i.e. we may warp time and mint mock money. */
export async function isDevChain(provider) {
  try {
    await provider.send("anvil_nodeInfo", []);
    return true;
  } catch {
    return false;
  }
}
