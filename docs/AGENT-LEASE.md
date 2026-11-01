# AgentLease: renting an agent

AgentLease (`src/AgentLease.sol`) lets the owner of an ERC-8004 agent rent it out for 1 to 90 days. The renter runs
the agent on Priors for that term: it sells the agent's work and takes paid jobs under its name, paid to its own
address. It is deployed on Robinhood Chain (chain 4663) since 2026-11-01 at `0xF2299A992879764ceF0107Aa9Beb07AdfBe0e479`,
its source verified on the explorer (exact match); its deploy record is `deployments/4663.agent-lease.json`. Priors' own
pages offer renting only on the test site for now; the contract itself is open to anyone on chain.

AgentLease is a separate contract beside AgentMarketV2 (`0x6a4583242B8313313E684d02aB7dc6bFf8749670`), the agent
market. It reads the market's public views (the fee, `feeTo`, the refused list, `listingOf`, `recordHash` and
`lastSoldAt`) and changes nothing in it. No lease rule sits inside the market.

## What a renter gets, and never gets

| | During a lease |
|---|---|
| The agent (the NFT) | Stays in its owner's wallet. The owner can sell it or move it, and the lease goes on. |
| Its record, its line, its Score v2 | Stay with the agent. The lease never moves the agent, so nothing restarts. |
| Its work and paid jobs on Priors | The renter's, paid to the renter's own address. |
| Borrowing on its line | Never the renter. `rent` refuses anyone who can borrow for the agent (`isController`). |
| Its registry wallet and its file | Never the renter. `rent` refuses the agent's registry wallet. |

## How a lease works

1. **Offer.** The owner calls `offerRent(id, dayPrice, minDays, maxDays, renter, expiry)`: a daily rate in USDG units,
   a range of 1 to 90 days, anyone (`renter` zero) or one named address, and an expiry at most 30 days ahead. Nothing
   moves. The market's fee is pinned with the offer. A new offer replaces the standing one. An offer may be made while
   a lease runs: it can be taken once that lease ends, and it closes that lease's extensions.
2. **Rent.** The renter approves the total and calls `rent(id, days, maxTotal, recordHash, uriHash)`. The whole term,
   the daily rate times the days, goes into the contract, and none of it goes to the owner or to the market's `feeTo`
   then. (A lease that ran out unclaimed before is paid out first, as `claim` would pay it: its `RentPaid` and
   `FeeTaken` come before `Rented`.) The lease pins its fee: the lower rate and the lower minimum of the offer's fee
   and the market's now. `userOf(id)` names the renter until the lease's end. A rent is refused while a listing of the
   agent stands on AgentMarketV2 or on AgentMarket v1, whoever listed it.
3. **Day by day.** Day k of the lease (from 1) runs from `start + (k-1) days` to `start + k days`. Once a day has ended,
   its rent belongs to whoever held the agent at that moment, less its share of the fee. `claim(id)` pays every day that
   has ended and is not paid yet. Anyone can call it, at any time, and the owner collects its own rent: there is no
   keeper.
4. **Add days.** While the lease runs, its renter can add days with `extend(id, days, maxTotal, recordHash, uriHash)`,
   at the lease's own daily rate, up to the rented offer's longest term from the start.
5. **End.** A lease ends at its date by itself; its last claim closes it. It can end early: by its renter, or by the
   agent's owner (whoever holds it then, a buyer included), with `endLease(id, minRefund)`. An end first pays the days
   that ended to their holders: the renter's own end also pays the day under way, and the owner's end sends that day
   back too. Then every day not paid goes back to the renter from the contract, in full, and the call reverts rather
   than send back less than `minRefund`. `refundsOf(id)` gives that refund. A renter that also holds the agent ends as
   the renter. The owner pays nothing to end a lease. A broken agent's lease (defaulted, burnt, or sent to the lease
   contract) anyone ends, before its date or after, and every end of it sends the day under way back.

Example, at a 1% fee with a 1 USDG minimum: 30 days at 5 USDG is 150 USDG, all paid into the lease at the rent. Day 1
pays its owner 4 USDG when it ends (5 USDG less the 1 USDG minimum), days 2 to 20 pay 5 USDG each, and days 21 to 30 pay
4.95 USDG each: 1.50 USDG of fee in all. If the renter ends the lease 9 and a half days in, the owner gets days 1 to 10,
50 USDG less 1 USDG of fee, and the renter gets 100 USDG back for days 11 to 30. If the owner ends it at the same
moment, the owner gets days 1 to 9, 45 USDG less 1 USDG, and the renter gets 105 USDG back, day 10 included.

## The money

- **The fee is the market's, read live.** F(n), the fee on n days' rent, is `max(n x dayPrice x feeBps / 10,000,
  minFee)`, rounded down, from the market's `feeBps` and `minFee`, never from a constant. Today that is 1% with a 0.25
  USDG minimum, paid to BoardFeeSplitter (`0x49F333f2C06A47a7a881Bc5e6Da8A8b984271A0B`).
- **It comes out of each payout**, never out of what `rent` or `extend` pays in, and never out of a refund. After each
  payout, the fee taken on a lease in all is F(paidDays) at the lease's pin. So each day carries its own share,
  F(k) - F(k-1) for day k, however the payouts are grouped, and a day never paid carries none. Each payout's share goes
  to the market's `feeTo` read at that payout (`FeeTaken`). A raise of the market's fee after the rent never reaches a
  lease; a cut before the rent does.
- **A day is always above the fee** (`DayBelowFee`): an offer's daily rate must be above F(maxDays) at the market's fee
  when it is made, and a lease's pin can only lower that. So every payout leaves its holder something, the fee on a
  whole lease, added days included, is under one day's rent, and every refund is whole days in full. At 1% the fee on
  the longest term, 90 days, is 0.9 of a day's rent. A raise of the market's rate above 1.11% (its cap is 2%) would
  shorten the longest term a new offer can name, to 49 days at 2%; an offer or a lease made before keeps its own fee.
- **A paid lease costs at least 5 USDG** in all at the offer's shortest term (`MIN_RENT`).
- **A free lease**: a daily rate of 0 is allowed for one named address. No USDG moves and no fee is taken.
- **What the contract holds**: `(term - paidDays) x dayPrice` of each lease, plus what waits in `owed`. Nothing else,
  and never an agent.

## A sale, an accepted bid, a transfer

A sale does not end a lease. The lease goes on to its date, and the rent follows the agent. What the contract can see
of a change of hands is the market's last sale (`lastSoldAt`, on AgentMarketV2 and v1) and the owner now; the registry
shows no transfer at all. So each payout splits the days at the market's last sale since the last payout: the holder
at the last payout gets the days that ended by it, the owner now the rest. That split is exact for one market sale
since the last payout, and only then:

- **One sale on the market since the last payout** (a `buy` or an `acceptBid`): the days that ended by the sale
  (rounded down to whole days) go to the seller, and every later day, the one under way at the sale included, to the
  buyer.
- **A plain transfer with no sale since the last payout**: no time the contract can read, so every unpaid day goes to
  the receiver, the sender's days included.
- **Two changes of hands since the last payout**: the middle holder is paid nothing. Its days go to the holder at the
  last payout when the later change is a market sale, and to the owner now when it is a plain transfer.

**The client rule.** A claim records who holds the agent as well as paying the days ended, so the split is exact when
every change of hands is bracketed by claims: a client that changes hands of an agent with a stored lease claims before
and after the change, in the same operation (`[claim, ..., buy or acceptBid or transfer, claim]`). `claim` on an agent
with nothing stored returns 0 and logs nothing, so the claim after a change never reverts. `@priors/mcp`'s market tools
do this once the package carries the lease's record.

- The standing offer is void once the agent changes hands or sells (`OfferGone`), and anyone can cancel it.
- The new owner can end the lease early, at no cost to it, and can't be asked for more days: `extend` refuses once the
  agent changed hands (`ChangedHands`). Listing a rented agent is allowed.
- `rent` and `extend` are refused while any listing of the agent stands on either market, not yet expired, whoever
  listed it (`Listed`), so a buyer in flight never meets a new or a longer lease. A listing whose seller no longer holds
  the agent anyone may cancel on that market first.

## Add days

`extend(id, days, maxTotal, recordHash, uriHash)` adds days to a running lease in place: the renter only
(`NotRenter`), while the lease runs (`NoLease` once it is over), at the lease's own daily rate, paid into the contract
now, within `maxTotal`, with no fee then (the added days carry their share when they are paid out). Up to the rented
offer's longest term from the start (`BadDays` past it), and only while the owner that rented it out still holds the
agent and it has not sold since the rent (`ChangedHands`). `Extended(agentId, owner, renter, until, total)` logs the new
end.

## The rules at `rent`

1. The offer stands, has not expired, its owner still holds the agent, and the agent has not sold since the offer.
2. No lease runs on the agent.
3. The renter is the one named (if any), and is not the owner, the agent's registry wallet, or anyone who can borrow for
   it.
4. Neither the owner nor the renter is a pool custodian, refused on the market, or marked by the pool.
5. The agent is not a root and not defaulted, on pool v2 or v1.
6. The record and the file are the ones the renter read (`recordHash`, `uriHash`).
7. No listing of the agent stands on either market, not yet expired, whoever listed it.
8. The days are in the offer's range, and the total is within the renter's `maxTotal`.

## Defaults, frozen addresses, pause

- **A default.** An agent that defaulted on pool v2 or v1 and still has an owner is broken: anyone ends its lease, with
  `claim(id)` or `endLease(id, minRefund)`, before its date or after it. Every day that ended goes to its holders, and
  the day under way and the days not begun go back to the renter, whoever ends.
- **No owner.** An agent that was burnt, or sent to the lease contract itself, counts as burnt: the holder at the last
  payout gets the days that ended by a market sale since, and every other day not paid goes back to the renter.
  `userOf` names nobody.
- **The registry.** Only the registry's own word that the agent is gone (`ERC721NonexistentToken(id)`) counts as a
  burn. Any other failure to read the owner reverts `RegistryFailed(id)`, so an outage never moves an owner's rent to a
  renter.
- **A frozen address.** A payout USDG refuses (a frozen holder, renter or `feeTo`) never stops a claim or an end. It
  waits in `owed(account)` until anyone calls `withdraw(account)`, which pays that account only.
- **Pause.** The guardian (the Safe, GuardianPause, at most 14 days) can pause `offerRent`, `rent` and `extend`.
  `cancelOffer`, `claim`, `endLease` and `withdraw` are never paused, so money can always come back. The contract has
  no setting, no admin and no upgrade: the fee, `feeTo` and the refused list are the market's. It has no ETH path.

## Calls and views

| Call | Who | Paused |
|---|---|---|
| `offerRent(id, dayPrice, minDays, maxDays, renter, expiry)` | the agent's owner | yes |
| `cancelOffer(id)` | the offer's owner, or anyone once it can't be taken | never |
| `rent(id, days_, maxTotal, recordHash, uriHash)` | the renter, after `approve(lease, total)` | yes |
| `extend(id, days_, maxTotal, recordHash, uriHash)` | the lease's renter, after `approve(lease, total)` | yes |
| `claim(id)` | anyone; 0 with nothing stored; ends a broken agent's lease | never |
| `endLease(id, minRefund)` | the renter or the owner now while it runs; anyone once the agent is broken | never |
| `withdraw(account)` | anyone, for an account with `owed`; pays that account only | never |

Views: `userOf(id)` and `userExpires(id)` (EIP-4907's names and meaning: the renter and the end while the lease runs and
the agent has an owner, else zero); `leaseOf(id)` (renter, start, term, paidDays, maxDays, holder, dayPrice, owner,
settledAt, feeBps, minFee); `offerOf(id)`; `quote(id, days)` (the total and the fee the whole term carries);
`claimable(id)` (what a claim pays now, net of the fee); `refundsOf(id)` (`byRenter` and `byOwner`, what the renter's
own end and the owner's end send back now); `owed(account)`; `paused()`. The contract does not claim ERC-4907 in
`supportsInterface` and logs no `UpdateUser`: it is not the NFT.

```
event RentOffered(uint256 indexed agentId, address indexed owner, address indexed renter, uint256 dayPrice, uint8 minDays, uint8 maxDays, uint64 expiry)
event RentOfferCancelled(uint256 indexed agentId, address indexed by)
event Rented(uint256 indexed agentId, address indexed owner, address indexed renter, uint64 start, uint64 until, uint256 total, uint256 fee)
event Extended(uint256 indexed agentId, address indexed owner, address indexed renter, uint64 until, uint256 total)
event RentPaid(uint256 indexed agentId, address indexed to, uint256 amount)
event FeeTaken(uint256 indexed agentId, address indexed to, uint256 amount)
event LeaseEnded(uint256 indexed agentId, address indexed renter, address indexed by, uint256 refund)
event RentHeld(address indexed to, uint256 amount)
event Withdrawn(address indexed to, uint256 amount)
```

Errors: the lease's own (`NoOffer`, `OfferExpired`, `OfferGone`, `Leased`, `NotForYou`, `SelfRent`, `RenterIsWallet`,
`RenterControls`, `Listed`, `BadDays`, `DayBelowFee`, `NoLease`, `CannotEnd`, `NothingOwed`, `PayOutOfGas`,
`NotRenter`, `ChangedHands`, `RefundBelow`, `RegistryFailed`), the market's signatures for the same checks (`NotOwner`,
`Custodian`, `Refused`, `Marked`, `IsRoot`, `AgentDefaulted`, `RecordChanged`, `UriChanged`, `PriceTooLow`,
`PriceAbove`, `BadExpiry`, `CannotCancel`), and GuardianPause's `IsPaused`. The interface is
`src/interfaces/IAgentLease.sol`; the market's views it reads, `src/interfaces/IAgentMarket.sol`.

## The deployment

AgentLease was deployed through the CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with the salt
`keccak256("priors.AgentLease")`, so its address is fixed by its creation code and its seven constructor arguments:
the ERC-8004 registry, USDG, pool v2, pool v1, AgentMarketV2, AgentMarket v1 (the market's `previous`) and the Safe as
guardian. Transaction `0x30e3720f45094c01e9891e170dbe6c68187a7f8769990f193d8261dcd1191dc2`, block 103,660,343,
2026-11-01. `deployments/4663.agent-lease.json` holds the address, the block to read its logs from (`agentLeaseBlock`),
the arguments, the compiler settings (solc 0.8.26, optimizer 200 runs, cancun) and the code hashes. `src/AgentLease.sol`
here is byte-identical to the source verified on chain: `forge build src/AgentLease.sol` gives the deployed bytecode.
