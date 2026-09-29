# v2 security notes: what was found, what was fixed, what remains

This page covers the v2 set live on Robinhood Chain since block 71,702,460: `CreditPoolV2` (+ `PoolV2Lib`,
`CreditLensV2`), `TreasurySponsorV4`, `SeatVaultV3` (which replaced `SeatVaultV2` on 2026-09-25), the
`SeatSizer` that owns it since 2026-09-26, `InviteBond`, the `StockVault` since 2026-09-28 (the one upgradeable
Priors contract), and the growth seat vault `SeatVaultV4` with its own `SeatSizer` (live since 2026-09-29), plus the SDK's x402 float client and the `@priors/x402` and `@priors/mcp` packages. It lists every known
finding, so a rediscovery is not mistaken for a new one, and so you can check each ruling against a test.

**How these were found.** Several internal adversarial reviews before launch (three per-contract hunts, Slither,
invariant campaigns at twice the committed runs, a migration rehearsal on a fork of live chain state), an
independent second-model review of the final fixes, and a second-opinion review after launch (2026-09-25; rows
SO-1, SO-2 and AI-1, whose proofs of concept are internal; V-2's are public as V3 regression tests). **No third-party audit firm has reviewed v2.** Treat it
accordingly; [BOUNTY.md](../BOUNTY.md) says what a new finding is worth.

**The headline.** No path was found that reaches lender principal. Every loss found is bounded by a backer's own
stake, a staker's own seat, a per-epoch cap, or (for the yield-only residuals F-2, SO-1 and SO-2) a small share of
lender fees. That is a property of the design (every line is 100% backed, and a
default burns the backer's shares), not of a parameter.

Severity labels below are the reviewers'. "Fixed" means fixed in the deployed bytecode unless it says otherwise.

## CreditPoolV2

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| N-1 | High | **Self-backing loop took lender yield.** A root and its own agent could loop stake → vouch → borrow → restake. A default charged the principal only, never the fee, so the looped shares earned lender yield all term at no cost: about 88% of lenders' yield in the PoC. | **Fixed before launch for the self-loop (fee lock).** A loan's fee is locked out of the backer's free backing at `borrow` (`feeLocked`; `InsufficientBacking` if it does not fit), released at `repay`, and a default burns the backer's shares worth principal **plus** fee. The self-loop on its own now loses money. **A residual path around it remains: SO-1** (stake held only while marking a default), with the bound stated there. | `test/audit-final/FeeLockFix.t.sol`, `FinalAuditPool.t.sol` (`test_N1_…_fixed`) |
| N-2 | Medium | **Utilization-cap freeze.** The same loop filled to a 90% cap made every honest `borrow` revert `UtilizationTooHigh` for 33 days, restartable. | **Fixed by parameter:** `maxUtilizationBps` = 10000. Every loan is fully backed, so a lower cap protects nobody. With the fee lock, a freeze at a lower cap would also cost the attacker the fees. | `FinalAuditPool.t.sol` (`test_N2_fullUtilizationCap_freezeIsImpossible`) |
| F-1 | Medium | **Keeper bounty farmable.** `markDefault` pays `keeperBounty` from the reserve while the backer is charged only its own loans, so a root defaulting its own throwaway agents nets a bounty each time. | **Mitigated by `keeperBounty` = 0.** The permanent fix (charge the bounty to the defaulting backer) is not in this bytecode. Raising the bounty would need a 48 h timelock operation, visible on chain. | `test/review-v2/F1KeeperBountyMitigation.t.sol` (RED at the cap, GREEN at 0) |
| X4 | Low | **Nobody is paid to mark defaults** (a consequence of F-1's mitigation), and a loan repaid long after grace costs nothing extra. An unmarked default dilutes lenders until marked. | **Residual.** The protocol runs a keeper that marks loans past `defaultableAt` on a schedule (every 2 hours); `markDefault` stays permissionless, so anyone can. | `test/audit-v2/PoolV2Exploits.t.sol` (`test_X4_…`, `test_X4b_…`) |
| F-2 | Low | A root can stake just before a repayment and `unlock` right after, keeping lender fee share without the 0.5% early-exit fee (that fee applies to `withdraw` only). | **Residual, accepted.** Bounded by one repayment's lender share. The same stake-and-unlock move around `markDefault` has a larger bound, stated separately as SO-1 and SO-2. | `test_F2_rootJITSkipsTheExitFee` |
| SO-1 | Medium | **Stake held only while marking a default.** Root stake has no exit fee or hold, and `markDefault` is permissionless. A root that stakes a large amount, marks defaults and unlocks in one transaction takes most of each default's unpaid fee, which the fee lock sends to all remaining shares. Used around the N-1 loop it makes that loop profitable again. Yield only, never principal: under 1 USDG per 33-day cycle at launch size, linear in the pool's size. | **Residual, accepted until the next pool.** The protocol keeper marks defaults on a schedule (every 2 hours), and a stake → mark → unlock in one transaction is monitored; neither prevents it. The fix (a hold or exit fee on fresh root shares, or routing the unpaid fee out of reach) needs a migration. | internal PoC (`test_P2_…`) |
| SO-2 | Low | The same move around an honest loan past grace takes that loan's fee: at most 5 USDG at the maximum loan for 30 days, 15 USDG with the premium cap. | **Residual**, as SO-1. | internal PoC (`test_P1_…`) |
| X1 | Low | An owner with no delay could move the reserve and set the bounty in one block. | **Closed by deployment:** the owner is a 48 h `TimelockController` (Safe proposes and executes, no admin). A compromised owner reaches only the reserve, never lenders or backers. | `test_X1_…`, `test_R_compromisedOwnerReachesOnlyTheReserve` |
| F-6 | Low | `importFromV1` is permissionless and once-only; an early import while v1 was live would freeze a record v1 still changed. | **Closed by order:** v1 was paused before v2 existed. | `test_R_runbookOrderFreezesV1BeforeAnyImport` |
| N-3 | Info | `setHook` accepts any contract, so a root can point its hook at another backer's hook contract. | **Closed where it matters:** the seat vault's hooks require `rootId ==` its own root, and treasury v4 has no hook. A future hook must check `rootId`, not only `msg.sender == pool`. | `test/review-v2/ReviewSeatVaultV2.t.sol` |
| X3 | Info | A signed consent cannot be revoked before its deadline. | **Residual.** The SDK signs consents with a 1-hour deadline by default. | `test_X3_signedConsentCannotBeRevoked` |
| X2 | Info | A dust `addStake` from a stranger blocks `retireRoot`. | **Residual.** `unlock` still takes free backing out. | `test_X2_dustAddStakeBlocksRetireRoot` |
| F-5 | Info | `freeze(true)` on an empty line ends the sponsorship without a `Released` event. | Residual, no current backer reaches it. | review suite |
| X5 | Info (trust) | The ERC-8004 registry and USDG are upgradeable proxies administered by third parties. A registry admin could rewrite who owns which root. | **Trust assumption**, as in v1 (see SECURITY.md). Lenders stay whole even then. | `test_X5_registryUpgradeAdminTakesEveryRootStake` |

Checked and refuted, with tests in `test/audit-v2/PoolV2Exploits.t.sol` and `test/audit-final/`: share inflation
and `seed` front-running, reserve drain through slash rounding, fee misrouting, borrowing without backing, repay
griefing, consent replay (nonce, deadline, chain id, malleability, cross-pool, sale), hook re-entrancy / gas /
return bombs, guardian pause trapping funds (exits never pause), lender exit DoS at maximum draw, the linked
library, and a self-loop reaching lender principal.

## TreasurySponsorV4

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| T10 | Medium | **invite → cheap record → `raise` → default.** One invite plus three cheap qualified loans reaches the second line (now $25), which can then be defaulted: about one second line of treasury stake per invite. | **Bounded by `epochCap`**: $25 of new treasury exposure per 7-day epoch, first lines and raises combined, with the second line also at $25 (both lowered from the launch values of $100 and $50 by the Safe, tx [`0x940d9dd8…08cb9`](https://robinhoodchain.blockscout.com/tx/0x940d9dd831c5633be457e8891d50acb2293c918c725026fcf709ffee7d708cb9)). Every attempt needs a fresh invite; where invites are cheap (AI-1) the epoch cap is the bound. Lenders are untouched; the loss is treasury stake. | `test/audit-v2/TreasuryV4Exploits.t.sol` (`test_T10_exploit_farmRaiseThenDefault`) |
| N-4 | Low | T10 variant: an imported v1 record with 3 qualified loans passes `raise` in the same block as `firstLine`. | Same bound as T10. | `test/audit-final/FinalAuditTreasury.t.sol` |
| AI-1 | Medium | **Self-service invites.** The Telegram invite bot signs a treasury invite for any owner who proves control of an agent, up to 10 a day. Agents and wallets are free, so without a price one person could take the week's first lines. | **Priced since 2026-09-25:** self-service is on, and every automatic invite needs a 5 USDG bond from the agent's owner in `InviteBond` ([`0x8BE4…3275`](https://robinhoodchain.blockscout.com/address/0x8BE478c754D9124D11e78dB20F5bf4dA45403275)), the size of the first line. The bond comes back after 3 qualified repayments counted since it was posted, with none open, or 4 days after it was posted if the agent never got a line; it goes to the Safe on default, so taking a first line and walking away nets nothing. `InviteBond` does not see the invite, so the bot enforces the order (IB-1): it signs only while the bond cannot come back before the invite expires — no repayment counted on the bond yet, no loan open, the invite expiring at least an hour before the 4-day refund opens, and an invite shorter than a qualified loan's 7 days. **Residual:** after redeeming, 3 qualified loans release the bond, and the line can then be defaulted: 21+ days on the $5 line alone (one loan at a time), or about 7 days if the agent also borrows from a second backer's line at the same time. One first line per fresh owner and agent, bounded by `epochCap` ($25 per 7-day epoch), paid from treasury stake; lenders are untouched. | `test/InviteBond.t.sol` (`test_farm_repayOnceThenDefault_netsNothing`); internal review of the bot, 2026-09-25 |
| IB-1 | High (bounty rubric) | **Bond released before the invite is redeemed.** The no-line refund counts from the deposit and qualified loans under any backer count, so an owner could ask for an invite on day 3.5 and take the bond back on day 4 (or after 7 days of overlapping loans from their own root) and then redeem the invite unbonded. Found by the public-repo audit, 2026-09-25. | **Fixed in the bot on 2026-09-25** (the signing rules in AI-1). A contract-level fix (redeeming through the bond, counting only the treasury's own loans) needs treasury v5. Loss bound while it was open: `epochCap`; no automatic invite had been redeemed on v4. | internal PoC; the bot's rules are tested in its own suite |
| T8 | Low | An invite names an agent id, not its owner, so a later NFT holder can redeem it. | **Residual.** Invites expire, and each seats an agent once; `firstLine` also needs the current owner's pool consent. | `test_T08_exploit_nftBuyerRedeemsSomeoneElsesInvite` |
| T5 | Low | If the creator-fee escrow's claim ever failed, `sweep` would revert and USDG would wait. | **Residual.** The Pons escrow is immutable code that pays and makes no callback. | `test_T06_exploit_escrowClaimFailureStrandsTreasuryUsdg` |
| T18 | Low (ops) | Invite signers signed for treasury v3's EIP-712 domain, so every v4 invite would fail (safely). | **Fixed** in the invite tooling before launch. Invites are for domain `Priors Treasury` version `4`. | – |

Refuted: draining the treasury's USDG, misrouting sponsor fees, `sweep` re-entrancy, invite replay across
contracts, chains or versions, invite malleability, strangers burning the first-line cap, `reclaim`/`retire`
abuse, `rescue` reaching the asset or the stake.

## SeatVaultV2 → SeatVaultV3

Since 2026-09-25 the live seat vault is **SeatVaultV3** (`0x59D155C42A9263fA7596867b992bB3e84dF680a9`), SeatVaultV2 with the V-2 fixes below and nothing else; the rows below apply to V3 unless they say otherwise. SeatVaultV2 is empty and paused.

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| X-3 | High at placeholder numbers | **Self-seat loop.** Seat a fresh identity with your own $PRIORS, borrow the $5 line, default: half the seat is burnt, the line is kept. | **Gate + economics.** Seating requires `minRepaid` = 3 repaid loans. That gate is farmable (three minimum loans cost about half a cent in fees), so it is a filter, not the fix. **What closes it is the seat's value:** a seat is sized at about 5 lines of $PRIORS at the V4 pool price (12,000 $PRIORS, about $26, on 2026-09-25; it was a 1,000,000 placeholder from before $PRIORS had a price) and a default burns 50% of it, about 2.5 lines: the loop only pays once the price falls by more than about 60% with no resize. Since 2026-09-26 the seat vault is owned by the **SeatSizer** (section below), which resizes the seat on its own from the median of the last day's price observations, when it drifts under 80% or over twice its target: it raises straight to the target, cuts at most by half once a day, never under 10,000 $PRIORS, and pauses seats if its ceiling would leave the burn under 1.5 lines. The keeper also alerts the admin when the burn falls under 1.5 lines. The alert threshold was 20 lines (second-opinion audit V-L1), which at a $5 line meant a seat nobody would stake; it is lower now because losses stay capped at the vault's `epochCap` ($50 per 7-day epoch), paid from the vault's own stake, and lenders are untouched. Since SeatVaultV3 these levers also reach seats already open: `canBorrow` refuses new loans while paused or on a seat below the current terms (V-2, fixed). | `test/audit-v2/SeatVaultV2X3Mitigation.t.sol`, `SeatVaultV2Fixes.t.sol` |
| X-1 | Medium | A stale offer could be taken by the next NFT holder after a sale, who borrowed and defaulted against someone else's seat. | **Fixed:** an offer is bound to the agent's owner at offer time and re-checked at accept. | `test/audit-v2/SeatVaultV2Fixes.t.sol` |
| X-2 | Medium | Idle seats never expired, so self-seats could fill every slot and tie up the vault's backing. | **Fixed:** `expire(id)` is permissionless after `idleAfter` = 30 days with no loan open. The idle clock counts from the latest of seat opening, last borrow and **last repay**, so a long loan repaid today is not idle. | `SeatVaultV2Fixes.t.sol` (`test_fix_X2_aSeatIsNotIdleRightAfterALongLoanIsRepaid`) |
| V-2 | Low | **Levers and ownership did not reach open seats** (SeatVaultV2): `pauseSeats` and a new `seatSize` applied only to seats opened afterwards; an agent sold to a new owner kept its seat; an active seat could not be evicted, so seat capacity could be squatted. | **Fixed in SeatVaultV3.** `canBorrow` refuses new loans while seats are paused, or on a seat below the current size, burn or line; a seat is bound to the owner who accepted it, so a sale stops lending and anyone may close it (every token back to the staker); the Safe's `freezeSeat` closes any seat, every token back, never a burn. Loans already open are untouched. | `test/SeatVaultV3V2Fixes.t.sol` (the three proofs of concept replayed, each failing on V3); the V2 suites ported to V3 (`test/SeatVaultV3*.t.sol`) |
| X-4 | Low | A v1 default plus a failed hook could lock a seat forever. | **Closed by order:** v1 was paused before seats opened. | `test/SeatVaultV2V1DefaultOrder.t.sol` |
| V-3 | Info | SeatVaultV3 inherits OpenZeppelin's `renounceOwnership`. Called, it would remove the owner's levers for good: `pauseSeats`, `freezeSeat` and new parameters. | **Accepted, not redeployed.** The owner is the 2-of-3 Safe, so renouncing takes two signers doing it on purpose; stakers lose nothing if it happens (closing, settling, expiring and claiming never need the owner). SeatVaultV4 does not override it either; a SeatSizer owns each vault and refuses the call (SZ-6). | `src/SeatVaultV3.sol` (`Ownable2Step`, no override) |

Refuted: stealing or double-exiting a staker's $PRIORS, double-claiming fees across re-seats, a stranger burning a
live seat, offer squatting and consent redirection, EIP-1271 abuse of `registerAndSeat`, re-entrancy through pool
hooks, an owner moving stakers' tokens or fees.

## SeatSizer

Since 2026-09-26 the seat vault's owner is **SeatSizer** (`0xd24B6484f4E68d72Fd2d3AF7bD036560B2ed5E61`, `src/SeatSizer.sol`), and the Safe owns the SeatSizer. It keeps the seat worth about 5 lines of $PRIORS without a Safe signature each time: the keeper records the pool's price (read from the Uniswap V4 PoolManager's storage) at most every 29 minutes, and `resize` sizes the seat from the median of the last 24 hours (at least 24 observations). A raise goes to the target at once; a cut at most halves the seat, once a day; the seat stays within [10,000, 2,000,000] $PRIORS; if the ceiling leaves the burn under 1.5 lines, seats are paused. It can change nothing but `seatSize` (and that pause). The Safe calls every other vault power through `execute` (pause, freeze, gates, params, retire, rescue) and can take the vault back at any time; nobody can renounce ownership, of the SeatSizer or, through it, of the vault.

Reviewed before deployment by an internal review and an adversarial pass; **no third-party audit**. Tests: `test/SeatSizer.t.sol`, `test/audit-sizer/SeatSizerAudit.t.sol`, and `test/SeatSizerFork.t.sol` against live chain state (`FORK_RPC=…`).

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| SZ-1 | Medium | Once the seat sat at the ceiling, a further $PRIORS collapse never paused seats: `resize` reverted `Unchanged` before its pause check. | **Fixed before deployment:** the pause is checked even when the size cannot move, and re-applied if the Safe unpauses while the price is still collapsed. | `test_M1_atCeiling_aFurtherCollapsePauses`, `test_M1_afterSafeUnpause_theKeeperRepausesWhileStillCollapsed` |
| SZ-2 | Low | A seat the Safe set above the ceiling could be cut more than half in one step, and not counted as the day's cut. | **Fixed before deployment:** the cut is decided after the bounds and always at most halves. | `test_L1_seatAboveCeiling_aClampedRaiseIsAHalvingCut`, `test_L1_seatAboveCeiling_theCutBranchHalvesAtMost` |
| SZ-3 | Medium | A draft sized from a window that could be days old after a keeper outage, and capped raises at 2x a day, so seats lagged a crash. | **Fixed before deployment:** only the last 24 h count; raises go to the target at once. | `test_resize_onlyTheLastDayCounts_aStaleWindowCannotResize`, `test_resize_raisesAtOnce_anyTime` |
| SZ-4 | Low–Medium | **A pump held for about half a day moves the median.** The keeper blocks same-transaction sandwiches (a public poke in this fee-less pool would be free to manipulate), but anyone who holds a pumped price across ~25 keeper passes gets it recorded. | **Residual, bounded.** A cut is at most half, once a day, and never under 10,000 $PRIORS; at the 2026-09-26 price a 10,000 seat still burns about 2 lines, so the loop stays unprofitable, and losses remain capped by `epochCap`. The reverse (a held dump) only raises seats or pauses them, which stops credit and moves no funds. | design |
| SZ-5 | Low | A stolen keeper key can record false prices every pass. | **Residual, bounded** by the same limits as SZ-4; it can never move funds or reach an owner function, and the Safe replaces the keeper with one call. | `test_theKeeperHasNoOtherPower`, `test_keeperCannotReachOwnerPaths` |
| SZ-6 | Info | `renounceOwnership` (on the SeatSizer, or on the vault through `execute`) would strand the vault for good. | **Fixed before deployment:** both revert `NoRenounce`. | `test_renounceIsRefused_onTheSizerAndOnTheVault` |
| SZ-7 | Info | With a burn share under 30% (the vault allows 25%), a seat at the 5-line target burns under 1.5 lines, so every resize would pause seats. | **Accepted:** the live burn share is 50%; lowering it means raising `LINES` in a new SeatSizer first. | `test_poc_burnUnder30pct_everyResizeOnTargetPauses` |

`src/SeatSizer.sol` now carries the comments the growth seat vault's SeatSizer (next section) was built from: they note
that the pause check measures the slash (`burnBps`), of which a SeatVaultV4 with `keepBps` set burns only part, and
that the Pons hook takes about 3% of each swap. The code is unchanged: the live pair's SeatSizer (`0xd24B…5E61`) was
built from the previous comment text, so its executable code is the same and only its metadata differs.

## SeatVaultV4 (growth seats) and its SeatSizer

Deployed on 2026-09-29 (block 75,614,831), **live since block 75,648,704**: **SeatVaultV4**
(`0xb1c3a04496238D62E3c93118C297163855e22192`, `src/SeatVaultV4.sol`, root `#6466`), funded by the Safe with 1,087.06
USDG of backing (block 75,648,677) before its seats were opened. It is owned by a SeatSizer of its own
(`0x97C4e594D458f8BBE961d5384Bbd8a9Cc2D18777`, block 75,614,955, the same `src/SeatSizer.sol`, bounds
[110,000, 20,000,000] $PRIORS), which the Safe owns, as for the V3 pair. The deployed runtime bytecode of both matches
`forge build` of this repository's source (immutables masked); explorer verification is pending. SeatVaultV3 is
unchanged: its open seats run until they close, and new seats go to V4.

The settings at deployment: a seat of 120,000 $PRIORS (the sizer's target, about 5 lines), a $50 line, `burnBps`
5000 with `keepBps` 0 (a default burns half the seat, all of it, as on V3), at most 20 open seats, $1,000 of new lines
per 7-day epoch, 10 repaid loans before seating, seats idle after 30 days, loans of at most 7 days (`maxLoanTerm`),
protocol seats closed (`protocolEpochCap` 0 and no `protocolFeesTo`), fees owed to no staker to the Safe.

**What V4 adds to SeatVaultV3, and nothing else** (its contract notes list the same): the slash split (`keepBps` of a
staker's slash stays in the vault as protocol stake, which nobody can withdraw, and only the rest burns); protocol
seats backed by that stake, for agents the owner marks eligible, with their own weekly budget (`protocolEpochCap`) and
their fees to `protocolFeesTo`; `maxLoanTerm`; and both weekly budgets rolling in one place. With `keepBps` 0 and
`maxLoanTerm` 0 it behaves as V3, except that a new `epochLength` starts a new epoch (R2-3). It launched with
`keepBps` 0 and protocol seats closed: the split and protocol seats are off.

Reviewed twice before deployment, internally: an adversarial review with proofs of concept (`test/audit-v4/`), then a
second review of its fixes the same day (round 2). **No third-party audit.** Tests: `test/SeatVaultV4.t.sol` (the V3
suite ported to V4 at `keepBps` 0: V4 at 0 is V3), `test/SeatVaultV4Split.t.sol` (what V4 adds, and the round-2
regressions), `test/audit-v4/`, and the V3 audit suite, invariants and v1 default order ported to V4
(`test/audit-r2/R2Port_SeatVaultV4*.t.sol`). The round-2 review's own proofs of concept are internal; the regressions
cited below are public.

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| H-1 | High | **Protocol seats could be farmed.** A fresh identity fakes the record gate on a throwaway root for cents of fees, takes a protocol seat, draws the line and defaults: the funder pays the line and nothing of the attacker's is at risk. With the whole slash kept, the protocol stake refilled after every such default. | **Fixed before deployment:** a protocol seat needs the owner's eligibility (`setProtocolEligible`); protocol lines have their own weekly budget (`protocolEpochCap`, 0 until set); a protocol seat's own slash burns in full, so protocol defaults shrink the stake and never refill it. | `test/audit-v4/ProtocolSeatFarm.t.sol` (`test_farmedIdentity_cannotTakeAProtocolSeat`, `test_protocolSeatDefault_burnsItsWholeSlash_theStakeShrinks`, `test_protocolEpochCap_boundsProtocolLines`) |
| L-1 | Low | Closing protocol seats did not stop loans on protocol seats already open. | **Fixed before deployment:** `canBorrow` refuses a protocol seat's loan while protocol seats are closed. | `test_closingProtocolSeats_stopsBorrowsOnOpenOnes` |
| L-2 | Low | A protocol seat costs its taker nothing, so any gated agent could hold slots and backing. | **Fixed before deployment** by H-1's eligibility, completed in round 2 (R2-2): revoking eligibility, or `freezeSeat`, now removes an eligible agent on its own. | as H-1 and R2-2 |
| I-1 | Info | Protocol fees defaulted to the fee sink, not the funder, and did not follow `setFeeSink`. | **Fixed before deployment:** no recipient until the owner names one; until then protocol seats cannot open and protocol fees cannot be claimed. | `test_protocolFeesTo_unsetUntilNamed_andSeatsWaitForIt` |
| I-2 | Info | `keepBps` is read when a seat settles, not fixed when it opens (the staker's loss is unaffected); a protocol seat emits `Offered` with the vault as staker; a SeatSizer cut doubles how many protocol seats a stake backs. | **Documented;** eligibility and the protocol budget bound the last point. | – |
| R2-1 | Low | **Eligibility travelled with the agent id.** It was stored per id, not per vetted owner, so a new holder the Safe never vetted could take a protocol seat, draw and default, and an operator could shed the pool's owner-default mark the same way. | **Fixed before deployment:** `setProtocolEligible(ids, owners, eligible)` binds each agent to the owner the Safe vetted and reverts `OwnerChanged` unless that owner still holds it when the Safe's transaction runs; `seatFromProtocol` reverts `NotEligible` unless the agent's owner is still that owner. A pool delegate acts for the vetted owner, and a default is recorded against that owner. | `test_R2_1_eligibilityBindsTheOwnerWhenMarked`, `test_R2_1_marking_revertsIfTheVettedOwnerNoLongerHoldsIt`, `test_R2_1_transferredEligibleId_cannotTakeAProtocolSeat` |
| R2-2 | Low | **Neither owner lever alone removed an eligible agent.** `freezeSeat` closed its protocol seat and it re-seated in the next transaction; revoking eligibility left the open protocol seat able to borrow. | **Fixed before deployment:** `canBorrow` refuses a protocol seat whose agent is no longer eligible, or is held by anyone but the vetted owner; `freezeSeat` on a protocol seat also revokes the agent's eligibility while it is still bound to the owner who took the seat. | `test_R2_2_revokedEligibility_stopsLoansOnTheOpenProtocolSeat`, `test_R2_2_freezeSeat_protocolSeat_revokesEligibility`, `test_R2_2_freezeSeat_oldProtocolSeat_keepsTheNewHoldersEligibility`, `test_R2_2_freezeSeat_ordinarySeat_keepsEligibility` |
| R2-3 | Info | The two weekly budgets rolled in two places: shortening `epochLength` in the same second a protocol seat opened could leave the protocol budget carrying the old epoch while the vault's restarted (one extra line of room). | **Fixed before deployment:** one roll starts the next epoch with both counters at zero; a new `epochLength` starts a new epoch now, carrying what the current one spent; a clean close refunds only the epoch still running; new view `protocolEpochRoom()`. This is the one place V4 at its defaults differs from V3. | `test_R2_3_bothBudgetsRollTogether_andProtocolEpochRoom`, `test_R2_3_newEpochLength_startsAnEpochCarryingTheSpend`, `test_seatSizer_drivesV4` |
| R2 #8 | Low | **`canBorrow` ignored the loan term.** Once the seat's $PRIORS loses enough value while a loan is open, walking away pays better than repaying, and a longer term leaves more time for that fall. | **Fixed before deployment:** `maxLoanTerm` (`setMaxLoanTerm`, 1 to 365 days, or 0 for no cap beyond the pool's) refuses longer loans on every seat of the vault; **set to 7 days at deployment**. Loans already open keep their terms. | `test_maxLoanTerm_refusesLongerTerms_allowsShorter`, `test_ownerLevers_boundedAndOwnerOnly`, `test_seatSizer_drivesV4` (the Safe sets it through `SeatSizer.execute`) |

Left as they are, on purpose: a vetted owner can still hand its line to someone else through its pool delegate (the
default is recorded against the vetted owner, and the loss is the same one line); after a revoke, the open protocol
seat keeps its tokens and its slot until it is closed, frozen or expired, and lends nothing meanwhile. X-3's
economics apply to V4 at its larger line: the funder's USDG backs every line 100% and carries the credit risk, lenders
are never reached, and a staker who seats its own agent and walks away loses half a 5-line seat, so walking away pays
only after a fall of more than about 60% in $PRIORS since the seat was sized (about 50% at the edge of the sizer's
band). Open loans keep their terms through such a fall, which is why V4's loans are capped at 7 days.

Checked and sound, with a fuzzed sequence of random steps checking both after every step (`testFuzz_sequence`): the
vault's $PRIORS always equals `tokensHeld + protocolTokens`, and its USDG plus the pool's sponsor fees always covers
`totalFeesOwed`. Nobody, the owner included, can take the protocol stake through `rescue`, `withdrawOffer`, `accept`,
`close`, `expire`, `settle`, `freezeSeat` or re-entrancy; protocol fees stay out of `skim` and reach only
`protocolFeesTo`; and `SeatSizer` drives V4 unchanged. Like V3, V4 inherits `renounceOwnership` (V-3); while its
SeatSizer owns it, the sizer refuses that call (SZ-6).

## StockVault

Since 2026-09-28 (block 74,826,641) the **stock vault** (`0xbEcd07EC689988e16b870C121756C4c2C8cb02B6`, `src/StockVault.sol`, root `#6424`) backs lines with the agent's own Robinhood stock tokens. An agent's owner deposits one of the 35 accepted tokens and the vault vouches a line of that token's loan-to-value (25-50%, plus a record bonus) of the deposit's Chainlink value, at most $250, out of its own USDG stake in the pool. Every new loan asks the vault (`canBorrow`): a fresh price, no lending hold, the owner who opened the position, and the drawn principal within the loan-to-value of the collateral's value now. A default seizes the whole deposit to `seizeTo` (the Safe) and burns the vault's stake for the loan, as for any root: lenders never carry it.

**Upgradeable, unlike every other Priors contract.** The vault's address is a Transparent ERC-1967 proxy (`src/StockVaultProxy.sol`) to the implementation `0xF781b2634254d7819E9E17BfFc9D18C54C32008b`. Its ProxyAdmin (`0x5174A18550a295cd25aF59416a56B7e4c38C8Afc`) is owned by the Safe (2-of-3, no timelock), and only the Safe, through `ProxyAdmin.upgradeAndCall`, can point the vault at a new implementation. An upgrade can change anything the vault does, including moving the deposits and the stake it holds: depositors trust the Safe for that, on top of the rules below. `test/StockVaultUpgrade.t.sol` checks that only the ProxyAdmin's owner upgrades, that the implementation cannot be initialized and holds nothing, and that an upgrade keeps positions, stake, settings and tokens.

**The owner's powers.** The vault's owner is the same Safe (`Ownable2Step`; `renounceOwnership` reverts). Short of an upgrade, it can never take a depositor's tokens except through a default:

| call | what it does | bounds in the code |
|---|---|---|
| `setAsset(token, feed, maxAge, enabled, ltvBps, lineCap)` | accepts a token (or stops accepting it for new positions) with its Chainlink feed, the oldest price it uses, its loan-to-value and the USDG of open lines it may back | LTV 10-70%; `maxAge` at most 7 days; a held token's feed cannot change; a lower LTV shrinks what open lines can still draw, never the line vouched |
| `setParams` | the reference LTV the record bonus scales against, `maxLine` per position, `epochCap` of new lines per epoch, the epoch's length | LTV at most 70%; epoch at most 365 days |
| `setRecordBonus(roots, feeStep, bpsPerStep, maxBonus)` | which roots' repaid loans make an agent's record (the pool's `feesFrom`), and how fees paid under them add loan-to-value | at most 4 roots, never the vault's own; at most 20 points; a position never above 70% |
| `setPriceGuard`, `setSessionMaxAge`, `setIdleAfter`, `setIdleUndrawnAfter` | the lending holds' bounds, the price age while the market trades, the idle windows | a hold on a 5-50% move, windows at most 14 days; price age 1 h to 7 days; idle 1 to 365 days |
| `pause(bool)` | stops new positions and new loans | closing, settling, expiring, reclaiming and repaying never pause |
| `freezePosition(id)` | closes a position as its depositor could, every token back to the depositor | never seizes |
| `writeOff(id)` | for a position whose token cannot be sent back, with no loan open: its line ends and its stake is free | the tokens stay owed to the depositor; anyone can `reclaim` them once they move |
| `retire(shares, to)` | takes stake out | only stake that backs nothing, keeping every open line's fee room |
| `setSeizeTo`, `setFeeSink` | where seized tokens and sponsor fees go | – |
| `rescue(token, to)`, `rescueUsdg(to, amount)` | sends on a token sent by mistake; sends on USDG the vault received for someone else (a cash distribution on the tokens it holds) | `rescue` never reaches collateral held for positions, nor USDG; `rescueUsdg` is logged |
| `adopt(id)` | binds the vault's ERC-8004 identity | once |

The live settings (35 tokens, 25-50% loan-to-value, $1,000 of open lines per token and $500 for six, a record bonus from treasury v4's loans only) are in `deployments/stock-ltv.4663.json` and README's parameters table; the chain is right if they disagree.

Reviewed before deployment by an internal audit (2026-09-27) and a readiness review (2026-09-28); **no third-party audit**. Tests: `test/StockVault*.t.sol`, and `test/StockVaultFork.t.sol` against live chain state (`FORK_RPC=…`).

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| SV-1 | Medium | **No price-jump guard.** The feeds' multiplier can lag a corporate action by days; on a 1:N reverse split the same lag overstates collateral N times ($25 of stock opened a $125 line in the PoC). Bounded by `maxLine` and the weekly cap. | **Fixed before deployment:** lending holds on new lines and new loans: a move over 25% against any round of the last 14 days (widened from 5 days once SGOV's feed was found to have lagged 7), a price history that cannot be read, a multiplier change pending or under a day old, a multiplier that took effect after the feed's latest answer. | `test/StockVaultAuditFixes.t.sol` (`test_priceJump_*`, `test_multiplierChange_pendingOrRecent_holds`), `test/StockVaultReadinessFixes.t.sol` (`test_priceJump_heldThroughASevenDayLag`, `test_multiplierTakenEffectAfterTheFeedsLatestAnswer_holds`) |
| SV-2 | Medium | **A paused token was still lent against.** Paused by its issuer with an old price, it could be borrowed on and defaulted, and the seizure failed until it was unpaused. | **Fixed before deployment:** a hold while the token or its registry is paused, or the registry blocks the vault or `seizeTo`. | `test_pausedToken_holdsNewLinesAndLoans_butRepayStillWorks`, `test_pausedRegistry_holds`, `test_blockedVaultOrSeizeTo_holds` |
| SV-3 | Medium | **`skim` sent every USDG the vault held to the fee sink**, including cash paid to it for its depositors. | **Fixed before deployment:** `skim` sends only the sponsor fees it claims; any other USDG leaves only through the owner's logged `rescueUsdg`. | `test_skim_sendsOnlyTheFees_otherUsdgStays`, `test_rescueUsdg_ownerOnly_andLogged` |
| SV-4 | Low | An issuer burn from the vault left its last depositor short, and a token that cannot move stranded its line. | **Fixed before deployment:** a burn is shared pro rata across every position of that token; `writeOff` and `reclaim` for tokens that cannot move. | `test_adminBurn_*`, `test_writeOff_*` |
| SV-5 | Low | `expire` counted from the last borrow, so a 30-day loan repaid on time could be expired at once; a line never drawn held the weekly cap and the stake for 30 days. | **Fixed before deployment:** `expire` counts from the last loan or repayment; a line never drawn expires after 7 days. | `test_expire_*` |
| SV-6 | Medium | **A written-off position was overwritten by a new `open`**, locking its tokens for good. | **Fixed before deployment:** `open` reverts `TokensOwed` until they are reclaimed. | `test_open_refusedOnAWrittenOffPosition`, `test_open_refusedForTheAgentsNewOwner_whileTokensAreOwed` |
| SV-7 | Medium | **One loan-to-value for all 35 names** under-priced the default on the most volatile. | **Fixed before deployment:** each token's own loan-to-value and cap on open lines, set with `setAsset`. | `test/StockVaultLtv.t.sol`, `test_perTokenLtv_*`, `test_lineCap_*` |
| SV-8 | Info | `renounceOwnership` was inherited: renouncing would lock the funder's stake behind the open lines (`retire` and `writeOff` need an owner). | **Fixed before deployment:** it reverts. | `test_renounceOwnership_reverts` |
| SV-9 | Medium | **Loans on the agent's own stock read as risk someone else took.** The vault is a root, so a self-collateralised agent built a Score v2 record (and rung) nobody else risked anything for. | **Fixed in Score v2 2.0.1** ([SCORE-v2.md](SCORE-v2.md)): a loan the vault backs is the borrower's own money. **Residual:** the on-chain record and `CreditLensV2` do not look at who backed a loan, so such a record counts toward treasury v4's `raise`, as a root the agent's owner funds itself already could (T10's bound: $25 of treasury exposure per 7-day epoch). The record bonus never counts the vault's own loans. | `scripts/test-stocks.mjs`; `test_recordBonus_ignoresLoansOnTheVaultsOwnLines`, `test_recordBonus_ignoresARootTheOwnerFundsItself` |
| SV-10 | Info (trust) | The token's issuer can pause, block, burn and upgrade the 35 stock tokens, including the vault's. | **Trust assumption**, as for the registry and USDG (X5). A burn is shared pro rata; a token that cannot move is written off and reclaimed later (SV-4). The stake, never lenders, pays a default whose collateral turns out worthless. | SV-2, SV-4 tests |
| SV-11 | Info | A default seizes the whole deposit, even when it is worth more than the loan; there is no liquidation. A cash or token distribution paid to the vault is not credited to depositors (it leaves only through the owner's `rescue` / `rescueUsdg`). | **By design.** | – |
| SV-12 | Info | Prices: a price older than 26 hours stops new loans while the market trades; the week's last price (a Friday or Saturday, UTC) stays usable until Tuesday 06:00 UTC, never beyond the token's `maxAge` (4 days). A mid-week holiday stops new loans until trading resumes. Robinhood Chain has no sequencer-uptime feed to check. | **Accepted.** Repaying, closing and settling never wait on a price. | `test/StockVault.t.sol` (price age) |

## SDK and x402 float

| id | sev | finding | status |
|---|---|---|---|
| facilitator F1 | High | A settlement whose RPC answer was lost was reported as failed although it had mined: the merchant denied, the client signed again, one call was paid twice. | **Fixed** in the facilitator: the hash is recorded before broadcast, and a lost answer is `pending`, resolved by hash. |
| F2 | Medium | `pay()` returned a merchant's `pending` as a plain 402; calling `pay()` again signed a second payment. | **Fixed:** `pay()` resends the same header while pending, then returns `{pending, paymentHeader}` for `resend()`. It never signs twice for one call. |
| F3 | Medium | `pay()`'s default loan term was 1 day, while float means "get paid next week". | **Fixed:** 7 days by default, clamped to the pool's range; `dueAt` is returned. |
| – | – | A 402 names its own price. | By design: `maxPrice` (default 0.1 USDG) is checked before anything is signed or borrowed, and an authorization is valid for at most 600 s. |

| P-1 | Medium | `@priors/mcp` `pay_url` could outlast the MCP client's 60 s timeout; the model's retry then signed a second payment (also after a merchant 500). | **Fixed in @priors/mcp 0.1.6:** each call answers within 45 s (15 s per request); a payment signed and not counted as paid is resent, never signed again, until its `validBefore`, and the answer says not to retry before then. `@priors/x402` 0.1.3 returns `signed: { paymentHeaders, validBefore }` for every signed payment and turns a timeout after signing into `pending`. |
| P-2 | Medium | Caps were per call only: a steered model could spend the wallet a dollar at a time. | **Fixed (0.1.6):** `PRIORS_MAX_SPEND_USD` (5) and `PRIORS_MAX_BORROW_TOTAL_USD` (25) bound the process, counted when signed. |
| P-3 | Medium | `pay_url` reached localhost and private addresses, and followed redirects anywhere with the signed header. | **Fixed (0.1.6):** https only; hosts that resolve to loopback, private, link-local, CGNAT or mapped forms are refused (`PRIORS_ALLOW_LOCAL=1` opts in for testing); redirects are never followed (`@priors/x402` sends `redirect: "manual"` by default). Every connection re-checks the address it resolved, so a DNS answer that turns private after the check (rebinding) is refused too. Calls that move money run one at a time, so concurrent calls cannot sign twice for one purchase or pass the session caps together. |
| P-4, P-5 | Medium, Low | Merchant text (the settlement header, the body, listings) could read as the server's own lines. | **Fixed (0.1.6):** only a 32-byte tx hash is printed as the settlement; bodies, listings and redirect targets come back between per-call random markers; listing fields are one line, URLs https only, payTo a checked address. |
| P-6 | Low | `@priors/mcp` 0.1.3 pinned `@priors/x402` 0.1.1, without the `repayLoan` guard. | **Fixed:** 0.1.6 pins 0.1.3; `@priors/mcp` < 0.1.6 and `@priors/x402` < 0.1.3 are deprecated on npm. |
| P-7 | Low | `settleLoans` (package and `sdk/float.mjs`) repaid any `agentId`'s loans. | **Fixed:** refuses `NOT_CONTROLLER` unless the signer controls the agent. |
| P-8, P-9 | Low | No timeout or size limit on merchant answers; money tools marked non-destructive. | **Fixed:** bodies read up to 256 KB; `pay_url`, `borrow` and `repay` are `destructiveHint: true`. |

`npm run test:v2` covers these client guards without a network.

## Private reports, 2026-09-23 to 2026-09-29

Thirty-eight private reports (GitHub advisories) and one by email, triaged against the code and the chain on
2026-09-29. Each was reproduced (a local merchant, a unit test, or a fork of mainnet) before a ruling. One row per root
cause; duplicates are credited with the first report (credits below the table).

| id | sev | finding | status |
|---|---|---|---|
| P-10 | Medium | `@priors/x402` `pay()`: a connection dropped after the signed payment was sent threw, losing the signed headers, so a retry signed a second payment the merchant could settle; `pay_url` counted neither against `PRIORS_MAX_SPEND_USD` (a new path around P-1 and P-2). GHSA-r47g-9jjv-wx3j. | **Fixed (@priors/x402 0.2.1, @priors/mcp 0.2.1):** once the payment may be out, `resend()` never throws: a transport error is pending (`transportError`, the headers returned); the payer resends an unsettled payment for the same purchase (method and URL without the fragment) instead of signing, until it expires; an error after a loan or a signature carries them, and `pay_url` counts them and answers "do NOT call pay_url again". |
| F4 | Medium | `sdk/float.mjs` `pay()` returned the signed header only on a "pending" answer: a 500, a non-pending 402, a dropped connection or an abort after signing lost it, so a retry paid twice (F2's fix covered "pending" only). GHSA-6cpq-qq3c-9539. | **Fixed:** `paymentHeader` and `validBefore` are returned on every result once signed; a transport error or a timeout after signing is pending with the header; an error after the loan carries it. |
| F5 | Low | `sdk/float.mjs` followed redirects with the signed payment (P-3's fix was in the package only). GHSA-gj2g-xr52-v6g2. | **Fixed:** no redirect is followed unless the caller asks; the 3xx is the answer. |
| F6 | Low | `sdk/float.mjs` had no timeout and read merchant bodies whole (P-8's fix was in the package only). GHSA-fvcv-jqc9-2f8m. | **Fixed:** 60 s per request by default, bodies read up to 256 KB. |
| F7 | Low | Two concurrent `pay()` calls on a short wallet each borrowed the gap (payer and float). GHSA-482p-7442-6227 (F3). | **Fixed:** one payment at a time per wallet. |
| P-11 | Low | `pay_url`'s one-payment-per-purchase key included the URL fragment, so `url#a` and `url#b` signed twice. GHSA-c683-6cg3-g8xx. | **Fixed (0.2.1):** the fragment is not part of the purchase. |
| P-12 | Low | The SSRF guard missed NAT64 (64:ff9b::/96, 64:ff9b:1::/48), 6to4, Teredo and site-local addresses and 192.0.0.0/24 and the TEST-NETs. GHSA-mrgg-j3wr-3p2q (and the same by email). | **Fixed (0.2.1):** the embedded IPv4 is judged; Teredo, site-local and the local-use NAT64 prefix are refused. |
| P-13 | Low | `redact()` masked the key and a private RPC URL only as literals (spaced, split or percent-encoded forms passed). No path to make a library quote them was found. GHSA-rv53-8q6x-rxjf. | **Fixed (0.2.1):** the key is masked with separators between its digits; the RPC URL by its parts, in any case, raw or percent-encoded. |
| C-1 | Low | A `.env` in the directory the CLI runs in could point `priors-v2` at other contracts through `PRIORS_ADDRESSES`. GHSA-xw44-m4mg-h375. | **Fixed:** on a real chain an addresses file must match the published deployment unless `PRIORS_ALLOW_CUSTOM_ADDRESSES=1` is exported in the shell (a `.env` cannot set it). |
| C-2 | Low | Outside a clone, `npx priors` runs an unrelated npm package and `priors-v2` is unpublished; the CLI said "check it from anywhere". GHSA-phq5-75g6-49p5. | **Fixed:** the hint and the docs say to run from the clone, and the `priors-v2` npm name is held by a placeholder that only prints those instructions (it reads no environment and no key). |
| FAC-1 | Low | The facilitator's discovery feed listed a merchant's v1 resources on any URL, and a merchant could register a priors.trade URL; `find_services` did not say who is approved. GHSA-w47m-jmjp-hmr9. | **Fixed (facilitator.priors.trade, the MCP servers):** priors.trade and every approved merchant's origin are reserved; a listing needs the merchant's registered origin, checked again when read; listings say whether Priors approved the merchant. |
| IB-2 | Low | `InviteBond` snapshots `qualifiedRepaid` at deposit, and a later permissionless `importFromV1` could raise it, releasing the bond early (a new path to IB-1). GHSA-c4wg-mccg-3pfq. | **Not reachable:** every v1 record was imported (blocks 71,702,743–71,704,677) before `InviteBond` was deployed (72,112,874), no v1 record holds a qualified loan, v1 is paused and sealed, and every import now reverts. The invite bot also refuses an agent whose v1 record is not imported (it simulates `importFromV1`). A replacement bond must import before it snapshots. |
| O-1 | Low | A line from a root with no hook is bound to the agent id, so whoever buys the NFT can draw it. GHSA-45xq-8g3m-34jm. | **Residual (the T8, X-1, V-2 class):** the loss is bounded by the line the backer vouched, which the owner it vetted could draw and default without a sale; a backer binds owners through its hook (`canBorrow` gets the owner), as the seat vaults and the stock vault do. |
| O-2 | Low | `ownerDefaults` is keyed on an address, so moving agents to a fresh wallet sheds the mark. GHSA-g46p-969j-m75w. | **Residual (as R2-1):** a fresh address with no record is a fresh identity; a backer still has to choose to vouch for it. |
| O-3 | Low | An `importFromV1` of a v1 default could settle a v2 seat (half burned) or leave a v1 defaulter backing. GHSA-482p-7442-6227 (F1, F2). | **Not reachable (as X-4, F-6):** every v1 record is imported, none defaulted, v1 is paused. |
| S-1 | Low | Score v2 counts a backer's 30 days from its id's enrolment, not from when its current owner took it. GHSA-6f8j-g9rf-h284. | **Fixed (display only):** a backer's 30 days count from its current owner's arrival, read from the registry's transfers; no published score changed (no backer id had changed hands after enrolling). |

Credits, by row: the first valid report, then the later reports of the same root cause in filing order.

- P-10: @sands786; also @sebattoriq, @islaintent, @Fdxyz, @Godswork4, @dimazz12, @johndastech-glitch,
  @clementnaomi064-spec.
- F4: @sebattoriq; also @xbyteid, @Sangmadun, @Fdxyz, @JasmeJun, @ginan15, @Godswork4, @ashraf9191.
- F5: @andelaiceee-code; also @Godswork4.
- F6: @Fdxyz. F7 and O-3: @brianyazzz.
- P-11: @xShadowxIQ; also @Fdxyz.
- P-12: @johndastech-glitch, and Gerald Gerald by email the same day.
- P-13: @0ex-NightFall. C-1: @johndastech-glitch. C-2: @xbyteid. FAC-1: @mmasyoga0.
- IB-2: @daffhaidar; also @rabbinik, @0ex-NightFall, @johndastech-glitch.
- O-1: @sands786; also @xShadowxIQ. O-2: @Muhamadluis. S-1: @Firlinata.

Not findings: the facilitator's free tier was said to be unlimited and to halt every merchant (GHSA-gg53); its global
budget (300 free settles a day for the self-registered merchants together, published on `/health`) and the per-IP
and daily registration limits were live, and the approved merchants sit outside that budget. The v1-only reports
(GHSA-qq69, GHSA-f8mw, GHSA-576h, GHSA-q9hg) were checked against v2, which none of them reaches; thanks to llen
(@yossweh) and @byfor8 for them.

## Reproducing

```bash
forge test --match-path 'test/audit-v2/*' -vv
forge test --match-path 'test/audit-final/*' -vv
forge test --match-path 'test/review-v2/*' -vv
forge test --match-contract 'CreditPoolV2Invariant|SeatVaultV2Invariant|SeatVaultV3Invariant|TreasurySponsorV4Invariant'
forge test --match-path 'test/StockVault*' -vv
forge test --match-path 'test/SeatVaultV4*' -vv
forge test --match-path 'test/audit-v4/*' -vv
forge test --match-path 'test/audit-r2/*' -vv
FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/StockVaultFork.t.sol -vv
```

The proofs of concept for SO-1, SO-2 and AI-1 are internal (V-2's are public, replayed against V3 in `test/SeatVaultV3V2Fixes.t.sol`) and not in this repository; the rows above state
what they show. Tests named `test_X*` / `test_T*_exploit_*` pass by demonstrating the finding (and its bound); `test_R*` /
`*_refuted_*` pass by demonstrating a refutation; `*_fixed` pass by showing the attack now fails.
