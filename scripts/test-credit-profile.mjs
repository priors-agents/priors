// The ERC-8004 credit profile, network-free: leaves, roots and proofs (sdk/credit-profile.mjs), the file's encoding and
// schema, the shape checks a reader runs on a file and the chain rules. The reader against a chain is
// scripts/test-credit-reader.mjs; the Priors writer's plan is scripts/test-credit-writer.mjs; the real chain is
// scripts/test-credit-fork.mjs.
import assert from "node:assert/strict";
import { ethers } from "ethers";
import { execFileSync } from "node:child_process";
import * as P from "../sdk/credit-profile.mjs";

let passed = 0;
const failed = [];
const t = (name, fn) => {
  try { fn(); passed++; console.log(`ok - ${name}`); } catch (e) { failed.push(name); console.log(`not ok - ${name}\n  ${String(e?.message || e).slice(0, 1200).split("\n").join("\n  ")}\n  ${String(e?.stack || "").split("\n").find((l) => l.includes("test-credit-profile")) || ""}`); }
};
const SRC = { chainId: 1, contract: "0x00000000000000000000000000000000000C0FFE", blocks: [1, null], events: { open: "Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint64 dueAt)", repaid: "Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal)", defaulted: "Defaulted(uint256 indexed loanId, uint256 indexed agentId, uint256 principal)" }, fields: { amount: "principal", dueAt: "dueAt" } };
const ASSET = `eip155:1/erc20:${ethers.getAddress("0x0000000000000000000000000000000000005d01")}`;
const tx = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
const leaf = (n, o = {}) => ({ src: 0, loan: String(n), amount: String(n * 1_000_000), dueAt: 2000, closedAt: 1000, outcome: P.ON_TIME, block: 100 + n, tx: tx(n), log: n % 3, openBlock: 50 + n, openTx: tx(1000 + n), openLog: 0, ...o });
/** The RFC 8785 subset this profile writes (sorted keys, no whitespace), written here independently of the SDK. */
const canon = (v) => (v === null || typeof v !== "object" ? JSON.stringify(v) : Array.isArray(v) ? `[${v.map(canon).join(",")}]` : `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`);

t("the committed vectors are what the code produces (docs/erc-8004-credit/vectors.json, the Solidity test)", () => {
  execFileSync(process.execPath, [new URL("./credit-vectors.mjs", import.meta.url).pathname, "--check"], { stdio: "pipe" });
});

t("every proof verifies for 1 to 9 leaves; a changed leaf or a proof from another leaf does not", () => {
  for (let n = 1; n <= 9; n++) {
    const hs = Array.from({ length: n }, (_, i) => P.leafHash(leaf(i + 1), SRC, 7));
    const root = P.merkleRoot(hs);
    hs.forEach((h, i) => assert.ok(P.verifyProof(P.merkleProof(hs, i), root, h), `n=${n} i=${i}`));
    const forged = P.leafHash(leaf(1, { amount: "999000000" }), SRC, 7);
    assert.ok(!P.verifyProof(P.merkleProof(hs, 0), root, forged));
    if (n > 1) assert.ok(!P.verifyProof(P.merkleProof(hs, 1), root, hs[0]));
  }
  assert.equal(P.merkleRoot([]), ethers.ZeroHash);
});

t("the leaf hash binds every field: agent, lender, loan, amount, dates, outcome, transaction, log", () => {
  const base = P.leafHash(leaf(1), SRC, 7);
  assert.notEqual(P.leafHash(leaf(1), SRC, 8), base);
  assert.notEqual(P.leafHash(leaf(1), { ...SRC, contract: "0x00000000000000000000000000000000000C0FFF" }, 7), base);
  assert.notEqual(P.leafHash(leaf(1), { ...SRC, chainId: 2 }, 7), base);
  for (const [k, v] of [["loan", "9"], ["amount", "1"], ["dueAt", 2001], ["closedAt", 1001], ["outcome", P.LATE], ["tx", tx(99)], ["log", 9]]) assert.notEqual(P.leafHash(leaf(1, { [k]: v }), SRC, 7), base, k);
  // the class and the block are not committed: the lender's claim, and a lookup aid
  assert.equal(P.leafHash(leaf(1, { cls: "secured:stock", block: 5 }), SRC, 7), base);
});

t("the outcome follows the dates: on time when closedAt <= dueAt, late after, defaulted on a default", () => {
  assert.equal(P.outcomeOf({ closedAt: 10, dueAt: 10 }), P.ON_TIME);
  assert.equal(P.outcomeOf({ closedAt: 11, dueAt: 10 }), P.LATE);
  assert.equal(P.outcomeOf({ defaulted: true, closedAt: 1, dueAt: 10 }), P.DEFAULTED);
});

const statement = (o = {}) => P.statementFile({
  chainId: 1, identityRegistry: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432", writer: "0x000000000000000000000000000000000000bEEF", agentId: 7, asset: ASSET, decimals: 6,
  sources: [SRC], seq: 1, prev: null, window: { fromBlock: 1, toBlock: 500, toTime: 9999 },
  leaves: [leaf(3), leaf(1), leaf(2, { outcome: P.LATE, closedAt: 3000 }), leaf(4, { outcome: P.DEFAULTED, cls: "secured:stock" })],
  opened: { count: 5, amount: "15000000" }, outstanding: { count: 1, amount: "5000000" }, createdAt: 9999, lender: { name: "Example lender" }, ...o,
});
const defaultF = (o = {}) => P.defaultFile({ chainId: 1, identityRegistry: "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432", writer: "0x000000000000000000000000000000000000bEEF", agentId: 7, asset: ASSET, decimals: 6, source: SRC, leaf: leaf(4, { outcome: P.DEFAULTED, cls: "secured:pt", openBlock: 90, openTx: tx(90), openLog: 0 }), createdAt: 1, ...o });
const entryOf = (f) => ({ agentId: f.agentId, client: f.clientAddress.split(":").pop(), tag1: f.tag1, tag2: f.tag2, value: f.value, valueDecimals: f.valueDecimals });

t("a statement: value = principal repaid on time, totals by outcome and class, leaves sorted, tag2 mixed", () => {
  const f = statement();
  assert.equal(f.value, "4000000"); // loans 1 and 3
  assert.deepEqual(f.credit.closed, { onTime: { count: 2, amount: "4000000" }, late: { count: 1, amount: "2000000" }, defaulted: { count: 1, amount: "4000000" }, recovered: { count: 0, amount: "0" } });
  assert.equal(f.tag2, P.MIXED);
  assert.deepEqual(Object.keys(f.credit.classes), ["secured:stock", "unsecured"]);
  assert.deepEqual(f.credit.anchors.map((a) => a.loan), ["1", "2", "3", "4"]);
  assert.equal(f.credit.leaves, 4);
  assert.deepEqual(P.checkFile(f, entryOf(f)), []);
  // one class: tag2 is it; no loans: the line's class
  assert.equal(statement({ leaves: [leaf(1)] }).tag2, "unsecured");
  assert.equal(statement({ leaves: [], cls: "secured:pt" }).tag2, "secured:pt");
  assert.equal(statement({ leaves: [] }).credit.root, ethers.ZeroHash);
});

t("the same inputs give the same bytes; the oldest anchors go first when a file is too big, never the root", () => {
  const a = P.encodeFile(statement()), b = P.encodeFile(statement());
  assert.equal(a.feedbackHash, b.feedbackHash);
  assert.equal(a.feedbackHash, ethers.keccak256(P.decodeDataURI(a.feedbackURI)));
  const small = P.encodeFile(statement(), { max: a.size - 50 });
  assert.ok(small.size <= a.size - 50);
  assert.deepEqual(small.file.credit.anchors.map((x) => x.loan), ["2", "3", "4"]); // one anchor is ~250 bytes
  assert.equal(small.file.credit.root, a.file.credit.root);
  assert.throws(() => P.encodeFile(statement({ leaves: [] }), { max: 100 }), /over 100/);
});

t("a reader's shape checks catch a file that does not match its entry or itself", () => {
  const f = statement();
  const e = entryOf(f);
  assert.match(P.checkFile(f, { ...e, value: "1" }).join(), /value\/valueDecimals differ/);
  assert.match(P.checkFile(f, { ...e, client: "0x000000000000000000000000000000000000dEaD" }).join(), /not the entry's writer/);
  assert.match(P.checkFile({ ...f, value: "5000000" }, { ...e, value: "5000000" }).join(), /not the on-time principal/);
  const bad = structuredClone(f); bad.credit.closed.late.count = 0;
  assert.match(P.checkFile(bad, e).join(), /do not add up/);
  const late = structuredClone(f); late.credit.anchors[1].outcome = P.ON_TIME;
  assert.match(P.checkFile(late, e).join(), /outcome does not fit its dates/);
  assert.match(P.checkFile({ ...f, credit: { ...f.credit, seq: 2 } }, e).join(), /prev does not fit seq/);
  assert.match(P.checkFile({ ...f, credit: { ...f.credit, v: "x" } }, e).join(), /not an erc8004-credit\/v1 file/);
});

t("a chain: seq from 1, prev = the last hash, windows back to back; a gap or a missing statement is reported", () => {
  const s = (seq, from, to, prevHash, hash) => ({ feedbackHash: hash, file: { credit: { seq, prev: prevHash, window: { fromBlock: from, toBlock: to } } } });
  const h = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
  assert.deepEqual(P.checkChain([s(1, 1, 100, null, h(1)), s(2, 101, 200, h(1), h(2)), s(3, 201, 300, h(2), h(3))]), []);
  assert.match(P.checkChain([s(1, 1, 100, null, h(1)), s(2, 102, 200, h(1), h(2))]).join(), /window starts at 102/);
  assert.match(P.checkChain([s(1, 1, 100, null, h(1)), s(3, 101, 200, h(2), h(3))]).join(), /seq 1 is followed by 3/);
  assert.match(P.checkChain([s(1, 1, 100, null, h(1)), s(2, 101, 200, h(9), h(2))]).join(), /prev is not seq 1's hash/);
  assert.match(P.checkChain([s(2, 101, 200, h(1), h(2))]).join(), /starts at seq 2/);
});

t("a default entry carries one defaulted leaf; value = its principal", () => {
  const f = defaultF();
  assert.equal(f.tag1, P.TAG_DEFAULTED);
  assert.equal(f.tag2, "secured:pt");
  assert.equal(f.value, "4000000");
  assert.deepEqual(P.checkFile(f, entryOf(f)), []);
  assert.throws(() => defaultF({ leaf: leaf(4) }), /defaulted leaf/);
});

t("event signatures: where each indexed param sits", () => {
  const e = P.eventInfo("Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 indexed sponsorId, uint256 principal, uint256 fee, uint64 dueAt, address to)");
  assert.deepEqual(e.topicOf, { loanId: 1, agentId: 2, sponsorId: 3 });
  assert.equal(e.topic0, ethers.id("Borrowed(uint256,uint256,uint256,uint256,uint256,uint64,address)"));
});

// ---- audit findings (ops/pvr-2026-10-07/credit-audit/format-reader-codex.md) ---------------------------------------
const h = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
const src = (n, blocks) => ({ ...SRC, contract: ethers.getAddress(ethers.zeroPadValue(ethers.toBeHex(0xa000 + n), 20)), blocks });
/** A chain link: a statement's feedbackHash and the credit fields the chain rules read. */
const link = (seq, from, to, sources, { asset = ASSET, decimals = 6 } = {}) => ({ feedbackHash: h(seq), file: { credit: { seq, prev: seq === 1 ? null : h(seq - 1), window: { fromBlock: from, toBlock: to }, sources, asset, decimals } } });

t("2. a chain covers each source from its first block: seq 1 starts at or before it; later statements declare every earlier source their window reaches", () => {
  const A = src(1, [100, null]), B = src(2, [100, null]);
  assert.deepEqual(P.checkChain([link(1, 100, 400, [A, B]), link(2, 401, 600, [A, B])]), []);
  assert.match(P.checkChain([link(1, 200, 400, [A])]).join(), /seq 1 starts at block 200, after the first block of source .*\(100\)/);
  assert.match(P.checkChain([link(1, 100, 400, [A, B]), link(2, 401, 600, [A])]).join(), new RegExp(`seq 2 does not declare source ${B.contract}`));
  // a source whose declared range ended before the window need not be declared
  assert.deepEqual(P.checkChain([link(1, 100, 400, [A, src(2, [100, 300])]), link(2, 401, 600, [A])]), []);
  // a source first declared later starts within or after that statement's window
  assert.deepEqual(P.checkChain([link(1, 100, 400, [A]), link(2, 401, 600, [A, src(3, [450, null])])]), []);
  assert.match(P.checkChain([link(1, 100, 400, [A]), link(2, 401, 600, [A, src(3, [300, null])])]).join(), /seq 2 starts at block 401, after the first block of source .*\(300\)/);
  // a source's declaration does not change along the chain (its end may go from null to a block)
  assert.match(P.checkChain([link(1, 100, 400, [A, B]), link(2, 401, 600, [A, { ...B, blocks: [150, null] }])]).join(), /changed/);
  assert.deepEqual(P.checkChain([link(1, 100, 400, [A, B]), link(2, 401, 600, [A, { ...B, blocks: [100, 500] }])]), []);
  // a reader's manifest: the writer's sources as the reader trusts them
  assert.match(P.checkChain([link(1, 100, 400, [A])], { manifest: [A, B] }).join(), new RegExp(`seq 1 does not declare source ${B.contract} of the reader's manifest`));
  assert.match(P.checkChain([link(1, 100, 400, [A, B])], { manifest: [A] }).join(), new RegExp(`source ${B.contract} is not in the reader's manifest`));
  assert.match(P.checkChain([link(1, 200, 400, [{ ...A, blocks: [200, null] }])], { manifest: [A] }).join(), /starts at block 200, after the first block of source .*\(100\)/);
});

t("3. v1 reserves recovery: a recovered total, an outcome-4 leaf, or a zero root over leaves is a shape problem", () => {
  const f = statement();
  const e = entryOf(f);
  const rec = structuredClone(f);
  rec.credit.closed.recovered = { count: 999, amount: "999999999" };
  rec.credit.leaves += 999;
  assert.match(P.checkFile(rec, e).join(), /recovered/, "999 recoveries pass the shape check");
  const zero = structuredClone(f);
  zero.credit.root = ethers.ZeroHash;
  assert.match(P.checkFile(zero, e).join(), /root/, "a zero root over 4 leaves");
  const four = structuredClone(f);
  four.credit.anchors[0].outcome = P.RECOVERED;
  assert.match(P.checkFile(four, e).join(), /outcome/);
});

t("4. one asset per chain: asset and decimals do not change from statement to statement", () => {
  const A = src(1, [100, null]);
  assert.match(P.checkChain([link(1, 100, 400, [A]), link(2, 401, 600, [A], { asset: "eip155:1/erc20:0x0000000000000000000000000000000000001818", decimals: 18 })]).join(), /seq 2: asset .* differs from seq 1/);
  assert.match(P.checkChain([link(1, 100, 400, [A]), link(2, 401, 600, [A], { decimals: 18 })]).join(), /seq 2: asset .* differs from seq 1/);
});

t("5. the asset is a CAIP-19 id: a malformed one is a shape problem", () => {
  for (const asset of ["not-a-caip-id", "eip155:1/erc20:0x123", "eip155:01/erc20:0x0000000000000000000000000000000000005D01", "eip155:1:0x0000000000000000000000000000000000005D01", ""]) {
    const f = statement({ asset });
    assert.match(P.checkFile(f, entryOf(f)).join(), /asset/, JSON.stringify(asset));
  }
});

const pathsOf = (v, pre = []) => (v && typeof v === "object" ? Object.keys(v).flatMap((k) => { const p = [...pre, Array.isArray(v) ? Number(k) : k]; return [p, ...pathsOf(v[k], p)]; }) : []);
const getAt = (o, path) => path.reduce((x, k) => x[k], o);
const setAt = (o, path, v) => { const parent = getAt(o, path.slice(0, -1)), k = path.at(-1); if (v === undefined) { if (Array.isArray(parent)) parent.splice(k, 1); else delete parent[k]; } else parent[k] = v; };
t("7. the schema is strict and bounded: a malformed file gives problems, never an exception", () => {
  const BAD = [undefined, null, true, -1, 1.5, 2 ** 60, "", "x".repeat(5000), [], {}, [1], { a: 1 }];
  let n = 0;
  const threw = [], silent = [];
  for (const f of [statement(), defaultF()]) {
    const e = entryOf(f);
    for (const path of pathsOf(f)) for (const v of BAD) {
      const was = getAt(f, path);
      if (canon(was) === canon(v ?? null) && v !== undefined) continue;
      const g = structuredClone(f);
      setAt(g, path, v);
      const what = `${path.join(".")} = ${String(JSON.stringify(v)).slice(0, 12)}`;
      let p;
      try { p = P.checkFile(g, e); } catch (x) { threw.push(`${what}: threw ${x.message}`); continue; }
      if (v !== undefined && !(path.join(".") === "credit.anchors" && Array.isArray(v) && !v.length) && !p.length) silent.push(what);
      n++;
    }
  }
  assert.deepEqual(threw.slice(0, 3), [], `${threw.length} malformed files throw instead of giving problems`);
  assert.deepEqual(silent.slice(0, 3), [], `${silent.length} malformed files give no problem`);
  assert.ok(n > 1000, `${n} mutations`);
  for (const junk of [null, 1, "x", [], {}, { credit: null }, { credit: { v: P.PROFILE } }]) {
    let p;
    try { p = P.checkFile(junk, {}); } catch (x) { assert.fail(`${JSON.stringify(junk)}: threw ${x.message}`); }
    assert.ok(p.length, JSON.stringify(junk));
  }
  // the bounds: sources, anchors, strings
  const f = statement();
  const e = entryOf(f);
  const many = structuredClone(f);
  many.credit.sources = Array.from({ length: 17 }, (_, i) => src(i, [1, null]));
  assert.match(P.checkFile(many, e).join(), /sources/);
  const leaves17 = Array.from({ length: 17 }, (_, i) => leaf(i + 1));
  const anchors = statement({ leaves: leaves17, anchors: 17 });
  assert.match(P.checkFile(anchors, entryOf(anchors)).join(), /anchors/);
  for (const name of ["x".repeat(65), "red\u001b[31m", ""]) {
    const g = structuredClone(f);
    g.credit.lender.name = name;
    assert.match(P.checkFile(g, e).join(), /lender/, JSON.stringify(name));
  }
  assert.match(P.checkFile({ ...f, createdAt: "yesterday" }, e).join(), /createdAt/);
});

t("8. ids are decimal strings in the file, exact past 2^53; a Number id that is not exact is refused", () => {
  const big = 9007199254740993n;
  const f = statement({ agentId: big });
  assert.equal(f.agentId, "9007199254740993");
  assert.equal(typeof statement().agentId, "string");
  assert.equal(statement({ agentId: "9007199254740993" }).credit.root, f.credit.root);
  assert.equal(P.leafHash(leaf(1), SRC, big), P.leafHash(leaf(1), SRC, "9007199254740993"));
  assert.throws(() => statement({ agentId: Number.MAX_SAFE_INTEGER + 2 }), /exact|safe/);
  assert.throws(() => P.leafHash(leaf(1), SRC, 2 ** 60), /exact|safe/);
  const L = 2n ** 64n + 1n;
  assert.equal(statement({ leaves: [leaf(1, { loan: L })] }).credit.anchors[0].loan, "18446744073709551617");
  assert.match(P.checkFile(f, { ...entryOf(f), agentId: big - 1n }).join(), /agentId differs/);
  const num = structuredClone(f);
  num.agentId = 7;
  assert.match(P.checkFile(num, { ...entryOf(f), agentId: 7n }).join(), /agentId/, "a JSON number agentId");
});

t("9. encodeFile writes canonical JSON (RFC 8785): sorted keys at every level, no whitespace", () => {
  for (const f of [statement(), defaultF()]) {
    const text = ethers.toUtf8String(P.encodeFile(f).bytes);
    assert.equal(text, canon(JSON.parse(text)), "the bytes are not the file's canonical JSON");
  }
});

t("9. decodeDataURI reads only the exact data:application/json;base64, prefix with canonical base64", () => {
  const b = ethers.toUtf8Bytes('{"a":1}');
  const b64 = ethers.encodeBase64(b); // eyJhIjoxfQ==
  assert.deepEqual(P.decodeDataURI(P.DATA_URI_PREFIX + b64), b);
  for (const uri of [
    "data:text/plain,%7B%22a%22%3A1%7D", "data:application/json,%7B%22a%22%3A1%7D", `DATA:application/json;base64,${b64}`, `data:application/json;charset=utf-8;base64,${b64}`,
    `${P.DATA_URI_PREFIX}${b64.slice(0, 4)} ${b64.slice(4)}`, `${P.DATA_URI_PREFIX}${b64.replace(/=+$/, "")}`, `${P.DATA_URI_PREFIX}${b64.replace("fQ==", "fR==")}`, `${P.DATA_URI_PREFIX}${b64.replace(/\+/g, "-")}A-_=`,
  ]) assert.equal(P.decodeDataURI(uri), null, uri);
});

console.log(`\n${passed} passed${failed.length ? `, ${failed.length} failed:\n  ${failed.join("\n  ")}` : ""}`);
process.exit(failed.length ? 1 : 0);
