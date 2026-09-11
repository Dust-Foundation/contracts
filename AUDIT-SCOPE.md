# Dust: audit scope

Prepared for the external audit. Everything below is verifiable against this
repository and the deployed contracts on Robinhood Chain (chain id 4663).

The first external review (CredShields, report dated 11 September 2026,
against tag `audit-2026-09`, commit 01b014f) returned 12 findings: 1 high,
4 medium, 5 low, 2 informational. The v3 contracts in `src/` are the response.
Every finding, the fix and where it lives are listed in "Findings and responses
(v3)" below. v3 is not deployed yet; the live addresses further down are v2.

## What Dust is

Dust is a round-up investing protocol on Robinhood Chain. A user opts in, and
their swaps and outside spending get rounded up to the next dollar; the change
is pulled into the user's own vault position and swept into a basket of
Robinhood Stock Tokens the user composed. Non-custodial: no owner, keeper, or
team role can move a user's funds anywhere except into that user's own vault
position, and withdrawals always work.

## In scope (v3)

| File | What it is | Lines (code) |
|---|---|---|
| src/DustVault.sol | Per-user ledger and custody of accrued USDG and Stock Tokens. Withdrawals always available, no pause, no owner power over balances. Module wiring set once. Logic unchanged from v2; token movements go through SafeTransfer. | 79 |
| src/DustRouter.sol | In-app swap with the round-up: swaps USDG for a Stock Token to the user, refunds whatever the pool did not consume, rounds up on the measured spend, moves the round-up into the vault. Accepts only pools the canonical factory resolves for the pair. Callback payment bounded by the committed amount. No admin. | 119 |
| src/DustSweeper.sol | Buys each user's own basket from an owner-curated menu (Stock Token to canonical Uniswap v3 pool paired with USDG). Deterministic, leg isolation, on-chain TWAP price floor per leg, pinned quotes (amount, pools, fee, nonce), one sweep per user per 5 minutes, user revocation (clearBasket), fee of at most 5% charged on the stable actually invested. Owner powers: menu, fee, keeper, treasury, min sweep, pause of new sweeps only. Two-step ownership. | 320 |
| src/DustCapture.sol | Capture Everywhere: user sets a weekly cap; the keeper pulls observed round-ups into the user's vault position from one of three sources: USDG allowance, WETH allowance (exact-output swap on a fixed, factory-verified WETH/USDG pool, paid in the swap callback), or an ETH float the user deposited and can withdraw at any time. WETH pulls are bounded by a 10-minute pool TWAP plus 2%, in aggregate per swap. The vault credit is the measured balance delta. No owner, no pause. | 224 |
| src/interfaces/IDust.sol | Interfaces (ERC-20, WETH9, Uniswap v3 pool subset, pool provenance, factory, vault). | 55 |
| src/libraries/SafeTransfer.sol | Token movement helper: accepts a call that returns nothing or `true`, bubbles a token's own revert data, reverts `TransferFailed()` on a `false` return or a codeless address. `tryTransfer` is the non-reverting variant used only for the sweep fee. | 27 |
| src/libraries/TickMath.sol, FullMath.sol | Vendored from Uniswap v3-core (0.8 versions), pragma pinned to 0.8.35. Used by DustCapture.maxWethInFor and DustSweeper.expectedOutAtTwap. | |
| script/Deploy.s.sol | Deployment and wiring, including the mainnet prechecks (factory provenance for every pool), the fifteen-pair menu and the two-step ownership handover. Review for correctness of wiring, not as user-facing code. | |

Out of scope: src/ComposabilityProbe.sol (a read-only probe used during
research), test/mocks, and the off-chain keeper (a separate repository; its
powers are fully bounded by the contracts above and it is described in the
trust model).

## Deployed instances (Robinhood Chain mainnet, chain id 4663)

These are the v2 contracts the audit reviewed. They stay live until v3 is
deployed and users have migrated; DustVault.setModules is one-shot, so all four
are redeployed together.

| Contract | Address |
|---|---|
| DustVault (v2) | 0xC6d3FCA5aa8274c03d015d914ae102f3FF344137 |
| DustRouter (v2) | 0x6A2A77F4ccb7ca9d5Af36EDb8491Af201bF209b3 |
| DustSweeper (v2) | 0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899 |
| DustCapture (v2) | 0xc33e4EB6099bd96127D6016E9EdE1234d3a69406 |

Dependencies: USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (6 decimals,
upgradeable proxy issued by Paxos), WETH 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
(upgradeable L2 WETH), Uniswap v3 factory 0x1f7d7550b1b028f7571e69a784071f0205fd2efa
and the WETH/USDG 0.01% pool 0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca, Stock
Tokens (OpenZeppelin beacon proxies with an issuer-controlled pause and
blocklist registry at 0xe10b6f6B275de231345c20D14Ab812db62151b00, ERC-8056
uiMultiplier). Full notes in MAINNET-ADDRESSES.md.

## Trust model and invariants to check

1. No path moves a user's stable or tokens to any destination other than that
   user's vault balance or a `to` address chosen by the user in a withdrawal.
2. The keeper (a hot key) can only: sweep a user's accrued stable into that
   user's own basket at no worse than the pool's own 10-minute TWAP less 3%
   per leg (minOut can only tighten that), against a quote it pinned (accrued
   amount, pool per leg, fee rate, basket nonce), at most once per user per
   5 minutes, and only while the user keeps a basket set; and pull round-ups
   bounded by the user's weekly cap in stable units, the user's allowance or
   float, and (for WETH paths) the TWAP + 2% bound applied in aggregate per
   swap. The user revokes both surfaces alone: clearBasket and setWeeklyCap(0).
3. DustVault.accrue trusts its callers (router, capture) to have transferred
   stable in the same transaction; both callers are fixed at wiring time.
4. Owner powers on DustSweeper are enumerated and bounded (fee <= 500 bps of
   the stable actually invested, menu limited to pools the canonical factory
   resolves for the pair and fee tier, pause affects new sweeps only). A fee
   or venue change between quote and execution makes the sweep revert rather
   than execute different economics. DustVault, DustRouter and DustCapture
   have no admin functions after deployment.
5. Withdrawals (accrued stable, Stock Tokens, ETH float) work in every state,
   including while sweeps are paused and with a weekly cap of zero.
6. Swap callbacks (uniswapV3SwapCallback, synthraV3SwapCallback) accept only
   the expected pool during an in-flight swap and pay, in aggregate across
   every callback of that swap, at most the amount committed to it
   (the router's amountIn, the sweeper leg's slice, the capture's WETH limit).
7. Nothing the router, sweeper or capture credits is taken from a pool's
   report: spent stable, tokens received and stable delivered to the vault are
   all measured as balance deltas.

## Known limitations (documented, not hidden)

- A compromised keeper can still buy up to 3% below the 10-minute single-pool
  TWAP on each sweep leg, and overpay by up to 2% on each WETH-funded capture,
  bounded by the user's accrued balance and weekly cap. The single-pool TWAP
  is the manipulation surface in both cases.
- Allocation drift (audit I001, accepted): when a basket leg is persistently
  skipped (delisted, paused, no oracle, below the floor), its slice returns to
  the user's accrued balance and is re-split across the whole basket on the
  next sweep, so the realized allocation drifts toward the buyable legs. The
  user can withdraw accrued stable at any time or clear the basket. Parking a
  skipped slice per token would add per-token accrued ledgers and a second
  sweep path for a fairness concern with no loss of funds; not built.
- Issuer freeze of the sweeper (audit L001, accepted variant): USDG has a
  per-address freeze. A frozen treasury is handled (the fee is waived for that
  sweep and returned to the user). If the issuer freezes the immutable sweeper
  address itself, DustVault.debitAccrued reverts and sweeping stops for
  everyone until a redeploy; accrued balances and withdrawals are untouched.
  This is a compliance action by the issuer, not an attacker path.
- Sweep rounding: the investable amount is amount * 10000 / (10000 + feeBps)
  (feeBps only; the treasury does not enter the slicing) and the fee is feeBps
  of what was invested, so a full fill leaves at most two raw stable units
  re-accrued. With no treasury set the reserve simply returns to the user.
- The weekly window is fixed from the first opt-in and rolls forward, so up
  to 2x the cap can be pulled across a window boundary.
- costBasis in the vault is never reduced by withdrawals (display only).
- Stock Token withdrawals depend on the issuer not having paused or blocked
  the token or the address; Dust cannot override that.
- A user-chosen `to` in withdrawEth may be a contract; EthWithdrawn is emitted
  after the ETH transfer (accounting is debited before the transfer).

## Findings and responses (v3)

Line references are to the v3 sources in this repository. Each item has a
test that reproduces the auditor's scenario and checks the fix: unit tests in
test/DustAuditV3.t.sol (mocks), mainnet-state tests in
test/DustMainnetFork.t.sol, capture tests in test/DustCaptureAdversarial.t.sol.

| ID | Finding | Response | Where |
|---|---|---|---|
| H001 | DustRouter kept the unspent part of a partial fill and any address could take it through the callback. | Fixed. The pool must be the canonical factory's pool for (stable, tokenOut, fee). Stable spent is measured as the router's balance delta across the swap, tokens received are measured at the caller; both must be non-zero and tokensOut >= minOut (minOut must be non-zero). The unspent remainder is refunded before the round-up is computed on the spent amount. The callback may pay at most amountIn in aggregate (OverCommitted). The event reports the spent amount. Reproduced on a mainnet fork against the thin TSLA/USDG 0.05% pool: of 100,000 USDG offered the pool consumed about 13% and the rest came back in the same call, router balance zero afterwards. | src/DustRouter.sol:122 (factory), 129-139 (measured swap), 143-150 (guards, refund), 153 (round-up on spent), 164-174 (callback bound). Tests: DustAuditV3 test_H001_* (incl. the fuzz testFuzz_H001_routerNeverAccumulates and test_H001_poolLyingAboutFeeIsRefused), DustMainnetFork test_H001_* |
| M001 | Fee charged on the gross amount and re-charged on recycled leftover; effective fee could exceed MAX_FEE_BPS. | Fixed. Legs are sliced from amount * 10000 / (10000 + feeBps); after the legs the fee is invested * feeBps / 10000 and amount - invested - fee is re-accrued. Returned stable carries no fee and is never re-taxed, so the lifetime fee on a unit of round-up is at most feeBps. One filled leg of twenty at 1% now pays 1% of that leg, not 2,020 bps. | src/DustSweeper.sol:342-343 (slicing), 371-389 (settlement). Tests: DustAuditV3 test_M001_* |
| M002 | buyLeg credited the pool-reported output instead of the vault's realized delta. | Fixed. The tokens that arrived at the sweeper are measured (not read from the swap return), then the vault's balance is read before and after the transfer and the delta is what creditTokens receives; a zero delta reverts the leg. | src/DustSweeper.sol:415-421, 464-481 (_buy measures). Test: DustAuditV3 test_M002_creditEqualsVaultBalanceDelta |
| M003 | No user revocation, only price bound was the keeper's own minOut, quotes replayable, no rate limit. | Fixed. clearBasket() deletes the basket, bumps the nonce, emits BasketCleared; sweep reverts NoBasket afterwards. Every leg must deliver at least the pool's 10-minute TWAP output less MAX_SWEEP_SLIPPAGE_BPS (300); minOut can only tighten it; a pool whose observe() reverts is skipped (LegSkipped), not fatal. basketNonce is consumed by every sweep. MIN_SWEEP_INTERVAL (300 s) per user, TooSoon otherwise. On a mainnet fork, a 2M USDG buy that moved the TSLA/USDG 0.3% spot far from its TWAP made a minOut = 1 sweep skip the leg and return the stable. | src/DustSweeper.sol:61-65 (constants), 225-229 (clearBasket), 323-335 (nonce, interval, consumption), 403-405 (floor in buyLeg), 429-458 (expectedOutAtTwap, twapFloor). Tests: DustAuditV3 test_M003_* (incl. test_M003_repeatedWorstCaseSweepsAreBounded and test_M003_twapFloorHoldsWithStableAsToken1), DustMainnetFork test_M003_* |
| M004 | sweep pinned only the basket composition; amount, venue, fee basis and treasury were mutable between quote and execution. | Fixed. New signature sweep(user, maxAmount, pools, minOuts, expectedNonce, expectedFeeBps). Reverts AmountAboveQuote if accrued > maxAmount, LengthMismatch if pools or minOuts length differs from the basket, PoolMismatch if a listed leg's pool differs from pools[i] (a delisted leg is skipped regardless), FeeChanged if feeBps differs, StaleBasket on the nonce. Leg sizes are derived from feeBps alone (the pinned value), never from the treasury, so setTreasury between quote and execution cannot resize a leg; with no treasury the fee reserve returns to the user. minSweepAmount is the one owner input a quote does not carry; it can only make the sweep revert (BelowMinimum), never execute differently. | src/DustSweeper.sol:309-331 (pins), 342-343 (slicing), 359 (venue), 371-383 (settlement). Tests: DustAuditV3 test_M004_* (incl. test_M004_treasuryChangeCannotResizeLegs, test_M004_minSweepAmountChangeOnlyReverts) |
| L001 | Settlement transfers not leg-isolated; a frozen treasury bricked sweeping. | Fixed for the treasury: the fee transfer uses a non-reverting call; on failure the fee is zero for that sweep, FeeSkipped is emitted and the amount returns to the user through reaccrue. Reproduced on real USDG with a mocked freeze of the treasury address. The sweeper-freeze variant is accepted and documented above. | src/DustSweeper.sol:372-383; src/libraries/SafeTransfer.sol tryTransfer. Tests: DustAuditV3 test_L001_*, DustMainnetFork test_L001_* |
| L002 | buyLeg never bounded spent against the leg's slice; a non-canonical listed pool could drain other legs. | Fixed. listStock requires pool == factory.getPool(token0, token1, pool.fee()). The leg's callback may pay at most legIn in aggregate (OverCommitted), and buyLeg additionally reverts SlippageExceeded if the measured spend exceeds legIn. A leg that trips either is skipped and its slice returned. | src/DustSweeper.sol:168 (listing), 413 (spent bound), 483-493 (callback bound). Tests: DustAuditV3 test_L002_*, DustUnit test_sweeper_rejectsNonCanonicalPool |
| L003 | Bare transfer / transferFrom through an interface that declares a bool return. | Fixed. src/libraries/SafeTransfer.sol is used for every token movement in all four contracts. A token returning nothing (USDT style) works; a token's own revert data is bubbled unchanged; a false return or a codeless address reverts TransferFailed(), the selector the contracts already declared, so keeper and app error matching is unchanged. The if (!...) revert wrappers are gone. | src/libraries/SafeTransfer.sol; every safeTransfer / safeTransferFrom call site. Tests: DustAuditV3 test_L003_* |
| L004 | DustCapture bounded WETH per callback, not per swap, and credited the pool's reported stable delta; provenance lived in the deploy script only. | Fixed. _paySwap decrements pending.wethLimit in storage by each payment (OverMaxWethIn on the second callback that would exceed it). The vault's stable balance is read before the swap and the delta must equal amountOut (PartialFill otherwise). The constructor takes the factory and requires ethPool == factory.getPool(weth, stable, ethPool.fee()). NatSpec states the aggregate bound. | src/DustCapture.sol:104-134 (constructor), 285, 301 (measured credit), 312-339 (_paySwap). Tests: DustCaptureAdversarial test_L004_*, DustCapture test_constructorRejectsNonCanonicalPool |
| L005 | Floating pragmas, no solc pin. | Fixed. pragma solidity 0.8.35 in all seven in-scope files (the two vendored libraries note the deviation from upstream) and solc = "0.8.35" in foundry.toml. | src/*.sol, src/interfaces/IDust.sol, src/libraries/*.sol, foundry.toml |
| I001 | Repeated partial sweeps drift a user's realized allocation. | Accepted as designed; documented in the DustSweeper NatSpec and in "Known limitations" above. No code change. | src/DustSweeper.sol:43-46 |
| I002 | minOuts[i] == 0 rejected before the delisted-leg skip. | Fixed. A leg with poolFor == 0 is skipped before the ZeroMinOut check, so a placeholder of zero for a delisted leg no longer reverts the sweep. | src/DustSweeper.sol:354-360. Test: DustAuditV3 test_I002_delistedLegWithZeroMinOutIsSkipped |

Interface changes for integrators (keeper and app) are collected in the
handoff notes of the v3 change: new constructors (factory argument on
DustRouter, DustSweeper, DustCapture), the sweep signature, clearBasket,
the Swept event now carrying the fee, FeeSkipped and BasketCleared events, the
router event reporting the spent amount, and the new errors.

## Prior review

Internal adversarial review (test/DustCaptureAdversarial.t.sol) found and fixed
two issues before mainnet: a checked-arithmetic underflow in remainingThisWeek
when a cap was lowered below the week's usage, and an ETH-stranding path in
withdrawEth when `to` was the WETH contract. The external audit above is the
first third-party review.

## Frozen revision

The audit target was the git tag `audit-2026-09` (commit 01b014f). Test
results at that revision: 68 unit and adversarial tests passing, 17 mainnet
fork tests passing (1 opt-in heavy test skipped). The v3 response revision
passes 144 tests: 107 unit and adversarial (including 28 audit reproductions
and retest break attempts in test/DustAuditV3.t.sol), 24 mainnet fork, 13
testnet fork, none skipped.

## Build and test

Foundry, via_ir, solc 0.8.35. `forge build`, then `forge test`. The mainnet
fork suite (test/DustMainnetFork.t.sol) forks Robinhood Chain from
foundry.toml's `robinhood_mainnet` alias, pinned FORK_LAG blocks behind the
head it discovers; the public RPC is not an archive node, so a pinned
`MAINNET_FORK_BLOCK` must be within the last few thousand blocks. For a
deterministic replay pass `--fork-url` with an archive provider's URL from the
environment (never write a keyed URL into a file) together with
`MAINNET_FORK_BLOCK`. Expected: 144 passed, 0 skipped.

## Contact

Through the channel this repository access was granted from. Findings can be
filed as private issues on this repository.
