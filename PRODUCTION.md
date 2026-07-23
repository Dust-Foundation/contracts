# Dust — production readiness (M4)

What must be true before real money touches these contracts on mainnet. This is
the operational spine: key management, monitoring, incident response, and the
audit gate. Items marked **[you]** need the founder to execute (they involve
keys, accounts, or money I can't and shouldn't handle).

## Admin key management

The sweeper owner has exactly these powers (nothing else): curate the stock
menu, set the fee (capped 5% in code), set the keeper, set minSweep, pause. It
has **no power over user funds** — cannot withdraw, cannot exceed a user's
accrued, cannot change a user's basket, cannot block withdrawals.

Even so, that owner key must not be a single EOA on mainnet.

- **[you] Owner = a multisig** (e.g. Safe, 2-of-3 or 3-of-5). Deploy the multisig
  with your signers, then `transferOwnership(multisig)` and have it
  `acceptOwnership()` (two-step is built in, so a wrong address can't brick it).
- **[you] Sensitive changes behind a timelock.** Route fee changes and treasury
  changes through a timelock contract owned by the multisig, so any change is
  announced on-chain before it takes effect. (Menu adds are low-risk and can be
  multisig-direct; menu removals and fee changes should be timelocked.)
- **Keeper key is separate and low-privilege.** It can only call `sweep()`. Run
  it as a dedicated hot key, funded with a little gas, rotated via `setKeeper`
  if it ever leaks. Never the deploy key, never the multisig.
- **Treasury** is its own address (the fee recipient), ideally a second multisig
  or a cold address. Set via `setTreasury`.

## The pause policy (written, so it's not discretionary)

`setPaused(true)` stops **new sweeps only**. It cannot touch the vault and
cannot block withdrawals — that invariant is enforced in code and tested.

Pause is justified only by: an active exploit, a critical oracle/price failure,
or an issuer halt on the stock tokens that makes sweeps revert en masse.
Deciding to pause is a multisig action. While paused, users can still withdraw
everything. Unpause when the triggering condition clears, with a public note.

## Monitoring & alerting

Stand up alerts on:
- **Sweep failures / mass LegSkipped** — an issuer pause or a broken pool.
- **Keeper health** — is it sweeping? gas balance? stuck txs?
- **Vault invariant** — for a sample of users, `sum(costBasis + accrued)` never
  exceeds stable ever received; token balances backed by real holdings.
- **Fee anomalies** — treasury inflow vs. expected from sweep volume.
- **Sequencer / RPC health** on Robinhood Chain.
- **Price deviation** once a TWAP guard exists — sweeps executing far from oracle.

A public status page + a written postmortem habit. Incidents get disclosed by
us, quickly, not discovered in a screenshot thread.

## Incident runbook (skeleton)

1. **Detect** — alert fires or report comes in.
2. **Assess** — is user money at risk right now? If yes and it's protocol-side,
   multisig `setPaused(true)` immediately (withdrawals stay open).
3. **Contain** — rotate the keeper key if it's a keeper compromise; delist a
   bad stock if it's an issuer problem.
4. **Communicate** — status page within the hour, plain language.
5. **Fix & verify** — patch, test against a fork, re-review the diff.
6. **Postmortem** — public writeup: what happened, blast radius, the fix.

## Pre-mainnet checklist

- [ ] **[you] Professional audit booked and passed**, report published in full.
      Book early — audit lead time is the schedule's long pole. The internal
      adversarial review (core mechanics: leg isolation, callbacks, access
      control, accounting) plus the inline review of the new surface (menu,
      per-user basket, fee) are done and documented in `audit/`, but they do
      **not** replace an external audit.
- [ ] Keeper `minOut` derived from a TWAP/quote, not the testnet floor of `1`
      (security review H-2 — the one must-fix before a live keeper).
- [ ] Stable switched to real USDG (6 decimals) — the `unit` in DustRouter and
      all amount math must move from 1e18 to 1e6. Re-run the full suite.
- [ ] Multisig owns the protocol; keeper + treasury are separate keys.
- [ ] **[you] Bug bounty live** (Immunefi or self-hosted) from mainnet day one.
- [ ] Monitoring + status page + runbook live.
- [ ] **[you] Legal sign-off** on the mainnet-beta scope, disclosures, fee, ToS.
- [ ] Non-stable-swap round-up pricing decided (oracle) or explicitly deferred.

## What's deliberately NOT here

No user-fund custody powers, no upgradeable proxy (contracts are immutable;
a new version means a new deploy and an opt-in migration), no caps/allowlist
(founder decision — the design's blast radius is already small).
