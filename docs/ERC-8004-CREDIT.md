---
title: Credit history for ERC-8004 agents
description: A profile of the ERC-8004 Reputation Registry for loan outcomes that any reader can rebuild from the lender's own logs
author: Priors contributors (@priors_trade)
discussions-to: (Ethereum Magicians thread, to open)
status: Draft (pre-submission, 2026-10-07)
type: Standards Track
category: ERC
requires: 8004
---

*Working draft, kept in this repository until it is posted for discussion. The reference reader, the format's code,
the test vectors and their tests are in this repository; Priors' writer and its fork test run in Priors' own
deployment (see "Reference implementation").*

## Abstract

This profile gives lenders one way to write an agent's credit history to the ERC-8004 Reputation Registry: loans
opened, repaid on time, repaid late, defaulted. It adds no contract. A lender posts ordinary `giveFeedback` entries
with two tags, `credit.statement` and `credit.defaulted`, whose files are carried in the entry itself.

A statement commits, with a Merkle root, to every loan of the agent that closed in a block window at the lender's
contracts. Each loan is a leaf naming the lender's own log that closed it. A reader holding nothing but an RPC
endpoint can rebuild every leaf from those logs, check the root and the totals, and sample the money that moved.

A lender's statements for one agent are chained by hash over back-to-back windows. Skipping a window or revoking a
statement is visible to every reader. Dropping a loan at a contract the lender declares is visible to every reader
that rebuilds the statements.

## Motivation

ERC-8004 gives agents an identity and a place where anyone can leave feedback. Most feedback is an opinion, and an
opinion costs nothing to fake. A repaid loan is different: someone put money at risk and got it back, and both
transfers are on chain.

Credit history is the one kind of reputation that can be checked against money that moved. Today every lender to
agents keeps it in its own format, so a record earned with one lender is invisible to the next. Lenders also use
values that cannot be compared: scores on different scales, counts, amounts.

Goals:

1. **No new core contract.** It works on every chain where the ERC-8004 registries are deployed, today.
2. **Checkable from the chain alone.** Every number in a statement can be rebuilt from the lender's logs. A reader
   needs no API from the lender.
3. **Omission is visible.** A lender cannot quietly leave out a default at the contracts it declares: windows are
   contiguous and chained, they cover each contract from its first block, and the root covers every loan closed in
   the window. Which contracts a lender has is the reader's call (see Readers).
4. **Scales to many small loans.** Agents borrow often and in small amounts. In the reference deployment, 140 agents
   closed 28,008 loans in 16 days. One entry per loan would flood the registry. One statement per agent per
   period, at about 2–4 KB, does not.
5. **Provable on chain, one loan at a time.** A contract can verify that a given loan is in a statement with a Merkle
   proof (OpenZeppelin `MerkleProof`).

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT
RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174.

### Terms

- **Lender:** whoever extends credit to an agent.
- **Source:** a lender contract whose logs record loans opening and closing.
- **Writer:** the address that posts the lender's credit entries (the entry's `clientAddress`).
- **Loan:** one extension of credit with an id unique within its source, a principal and a due time.
- **Leaf:** one closed loan.
- **Statement:** the leaves of one agent at one writer's sources over a block window.
- **Class:** what secured the loan. `unsecured`, or `secured:<kind>` where kind is one of `stock`, `pt`, `lst`, `stable`,
  `nft` or `other`.
- **Manifest:** a reader's own list of a writer's sources, taken from somewhere other than the writer's files.

### Entries

A writer posts entries with `giveFeedback(agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI,
feedbackHash)`:

| tag1 | value | tag2 | when |
| --- | --- | --- | --- |
| `credit.statement` | principal repaid on time in the window | the leaves' class; `mixed` if more than one; the agent's current line class if no leaf | periodically, per agent |
| `credit.defaulted` | principal of the defaulted loan | the loan's class | when a loan defaults |

- `valueDecimals` MUST equal the decimals of the statement's `asset`, and amounts are in the asset's base units.
- `endpoint` SHOULD be empty.
- `feedbackURI` MUST be exactly `data:application/json;base64,` followed by the base64 of the file's bytes (RFC 4648
  standard alphabet, padded, no other character), so the entry carries its own evidence and outlives any server.
  `feedbackHash` MUST be `keccak256` of those bytes.
- The file's bytes MUST be its canonical encoding (see Encoding).
- A writer MUST NOT revoke a credit entry.
- A writer SHOULD be an address used only for credit entries, and MUST NOT own an agent it writes about (the registry
  already refuses self-feedback).

### Sources

Every file lists the sources its leaves come from:

```json
{
  "chainId": 4663,
  "contract": "0x…",
  "blocks": [71702460, null],
  "events": {
    "open": "Borrowed(uint256 indexed loanId, uint256 indexed agentId, uint256 indexed sponsorId, uint256 principal, uint256 fee, uint64 dueAt, address to)",
    "repaid": "Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer)",
    "defaulted": "Defaulted(uint256 indexed loanId, uint256 indexed agentId, uint256 indexed sponsorId, uint256 principal, uint256 sharesBurnt, address owner)"
  },
  "fields": { "amount": "principal", "dueAt": "dueAt" }
}
```

- `contract` is EIP-55 checksummed. A source is identified by (`chainId`, `contract`).
- `events` are the exact event signatures the contract emits, with parameter names. The three are distinct and not
  anonymous.
- Each of the three events MUST have `uint` parameters named `loanId` and `agentId`, plus the `uint` parameter named by
  `fields.amount`. The `open` event MUST also have the `uint` parameter named by `fields.dueAt` (unix seconds).
- `agentId` SHOULD be indexed, so a reader can filter by agent.
- `blocks` is `[first, last]`: a block at or before the contract's first loan (its deployment block is a safe choice),
  and its last block of lending, or `null` while it still lends.
- Along a (writer, agent) chain, a source's `first`, `events` and `fields` MUST NOT change. `last` may change once, from
  `null` to a block.
- A reader MUST NOT narrow its log scan with a writer's `blocks`: a writer could end a range early to hide later loans.
  It MAY narrow it with the ranges of a manifest it trusts.

A lender whose contract does not emit such events cannot be checked by readers and SHOULD NOT write this profile.

### Encoding

A file is UTF-8 JSON in the canonical form of RFC 8785 (JCS): object keys sorted by UTF-16 code units, no whitespace,
strings escaped as JCS does. One file has one byte string, so every reader gives it the same meaning.

- Every JSON number in a file is an integer from 0 to 2^53 − 1. Ids (`agentId`, `loan`) and amounts (`value` and
  every `amount`) are decimal strings without leading zeros, because they are `uint256` (`value` is `int128`) and can
  pass 2^53. ERC-8004's example file writes `agentId` and `value` as JSON numbers; this profile writes them as
  strings.
- Addresses are EIP-55 checksummed. `agentRegistry` and `clientAddress` are CAIP-10 (`eip155:<chainId>:<address>`)
  on the same chain. Hashes are lowercase `0x`-prefixed hex. `createdAt` is UTC to the second
  (`2026-10-07T14:29:10Z`).
- A file has exactly the fields this document lists. Only `lender`, and `lender.about` within it, are optional.
- A file MUST NOT exceed 8,192 bytes. It holds at most 16 sources and 16 anchors. `lender.name` is 1 to 64 characters
  (UTF-16 code units), `lender.about` 1 to 256, an event signature at most 512, and no string has control characters.

A reader MUST reject a file whose URI is not exactly the prefix and canonical base64, whose bytes are not UTF-8, or
whose bytes are not the canonical encoding of the JSON they parse to. The last check rejects duplicate keys (parsers
disagree on which one wins), whitespace, and other spellings of a number.

### Leaves

A leaf is one loan of the agent closed at a source by a `repaid` or `defaulted` log.

| field | meaning |
| --- | --- |
| `loan` | `loanId`, a decimal string |
| `amount` | the close log's amount field, in base units, a decimal string |
| `dueAt` | the open log's due time |
| `closedAt` | the timestamp of the block holding the close log |
| `outcome` | `1` repaid on time (`closedAt <= dueAt`), `2` repaid late, `3` defaulted, `4` recovered (reserved: a v1 file MUST NOT carry it, see Open questions) |
| `tx`, `log` | the close log's transaction hash and log index in its block |
| `block` | the close log's block (a lookup aid, not committed) |
| `src` | index of the leaf's source in the file's `sources` (not committed) |
| `cls` | the loan's class (the lender's claim, not committed) |
| `openBlock`, `openTx`, `openLog` | where the open log is (not committed; REQUIRED in written leaves, for a light reader) |

The leaf hash, as OpenZeppelin's `MerkleProof` expects:

```
leafHash = keccak256(bytes.concat(keccak256(abi.encode(
  uint256 chainId, address contract, uint256 agentId, uint256 loanId, uint256 amount,
  uint64 dueAt, uint64 closedAt, uint8 outcome, bytes32 txHash, uint32 logIndex))))
```

Leaves are ordered by close block, then log index. The root is a binary Merkle tree over the leaf hashes in that
order: each pair is hashed sorted (`keccak256(min ‖ max)`), and an odd last node is carried up unchanged. The root of
no leaves is `bytes32(0)`.

### Statement file

The file holds ERC-8004's off-chain feedback fields and one object, `credit`. It is shown here in reading order; its
bytes are canonical (keys sorted, no whitespace):

```json
{
  "agentRegistry": "eip155:4663:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432",
  "agentId": "6197",
  "clientAddress": "eip155:4663:0x…writer",
  "createdAt": "2026-10-07T14:29:10Z",
  "value": "…", "valueDecimals": 6,
  "tag1": "credit.statement", "tag2": "unsecured",
  "credit": {
    "v": "erc8004-credit/v1",
    "lender": { "name": "…", "about": "https://…" },
    "asset": "eip155:4663/erc20:0x…",
    "decimals": 6,
    "sources": [ { "…": "as above" } ],
    "seq": 2,
    "prev": "0x…feedbackHash of seq 1",
    "window": { "fromBlock": 75927565, "toBlock": 82543414, "toTime": 1791383350 },
    "opened":      { "count": 115, "amount": "…" },
    "closed": {
      "onTime":    { "count": 114, "amount": "…" },
      "late":      { "count": 0, "amount": "0" },
      "defaulted": { "count": 0, "amount": "0" },
      "recovered": { "count": 0, "amount": "0" }
    },
    "classes":     { "unsecured": { "onTime": { "…": "…" } } },
    "outstanding": { "count": 1, "amount": "…" },
    "leaves": 114,
    "root": "0x…",
    "anchors": [ { "src": 0, "cls": "unsecured", "loan": "…", "amount": "…", "dueAt": 0, "closedAt": 0, "outcome": 1, "block": 0, "tx": "0x…", "log": 0, "openBlock": 0, "openTx": "0x…", "openLog": 0 } ]
  }
}
```

- `value` is `credit.closed.onTime.amount`, as a decimal string of base units. JSON numbers lose precision past
  2^53.
- `asset` is the token lent, as a CAIP-19 id: `eip155:<chainId>/erc20:<address>`. In v1 it is an ERC-20 token.
  `decimals` is the token's `decimals()`.
- `asset` and `decimals` MUST NOT change along a (writer, agent) chain. A lender that lends several assets to one
  agent uses one writer address per asset.
- `seq` starts at 1 for each (writer, agent) pair and increases by 1. `prev` is the previous statement's
  `feedbackHash`, or `null` for seq 1.
- `window.fromBlock` is the previous statement's `toBlock + 1`. `toTime` is the timestamp of `toBlock`. `toBlock`
  SHOULD be final on its chain.
- Seq 1's window MUST start at or before the first block of every source it declares, so it covers the agent's whole
  history with the lender at those sources. Seq 1 MUST declare every source the lender has used for this agent.
- A later statement MUST declare every source that has a leaf or an opened loan in its window, and every source an
  earlier statement declared whose `blocks` reach its window (`first <= toBlock`, and `last` is `null` or
  `>= fromBlock`). A source it declares for the first time MUST have its first block at or after its `fromBlock`.
- A statement MUST include every leaf whose close log is at one of its sources within the window.
- `leaves` is the number of leaves. `root` is `bytes32(0)` exactly when `leaves` is 0.
- `closed.recovered` MUST be `{ "count": 0, "amount": "0" }` in v1 (recovery is reserved), and the outcome counts
  add up to `leaves`.
- `opened` covers the loans whose open log is in the window. `outstanding` covers the loans opened at or before
  `toBlock` and not closed at or before it.
- `classes` splits `closed` by class, as claimed by the lender: one key per class with a loan in the window, adding up
  to `closed`. `tag2` is its one key, `mixed` for more than one, or the agent's line class when it is empty.
- `anchors` are the latest leaves in leaf order, all in the window, written in full (RECOMMENDED: 5). Statement files
  SHOULD stay under 4 KB, and a writer drops the oldest anchors first to fit.

### Default file

A `credit.defaulted` entry carries the same head, then `credit` with `v`, `lender`, `asset`, `decimals`, `sources`
(one source) and `leaf` (the defaulted leaf, written in full). Its `asset` and `decimals` are its chain's, and `tag2`
is the leaf's class. The writer SHOULD post it within 24 hours of the default. The statement whose window holds the
default MUST count it.

### Writers

A writer:

- MUST post statements so that each agent's windows are back to back from its first statement onward;
- MUST start each agent's seq 1 at or before the first block of every source it declares;
- SHOULD post a statement at least every 30 days while the agent has loans opened or closed;
- MUST NOT revoke credit entries;
- MUST NOT post two statements with the same `seq` for one agent;
- SHOULD check each file against this profile before posting it: a posted file cannot be replaced.

### Readers

A reader:

- MUST check each entry's bytes: the URI (see Entries), that `feedbackHash` equals `keccak256` of the bytes it
  carries, the encoding (see Encoding), every field and limit of this profile, and that the file's spec fields match
  the entry;
- MAY take a writer's entries from an index instead of scanning the registry's `NewFeedback` logs. It MUST then read
  each from its transaction receipt (the registry's log, for this agent, from this writer), and check that the
  entries' `feedbackIndex` values, credit or not, run from 1 to `getLastIndex(agentId, writer)` with none missing: an
  index that leaves out an entry would hide it;
- MUST walk each (writer, agent) chain and treat any of the following as a failure of that writer for that agent:
  a revoked credit entry, a seq gap, a `prev` mismatch, windows that are not back to back, a seq 1 that starts after
  the first block of a source it declares, a statement that leaves out a source it must declare, a source whose
  declaration changes, or an asset or decimals that change;
- MUST check that each statement's window ends before the block its entry was posted in, and that `toTime` is that
  block's time (a statement cannot pre-claim blocks still to come);
- MUST check each anchor and each default leaf against the source's logs. That means the close log at (`tx`, `log`)
  is the source's event for this loan, agent and amount; the open log at (`openTx`, `openLog`) in `openBlock` gives
  `dueAt`; the close block's time is `closedAt`; and the outcome fits the dates;
- SHOULD check that the asset moved for those loans: at least the principal out of the source when the loan opened
  (default leaves too), and at least the principal into it on repayment. A reader that checks funds MUST treat an
  asset that is not an ERC-20 on the sources' chain, or whose `decimals()` is not `decimals`, as a failure, not as a
  reason to skip the check;
- MUST NOT present the totals of a statement it has not rebuilt as checked, nor add them to totals it reports as
  checked. Without a rebuild they are the writer's claims;
- SHOULD rebuild statements in full before extending credit on the strength of them;
- MUST compute totals by adding up the statements' `closed` figures, per asset, never across assets. `getSummary`
  averages the values of the entries it matches; it does not add them up (measured on the deployed registry: two
  entries of 5 and 7 give a summary value of 6);
- MUST report a writer it asked about that has no statement for the agent as having no data, not as a clean record;
- MUST choose which writers it trusts, as `getSummary` already requires a list of client addresses. Anyone can
  deploy a contract and write statements about loans it made to itself (see Security considerations);
- SHOULD bound what it reads (entries per writer, log queries per rebuild). A malformed entry or a failed check fails
  that writer only.

There are two levels of check:

- **Light** is a sample: the checks above, with a handful of calls per statement. It shows that nothing it checked is
  wrong. It does not show that the root covers every loan of a window, nor that the totals are right: a statement
  whose anchors are real and whose totals are invented passes every light check.
- **Full** rebuilds each statement from the logs of every source the chain declares: its leaves, `leaves`, `root`,
  the four totals, `opened`, `outstanding`, and that the anchors are the window's latest leaves. It scans each source
  over the whole chain, whatever its `blocks` say. It needs the sources' logs for the agent and one block time per
  closed loan. Checking the money that moved for every loan costs one receipt per loan; the reference reader checks
  it on the anchors and default leaves only, and says so.

**Which sources a lender has is the reader's trust decision.** Omission is visible within the sources a writer
declares: a full rebuild finds any loan the statements leave out at those sources, from the start of seq 1. No reader
can find a loan at a contract the writer never names. A reader that knows a lender's contracts (from the lender's
documentation, an audit, or a registry it trusts) MAY hold a manifest: those sources, with their first blocks,
events and fields. With a manifest, the reader MUST also fail a writer when seq 1 starts after a manifest source's
first block, when a statement leaves out a manifest source whose blocks reach its window, or when a file declares a
source the manifest does not list or with other events or fields. It MAY then scan each source over its manifest
range only.

## Rationale

- **A profile of the existing registry, not a new one.** Every ERC-8004 deployment and every indexer of
  `NewFeedback` already sees these entries. Credit events also live next to the agent's other reputation, and
  `tag1` is indexed, so a reader can find them with one log filter.
- **Statements, not one entry per loan.** Per-loan entries cost 150,000 to 200,000 gas each and would bury an agent's
  other feedback. A statement costs the same as one entry and covers any number of loans. Defaults still get their
  own entry, so they stand out at once.
- **Leaves name logs, not lender claims.** Everything committed in a leaf is something the source's logs and block
  headers prove. Anything that cannot be proven in a standard way (the class, the lender's name) sits outside the
  hash and is marked as a claim.
- **A Merkle root rather than a list.** It keeps the file small, it can be rebuilt from logs, and it allows one-loan
  proofs on chain. The leaf encoding and pair hashing are OpenZeppelin's, so no custom verifier is needed.
- **Events declared in the file.** A reader needs no registry of lender adapters: the file says which signatures to
  read and which parameters hold the amount and due time.
- **`data:` URIs.** The evidence is in the entry's own calldata, so it is immutable and needs no server or pinning.
  On the reference chain a 2.7 KB file posted for 198,000 gas (measured on a fork), which is a fraction of a cent.
- **Amounts and ids as strings.** Base units of 18-decimal assets pass 2^53, and so can a `uint256` agent or loan id.
  A reader that parses JSON numbers as floating point would read the wrong agent.
- **Canonical JSON.** The hash fixes the bytes, not their meaning: with duplicate keys or other number spellings,
  two readers could read one file two ways. One canonical form leaves one reading, and a reader checks it by
  re-encoding what it parsed.
- **Sources covered from their first block.** A chain that started after a source's first loans, or a statement that
  dropped a source, would hide loans from a full rebuild. Requiring each declared source to be covered from its first
  block makes omission visible within the declared sources; the rest is the reader's trust decision.
- **One asset per chain.** Amounts in different tokens cannot be added. Keeping one asset per (writer, agent) chain
  keeps a chain's totals in one unit.

## Backwards compatibility

The profile adds tags and a file format; it changes nothing in ERC-8004. Readers that do not know the tags ignore
them. A lender's existing score entries (for example a `priors-score` entry) are unaffected.

## Test cases

`docs/erc-8004-credit/vectors.json`, generated by `node scripts/credit-vectors.mjs`, holds:

- five leaves (on time, late, secured, defaulted) with their hashes, every proof and the root, for agent
  `9007199254740993` (2^53 + 1) and with one loan id past 2^64, so ids read as floating point fail;
- the empty root;
- a statement file with its exact canonical bytes, `feedbackHash`, `feedbackURI` and the `giveFeedback` calldata;
- a default file with its exact canonical bytes, `feedbackHash` and `feedbackURI`.

`test/CreditProfileVectors.t.sol` (generated from the same vectors) recomputes the leaf hashes in Solidity and
verifies every proof with OpenZeppelin `MerkleProof`. A forged leaf fails.

## Reference implementation

In this repository (github.com/priors-agents/priors):

| | |
| --- | --- |
| `sdk/credit-profile.mjs` | leaves, Merkle root and proofs, statement and default files, canonical encoding, the schema, the reader's shape and chain checks (pure) |
| `sdk/credit-reader.mjs` | find an agent's credit entries (a registry log scan, or entries located by the caller and checked against `getLastIndex`), check them light (`sampled`) or full (`rebuilt`) against the chain, with an optional manifest; add up rebuilt totals of trusted writers, by asset (lender-neutral) |
| `scripts/verify-credit.mjs` | the reader as a command: `node scripts/verify-credit.mjs <agentId> [--writer 0x…] [--full] [--sources manifest.json] [--no-funds]`. Exit 0: every check it ran passed; 1: a problem; 2: no data (a `--writer` with no statement, or no credit entry) |
| `docs/erc-8004-credit/priors-manifest.json` | Priors' writer and its two pools as a reader manifest (`--sources`) |
| `scripts/credit-vectors.mjs`, `docs/erc-8004-credit/vectors.json`, `test/CreditProfileVectors.t.sol` | the test vectors, and the same leaves and proofs checked by OpenZeppelin's `MerkleProof` in Solidity |
| `scripts/test-credit-profile.mjs` | unit tests of the format (18) |
| `scripts/test-credit-reader.mjs` | the reader and the command against an in-memory chain served over JSON-RPC (14) |

In Priors' own deployment (not in this repository):

| | |
| --- | --- |
| `sim-worker/credit-core.mjs`, `scripts/credit-pass.mjs` | the writer: Priors' two pools as sources, statements from the site's snapshot, one pass at a time per writer key |
| `credit-worker/` | the hourly pass on Cloudflare |
| `scripts/test-credit-fork.mjs` | the writer and the reader end to end on a fork of Robinhood Chain |

The fork test uses the real registry and three real agents.

- The writer posts seq 1 and seq 2 for an agent with 252 loans across both pools: 138 loans in the first window, 114
  in the second.
- The reader rebuilds both statements from the pools' logs and matches every root and total. It also checks the
  USDG movement of each anchor.
- The reader then catches each of these:
  - a statement that drops one loan, which passes the light check (reported as sampled, not counted) and fails the
    rebuild;
  - an anchor with an inflated amount;
  - a default entry that cites a repayment's log;
  - a window gap;
  - a window reaching past the block the statement was posted in;
  - a revoked statement.

## Security considerations

- **Self-dealing lenders.** A contract can emit `Borrowed` and `Repaid` for loans it makes to an agent its owner
  controls, cycling the same money. Every check in this profile passes for such loans, because they did happen.
  Readers MUST therefore decide which writers to trust. Signals that help:
  - the capital the lender has at risk across many unrelated agents;
  - the lender's own default rate;
  - whether the lender's funds and the agent's funds come from the same place.
  
  An on-chain lender registry is left as an open question.
- **A lying writer.** A writer key can post a false statement, but it cannot remove an earlier one. A false root
  fails a full rebuild. A skipped window or a dropped default at a declared source leaves a gap or a mismatch. A
  source the writer never declares is invisible to a reader without a manifest.
- **Light checks are samples.** A statement with real anchors and invented totals passes them. A light result is the
  writer's claim, and readers MUST NOT count it as checked.
- **A lying source contract.** Logs prove what a contract emitted, not that it is honest. The funds check ties the
  sampled loans to actual transfers of the asset; a contract can still emit loan events with no money behind the
  others. Readers relying on a source should know its code (verified source, audits).
- **Reorgs.** A statement over unfinalised blocks can name logs that later disappear. Windows SHOULD end at final
  blocks.
- **Late versus on time** follows block timestamps, so a loan repaid within a few seconds of `dueAt` can fall either
  side. Lenders SHOULD keep their own lateness rule consistent with `closedAt <= dueAt`.
- **Privacy.** Every amount and address in a statement is already public in the source's logs. Files MUST NOT carry
  personal or off-chain identity data. Credit scoring of people is regulated in many places (for example as high-risk
  under the EU AI Act). This profile records machine-to-contract loans only.
- **Endpoints.** Full rebuilds read many logs. Public endpoints may limit log ranges or history, so a reader may need
  an archive endpoint. A writer's windows and sources decide how many log queries a rebuild needs, so readers SHOULD
  cap them.

## Open questions (for discussion)

1. **Recovered amounts.** After a default, value seized or repaid later. Outcome 4 is reserved: a v1 file carries no
   recovered leaf and a zero `recovered` total. A source would declare a `recovered` event, and a leaf would cite it.
2. **Partial repayments** and loans that roll over.
3. **Sources on several chains** in one statement. The reference reader reports a source on another chain as not
   rebuilt.
4. **A lender registry**, and how readers weight lenders.
5. **An on-chain view** that checks a Merkle proof against a statement's root. The root is in the file, not in
   registry storage, so a contract needs the file's bytes plus the `feedbackHash` from the `NewFeedback` event.
6. **Tag names**, and whether a lender's summary score should also have a standard tag (`credit.score`).

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
