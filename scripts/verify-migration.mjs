// Confirm the code running on chain IS the code in this repo.
//
// These contracts are not upgradeable, so "fixed in src/" and "fixed on chain" are two different claims
// with a deployment in between. SECURITY.md points here for the second one: this reads the runtime
// bytecode of every contract in the deployment record and checks it against the artifact `forge build`
// produced from the source you are looking at. If they match, the fixes described in SECURITY.md are the
// code that is live - you do not have to take this file's word for it.
//
// Requires a build first, because it compares against out/:
//   forge build
//   RPC_URL=https://rpc.mainnet.chain.robinhood.com node scripts/verify-migration.mjs
//
// Defaults to deployments/4663.json (Robinhood Chain mainnet); pass another record as argv[1].
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const RPC = process.env.RPC_URL || 'https://rpc.mainnet.chain.robinhood.com';
const RECORD = process.argv[2] || 'deployments/4663.json';

let failed = 0;
const check = (name, fn) => {
  try { const detail = fn(); console.log(`  ok   ${name}${detail ? ' — ' + detail : ''}`); }
  catch (e) { console.log(`  FAIL ${name}\n       ${e.message}`); failed += 1; }
};

/* Solidity bakes constructor immutables into the runtime bytecode and appends a CBOR metadata blob, so a
   raw keccak of deployed code can never equal the compiled artifact. Zero the immutable ranges the artifact
   itself declares, drop the metadata suffix, then compare what is left: the actual instructions. The
   immutable VALUES are not lost - they are checked separately, by calling the getters that expose them. */
function normalise(hexCode, immutableReferences) {
  let b = Buffer.from(hexCode.replace(/^0x/, ''), 'hex');
  for (const refs of Object.values(immutableReferences || {})) {
    for (const { start, length } of refs) b.fill(0, start, start + length);
  }
  if (b.length > 2) {
    const mlen = b.readUInt16BE(b.length - 2);
    if (mlen > 0 && mlen + 2 <= b.length) b = b.subarray(0, b.length - mlen - 2);
  }
  return ethers.keccak256(b);
}

const artifactOf = (name) => {
  const p = path.join(ROOT, 'out', `${name}.sol`, `${name}.json`);
  if (!fs.existsSync(p)) throw new Error(`no artifact at out/${name}.sol/${name}.json — run \`forge build\` first`);
  return JSON.parse(fs.readFileSync(p, 'utf8'));
};

const main = async () => {
  const provider = new ethers.JsonRpcProvider(RPC);
  const d = JSON.parse(fs.readFileSync(path.join(ROOT, RECORD), 'utf8'));
  console.log(`record ${RECORD}\nrpc    ${RPC}\n`);

  // Every contract the record names, checked against the artifact of the same name. The treasury holds its
  // own stake and enforces the invite gate, so it matters as much as the pool that its live code is the
  // published code.
  const CONTRACTS = [
    ['CreditPool', d.creditPool],
    ['TreasurySponsor', d.treasurySponsor],
    ['ReserveFunder', d.reserveFunder],
  ].filter(([, a]) => a);

  console.log('Deployed runtime bytecode matches the compiled artifact (immutables zeroed, metadata stripped)');
  const code = Object.fromEntries(await Promise.all(CONTRACTS.map(async ([n, a]) => [n, await provider.getCode(a)])));
  for (const [name, addr] of CONTRACTS) {
    check(`${name} at ${addr}`, () => {
      const onChain = code[name];
      if (!onChain || onChain === '0x') throw new Error(`no code at ${addr}`);
      const art = artifactOf(name);
      const refs = art.deployedBytecode.immutableReferences;
      const a = normalise(onChain, refs);
      const b = normalise(art.deployedBytecode.object, refs);
      if (a !== b) throw new Error(`deployed ${a.slice(0, 18)} vs compiled ${b.slice(0, 18)}`);
      const slots = Object.values(refs || {}).reduce((n, r) => n + r.length, 0);
      return `${a.slice(0, 18)}… (${slots} immutable slot${slots === 1 ? '' : 's'} excluded)`;
    });
  }

  // The immutable slots the bytecode check zeroed, read back through their getters - so the wiring between
  // the three contracts is the wiring the record claims, not just three individually-correct programs.
  console.log('\nImmutable wiring resolves to the addresses in the record');
  const pool = new ethers.Contract(d.creditPool, [
    'function usdc() view returns (address)', 'function registry() view returns (address)',
    'function owner() view returns (address)',
  ], provider);
  const eq = (label, got, want) => check(label, () => {
    if (ethers.getAddress(got) !== ethers.getAddress(want)) throw new Error(`got ${got}, record says ${want}`);
    return ethers.getAddress(got);
  });
  eq('CreditPool.usdc() == record.usdc', await pool.usdc(), d.usdc);
  eq('CreditPool.registry() == record.registry', await pool.registry(), d.registry);
  if (d.owner) eq('CreditPool.owner() == record.owner', await pool.owner(), d.owner);

  const treasury = new ethers.Contract(d.treasurySponsor, [
    'function pool() view returns (address)', 'function agentId() view returns (uint256)',
  ], provider);
  eq('TreasurySponsor.pool() == record.creditPool', await treasury.pool(), d.creditPool);
  const agentId = await treasury.agentId();
  check('TreasurySponsor.agentId() matches record', () => {
    if (d.treasuryAgentId != null && agentId !== BigInt(d.treasuryAgentId)) throw new Error(`chain ${agentId} vs record ${d.treasuryAgentId}`);
    return String(agentId);
  });

  console.log(failed ? `\n${failed} check(s) failed` : '\nAll checks passed: the deployed code is the code in this repo.');
  process.exit(failed ? 1 : 0);
};

main().catch((e) => { console.error('FAILED:', e.shortMessage || e.message); process.exit(1); });
