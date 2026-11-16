# Changelog

## 0.3.2 (2026-11-10)

Security fixes from the private reports of 2026-11-07 by @pa-khan (GHSA-p87w-g46g-5w3h) and 2026-11-08 by @mr-hrydarie
(GHSA-8pvh-wx87-mf7x); 0.2.0 to 0.3.1 are affected:

- **The request body is found wherever it stands, and nothing in braces is read as an amount** (GHSA-p87w-g46g-5w3h,
  reported by @pa-khan; GHSA-8pvh-wx87-mf7x, reported by @mr-hrydarie). A brace before the body that was not JSON (a
  template's `{model}`, a URL's `?u={id}`) hid the body, so its prompt was read for the price and a borrow and the
  payment went out as a GET; an example block before the body was sent instead of it; a `{}` inside a seller's URL was
  taken for the body and cut the URL, whose tail was then read. Every ``` block and `{...}` outside a URL is now taken
  out before the URL and the amounts are read, and the body is the message's one JSON object: two, one that does not
  parse, or one joined to the URL pay nothing.
- **A cap phrase's count is not a price** (GHSA-p87w-g46g-5w3h): "up to 50 items" no longer names a price of 50, and
  "borrow 0.50 USDG (up to 5)" no longer a price of 5.

On `@priors/mcp` 0.19.1 (was 0.18.1): among its changes, `repay` pays from the agent's declared ERC-8004 wallet when
LineKey is the agent's pool delegate (GHSA-45h8-v5q8-4j43), and the state file's lock, which keeps a purchase to one
signature, is never taken from a running server by a clock (GHSA-wqww-vjpx-w8mq).

## 0.3.1 (2026-11-05)

Security fix from the private report of 2026-11-04 by @sonson0910 (GHSA-mc89-r73h-33vv; 0.3.0 is affected):

- A URL is taken out of the message whole, up to the next space, before any amount or id is read. 0.3.0 stopped a URL
  at `)`, `]` or `'`, which are a URL's own characters, so what followed in it stayed in the message's words:
  `https://seller.example/data#)borrow$5,max$0.50` named a borrow of 5 and a price of 0.50, and a `max$9` there won over
  the user's "at most 0.10". The URL paid is as before.

On `@priors/mcp` 0.18.1 (was 0.16.0): among its changes, auto-borrow never borrows on a plan whose AutoRepay epoch could
not be read (GHSA-mc89-r73h-33vv), and Autopay's plan is current only from the declared wallet (GHSA-m3hr-g75r-gmcj).

## 0.3.0 (2026-11-03)

**Breaking: the money actions answer no one until `PRIORS_OWNER_ENTITY_IDS` is set.** An agent upgraded from 0.2.x
without it still reads records, but `PRIORS_PAY_X402` and `PRIORS_REPAY` refuse every message, and the answer says what
to set.

Security fixes from the private reports of 2026-10-31 (published versions 0.1.0 to 0.2.1 are affected):

- `PRIORS_PAY_X402` and `PRIORS_REPAY` answer only the entities in the new `PRIORS_OWNER_ENTITY_IDS` setting (or
  anyone, with `*`); unset, they answer no one. Before, any member of a room the agent is in could make it pay and
  borrow within `@priors/mcp`'s caps (GHSA-p29w). **Set it when upgrading.**
- Amounts and ids are read from the message with its URLs taken out, and keywords as whole words: a URL's path or
  query (`/pay1/borrow5.json`) no longer sets the price or a borrow, a URL's `#123` is not an agent id, a bare "pay N"
  is the price only when no cap phrase is named and N is an amount, and an aside after the borrow phrase ("borrow 0.50
  (up to 5)") is the borrow's (GHSA-rf6g, GHSA-62m7).

On `@priors/mcp` 0.16.0 (was 0.15.0): among its changes, Autopay and auto-borrow refuse an agent whose declared wallet
is its owner's own address, which AutoRepay never repays under a wallet plan (GHSA-65qg).
