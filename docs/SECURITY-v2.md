# v2 security notes: what was found, what was fixed, what remains

This page covers the v2 set live on Robinhood Chain since block 71,702,460: `CreditPoolV2` (+ `PoolV2Lib`,
`CreditLensV2`), `TreasurySponsorV4` and `SeatVaultV2`, plus the SDK's x402 float client. It lists every known
finding, so a rediscovery is not mistaken for a new one, and so you can check each ruling against a test.

**How these were found.** Several internal adversarial reviews before launch (three per-contract hunts, Slither,
invariant campaigns at twice the committed runs, a migration rehearsal on a fork of live chain state), an
independent second-model review of the final fixes, and a second-opinion review after launch (2026-09-25; rows
SO-1, SO-2, AI-1 and V-2, whose proofs of concept are internal). **No third-party audit firm has reviewed v2.** Treat it
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
| AI-1 | Medium | **Self-service invites.** The Telegram invite bot signs a treasury invite for any owner who proves control of an agent, up to 10 a day. Agents and wallets are free, so without a price one person could take the week's first lines. | **Priced since 2026-09-25:** self-service is on, and every automatic invite needs a 5 USDG bond from the agent's owner in `InviteBond` ([`0xd7D8…60b8`](https://robinhoodchain.blockscout.com/address/0xd7D85590173aF18459e8D158f4E6B243837a60b8)), the size of the first line. It comes back after the treasury's seasoning bar (3 qualified repayments, none open) or after 4 days with no line, and goes to the Safe on default, so taking a first line and walking away nets nothing. **Residual:** a patient agent that repays 3 qualified loans (21+ days of fees) gets its bond back and can then default, about one line; that is T10's seasoned path, still bounded by `epochCap` ($25 per 7-day epoch), paid from treasury stake; lenders are untouched. | `test/InviteBond.t.sol` (`test_farm_repayOnceThenDefault_netsNothing`); internal review of the bot, 2026-09-25 |
| T8 | Low | An invite names an agent id, not its owner, so a later NFT holder can redeem it. | **Residual.** Invites expire, and each seats an agent once; `firstLine` also needs the current owner's pool consent. | `test_T08_exploit_nftBuyerRedeemsSomeoneElsesInvite` |
| T5 | Low | If the creator-fee escrow's claim ever failed, `sweep` would revert and USDG would wait. | **Residual.** The Pons escrow is immutable code that pays and makes no callback. | `test_T06_exploit_escrowClaimFailureStrandsTreasuryUsdg` |
| T18 | Low (ops) | Invite signers signed for treasury v3's EIP-712 domain, so every v4 invite would fail (safely). | **Fixed** in the invite tooling before launch. Invites are for domain `Priors Treasury` version `4`. | – |

Refuted: draining the treasury's USDG, misrouting sponsor fees, `sweep` re-entrancy, invite replay across
contracts, chains or versions, invite malleability, strangers burning the first-line cap, `reclaim`/`retire`
abuse, `rescue` reaching the asset or the stake.

## SeatVaultV2

| id | sev | finding | status | evidence |
|---|---|---|---|---|
| X-3 | High at placeholder numbers | **Self-seat loop.** Seat a fresh identity with your own $PRIORS, borrow the $5 line, default: half the seat is burnt, the line is kept. | **Gate + economics.** Seating requires `minRepaid` = 3 repaid loans. That gate is farmable (three minimum loans cost about half a cent in fees), so it is a filter, not the fix. **What closes it is the seat's value:** a seat is 1,000,000 $PRIORS and a default burns 50% of it. At the market price on 2026-09-24 (about 0.00148 USDG per $PRIORS) a default burns about $740 to take a $5 line; the loop pays only below about 0.00001 USDG per $PRIORS, a drop of more than 99%. Losses are also capped at the vault's `epochCap` ($50 per 7-day epoch), paid from the vault's own stake; lenders are untouched. If the price collapses: a keeper price guard alerts when half a seat is worth less than about 20 lines of USDG, and the Safe can then `pauseSeats` or raise `seatSize`. **Those levers reach new seats only, not seats already open** (V-2). | `test/audit-v2/SeatVaultV2X3Mitigation.t.sol`, `SeatVaultV2Fixes.t.sol` |
| X-1 | Medium | A stale offer could be taken by the next NFT holder after a sale, who borrowed and defaulted against someone else's seat. | **Fixed:** an offer is bound to the agent's owner at offer time and re-checked at accept. | `test/audit-v2/SeatVaultV2Fixes.t.sol` |
| X-2 | Medium | Idle seats never expired, so self-seats could fill every slot and tie up the vault's backing. | **Fixed:** `expire(id)` is permissionless after `idleAfter` = 30 days with no loan open. The idle clock counts from the latest of seat opening, last borrow and **last repay**, so a long loan repaid today is not idle. | `SeatVaultV2Fixes.t.sol` (`test_fix_X2_aSeatIsNotIdleRightAfterALongLoanIsRepaid`) |
| V-2 | Low | **Levers and ownership do not reach open seats.** `pauseSeats` and a new `seatSize` apply only to seats opened afterwards; an agent sold to a new owner keeps its seat; an active seat cannot be evicted, so seat capacity can be squatted (idle seats still expire, X-2). | **Residual.** The vault's backing is kept to the lines in use, and losses stay within the vault's `epochCap` and its own stake; lenders are untouched. Seat freeze, eviction and owner binding need a new vault. | internal PoC (`test_F2_…`, `test_F3_…`, `test_F4_…`) |
| X-4 | Low | A v1 default plus a failed hook could lock a seat forever. | **Closed by order:** v1 was paused before seats opened. | `test/SeatVaultV2V1DefaultOrder.t.sol` |

Refuted: stealing or double-exiting a staker's $PRIORS, double-claiming fees across re-seats, a stranger burning a
live seat, offer squatting and consent redirection, EIP-1271 abuse of `registerAndSeat`, re-entrancy through pool
hooks, an owner moving stakers' tokens or fees.

## SDK and x402 float

| id | sev | finding | status |
|---|---|---|---|
| facilitator F1 | High | A settlement whose RPC answer was lost was reported as failed although it had mined: the merchant denied, the client signed again, one call was paid twice. | **Fixed** in the facilitator: the hash is recorded before broadcast, and a lost answer is `pending`, resolved by hash. |
| F2 | Medium | `pay()` returned a merchant's `pending` as a plain 402; calling `pay()` again signed a second payment. | **Fixed:** `pay()` resends the same header while pending, then returns `{pending, paymentHeader}` for `resend()`. It never signs twice for one call. |
| F3 | Medium | `pay()`'s default loan term was 1 day, while float means "get paid next week". | **Fixed:** 7 days by default, clamped to the pool's range; `dueAt` is returned. |
| – | – | A 402 names its own price. | By design: `maxPrice` (default 0.1 USDG) is checked before anything is signed or borrowed, and an authorization is valid for at most 600 s. |

`npm run test:v2` covers these client guards without a network.

## Reproducing

```bash
forge test --match-path 'test/audit-v2/*' -vv
forge test --match-path 'test/audit-final/*' -vv
forge test --match-path 'test/review-v2/*' -vv
forge test --match-contract 'CreditPoolV2Invariant|SeatVaultV2Invariant|TreasurySponsorV4Invariant'
```

The proofs of concept for SO-1, SO-2, AI-1 and V-2 are internal and not in this repository; the rows above state
what they show. Tests named `test_X*` / `test_T*_exploit_*` pass by demonstrating the finding (and its bound); `test_R*` /
`*_refuted_*` pass by demonstrating a refutation; `*_fixed` pass by showing the attack now fails.
