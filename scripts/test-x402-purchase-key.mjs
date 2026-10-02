// @priors/x402's purchase key for a multipart/form-data body (P-24 in docs/SECURITY-v2.md): one purchase whatever
// spelling a form parser reads alike (GHSA-85hm, GHSA-3h5x, GHSA-cpvc, GHSA-79g3), two when a parser reads two.
// Network-free.
//   node scripts/test-x402-purchase-key.mjs
import assert from "node:assert/strict";
import { purchaseKey } from "../packages/x402/index.mjs";

let passed = 0;
async function check(name, fn) { await fn(); passed++; console.log("  ok   " + name); }

const MB = "----X";
const part = (name, value, extra = "", quoted = true) => `--${MB}\r\nContent-Disposition: form-data; name=${quoted ? `"${name}"` : name}${extra}\r\n\r\n${value}\r\n`;
const form = (parts, boundary = MB, type = `multipart/form-data; boundary=${boundary}`) =>
  ({ method: "POST", body: parts.join("").split(MB).join(boundary) + `--${boundary}--\r\n`, headers: { "content-type": type } });
const k = (init) => purchaseKey(new Request("https://m.example/f", init));
const same = async (a, b, why) => assert.equal(await k(a), await k(b), why);
const apart = async (a, b, why) => assert.notEqual(await k(a), await k(b), why);
const base = form([part("item", "book")]);
const withHeader = (h) => form([part("item", "book", `\r\n${h}`)]);

await check("85hm: parts reordered, Content-Type: text/plain stated or omitted, a name quoted or not, another boundary", async () => {
  await same(form([part("item", "book"), part("qty", "1")]), form([part("qty", "1"), part("item", "book")]), "parts reordered");
  await same(base, withHeader("Content-Type: text/plain"), "text/plain stated");
  await same(base, form([part("item", "book", "", false)]), "a name unquoted");
  await same(base, form([part("item", "book")], "ZZ"), "another boundary");
});
await check("3h5x: a part's media type in another spelling (charset utf-8 or utf8, quoted, case, spaces)", async () => {
  for (const ct of ["text/plain; charset=utf-8", 'text/plain;charset="UTF-8"', "Text/Plain; Charset=utf8", "text/plain ; charset = utf-8"]) await same(base, withHeader(`Content-Type: ${ct}`), ct);
});
await check("cpvc: part headers no form parser reads, an identity transfer encoding, a header repeated", async () => {
  for (const h of ["Content-Transfer-Encoding: 8bit", "Content-Transfer-Encoding: BINARY", "X-Custom: 1", "X-Custom: 1\r\nX-Custom: 2"]) await same(base, withHeader(h), h);
});
await check('79g3: a boundary holding "json", whitespace around its "=", filename* keyed as written', async () => {
  await same(base, form([part("item", "book")], "----jsonBoundary"), "json in the boundary");
  await same(base, { ...base, headers: { "content-type": `multipart/form-data; boundary = ${MB}` } }, "boundary = X");
  await same(base, { ...base, headers: { "content-type": `multipart/form-data; BOUNDARY="${MB}"` } }, "the parameter's case and quotes");
  const star = (name, b) => form([part("f", "x", `; filename="r.pdf"; filename*=UTF-8''${name}`)], b);
  await same(star("a.pdf", MB), star("a.pdf", "ZZ"), "filename*, another boundary");
  await apart(star("a.pdf", MB), star("b.pdf", MB), "another filename*");
});
await check("what a parser reads differently stays two purchases", async () => {
  await apart(base, form([part("item", "pen")]), "another value");
  await apart(form([part("t", "1"), part("t", "2")]), form([part("t", "2"), part("t", "1")]), "repeated fields keep their order");
  await apart(base, withHeader("Content-Transfer-Encoding: base64"), "a transfer encoding parsers decode");
  await apart(base, withHeader("Content-Type: text/plain; charset=iso-8859-1"), "another charset");
  const file = (ct) => form([part("f", "x", `; filename="x.pdf"\r\nContent-Type: ${ct}`)]);
  await apart(file("application/pdf; foo=bar"), file("application/pdf"), "a file's media-type parameters (File.type keeps them)");
  await same(file('application/pdf; a=1; B="2"'), file("application/pdf;b=2;a=1"), "...in any order, quoting or case");
  await apart(base, { method: "POST", body: "item=book", headers: { "content-type": "application/x-www-form-urlencoded" } }, "a urlencoded form");
  const two = (b) => form([part("item", "book", "\r\nContent-Type: text/plain\r\nContent-Type: image/png")], b);
  await apart(two(MB), two("ZZ"), "two of a header a parser reads: by its bytes");
});

console.log(`\ntest-x402-purchase-key: all ${passed} good`);
