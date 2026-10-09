// `priors-mcp link-wallet` (0.8.0): the agent's own key signs the ERC-8004 registry's AgentWalletSet message, so
// the agent's owner can declare that key the agent's wallet (`setAgentWallet`) and so prove, before any money moves,
// that the runtime really holds the key. A pasted address proves nothing: a typo, or someone else's address, would
// receive the USDG Go mode borrows for the agent. Declared, the wallet's x402 income also counts as the agent's.
//
// What is signed is exactly what the live registry checks (IdentityRegistryUpgradeable 2.0.0 on Robinhood Chain, read
// on 2026-10-09: eip712Domain() answers "ERC8004IdentityRegistry", version "1", chain 4663, the registry itself, no salt;
// the type hash below is in its code):
//   AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)
// with `owner` the agent's owner (ownerOf) when the owner sends the call, and `deadline` at most 5 minutes after the
// block that includes it (MAX_DEADLINE_DELAY). So the signature is good for a few minutes only: this command signs
// for 4 minutes past the chain's latest block by default (--valid, 30 to 290 seconds), and is run again for a fresh one.
//
// Before signing it reads the registry's eip712Domain() and refuses if any field differs from the one above (another
// contract, another chain, an upgrade that changed the domain): it never signs for a domain it does not know. It reads
// the owner from the chain (--owner, when given, must match it), never from the agent's text. It is a command the
// operator runs, never an MCP tool: a model reading untrusted text must not be able to sign a wallet over to an agent
// someone else names. The key comes from PRIORS_KEY_FILE or PRIORS_KEY, as for the server, and is never printed.
import { ethers } from "ethers";
import { readFileSync } from "node:fs";
import { keyFromEnv } from "./key-file.mjs";

export const REGISTRY_EIP712 = Object.freeze({ name: "ERC8004IdentityRegistry", version: "1" });
export const AGENT_WALLET_TYPES = Object.freeze({ AgentWalletSet: [
  { name: "agentId", type: "uint256" }, { name: "newWallet", type: "address" }, { name: "owner", type: "address" }, { name: "deadline", type: "uint256" },
] });
/** The registry's MAX_DEADLINE_DELAY: a deadline later than this past the including block is refused ("deadline too far"). */
export const MAX_DEADLINE_DELAY_S = 300;
export const DEFAULT_VALID_S = 240;
export const REGISTRY_ABI = [
  "function eip712Domain() view returns (bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)",
  "function ownerOf(uint256 agentId) view returns (address)",
  "function getAgentWallet(uint256 agentId) view returns (address)",
  "function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes signature)",
];

export class LinkError extends Error {}

/**
 * Sign AgentWalletSet for `agentId` with `signer` (an ethers Wallet, the agent's key) against `registry` on chain
 * `chainId`, reading the domain, the owner, the declared wallet and the latest block through `provider`. Returns what
 * the owner needs to send `setAgentWallet`, or { alreadyLinked: true } when the key is already the agent's wallet.
 */
export async function signAgentWallet({ signer, provider, registry, chainId = 4663, agentId, validSeconds = DEFAULT_VALID_S, expectOwner = null }) {
  if (!Number.isInteger(validSeconds) || validSeconds < 30 || validSeconds > MAX_DEADLINE_DELAY_S - 10) throw new LinkError(`--valid must be a whole number of seconds from 30 to ${MAX_DEADLINE_DELAY_S - 10} (the registry takes a deadline at most ${MAX_DEADLINE_DELAY_S / 60} minutes ahead)`);
  const id = BigInt(agentId);
  const reg = new ethers.Contract(registry, REGISTRY_ABI, provider);
  let d;
  try { d = await reg.eip712Domain(); } catch (e) { throw new LinkError(`the registry at ${registry} did not answer eip712Domain() (${e?.shortMessage || e?.message || e}); nothing was signed`); }
  const same = d.name === REGISTRY_EIP712.name && d.version === REGISTRY_EIP712.version && BigInt(d.chainId) === BigInt(chainId)
    && ethers.getAddress(d.verifyingContract) === ethers.getAddress(registry) && d.fields === "0x0f" && /^0x0{64}$/.test(d.salt) && d.extensions.length === 0;
  if (!same) throw new LinkError(`the registry's EIP-712 domain is not the one this version signs for (it answered "${String(d.name).slice(0, 60)}" version "${String(d.version).slice(0, 20)}" on chain ${d.chainId} for ${d.verifyingContract}); nothing was signed. Update @priors/mcp.`);
  let owner;
  try { owner = ethers.getAddress(await reg.ownerOf(id)); } catch (_) { throw new LinkError(`agent #${id} does not exist on the registry (ownerOf failed); nothing was signed`); }
  if (expectOwner && ethers.getAddress(expectOwner) !== owner) throw new LinkError(`agent #${id} is owned by ${owner}, not by ${ethers.getAddress(expectOwner)}; nothing was signed`);
  const newWallet = ethers.getAddress(await signer.getAddress());
  let current = null;
  try { current = ethers.getAddress(await reg.getAgentWallet(id)); } catch (_) { /* unknown: sign anyway */ }
  const base = { registry: ethers.getAddress(registry), chainId: Number(chainId), agentId: String(id), newWallet, owner };
  if (current === newWallet) return { ...base, alreadyLinked: true };
  const block = await provider.getBlock("latest");
  if (!block || !Number.isSafeInteger(Number(block.timestamp))) throw new LinkError("could not read the chain's latest block; nothing was signed");
  const deadline = BigInt(block.timestamp) + BigInt(validSeconds);
  const domain = { ...REGISTRY_EIP712, chainId: Number(chainId), verifyingContract: base.registry };
  const message = { agentId: id, newWallet, owner, deadline };
  const signature = await signer.signTypedData(domain, AGENT_WALLET_TYPES, message);
  if (ethers.verifyTypedData(domain, AGENT_WALLET_TYPES, message, signature) !== newWallet) throw new LinkError("the signature did not verify; nothing to send");
  const calldata = new ethers.Interface(REGISTRY_ABI).encodeFunctionData("setAgentWallet", [id, newWallet, deadline, signature]);
  return { ...base, alreadyLinked: false, deadline: String(deadline), expiresAt: new Date(Number(deadline) * 1000).toISOString().replace(".000Z", "Z"), signature, digest: ethers.TypedDataEncoder.hash(domain, AGENT_WALLET_TYPES, message), calldata };
}

const HELP = `priors-mcp link-wallet: sign the ERC-8004 AgentWalletSet message with the agent's key, so its owner can declare
this key the agent's wallet (setAgentWallet on the identity registry).

  priors-mcp link-wallet --agent <id> [--owner <0x address>] [--valid <seconds>] [--json]

The key comes from PRIORS_KEY_FILE (a file only you can read) or PRIORS_KEY, never from the command line; PRIORS_RPC
picks the endpoint. The owner must send the call within --valid seconds (default ${DEFAULT_VALID_S}, at most ${MAX_DEADLINE_DELAY_S - 10}): the
registry takes a signature at most 5 minutes ahead. Run it again for a fresh one.
`;

/** The command: parses `argv` (after "link-wallet"), prints to `out`/`err`, returns the exit code. */
export async function runLinkWallet(argv, { env = process.env, out = (s) => process.stdout.write(s), err = (s) => process.stderr.write(s), deps = {} } = {}) {
  const o = { json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const [flag, inline] = a.startsWith("--") && a.includes("=") ? [a.slice(0, a.indexOf("=")), a.slice(a.indexOf("=") + 1)] : [a, undefined];
    const val = () => { if (inline !== undefined) return inline; i++; if (i >= argv.length) throw new LinkError(`${flag} needs a value`); return argv[i]; };
    try {
      if (flag === "--help" || flag === "-h") { err(HELP); return 0; }
      else if (flag === "--json") o.json = true;
      else if (flag === "--agent") o.agent = val();
      else if (flag === "--owner") o.owner = val();
      else if (flag === "--valid") o.valid = val();
      else throw new LinkError(`unknown argument ${JSON.stringify(a.slice(0, 40))} (see --help)`);
    } catch (e) { err(`priors-mcp link-wallet: ${e.message}\n`); return 2; }
  }
  const fail = (m, code = 1) => { err(`priors-mcp link-wallet: ${m}\n`); return code; };
  const agentRaw = String(o.agent ?? env.PRIORS_AGENT_ID ?? "").trim();
  if (!/^\d{1,78}$/.test(agentRaw)) return fail(agentRaw ? "--agent must be a decimal agent id" : "name the agent: --agent <id> (or set PRIORS_AGENT_ID)", 2);
  if (o.owner !== undefined && !/^0x[0-9a-fA-F]{40}$/.test(o.owner)) return fail("--owner must be a 0x address", 2);
  if (o.valid !== undefined && !/^\d{1,4}$/.test(o.valid)) return fail(`--valid must be a whole number of seconds from 30 to ${MAX_DEADLINE_DELAY_S - 10}`, 2);
  const keyed = deps.key ?? keyFromEnv(env, deps.keyFile);
  if (keyed.problem) return fail(`${keyed.problem}. Nothing was signed.`);
  if (!keyed.key) return fail("no key: set PRIORS_KEY_FILE to a file holding the agent's key (only you may read it), or PRIORS_KEY. Never pass a key on the command line.");
  if (!/^(0x)?[0-9a-fA-F]{64}$/.test(keyed.key)) return fail("PRIORS_KEY is not a 32-byte hex private key. Nothing was signed.");
  const dep = deps.deployments ?? JSON.parse(readFileSync(new URL("../deployments/4663.v2.json", import.meta.url), "utf8"));
  const provider = deps.provider ?? new ethers.JsonRpcProvider(env.PRIORS_RPC || "https://rpc.mainnet.chain.robinhood.com", ethers.Network.from(4663), { staticNetwork: true, cacheTimeout: -1, batchMaxCount: 1 });
  const signer = new ethers.Wallet(keyed.key);
  const secret = keyed.key.replace(/^0x/i, "").toLowerCase();
  const clean = (s) => String(s).split(secret).join("<redacted>").split(secret.toUpperCase()).join("<redacted>");
  let r;
  try {
    r = await signAgentWallet({ signer, provider, registry: dep.registry, chainId: dep.chainId ?? 4663, agentId: agentRaw, validSeconds: o.valid === undefined ? DEFAULT_VALID_S : Number(o.valid), expectOwner: o.owner ?? null });
  } catch (e) {
    const m = e instanceof LinkError ? e.message : `could not reach the chain (${e?.shortMessage || e?.message || e}); nothing was signed`;
    // a private RPC URL (it can carry a token) is cut whole and by its host, as the server cuts it from answers
    let t = clean(m);
    if (env.PRIORS_RPC) { const parts = [env.PRIORS_RPC]; try { const u = new URL(env.PRIORS_RPC); parts.push(u.href, u.host, u.hostname); } catch (_) { /* the literal */ } for (const p of parts.filter((x) => x && x.length >= 6).sort((a, b) => b.length - a.length)) t = t.split(p).join("<rpc>"); }
    return fail(t);
  } finally { if (!deps.provider) provider.destroy?.(); }
  if (o.json) { out(`${JSON.stringify(r)}\n`); return 0; }
  if (r.alreadyLinked) { out(`${r.newWallet} is already agent #${r.agentId}'s ERC-8004 wallet (owner ${r.owner}): nothing to sign.\n`); return 0; }
  const paste = JSON.stringify({ agentId: r.agentId, newWallet: r.newWallet, owner: r.owner, deadline: r.deadline, signature: r.signature });
  out([
    `Signed: ${r.newWallet} (this key) as agent #${r.agentId}'s ERC-8004 wallet, for its owner ${r.owner}.`,
    `The owner sends it before ${r.expiresAt} (the registry takes a signature for at most 5 minutes; run this again for a fresh one):`,
    `  to    ${r.registry} (the ERC-8004 identity registry, Robinhood Chain ${r.chainId})`,
    `  call  setAgentWallet(${r.agentId}, ${r.newWallet}, ${r.deadline}, signature)`,
    `  data  ${r.calldata}`,
    `signature ${r.signature}`,
    `For Priors: ${paste}`,
    "To let this key also borrow on the agent's line, the owner names it the agent's delegate on the pool (setDelegate) in the same step.",
    "",
  ].join("\n"));
  return 0;
}
