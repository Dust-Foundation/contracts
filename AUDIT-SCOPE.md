# Dust: audit scope

Prepared for the external audit. Everything below is verifiable against this
repository and the deployed contracts on Robinhood Chain (chain id 4663).

## What Dust is

Dust is a round-up investing protocol on Robinhood Chain. A user opts in, and
their swaps and outside spending get rounded up to the next dollar; the change
is pulled into the user's own vault position and swept into a basket of
Robinhood Stock Tokens the user composed. Non-custodial: no owner, keeper, or
team role can move a user's funds anywhere except into that user's own vault
position, and withdrawals always work.

## In scope

| File | What it is | Lines (code) |
|---|---|---|
| src/DustVault.sol | Per-user ledger and custody of accrued USDG and Stock Tokens. Withdrawals always available, no pause, no owner power over balances. Module wiring set once. | 77 |
| src/DustRouter.sol | In-app swap with the round-up: swaps USDG for a Stock Token to the user, moves the round-up into the vault. No admin. | 89 |
| src/DustSweeper.sol | Buys each user's own basket from an owner-curated menu (token to Uniswap v3 pool paired with USDG). Deterministic, leg isolation, partial fills credited only for stable spent, fee capped at 5% in code. Owner powers: menu, fee, keeper, treasury, min sweep, pause of new sweeps only. Two-step ownership. | 247 |
| src/DustCapture.sol | Capture Everywhere: user sets a weekly cap; the keeper pulls observed round-ups into the user's vault position from one of three sources: USDG allowance, WETH allowance (exact-output swap on a fixed WETH/USDG pool, paid in the swap callback), or an ETH float the user deposited and can withdraw at any time. WETH pulls are bounded by a 10-minute pool TWAP plus 2%. No owner, no pause. | 203 |
| src/interfaces/IDust.sol | Interfaces (ERC-20, WETH9, Uniswap v3 pool subset, vault). | |
| src/libraries/TickMath.sol, FullMath.sol | Vendored from Uniswap v3-core (0.8 versions), used only by DustCapture.maxWethInFor. | |
| script/Deploy.s.sol | Deployment and wiring, including the mainnet prechecks. Review for correctness of wiring, not as user-facing code. | |

Out of scope: src/ComposabilityProbe.sol (a read-only probe used during
research), test/mocks, and the off-chain keeper (a separate repository; its
powers are fully bounded by the contracts above and it is described in the
trust model).

## Deployed instances (Robinhood Chain mainnet, chain id 4663)

| Contract | Address |
|---|---|
| DustVault | 0xC6d3FCA5aa8274c03d015d914ae102f3FF344137 |
| DustRouter | 0x6A2A77F4ccb7ca9d5Af36EDb8491Af201bF209b3 |
| DustSweeper | 0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899 |
| DustCapture | 0xc33e4EB6099bd96127D6016E9EdE1234d3a69406 |

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
   user's own basket at prices no worse than caller-supplied non-zero minOuts,
   and pull round-ups bounded by the user's weekly cap in stable units, the
   user's allowance or float, and (for WETH paths) the TWAP + 2% bound.
3. DustVault.accrue trusts its callers (router, capture) to have transferred
   stable in the same transaction; both callers are fixed at wiring time.
4. Owner powers on DustSweeper are enumerated and bounded (fee <= 500 bps,
   pause affects new sweeps only). DustVault, DustRouter and DustCapture have
   no admin functions after deployment.
5. Withdrawals (accrued stable, Stock Tokens, ETH float) work in every state,
   including while sweeps are paused and with a weekly cap of zero.
6. Swap callbacks (uniswapV3SwapCallback, synthraV3SwapCallback) accept only
   the expected pool during an in-flight swap and pay only what the pool
   reports as owed.

## Known limitations (documented, not hidden)

- A compromised keeper can still overpay by up to 2% of each WETH-funded
  capture, bounded by the user's weekly cap; the 10-minute single-pool TWAP is
  the manipulation surface.
- The weekly window is fixed from the first opt-in and rolls forward, so up
  to 2x the cap can be pulled across a window boundary.
- costBasis in the vault is never reduced by withdrawals (display only).
- Stock Token withdrawals depend on the issuer not having paused or blocked
  the token or the address; Dust cannot override that.
- A user-chosen `to` in withdrawEth may be a contract; EthWithdrawn is emitted
  after the ETH transfer (accounting is debited before the transfer).

## Prior review

Internal adversarial review (test/DustCaptureAdversarial.t.sol) found and fixed
two issues before mainnet: a checked-arithmetic underflow in remainingThisWeek
when a cap was lowered below the week's usage, and an ETH-stranding path in
withdrawEth when `to` was the WETH contract. No external audit yet.

## Frozen revision

The audit target is the git tag `audit-2026-09` on this repository. Test
results at that revision: 68 unit and adversarial tests passing, 17 mainnet
fork tests passing (1 opt-in heavy test skipped).

## Build and test

Foundry, via_ir. `forge build`, then `forge test`. The mainnet fork suite
(test/DustMainnetFork.t.sol) forks Robinhood Chain from foundry.toml's
`robinhood_mainnet` alias; pin `MAINNET_FORK_BLOCK` within the last few
thousand blocks (the public RPC is not an archive node). Expected: 103 passed,
1 skipped (an opt-in heavy test).

## Contact

Through the channel this repository access was granted from. Findings can be
filed as private issues on this repository.
