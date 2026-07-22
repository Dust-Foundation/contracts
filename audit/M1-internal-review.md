# Dust M1 Contracts — Final Audit Report

**Scope:** `DustRouter.sol`, `DustSweeper.sol`, `DustVault.sol`
**Verification:** 16 surviving findings deduped to 9 (2 HIGH, 1 MEDIUM, 4 LOW, 2 INFO). 3 false positives killed (fee-on-transfer over-credit, rebasing under-collateralization, router sandwich — all correctly rejected: the router enforces caller `minOut` and pairing, and `_buy` credits pool-reported deltas backed by a `balanceOf` check).

The verified set collapses along three root causes: (A) the sweep path has no protocol-enforced price protection, (B) the sweep assumes exact-input swaps fully fill and has no fund-recovery path, (C) the sweep is atomic over a global basket of issuer-gated tokens. Everything else is secondary.

---

## H-1 — Partial-fill swap permanently strands user stable in the sweeper
**Severity: High** · `contracts/src/DustSweeper.sol:156` (with `:130`, `:163`, `:171`)

`sweep` debits the user's **full** accrued stable up front (`vault.debitAccrued`, line 130) and then assumes each `_buy` consumes its entire `legIn` (`spent += legIn`, line 137). But `_buy` pins `sqrtPriceLimitX96` to the absolute extreme (line 163) and only validates tokens *received* (`balanceOf >= out`, line 171) — it never checks that the full `legIn` stable was actually paid. In a Uniswap-v3 exact-input swap, if the pool's liquidity in the swap direction is exhausted before the input is consumed, the swap terminates early: `_payPool` pays the pool only the consumed `owed` (lines 177-179) and the unspent remainder stays in the sweeper. That remainder was already debited from the user's ledger, was not invested, was not credited back, and **`DustSweeper` has no skim, sweep-out, or recovery function of any kind** — the stable is stuck permanently. This is the single most severe finding: guaranteed, irreversible fund loss on any thin or heavily-weighted pool, no attacker required.

**Fix:** In `_buy`, capture the pool-reported input delta (`a0`/`a1` on the stable side) and either (a) `revert` on partial fill so the atomic sweep unwinds and the debit reverts, or (b) credit only the consumed amount and re-accrue the difference back to the user's vault balance. Never assume exact-input fully fills.

---

## H-2 — Keeper sweeps have no enforceable slippage floor; every batch is a free sandwich
**Severity: High** · `contracts/src/DustSweeper.sol:141` (with `:163`, `:122`, `:138`)

*(Consolidates four reported findings — lines 163, 141, 122, 138 — into one root cause.)* The only price protection on a sweep leg is `if (got < minOuts[i]) revert` (line 141), and `minOuts` is entirely caller-supplied. The pool's own guard is disabled: `sqrtPriceLimitX96` is pinned to `MIN/MAX_SQRT_RATIO±1` (line 163), so the exact-input swap fills at *any* price. For the product's primary flow — keeper batch sweeps — the user does not supply `minOuts`; the keeper does, and the documented keeper behavior passes `minOuts=[0,…]`. With a zero floor, `got < 0` is never true, so any output including near-zero is accepted (the degenerate illiquid/thin-pool case, line 138, is the same bug without an active attacker). Sweep amounts and basket are public and the tx is deterministic, so an MEV searcher (or the keeper itself) front-runs the sweep, skews the pool, lets the sweep buy at the ruined price, and back-runs. The user is credited the tiny `got` but `costBasis` is charged the full `legIn` (line 144) — realized, permanent loss, repeatable on every leg of every sweep. The contract's "deterministic, nobody chooses what a sweep buys" claim is false on the price dimension: it is pure keeper discretion, and `setKeeper` (line 103) plus no per-user opt-in means one compromised keeper key exposes every user with an accrued balance.

**Fix:** Enforce an on-chain minimum-out the keeper cannot waive — derive it per leg from the pool's own TWAP (`observe()`) with a bounded max deviation, and/or set a real per-leg `sqrtPriceLimitX96`. At minimum reject `minOut == 0` on the keeper path. Additionally require `got > 0` per leg, and consider a per-user opt-in flag so self-sweepers (who set their own `minOuts`) aren't exposed to keeper discretion.

---

## M-1 — One paused/blocklisted basket token bricks sweeping for all users
**Severity: Medium** · `contracts/src/DustSweeper.sol:143` (with `:133`)

*(Consolidates three reported copies — lines 143, 133, and the "M0 park-in-USDG" variant.)* Per M0-FINDINGS #1, the stock tokens are blocklist-gated proxies whose `transfer` reverts on global `paused()` or `isBlocked(from/to)`. The sweep loop is strictly all-or-nothing over a single global basket: `IERC20(leg.token).transfer(address(vault), got)` (line 143) on any one of up to 20 legs reverts the entire sweep, including the earlier `debitAccrued`. For tokenized equities a halted/non-transferable state is a **normal** condition (overnight, weekends, corporate actions, volatility halts), not an exotic attack — so a third-party issuer can unilaterally take down the protocol's headline function for *every* user, not just holders of that token. No stable is lost (the revert is atomic), but the only remedy is `proposeBasket → timelockDelay → executeBasket`, far too slow for an intraday halt. This directly contradicts the M0 design requirement that the sweeper "must handle a future isBlocked/paused revert gracefully (park the round-up in USDG, never brick the vault)" — the implementation does the opposite.

**Fix:** Isolate legs. Wrap each leg's buy+transfer+credit in `try/catch` (or a low-level call) and skip a failing leg, re-accruing that leg's slice back to the user's `accruedStable` so accounting stays whole and the stable never sticks in the sweeper. Emit an event for skipped legs so the keeper/UI can react.

---

## L-1 — Vault "withdrawals ALWAYS work" invariant is false for basket tokens
**Severity: Low** · `contracts/src/DustVault.sol:95` (header at `:10-11`, transfer at `:99`)

*(Consolidates two reported copies.)* The header states as a core invariant that withdrawals always work and no power can freeze balances. That holds for `accruedStable` but **not** for `tokenBalance`: `withdrawToken` does `IERC20(token).transfer(to, amount)` (line 99), and if the issuer sets `paused()` or `isBlocked(vault)`, every user's stock-token withdrawal reverts. An external party (the issuer) can effectively freeze all basket holdings in the vault, with no code path to make users whole. This is an inherent property of custodying gated tokens, but the comment — and any docs/UI derived from it — overstate the guarantee.

**Fix:** Scope the invariant comment to the stable ledger and internal accounting only; document the issuer-pause residual risk. Consider giving users a router-side unwrap-to-stable path they can use while a token is unblocked, so exposure is opt-out.

---

## L-2 — One-step `transferOwnership` with no zero-address check can brick governance
**Severity: Low** · `contracts/src/DustSweeper.sol:113`

`transferOwnership` sets `owner = to` immediately (line 115) with no two-step accept and no non-zero validation. A typo or transfer to `address(0)` permanently disables `proposeBasket`, `setPaused`, `setKeeper`, and `setMinSweepAmount`. User funds are safe (vault withdrawals are independent of the sweeper owner), but the basket, pause switch, and keeper rotation freeze forever — and a later-compromised keeper key could no longer be revoked, compounding H-2.

**Fix:** Adopt an `Ownable2Step`-style pending-owner / `acceptOwnership` flow and reject `address(0)`.

---

## L-3 — Sweep is not bound to the basket version its `minOuts` were quoted against
**Severity: Low** · `contracts/src/DustSweeper.sol:88`

`executeBasket` is permissionless once the timelock passes (line 88) and rewrites the global basket. `sweep` only checks `minOuts.length == basket.length` (line 126). If a same-length, reordered/retokened basket executes between the keeper quoting `minOuts` and its sweep landing, `minOuts[i]` now guards the wrong leg — bounds can be too loose (feeding H-2) or spuriously revert. The public timelock makes the window narrow, but nothing ties a sweep to the basket it was priced for.

**Fix:** Have the caller pass an expected basket identifier (hash of the current basket, or an incrementing `basketVersion`) into `sweep` and revert on mismatch.

---

## L-4 — `_validate` does not verify pool ↔ token ↔ stable correspondence
**Severity: Low** · `contracts/src/DustSweeper.sol:192` *(2/3 REAL)*

`_validate` checks only non-zero token/pool, leg count 1..20, and weights summing to 10 000 (lines 192-200). It does not confirm `leg.pool` is actually paired with `stable`, nor that the pool's non-stable side equals `leg.token` — a check the **router does** perform (`DustRouter.sol:81-84`). `_buy` trusts the basket blindly, deriving `zeroForOne` from `token0()==stable` alone. A mismatched leg reverts (`BadCallback`, line 171) rather than misdirecting funds, so this is not a theft path, but a compromised owner (or a mis-specified proposal that survives the timelock) can wire in a structurally bogus leg that is accepted at propose time.

**Fix:** In `_validate`, read `pool.token0()/token1()` and require exactly one side `== stable` and the other `== leg.token`, mirroring the router.

---

## L-5 — User can grief keeper gas by front-running the sweep with `withdrawAccrued`
**Severity: Low** · `contracts/src/DustSweeper.sol:128`

`sweep` reads `amount = vault.accruedStable(user)` fresh (line 128) and reverts `BelowMinimum` if it's below `minSweepAmount` (line 129). A user can call `vault.withdrawAccrued` (always permissionless) to drop their balance just below the threshold in the block before the keeper's sweep lands, reverting it and wasting keeper gas. Blast radius is limited to that user's own sweep (no shared batch state on-chain), so it only wastes keeper gas, not other users' funds.

**Fix:** Make the keeper's off-chain batch tolerate individual reverts (per-user `try/catch`, skip users whose accrued dropped) — the same leg-isolation pattern as M-1. Do not add a withdrawal dwell time; it would erode the always-withdrawable stable guarantee.

---

## I-1 — `expectedPool` guard is plain storage, not transient (self-DoS only)
**Severity: Info** · `contracts/src/DustSweeper.sol:41` / `DustRouter.sol:24`

The comment labels `expectedPool` a transient var, but it is plain storage. In the router the pool is caller-chosen, so a malicious pool can re-enter `swapWithRoundUp` during its own `swap`; the nested call resets `expectedPool` to `0` on return, so the outer callback fails `pool != expectedPool` and the outer swap reverts. This is a self-inflicted DoS on the attacker's own transaction — never a misdirected payment (`_payPool` always pays the decoded pool that must simultaneously equal `msg.sender` and `expectedPool`, and the router holds no funds between txs). No theft path.

**Fix (hardening):** Use EIP-1153 transient storage (`tstore`/`tload`) for `expectedPool`, or add a `nonReentrant` guard on the public entrypoints, to make the transient intent explicit rather than relying on the revert.

---

## I-2 — Verified clean (noted so they are not re-flagged)
**Severity: Info** · `contracts/src/DustSweeper.sol:136`, `DustVault.sol`

(1) The `weightBps` split gives the last leg `amount - spent`; since weights sum to 10 000 and every non-last leg takes `floor`, `spent < amount` always holds — no underflow, no stranded stable, rounding dust deterministically absorbed by the last leg. (2) A zero-weight leg hits `if (legIn == 0) continue` (line 138), safe. (3) `DustVault` is pure per-user accounting (mappings, no pooled shares, no share price), so first-depositor / donation / inflation attacks do not apply. The three killed findings (fee-on-transfer over-credit, rebasing under-collateralization, router sandwich) were correctly rejected.

---

## Bottom line

**Not ready for external audit — fix H-1 and H-2 first.** H-1 is a guaranteed, unrecoverable loss of user stable on any partial fill, and H-2 makes the primary keeper-driven flow a systemic MEV drain; both stem from the sweep trusting extreme-limit exact-input swaps with no enforced floor and no fund-recovery path. Land the H-1/H-2/M-1 fixes (they share the leg-isolation + on-chain-price-guard shape), clear the LOW governance/validation items, then send to external audit.