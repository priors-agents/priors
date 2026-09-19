#!/usr/bin/env node
// A local Priors chain, from nothing, in one command.
//
//   npm run devnet
//
// Starts anvil if nothing is listening, deploys the pool with its mocks, and then does the three things a fresh
// pool needs before any agent can borrow:
//
//   1. a lender deposits, so there is money to lend
//   2. someone funds the first-loss reserve, so unbacked credit is allowed at all
//   3. the treasury sponsor gets stake, so `firstLine()` has capacity to vouch with
//
// Without (3) every `firstLine` reverts, which is the single most confusing way a fresh deployment fails.
import { spawn } from "node:child_process";
import { mkdirSync, openSync } from "node:fs";
import { join } from "node:path";
import { ethers } from "ethers";
import { ROOT, devWallet, readDeployment, isDevChain } from "../sdk/env.mjs";

const RPC = process.env.RPC_URL || "http://127.0.0.1:8545";
const USD = 1_000_000n;
const dollars = (n) => BigInt(n) * USD;

const POOL_ABI = [
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function fundReserve(uint256 amount)",
  "function creditReport(uint256) view returns (tuple(bool enrolled,bool isRoot,bool defaulted,uint256 sponsor,uint256 capacity,uint256 available,uint256 delegatedIn,uint256 delegatedOut,uint256 earned,uint256 stake,uint256 principalOut,uint256 activeLoans,uint256 loansRepaid,uint256 volumeRepaid,uint256 feesPaid,uint256 recourseHonored,uint256 childrenDefaulted,uint64 enrolledAt,uint256 score,uint256 qualifiedRepaid,uint256 dollarSecondsRepaid))",
  "function poolLiquidity() view returns (uint256)",
  "function reserve() view returns (uint256)",
];
const TREASURY_ABI = ["function sweep() returns (uint256,uint256)", "function agentId() view returns (uint256)", "function epochRoom() view returns (uint256)"];
const MOCK_USDC_ABI = ["function mint(address,uint256)", "function approve(address,uint256)", "function balanceOf(address) view returns (uint256)"];

const log = (...a) => console.log(...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function reachable(rpc) {
  try {
    const p = new ethers.JsonRpcProvider(rpc, undefined, { cacheTimeout: -1 });
    await p.getNetwork();
    return true;
  } catch {
    return false;
  }
}

async function startAnvil() {
  log("» starting anvil");
  const logFile = join(ROOT, "anvil.log");
  const out = openSync(logFile, "a");
  const child = spawn("anvil", ["--silent"], { detached: true, stdio: ["ignore", out, out] });
  child.unref();
  for (let i = 0; i < 100; i++) {
    if (await reachable(RPC)) return;
    await sleep(200);
  }
  throw new Error(`anvil did not come up on ${RPC} after 20s. Is foundry installed? See ${logFile}`);
}

function run(cmd, args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ...env } });
    let out = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (out += d));
    child.on("error", (e) => reject(new Error(`${cmd} could not be run: ${e.message}\n  is foundry on your PATH? https://getfoundry.sh`)));
    child.on("close", (code) => (code === 0 ? resolve(out) : reject(new Error(`${cmd} ${args.join(" ")} failed (exit ${code}):\n${out}`))));
  });
}

export async function devnet() {
  if (!(await reachable(RPC))) await startAnvil();
  else log(`» reusing the chain already listening on ${RPC}`);

  const provider = new ethers.JsonRpcProvider(RPC, undefined, { cacheTimeout: -1 });
  const chainId = Number((await provider.getNetwork()).chainId);
  if (!(await isDevChain(provider))) throw new Error(`${RPC} is not a local dev chain (chain ${chainId}). devnet.mjs deploys mocks and mints money; it must never point at a real chain.`);

  const deployer = new ethers.NonceManager(devWallet(0).connect(provider));
  const deployerAddr = await deployer.getAddress();

  mkdirSync(join(ROOT, "deployments"), { recursive: true });
  log("» deploying CreditPool + TreasurySponsor + mocks");
  await run("forge", ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--private-key", devWallet(0).privateKey, "--broadcast", "-q"]);

  const dep = readDeployment(chainId);
  if (!dep) throw new Error(`deploy reported success but deployments/${chainId}.json is missing`);

  const usdc = new ethers.Contract(dep.usdc, MOCK_USDC_ABI, deployer);
  const pool = new ethers.Contract(dep.creditPool, POOL_ABI, deployer);
  const treasury = new ethers.Contract(dep.treasurySponsor, TREASURY_ABI, deployer);

  log("» lender deposits $20,000 and funds a $2,500 first-loss reserve");
  await (await usdc.mint(deployerAddr, dollars(1_000_000))).wait();
  await (await usdc.approve(dep.creditPool, dollars(1_000_000))).wait();
  await (await pool.deposit(dollars(20_000), deployerAddr)).wait();
  await (await pool.fundReserve(dollars(2_500))).wait();

  // The treasury only vouches out of stake it holds. On a real chain that stake arrives as creator fees from the
  // token; here we hand it the asset directly and let its own sweep() split it: half to the reserve, half staked
  // under its ERC-8004 identity as a root sponsor. Same code path, same accounting, no shortcut.
  log("» treasury sweeps $400 -> half to the reserve, half staked as a root sponsor");
  await (await usdc.mint(dep.treasurySponsor, dollars(400))).wait();
  await (await treasury.sweep()).wait();

  const tId = Number(await treasury.agentId());
  const report = await pool.creditReport(tId);
  if (!report.enrolled || report.available === 0n) {
    throw new Error(`the treasury did not end up able to vouch (agentId=${tId}, enrolled=${report.enrolled}, available=${report.available}). firstLine() would revert.`);
  }

  const fmt = (u) => `$${(Number(u) / 1e6).toLocaleString("en-US")}`;
  log("");
  log(`  chain            ${chainId}  ${RPC}`);
  log(`  CreditPool       ${dep.creditPool}`);
  log(`  TreasurySponsor  ${dep.treasurySponsor}  (agent #${tId}, can vouch ${fmt(report.available)}, ${fmt(await treasury.epochRoom())} left this epoch)`);
  log(`  USDG (mock)      ${dep.usdc}`);
  log(`  ERC-8004 registry ${dep.registry}`);
  log(`  pool liquidity   ${fmt(await pool.poolLiquidity())}   reserve ${fmt(await pool.reserve())}`);
  log("");
  log(`  written to deployments/${chainId}.json — every command below picks it up automatically.`);
  return { dep, chainId, provider };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  devnet()
    .then(() => {
      log("next:  npx priors flow     # register an agent, take the $5 line, borrow, repay, score");
      process.exit(0);
    })
    .catch((e) => {
      console.error(`\n${e.message}`);
      process.exit(1);
    });
}
