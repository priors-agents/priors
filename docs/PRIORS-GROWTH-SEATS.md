# Growth seats: $50 lines with $PRIORS at stake

Live since 2026-09-29 on Robinhood Chain (chain 4663): **SeatVaultV4** `0xb1c3a04496238D62E3c93118C297163855e22192`
(root `#6466`), owned by its own **SeatSizer** `0x97C4e594D458f8BBE961d5384Bbd8a9Cc2D18777`, which the 2-of-3 Safe owns.
Addresses are in [`deployments/4663.v2.json`](../deployments/4663.v2.json); findings and fixes are in
[`SECURITY-v2.md`](SECURITY-v2.md#seatvaultv4-growth-seats-and-its-seatsizer).

## How a growth seat works

- A staker offers a seat of $PRIORS behind an agent with 10 or more repaid loans, and the agent's owner accepts it. The
  vault then backs a $50 line for the agent with its funder's USDG, 100%, so a default never reaches lenders.
- The staker earns the sponsor share of the agent's fees (25%) while the seat is open. In practice the staker is often
  the agent's owner: the seat is collateral the owner posts behind its own line.
- Loans on a growth seat last at most 7 days (`maxLoanTerm`), and `canBorrow` checks the seat against the vault's
  current terms on every loan, so a seat smaller than the current size cannot borrow again.
- On a default, `burnBps` of the seat (50%) is slashed and the rest goes back to the staker in the same transaction.
- A seat is about five lines of $PRIORS. The SeatSizer sets the size from a day-long median of keeper observations of
  the $PRIORS pool: it raises at once, cuts at most by half a day, and stays within [110,000, 20,000,000] $PRIORS.
- At most 20 seats are open and at most $1,000 of new lines open per 7 days. A seat idle for 30 days can be closed by
  anyone, every token back to its staker.

SeatVaultV3 (`0x59D155C42A9263fA7596867b992bB3e84dF680a9`, $5 lines) is unchanged: its open seats run until they close.

## Seat vault V4

`SeatVaultV4` is `SeatVaultV3` plus three things; with `keepBps` 0 and `maxLoanTerm` 0 it behaves as V3 (its test suite
is V3's, ported).

- **The slash split.** `keepBps` of a slash stays in the vault as protocol stake and only the rest burns. Nobody (not
  the owner, not the funder) can withdraw, transfer or sell protocol stake.
- **Protocol seats.** Protocol stake can back seats for agents the owner marks eligible, and only while the owner the
  Safe vetted still holds the agent. They have their own weekly budget (`protocolEpochCap`), their fees go to
  `protocolFeesTo`, which must be named before any can open, and a protocol seat's own default burns its whole slash.
  Revoking eligibility, or closing protocol seats, stops loans on the ones already open.
- **The loan-term cap** (`maxLoanTerm`), 7 days at launch.

At launch the split and protocol seats are off: `keepBps` 0 (a default burns the whole slash, as on V3),
`protocolEpochCap` 0 and no `protocolFeesTo`.

## Risks

- **The funder carries the credit risk.** Open loans keep their terms, so if $PRIORS falls far below the level the seats
  were sized at, defaulting can pay for every agent with a loan open: the loss can reach every line still out, which
  can be more than 20 × $50 when one week's lines default beside the next week's, and never more than the vault's
  stake (about 1,116 USDG on 2026-10-09; X-5).
  Short loans, the record gate, the per-loan re-check and the keeper's price guard (an alert to the Safe, which can
  pause new seats) limit it; lenders are never reached.
- **A farmed record.** The on-chain record counts small self-backed loans, so the gate alone is weak; the seat, about
  five lines of $PRIORS slashed on a default, is what makes a farmed identity unprofitable outside a crash.
- **A pumped price.** The size follows a day-long median of keeper observations, within fixed bounds, not the spot price.
