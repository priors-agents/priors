/* LineKey, the spending key for an agent's credit line (src/LineKey.sol, docs/LINE-KEY.md, "Using it in Go mode and the
   MCP"; SITE_LINE_KEY=on): one file for Go mode (web/account-line-key.js: the agent panel's Spending key, its calls sent
   as sponsored operations of the account) and for agents (@priors/mcp's line_key_status and line_key_spend:
   packages/mcp/src/line-key-core.cjs is this file, byte for byte). It holds what both must agree on: the deployment's
   address, the contract's rules and the test stage's caps the gas gate holds (gas-worker/gate.mjs LINE_KEY_LIMITS,
   scripts/test-line-key.mjs keeps them equal), the calls of a setup, a revoke and a payment, the key's state read back,
   and the words of a refusal as codes (each reader says them in its own language).
     setup:   [pool.setDelegate(agentId, lineKey) unless the line names the key already,] lineKey.configure(agentId,
              terms, payees) [, lineKey.setPayee(agentId, payee, false, 0) for each payee taken off]
     revoke:  lineKey.revoke(agentId)
     pay:     lineKey.spend(agentId, payee, amount, ref), from the key's operator alone
   Pure: no DOM, no chain, no library. The caller brings `encode(to, sig, args) -> { to, data }` (Go mode: the bundle's
   PriorsApp.encodeCall; the MCP: ethers' Interface) and the reads. Amounts are 6-decimal bigints (USDG's base units);
   times are seconds, as numbers.

   window.PriorsLineKeyCore (a page) / module.exports (node):
     ADDRESS                 { [chainId]: the LineKey deployment (deployments/4663.line-key.json) }
     LIMITS                  the contract's and the pool's bounds: maxPayees (32), maxPayments (64), maxPeriodS (365 d),
                             bps (10,000), minTermS (1 d), maxTermS (30 d), minLoan (5 USDG), maxLoan (500 USDG)
     STAGE                   the test stage's caps (owners opt in one by one, with small caps): maxPerPeriod (100 USDG),
                             minPeriodS (1 d), maxExpiryS (90 d), maxPayeesPerOp (8), spendGas (900,000: a payment's gas
                             at worst, 815,000 measured, with room)
     REASONS                 the contract's Reason enum, in order, as codes ("ok", "no-key", "owner-changed", ...)
     SIG                     the functions' signatures, structs spelled out
     terms(o)                o { operator, perPayment, perPeriod, periodS, expiresAt, termS, maxFeeBps, now } -> the
                             Terms struct, frozen, or throws an Error whose .code is "operator" | "caps" | "min" | "stage-cap"
                             | "period" | "expiry" | "term" | "fee"
     payees(list, o)         list [{ payee, perPeriod (0n: only the key's caps) }], o { conf, terms } -> the list
                             checked, frozen; throws .code "payee" | "payee-dup" | "payee-cap" | "payees"
     setupCalls(encode, o)   o { conf { lineKey, pool }, agentId, terms, add, remove?, delegate (the pool's delegateOf
                             now), current? (view() of the key now) } -> the calls, each { to, data, what }; throws .code
                             "period-fixed" (a live key of this owner keeps its period: revoke, then set up)
     revokeCalls(encode, o)  o { conf, agentId } -> [revoke]
     spendCall(encode, o)    o { conf, agentId, payee, amount, ref } -> the one call, { to, data, what }
     ref(text)               "" -> 32 zero bytes; 0x and 64 hex digits -> as written (lower case); other text of 1 to 31
                             UTF-8 bytes -> those bytes padded right (ethers' encodeBytes32String); throws .code "ref"
     refText(ref)            the text a ref() of text holds, or the ref itself, or "" for none
     view(r)                 r { key (keyOf), owner (the registry's ownerOf), delegate (the pool's delegateOf), payees
                             (payeesOf), spent (spentInPeriod(agentId, 0): [sum, count, releaseAt]), remaining, active,
                             conf, now } -> { state: "none" | "live" | "stale" | "expired" | "not-delegate", ... }
     refusal(data)           a revert's data -> { code, args } (a Reason code from Refused, the pool's error from
                             LineRefused, or a setup error), or null when it is none of them */
(function () {
  "use strict";
  const UNIT = 1_000_000n, DAY = 86_400, ZERO = "0x0000000000000000000000000000000000000000";
  const ADDRESS = Object.freeze({ 4663: "0x1090Df1B8A4B3F1e7D9aeDaA06fd29f56B9214fB" });
  const LIMITS = Object.freeze({ maxPayees: 32, maxPayments: 64, maxPeriodS: 365 * DAY, bps: 10_000, minTermS: DAY, maxTermS: 30 * DAY, minLoan: 5n * UNIT, maxLoan: 500n * UNIT });
  const STAGE = Object.freeze({ maxPerPeriod: 100n * UNIT, minPeriodS: DAY, maxExpiryS: 90 * DAY, maxPayeesPerOp: 8, spendGas: 900_000 });
  const REASONS = Object.freeze(["ok", "no-key", "owner-changed", "expired", "not-operator", "zero-amount", "payee-not-allowed", "over-per-payment", "ref-used", "too-many-payments", "over-period", "over-payee-period", "not-delegate"]);
  const TERMS = "(address operator, uint64 expiresAt, uint64 period, uint64 term, uint16 maxFeeBps, uint128 perPayment, uint128 perPeriod)";
  const PAYEE = "(address payee, uint128 perPeriod)";
  const SIG = Object.freeze({
    setDelegate: "function setDelegate(uint256 id, address delegate)",
    delegateOf: "function delegateOf(uint256) view returns (address)",
    ownerOf: "function ownerOf(uint256) view returns (address)",
    configure: "function configure(uint256 agentId, " + TERMS + " t, " + PAYEE + "[] add)",
    setPayee: "function setPayee(uint256 agentId, address payee, bool allowed, uint128 perPeriod)",
    revoke: "function revoke(uint256 agentId)",
    spend: "function spend(uint256 agentId, address payee, uint256 amount, bytes32 ref) returns (uint256 loanId)",
    keyOf: "function keyOf(uint256 agentId) view returns ((address owner, uint64 generation, " + TERMS + " terms))",
    payeesOf: "function payeesOf(uint256 agentId) view returns (" + PAYEE + "[] list)",
    spentInPeriod: "function spentInPeriod(uint256 agentId, address payee) view returns (uint256 spent, uint256 payments, uint64 releaseAt)",
    remaining: "function remaining(uint256 agentId) view returns (uint256)",
    maxPayment: "function maxPayment(uint256 agentId, address payee) view returns (uint256 m)",
    check: "function check(uint256 agentId, address operator, address payee, uint256 amount, bytes32 ref) view returns (uint8 r)",
    isActive: "function isActive(uint256 agentId) view returns (bool)",
    refUsed: "function refUsed(uint256, address, bytes32) view returns (bool)",
  });
  // the errors a refusal can come back as (their selectors: scripts/test-line-key.mjs computes each from its signature)
  const ERRORS = Object.freeze({
    "0xbd5adfec": ["Refused", 1], "0x4943604e": ["LineRefused", -1],
    "0xb9c08761": ["NotOwner", 2], "0xb13f9627": ["NoKey", 1], "0x89961e91": ["ZeroOperator", 0], "0xc8022a76": ["BadCaps", 0],
    "0x7bdc76e2": ["BadPeriod", 0], "0xf4ad9a1f": ["BadExpiry", 0], "0xc8a081c6": ["BadTerm", 0], "0x917f1a53": ["BadFee", 0],
    "0x6be7f09d": ["PeriodFixed", 0], "0xcb89ee36": ["BadPayee", 1], "0x70f6fab0": ["TooManyPayees", 0], "0xf41a8af8": ["NotRevoker", 2],
  });
  const POOL_ERRORS = Object.freeze({
    "0x9e87fac8": ["Paused", 0], "0x881b1e56": ["NotController", 2], "0xbbd82fd9": ["WrongSponsor", 2], "0xb2ee2355": ["AgentDefaulted", 1],
    "0x8b79e920": ["IsFrozen", 1], "0x14e3d195": ["OwnerDefaulted", 1], "0xea7cc938": ["InsufficientCapacity", 3],
    "0xa17e11d5": ["InsufficientLiquidity", 2], "0x75c2016e": ["UtilizationTooHigh", 0], "0x3420d5fa": ["LoanSizeOutOfRange", 1],
    "0x3e8328dc": ["TermOutOfRange", 1], "0xe757126a": ["FeeTooHigh", 2], "0xb6ecf956": ["BorrowBlockedByBacker", 1],
    "0x753ac7d5": ["NotOwnerOf", 2], "0xa42088b5": ["InvalidAgent", 1], "0x7691e9d6": ["IsRoot", 1],
  });

  const no = (code, message) => Object.assign(new Error(message || code), { code });
  const isBig = (v) => typeof v === "bigint";
  const ADDR = /^0x[0-9a-fA-F]{40}$/;
  const same = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
  const isZero = (a) => /^0x0{40}$/i.test(String(a));
  const whole = (n, lo, hi) => Number.isSafeInteger(n) && n >= lo && n <= hi;
  // a struct's field from a reader's answer: viem names them; ethers' Result answers both by name and by place
  const field = (x, name, i) => (x == null ? undefined : x[name] !== undefined ? x[name] : x[i]);
  const big = (v) => (isBig(v) ? v : BigInt(v == null ? 0 : v));
  // 6-decimal units in plain digits, trailing zeros dropped (12_500_000n -> "12.5"), for the calls' own words
  const fmt6 = (u) => { const s = String(u), d = s.padStart(7, "0"); const f = d.slice(-6).replace(/0+$/, ""); return d.slice(0, -6) + (f ? "." + f : ""); };
  const days = (s) => { const d = s / DAY; return Number.isInteger(d) ? `${d} day${d === 1 ? "" : "s"}` : `${s} s`; };

  /** The owner's terms, checked against the contract's rules and the stage's caps (see the header). */
  function terms({ operator, perPayment, perPeriod, periodS, expiresAt, termS, maxFeeBps, now }) {
    if (typeof operator !== "string" || !ADDR.test(operator) || isZero(operator)) throw no("operator", "the operator must be an address");
    if (!isBig(perPayment) || !isBig(perPeriod) || perPayment <= 0n || perPayment > perPeriod) throw no("caps", "a cap per payment above zero, and at most the cap per period");
    // under the pool's smallest loan, no payment could ever go through
    if (perPayment < LIMITS.minLoan) throw no("min", "a cap per payment of at least the pool's smallest loan, 5 USDG");
    if (perPeriod > STAGE.maxPerPeriod) throw no("stage-cap", "at most 100 USDG a period for now");
    if (!whole(periodS, STAGE.minPeriodS, LIMITS.maxPeriodS)) throw no("period", "a period of 1 to 365 days");
    if (!Number.isSafeInteger(now) || !whole(expiresAt, now + 1, now + STAGE.maxExpiryS)) throw no("expiry", "an expiry ahead, at most 90 days from now");
    if (!whole(termS, LIMITS.minTermS, LIMITS.maxTermS)) throw no("term", "a loan term of 1 to 30 days");
    if (!whole(maxFeeBps, 0, LIMITS.bps)) throw no("fee", "a most fee of 0 to 10,000 basis points");
    return Object.freeze({ operator, expiresAt, period: periodS, term: termS, maxFeeBps, perPayment, perPeriod });
  }

  /** The payees to list (each with its own cap per period, 0n for none), checked. */
  function payees(list, { conf, terms: t }) {
    if (!Array.isArray(list) || list.length > STAGE.maxPayeesPerOp) throw no("payees", `at most ${STAGE.maxPayeesPerOp} payees at a time`);
    const seen = new Set(), banned = [conf && conf.lineKey, conf && conf.pool, conf && conf.registry, conf && conf.usdg].filter(Boolean);
    return Object.freeze(list.map((p) => {
      const payee = p && p.payee, cap = p && p.perPeriod != null ? p.perPeriod : 0n;
      if (typeof payee !== "string" || !ADDR.test(payee) || isZero(payee) || banned.some((b) => same(b, payee))) throw no("payee", "a payee must be an address that is not the key, the pool, the registry or USDG");
      if (seen.has(payee.toLowerCase())) throw no("payee-dup", "each payee once");
      seen.add(payee.toLowerCase());
      if (!isBig(cap) || cap < 0n || (t && cap > t.perPeriod)) throw no("payee-cap", "a payee's own cap is at most the key's cap per period");
      return Object.freeze({ payee, perPeriod: cap });
    }));
  }

  const what = (x, w) => Object.assign({}, x, { what: w });
  /** A setup's calls: the key named the line's delegate when it is not yet, its terms and payees, the payees taken off. */
  function setupCalls(encode, { conf, agentId, terms: t, add = [], remove = [], delegate, current }) {
    const id = BigInt(agentId);
    if (current && current.state !== "none" && current.state !== "stale" && current.terms && current.terms.period !== t.period) throw no("period-fixed", "a live key keeps its period: revoke it, then set up a new one");
    const out = [];
    if (!same(delegate, conf.lineKey)) out.push(what(encode(conf.pool, SIG.setDelegate, [id, conf.lineKey]), `name the spending key agent #${id}'s delegate on the pool (in place of ${delegate && !isZero(delegate) ? delegate : "none"})`));
    out.push(what(encode(conf.lineKey, SIG.configure, [id, { operator: t.operator, expiresAt: BigInt(t.expiresAt), period: BigInt(t.period), term: BigInt(t.term), maxFeeBps: t.maxFeeBps, perPayment: t.perPayment, perPeriod: t.perPeriod }, add.map((p) => ({ payee: p.payee, perPeriod: p.perPeriod }))]),
      `set agent #${id}'s key: ${t.operator} pays up to ${fmt6(t.perPayment)} USDG a payment and ${fmt6(t.perPeriod)} USDG every ${days(t.period)}, ${add.length} payee${add.length === 1 ? "" : "s"} listed`));
    for (const r of remove) out.push(what(encode(conf.lineKey, SIG.setPayee, [id, r, false, 0n]), `take ${r} off agent #${id}'s payees`));
    return out;
  }

  const revokeCalls = (encode, { conf, agentId }) => [what(encode(conf.lineKey, SIG.revoke, [BigInt(agentId)]), `revoke agent #${BigInt(agentId)}'s spending key`)];

  function spendCall(encode, { conf, agentId, payee, amount, ref: r }) {
    if (!isBig(amount) || amount <= 0n) throw no("amount", "a payment above zero");
    if (typeof payee !== "string" || !ADDR.test(payee) || isZero(payee)) throw no("payee", "a payee must be an address");
    const id = BigInt(agentId);
    return what(encode(conf.lineKey, SIG.spend, [id, payee, amount, r || ref("")]), `pay ${fmt6(amount)} USDG to ${payee} from agent #${id}'s line, as its loan`);
  }

  /** A payment's reference as the key takes it (bytes32). */
  function ref(text) {
    const s = text == null ? "" : String(text).trim();
    if (s === "") return "0x" + "0".repeat(64);
    if (/^0x[0-9a-fA-F]{64}$/.test(s)) return s.toLowerCase();
    const bytes = new TextEncoder().encode(s);
    if (bytes.length > 31) throw no("ref", "a reference of at most 31 bytes, or 32 bytes in hex");
    return "0x" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("").padEnd(64, "0");
  }
  /** What a ref holds: the text ref() put in it, else the hex itself; "" for none. */
  function refText(r) {
    if (typeof r !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(r) || /^0x0{64}$/.test(r)) return "";
    const hex = r.slice(2).replace(/(00)+$/, "");
    if (hex.length >= 64 || hex.length === 0) return r;
    const bytes = new Uint8Array(hex.match(/../g).map((h) => parseInt(h, 16)));
    // text a person could have typed: valid UTF-8, no control character
    try { const t = new TextDecoder("utf-8", { fatal: true }).decode(bytes); return /[\u0000-\u001f\u007f]/.test(t) ? r : t; } catch (_) { return r; }
  }

  /** The key as read: its state, terms, payees and room, from the reads in the header. */
  function view({ key, owner, delegate, payees: list, spent, remaining: room, active, conf, now }) {
    const ko = field(key, "owner", 0);
    if (!ko || isZero(ko)) return Object.freeze({ state: "none", delegateIsKey: same(delegate, conf.lineKey), delegate: delegate || null });
    const tt = field(key, "terms", 2);
    const t = Object.freeze({
      operator: field(tt, "operator", 0), expiresAt: Number(field(tt, "expiresAt", 1)), period: Number(field(tt, "period", 2)),
      term: Number(field(tt, "term", 3)), maxFeeBps: Number(field(tt, "maxFeeBps", 4)), perPayment: big(field(tt, "perPayment", 5)), perPeriod: big(field(tt, "perPeriod", 6)),
    });
    const ps = Object.freeze((list || []).map((p) => Object.freeze({ payee: field(p, "payee", 0), perPeriod: big(field(p, "perPeriod", 1)) })));
    const delegateIsKey = same(delegate, conf.lineKey);
    const state = !same(ko, owner) ? "stale" : now >= t.expiresAt ? "expired" : !delegateIsKey ? "not-delegate" : "live";
    const s = spent || [];
    return Object.freeze({
      state, owner: ko, generation: Number(field(key, "generation", 1)), terms: t, payees: ps, delegateIsKey, delegate: delegate || null,
      spent: big(field(s, "spent", 0)), payments: Number(field(s, "payments", 1) || 0), releaseAt: Number(field(s, "releaseAt", 2) || 0),
      remaining: room == null ? null : big(room), active: active === true,
    });
  }

  // a revert's words: the 4 bytes of its error, then its static arguments, one word each
  const words = (hex, n) => { const out = []; for (let i = 0; i < n; i++) { const w = hex.slice(8 + i * 64, 8 + (i + 1) * 64); if (w.length !== 64) return null; out.push(BigInt("0x" + w)); } return out; };
  /** A refusal's code from its revert data (see the header), or null. */
  function refusal(data) {
    const hex = typeof data === "string" && /^0x[0-9a-fA-F]*$/.test(data) ? data.slice(2).toLowerCase() : "";
    if (hex.length < 8) return null;
    const sel = "0x" + hex.slice(0, 8), e = ERRORS[sel];
    if (!e) { const p = POOL_ERRORS[sel]; if (!p) return null; const a = words(hex, p[1]); return a ? { code: p[0], args: a, pool: true } : null; }
    if (e[0] === "Refused") { const a = words(hex, 1); return a && a[0] < BigInt(REASONS.length) ? { code: REASONS[Number(a[0])], args: [] } : null; }
    if (e[0] === "LineRefused") {
      // abi-encoded bytes: its offset, its length, then the line's own revert data
      const len = hex.length >= 8 + 128 ? Number(BigInt("0x" + hex.slice(8 + 64, 8 + 128))) : -1;
      if (len < 4 || hex.length < 8 + 128 + len * 2) return { code: "LineRefused", args: [] };
      const inner = refusal("0x" + hex.slice(8 + 128, 8 + 128 + len * 2));
      return inner && inner.pool ? inner : { code: "LineRefused", args: [] };
    }
    const a = words(hex, e[1]);
    return a ? { code: e[0], args: a } : null;
  }

  const api = { ADDRESS, LIMITS, STAGE, REASONS, SIG, ZERO, terms, payees, setupCalls, revokeCalls, spendCall, ref, refText, view, refusal };
  if (typeof window !== "undefined") window.PriorsLineKeyCore = api;
  if (typeof module === "object" && module && module.exports) module.exports = api;
})();
