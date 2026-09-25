# Bug bounty

[SECURITY.md](SECURITY.md) says how to report. This says what a report is worth, what is in scope, and what
we will not do to you for looking.

## Read this first: the size of the thing

The v2 pool holds **about $590 of assets** (lender deposits and backers' locked stake, $371 of it lent out) plus
a reserve of about $181, read from the chain on 2026-09-25. That is the whole protocol, today. We are telling you
that up front because a bounty page that implies millions are at stake, from a contract holding a few hundred
dollars, is asking you to spend a week of your time under false pretences.

So this is a small programme, honestly sized, and the ceiling is real. If you want to look at this because
the mechanism is interesting — unsecured credit for agents, where the only collateral is a record — the code
is here and the door is open. If you want it to pay rent, it will not.

## What a finding is worth

| Severity | What it means | Award |
|---|---|---|
| **Critical** | Funds leave the pool to someone not owed them, lender principal can be reached, or a backer's stake or a staker's seat can be taken. Anyone can do it, no privileged key. | **$3,000** |
| **High** | Credit can be obtained without the invite, the consent, the seat or the backing that is supposed to gate it, or accounting can be corrupted so the ledger lies about who repaid what. | **$1,000** |
| **Medium** | A rule can be bypassed with a privileged key that should not be able to bypass it, or a griefing path that costs others money without profiting you. | **$250** |
| **Low / Informational** | Wrong behaviour with no path to loss: a misleading view, a revert that should not happen, a documented rule the code does not implement. | public credit and acknowledgement only, no payout |

Paid in USDG on Robinhood Chain, or in whatever else we can agree on. One award per root cause, not per call
site. Anything below Medium is credited in public, not paid. We would rather say that here than argue about it
afterwards.

Severity is our judgement, argued in writing with you, not a number we pick in private. If you disagree with
where we land, say so — the reasoning is the part we will publish.

## In scope

The live v2 contracts on Robinhood Chain (chain 4663), deployed at block 71,702,460:

| Contract | Address |
|---|---|
| `CreditPoolV2` (with its linked `PoolV2Lib`) | [`0x281210097f0de7A8FB6F87310AF0f089c9C8DE21`](https://robinhoodchain.blockscout.com/address/0x281210097f0de7A8FB6F87310AF0f089c9C8DE21) |
| `CreditLensV2` | [`0x9d7035722bd42C551f82FEB9FDDd17453AEF3D9B`](https://robinhoodchain.blockscout.com/address/0x9d7035722bd42C551f82FEB9FDDd17453AEF3D9B) |
| `TreasurySponsorV4` (root `#6228`) | [`0x0c5091235A25bBFD3F5a009cBe04120D0CBAD573`](https://robinhoodchain.blockscout.com/address/0x0c5091235A25bBFD3F5a009cBe04120D0CBAD573) |
| `SeatVaultV2` (root `#6229`) | [`0x6D934C07a33E7285cE691A9B258cdB53F18e6B5F`](https://robinhoodchain.blockscout.com/address/0x6D934C07a33E7285cE691A9B258cdB53F18e6B5F) |
| `TimelockController` (the pool's owner, 48 h) | [`0x5d984C274035F81BB327d532897a902C5125F87c`](https://robinhoodchain.blockscout.com/address/0x5d984C274035F81BB327d532897a902C5125F87c) |

Also in scope: the SDK (`sdk/priors-v2.mjs`, `sdk/float.mjs`), the CLIs, the site's wallet path and the x402
facilitator at `facilitator.priors.trade`, where a bug can cost a *user* money even though the contracts are
sound — a mis-encoded call, a wrong address, a consent or an invite that redeems against the wrong agent, a
payment settled twice. The hosted MCP server at `mcp.priors.trade` and the paid API at `api.priors.trade` are in
scope on the same terms: the MCP server is read-only and holds no key, so a way to make it sign, send, or leak a
secret is a finding.

**The Telegram invite bot** (`@priors_agents_bot`) is in scope for **public credit only, no payout**, whatever the
severity. Its inviter key only signs first-line invites, and the treasury caps what those can draw each week
($25), so the worst a bot bug can cost is bounded by that cap. A path around the treasury's cap itself is a
contract finding and is paid as one.

## Out of scope

- **Anything needing the owner's Safe or the timelock.** The Safe is a 2-of-3 and it can change rules, through
  the 48 h timelock for the pool; that is the design, not a finding. "The owner could set a bad parameter" is not
  a bug.
- **The v1 contracts**, paused since the v2 cutover and kept as history: the v1 `CreditPool`
  (`0x0259889e6EBab1a18CeE7e62Bc5B9648FB6C44e5`), `TreasurySponsor` v2 and v3, `ReserveFunder` and the older pools.
  A finding there counts only if it also applies to v2.
- **Known v2 findings and their accepted residuals**, listed in [docs/SECURITY-v2.md](docs/SECURITY-v2.md). A new
  path around one of them, or a larger bound than the one stated there, is a finding.
- **Known issues** (next section).
- Gas optimisation, style, and "you should use a different pattern".
- Denial of service that costs the attacker more than the target, or that needs to be sustained forever.
- Anything about the RPC endpoint, the block explorer, or Cloudflare — not ours.
- Social engineering, phishing, or physical access to anyone.
- Reports from an automated scanner with no explanation of the path. Run the scanner; then tell us which
  finding is real and why.

## Known issues

Every issue listed in [docs/SECURITY-v2.md](docs/SECURITY-v2.md), whether fixed, mitigated, an accepted residual
or a trust assumption, is known. A report of one is not a new finding and is not paid at any tier; if it adds
something real (a cleaner reproduction, a tighter measurement) we will credit it in public. That includes the
residuals added after launch: SO-1 and SO-2 (stake held only while marking a default), AI-1 (the invite bot's
self-service mode) and V-2 (seat levers and ownership not reaching open seats).

What still counts is a new root cause, or a path that beats the bound stated for a listed issue: reaching lender
principal through it, or losing more than its stated cap. Severity for those is judged by the table above.

## Safe harbour

If you stay inside this, we will not pursue you and will not ask anyone else to:

- Use the testnet or a fork. There is no reason to prove it on mainnet and every reason not to.
- If you genuinely cannot reproduce it off mainnet, take **the smallest amount that proves the point**, tell
  us immediately, and send it back. We will still pay the award. Keeping the funds is theft, and then this
  section does not apply to you.
- Do not touch anyone else's agent, identity, or wallet.
- Do not publish before we have shipped a fix or 90 days have passed, whichever comes first. If we go quiet
  on you, 90 days is yours to use.

## What has already been found

[docs/SECURITY-v2.md](docs/SECURITY-v2.md) lists every known v2 finding, its fix or residual, and its test;
[SECURITY.md](SECURITY.md) has the v1 history. Three worth knowing before you start, because they are the obvious
ones:

- **Every line is 100% backed.** v2 has no earned or unbacked credit: a line is vouched out of a backer's locked
  pool shares, and a default burns that backer's shares worth principal and fee. Lenders are not supposed to be
  reachable at all. A path to lender principal is what "Critical" means above.
- **How first lines are issued.** Today a treasury v4 invite is approved by an admin and signed by the treasury's
  named inviter after a check that the requester owns the agent; redeeming it also needs the owner's pool consent.
  New treasury lines are capped at $25 a week by treasury v4's `epochCap`. The invite bot also has a self-service
  mode that signs for any owner who proves control of an agent; it is off today, and when it is on, one person
  taking the week's first lines within that cap is a listed residual (AI-1), not a finding. A seat needs a
  staker's $PRIORS and 3 repaid loans; a backer needs the owner's consent. Credit without one of those is "High".
- **Bounded, known losses.** The self-seat loop (X-3), the invite-to-raise path (T10) and self-service invites
  (AI-1) can cost a backer money, and holding stake only while marking a default (SO-1, SO-2) takes lender fees,
  within the per-epoch caps stated in SECURITY-v2.md. Beating those bounds is a finding; restating them is not.
