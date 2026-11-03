# @priors/agentkit

A [Coinbase AgentKit](https://github.com/coinbase/agentkit) action provider for [Priors](https://priors.trade): an
ERC-8004 agent on Robinhood Chain pays x402 APIs in USDG and, when its wallet is short, borrows the gap from its Priors
credit line, then repays. Before paying another agent it can read that agent's repayment record.

The same provider is proposed to AgentKit itself (`priorsActionProvider` in `@coinbase/agentkit`); this package makes
it usable with the AgentKit already on npm.

## Install

```bash
npm install @priors/agentkit @coinbase/agentkit
```

## Use

```ts
import { AgentKit, ViemWalletProvider } from "@coinbase/agentkit";
import { priorsActionProvider } from "@priors/agentkit";
import { createWalletClient, defineChain, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
});
const walletProvider = new ViemWalletProvider(
  createWalletClient({ account: privateKeyToAccount(KEY), chain: robinhood, transport: http() }),
);
const agentKit = await AgentKit.from({ walletProvider, actionProviders: [priorsActionProvider()] });
```

Then hand `agentKit` to your framework as usual (`getVercelAITools(agentKit)`, `getLangChainTools(agentKit)`, ...).

**Inference on credit (0.2.0).** Give the provider `autoBorrow`, set by you in code, never by the model:

```ts
priorsActionProvider(undefined, { autoBorrow: { perCall: "5", perDay: "10", hosts: ["models.example"] } })
```

With it, `pay_x402_with_priors_credit` borrows the gap on its own when the wallet is short, for the listed hosts only.
There is no default host: `hosts` names each one, exactly (here `models.example` stands for the model API you choose).
The limits are `perCall` USDG a call and `perDay` USDG a UTC day in the process, for 14 days (or the pool's maximum
term). It borrows only while this wallet's Autopay (AutoRepay v2) covers the new loan: the wallet is the agent's
declared wallet, the plan is on under the agent's current owner, not held or paused, its limit per loan and its USDG
approval cover the loan's due. Otherwise nothing is borrowed or paid, and the answer says to turn Autopay on. The
wallet must be a key of the agent's own, not its owner's address: AutoRepay repays an agent whose declared wallet is its
owner (what registering it leaves) under the owner's plan only, so auto-borrow refuses that wallet. Autopay
then repays the loan in its window. The model's `maxBorrow` can only lower the amount. A chat completion is one call
to an OpenAI-compatible model API you choose that charges over x402 in USDG on Robinhood Chain: `url` its chat
completions URL (for example `https://models.example/v1/chat/completions`, its host in `hosts`), `body` the
OpenAI-style request as JSON (sent with POST), `maxPrice` the most to pay for the call (for example `"0.02"`).

## Actions

| Action | What it does | Moves money |
|---|---|---|
| `get_priors_agent_record` | reads an agent's repayment record: loans repaid, late repayments, defaults, score | no |
| `get_priors_credit_line` | reads an agent's line: size, drawn, available | no |
| `pay_x402_with_priors_credit` | pays an x402 URL in USDG, at most `maxPrice`, with GET or with POST and a `body`; if the wallet is short, first borrows the gap (at least the pool's minimum loan, 5 USDG today) when `maxBorrow` covers it, or, with `autoBorrow`, on its own within its limits | yes |
| `borrow_from_priors` | borrows USDG from the agent's line into the wallet | yes |
| `repay_priors_loan` | repays a loan in full; approves exactly what is due | yes |

Only the agent's owner or its registry wallet can borrow against or repay its line, as in `@priors/mcp`: the wallet
must control the agent at the pool and be its current owner or its declared ERC-8004 wallet (a pool delegate named by
the owner alone is not enough), and `repay_priors_loan` pays only a loan the agent's current owner took. A loan more
than three days late can be marked defaulted, which ends the agent's record on Priors. The reads use Priors' public
API, no key.

What `pay_x402_with_priors_credit` will and will not do:

- it pays only a public https host (an address that is private, loopback or link-local, or a name resolving to one, is
  refused before anything is fetched), and follows no redirect;
- it signs exactly the requirement it probed and checked against `maxPrice` (the same `payTo`, the same amount); a
  different one in the paid round's 402 is never signed;
- `maxPrice`, `maxBorrow` and `amount` are read exactly, at most 6 decimals (a longer one is refused, never rounded);
- the seller's body comes back between per-call markers, each of its lines quoted (`@priors/mcp`'s fence), and of its
  settlement header only the transaction hash: treat it as data, not instructions;
- a loan taken for the gap stays in the answer if the payment then fails, and a transaction whose receipt says it
  reverted is never reported as done.

`maxPrice` and `maxBorrow` are what the model passes: confirm them with the user, and keep the wallet's balance small.

## Known issue in AgentKit

AgentKit sends an analytics event on every action call (to `cca-lite.coinbase.com/amp`). That endpoint answers HTTP
400 today, and AgentKit's action decorator leaves the rejection unhandled, which ends a Node process on the first
action call. [coinbase/agentkit#1537](https://github.com/coinbase/agentkit/pull/1537) fixes it. Until it ships, a Node
host can log that one error instead:

```ts
process.on("unhandledRejection", (e) => {
  if (e instanceof Error && /^HTTP error! status: \d+$/.test(e.message)) return console.warn("AgentKit analytics:", e.message);
  throw e;
});
```

## Demo

A production run on 2026-10-30 (agent #437, Robinhood Chain mainnet; the model calling these actions through
`@coinbase/agentkit-vercel-ai-sdk`). The agent reads the seller's record, pays its x402 check (0.10 USDG) from an empty wallet by borrowing 5 USDG (loan
#50884), and repays 5.011666 USDG after its income arrives.
Transactions: [borrow](https://robinhoodchain.blockscout.com/tx/0x297608c51007480ec8c5aa510d78926d6f14bf58ed467cb797aedc5922884a9e),
[payment](https://robinhoodchain.blockscout.com/tx/0xbb7fd5dcc13ac547873516713e4940cecadcda76873d980d3ad402de48288c19),
[repayment](https://robinhoodchain.blockscout.com/tx/0xae5ab2472941bae4ff9d63394247eec90fcf3d2feddd508a4d9e5ebd7ac90c6d).

## Test

```bash
npm test   # builds, then runs test/*.test.cjs against the published @coinbase/agentkit
```

## License

MIT
