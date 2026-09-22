# Bug bounty

[SECURITY.md](SECURITY.md) says how to report. This says what a report is worth, what is in scope, and what
we will not do to you for looking.

## Read this first: the size of the thing

The pool holds **about $344 of USDG**. That is the whole protocol, today. We are telling you that up front
because a bounty page that implies millions are at stake, from a contract holding three hundred dollars, is
asking you to spend a week of your time under false pretences.

So this is a small programme, honestly sized, and the ceiling is real. If you want to look at this because
the mechanism is interesting — unsecured credit for agents, where the only collateral is a record — the code
is here and the door is open. If you want it to pay rent, it will not.

## What a finding is worth

| Severity | What it means | Award |
|---|---|---|
| **Critical** | Funds leave the pool to someone not owed them, or a sponsor's stake can be taken. Anyone can do it, no privileged key. | up to **$1,000** |
| **High** | Credit can be obtained without the invite or the capacity that is supposed to gate it, or accounting can be corrupted so the ledger lies about who repaid what. | up to **$300** |
| **Medium** | A rule can be bypassed with a privileged key that should not be able to bypass it, or a griefing path that costs others money without profiting you. | up to **$100** |
| **Low** | Wrong behaviour with no path to loss: a misleading view, a revert that should not happen, a documented rule the code does not implement. | public credit, and our thanks |

Paid in USDG on Robinhood Chain, or in whatever else we can agree on. One award per root cause, not per call
site. **No award exceeds what the finding actually protects** — if a bug can drain $50, it is not a $1,000
finding, however elegant. We would rather say that here than argue about it afterwards.

Severity is our judgement, argued in writing with you, not a number we pick in private. If you disagree with
where we land, say so — the reasoning is the part we will publish.

## In scope

The deployed contracts on Robinhood Chain (chain 4663):

| Contract | Address |
|---|---|
| `CreditPool` | [`0x0259889e6EBab1a18CeE7e62Bc5B9648FB6C44e5`](https://robinhoodchain.blockscout.com/address/0x0259889e6EBab1a18CeE7e62Bc5B9648FB6C44e5) |
| `TreasurySponsor` v3 | [`0x59f212317b42D308E81EaF8C078fc8189E2a77Df`](https://robinhoodchain.blockscout.com/address/0x59f212317b42D308E81EaF8C078fc8189E2a77Df) |
| `TreasurySponsor` v2 | [`0x9338d18b5E7faC5ce06a6AD1Af33Db68fE0b4daC`](https://robinhoodchain.blockscout.com/address/0x9338d18b5E7faC5ce06a6AD1Af33Db68fE0b4daC) |

v2 is in scope because it is not retired: it still sponsors the lines it opened before v3, and it still holds
the stake backing them.

Also in scope: `sdk/priors.mjs` and the site's wallet path, where a bug can cost a *user* money even though
the contracts are sound — a mis-encoded call, a wrong address, an invite that redeems against the wrong agent.

## Out of scope

- **Anything needing the owner's Safe.** It is a 2-of-3 and it can change rules; that is the design, not a
  finding. "The owner could set a bad parameter" is not a bug.
- **The $65 stranded in the superseded pool.** Known, documented, and unreachable because `unvouch` is
  controller-gated and that controller is a contract with no passthrough. We know. It stays stranded.
- Gas optimisation, style, and "you should use a different pattern".
- Denial of service that costs the attacker more than the target, or that needs to be sustained forever.
- Anything about the RPC endpoint, the block explorer, or Cloudflare — not ours.
- Social engineering, phishing, or physical access to anyone.
- Reports from an automated scanner with no explanation of the path. Run the scanner; then tell us which
  finding is real and why.

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

[SECURITY.md](SECURITY.md) lists what is fixed and why. Two worth knowing before you start, because they are
the obvious ones and they are closed:

- **Unsecured first lines.** Any address could take a treasury line for any registered identity. v2 gated it
  to the identity's controller; v3 requires an EIP-712 invite signed by a key the owner named. A fresh
  identity costs cents, so a line that needs no person is a faucet.
- **Unsecured growth.** `maxEarned` is 0 on the live pool: no line can exceed what a sponsor's locked USDG
  backs. Nothing the pool lends is backed by reputation alone.

Finding a way around either of those is what "Critical" means above.
