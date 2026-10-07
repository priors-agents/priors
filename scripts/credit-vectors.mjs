// Test vectors for the ERC-8004 credit profile (docs/ERC-8004-CREDIT.md, "Test cases"): fixed leaves, their hashes,
// the Merkle root and every proof, a statement file and a default file with their exact (canonical JSON) bytes and
// keccak256, and the giveFeedback calldata that posts the statement. The agent id is past 2^53 and one loan id past
// 2^64, so an implementation that reads ids as floating-point numbers fails them. Also writes the Solidity test that
// checks the same leaf hashes and proofs on chain code (test/CreditProfileVectors.t.sol, OpenZeppelin MerkleProof).
//
//   node scripts/credit-vectors.mjs           write docs/erc-8004-credit/vectors.json and the Solidity test
//   node scripts/credit-vectors.mjs --check   fail if either file differs from what the code produces now
import { ethers } from "ethers";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import * as P from "../sdk/credit-profile.mjs";
import { REGISTRY_ABI } from "../sdk/attestation.mjs";

const ROOT = new URL("..", import.meta.url).pathname;
const JSON_OUT = ROOT + "docs/erc-8004-credit/vectors.json";
const SOL_OUT = ROOT + "test/CreditProfileVectors.t.sol";

// A made-up lender, made-up loans: nothing here is a real agent or a real transaction.
const SRC = {
  chainId: 1, contract: "0x00000000000000000000000000000000000C0FFE", blocks: [1000, null],
  events: {
    open: "Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint64 dueAt)",
    repaid: "Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal)",
    defaulted: "Defaulted(uint256 indexed loanId, uint256 indexed agentId, uint256 principal)",
  },
  fields: { amount: "principal", dueAt: "dueAt" },
};
const AGENT = "9007199254740993"; // 2^53 + 1: a float64 reads it as ...992
const WRITER = "0x000000000000000000000000000000000000bEEF";
const ASSET = `eip155:1/erc20:${ethers.getAddress("0x0000000000000000000000000000000000005d01")}`;
const tx = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
const open = (n, block, log) => ({ openBlock: block, openTx: tx(0xb0 + n), openLog: log });
const LEAVES = [
  { src: 0, cls: "unsecured", loan: "1", amount: "5000000", dueAt: 1_800_000_000, closedAt: 1_799_990_000, outcome: P.ON_TIME, block: 1100, tx: tx(0xa1), log: 3, ...open(1, 1050, 0) },
  { src: 0, cls: "unsecured", loan: "2", amount: "12500000", dueAt: 1_800_100_000, closedAt: 1_800_150_000, outcome: P.LATE, block: 1200, tx: tx(0xa2), log: 0, ...open(2, 1150, 2) },
  { src: 0, cls: "secured:stock", loan: "18446744073709551617", amount: "250000000", dueAt: 1_800_200_000, closedAt: 1_800_190_000, outcome: P.ON_TIME, block: 1300, tx: tx(0xa3), log: 7, ...open(3, 1250, 1) },
  { src: 0, cls: "unsecured", loan: "4", amount: "7000000", dueAt: 1_800_300_000, closedAt: 1_800_400_000, outcome: P.DEFAULTED, block: 1400, tx: tx(0xa4), log: 1, ...open(4, 1350, 0) },
  { src: 0, cls: "unsecured", loan: "5", amount: "1000000", dueAt: 1_800_500_000, closedAt: 1_800_450_000, outcome: P.ON_TIME, block: 1500, tx: tx(0xa5), log: 2, ...open(5, 1450, 4) },
];

export function build() {
  const hashes = LEAVES.map((l) => P.leafHash(l, SRC, AGENT));
  const root = P.merkleRoot(hashes);
  const proofs = hashes.map((_, i) => P.merkleProof(hashes, i));
  const common = { chainId: 1, identityRegistry: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432", writer: WRITER, agentId: AGENT, asset: ASSET, decimals: 6, lender: { name: "Example lender" } };
  const enc = P.encodeFile(P.statementFile({
    ...common, sources: [SRC], seq: 1, prev: null, window: { fromBlock: 1000, toBlock: 1600, toTime: 1_800_600_000 },
    leaves: LEAVES, opened: { count: 6, amount: "280500000" }, outstanding: { count: 1, amount: "5000000" }, createdAt: 1_800_600_100,
  }));
  const def = P.encodeFile(P.defaultFile({ ...common, source: SRC, leaf: LEAVES[3], createdAt: 1_800_400_100 }));
  const iface = new ethers.Interface(REGISTRY_ABI);
  const calldata = iface.encodeFunctionData("giveFeedback", [BigInt(AGENT), BigInt(enc.file.value), 6, P.TAG_STATEMENT, enc.file.tag2, "", enc.feedbackURI, enc.feedbackHash]);
  const out = (e) => ({ file: e.file, bytes: ethers.hexlify(e.bytes), size: e.size, feedbackHash: e.feedbackHash, feedbackURI: e.feedbackURI });
  return {
    profile: P.PROFILE,
    note: "Made-up lender and loans. Leaf hash = keccak256(bytes.concat(keccak256(abi.encode(chainId, contract, agentId, loanId, amount, dueAt, closedAt, outcome, txHash, logIndex)))); pairs hashed sorted (OpenZeppelin MerkleProof). Files are canonical JSON (RFC 8785: keys sorted, no whitespace); ids and amounts are decimal strings.",
    leafTypes: P.LEAF_TYPES,
    source: SRC, agentId: AGENT,
    leaves: LEAVES.map((l, i) => ({ ...P.leafOut(l), hash: hashes[i], proof: proofs[i] })),
    root,
    emptyRoot: P.merkleRoot([]),
    statement: { ...out(enc), giveFeedbackCalldata: calldata },
    default: out(def),
  };
}

/**
 * A statement `<lead><fn>(<args>);` at `indent` spaces, laid out as `forge fmt` lays it out at foundry.toml's
 * line_length (120): on one line if it fits; else the arguments on one line of their own if they fit; else one
 * argument per line. The generated test must pass `forge fmt --check` (the public repo's CI), without needing forge here.
 */
const LINE = 120;
function call(indent, lead, fn, args) {
  const pad = " ".repeat(indent), inner = " ".repeat(indent + 4);
  const flat = `${pad}${lead}${fn}(${args.join(", ")});`;
  if (flat.length <= LINE) return flat;
  if (inner.length + args.join(", ").length <= LINE) return `${pad}${lead}${fn}(\n${inner}${args.join(", ")}\n${pad});`;
  return `${pad}${lead}${fn}(\n${args.map((a) => `${inner}${a}`).join(",\n")}\n${pad});`;
}

function solidity(v) {
  const L = v.leaves;
  const leafArgs = (l, amount = l.amount) => [l.loan, amount, l.dueAt, l.closedAt, l.outcome, `bytes32(${l.tx})`, l.log].map(String);
  const leafLine = (l) => call(8, `h[${L.indexOf(l)}] = `, "_leaf", leafArgs(l));
  const proofs = L.map((l, i) => {
    const arr = l.proof.map((p, k) => `        p${i}[${k}] = bytes32(${p});`).join("\n");
    return `        bytes32[] memory p${i} = new bytes32[](${l.proof.length});\n${arr}${arr ? "\n" : ""}        assertTrue(MerkleProof.verify(p${i}, ROOT, h[${i}]), "proof ${i}");`;
  }).join("\n");
  return `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Generated by scripts/credit-vectors.mjs from docs/erc-8004-credit/vectors.json: do not edit by hand.
// The ERC-8004 credit profile's leaf hash and Merkle proofs, checked with OpenZeppelin's MerkleProof, so a contract can
// prove one loan of a statement on chain (docs/ERC-8004-CREDIT.md).
import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract CreditProfileVectorsTest is Test {
    uint256 constant CHAIN_ID = ${v.source.chainId};
    address constant LENDER = ${ethers.getAddress(v.source.contract)};
    uint256 constant AGENT = ${v.agentId};
    bytes32 constant ROOT = ${v.root};

    function _leaf(
        uint256 loanId,
        uint256 amount,
        uint64 dueAt,
        uint64 closedAt,
        uint8 outcome,
        bytes32 txHash,
        uint32 logIndex
    ) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(CHAIN_ID, LENDER, AGENT, loanId, amount, dueAt, closedAt, outcome, txHash, logIndex)
                )
            )
        );
    }

    function _leaves() internal pure returns (bytes32[] memory h) {
        h = new bytes32[](${L.length});
${L.map(leafLine).join("\n")}
    }

    function test_leafHashes() public pure {
        bytes32[] memory h = _leaves();
${L.map((l, i) => `        assertEq(h[${i}], ${l.hash});`).join("\n")}
    }

    function test_proofs() public pure {
        bytes32[] memory h = _leaves();
${proofs}
    }

    function test_tamperedLeafFails() public pure {
        bytes32[] memory h = _leaves();
        bytes32[] memory p0 = new bytes32[](${L[0].proof.length});
${L[0].proof.map((p, k) => `        p0[${k}] = bytes32(${p});`).join("\n")}
        // the same loan claimed as repaid on time with a larger amount
${call(8, "bytes32 forged = ", "_leaf", leafArgs(L[0], BigInt(L[0].amount) * 10n))}
        assertTrue(forged != h[0]);
        assertFalse(MerkleProof.verify(p0, ROOT, forged));
    }
}
`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const v = build();
  const json = JSON.stringify(v, null, 1) + "\n";
  const sol = solidity(v);
  if (process.argv.includes("--check")) {
    const bad = [];
    if (!existsSync(JSON_OUT) || readFileSync(JSON_OUT, "utf8") !== json) bad.push(JSON_OUT);
    if (!existsSync(SOL_OUT) || readFileSync(SOL_OUT, "utf8") !== sol) bad.push(SOL_OUT);
    if (bad.length) { console.error(`out of date (run node scripts/credit-vectors.mjs): ${bad.join(", ")}`); process.exit(1); }
    console.log("credit vectors up to date");
  } else {
    mkdirSync(ROOT + "docs/erc-8004-credit", { recursive: true });
    writeFileSync(JSON_OUT, json);
    writeFileSync(SOL_OUT, sol);
    console.log(`wrote ${JSON_OUT} (root ${v.root}, statement ${v.statement.size} bytes) and ${SOL_OUT}`);
  }
}
