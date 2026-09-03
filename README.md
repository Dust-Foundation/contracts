# Dust contracts

Solidity + Foundry. Four contracts, no upgradeability, no admin power over user funds:

- `src/DustVault.sol` custody and per-user ledger (accrued stable, Stock Token balances, cost basis). Withdrawals always work.
- `src/DustRouter.sol` stable -> Stock Token swap with the round-up captured in the same transaction.
- `src/DustSweeper.sol` owner-curated menu of (Stock Token, USDG pool) pairs; each user composes their own basket; the keeper sweeps accrued round-ups into it with caller-supplied per-leg minOuts. Failing legs are skipped, never fatal.
- `src/DustCapture.sol` opt-in, user-capped pulls for round-ups observed outside the app.

The single source of truth for every mainnet address is `MAINNET-ADDRESSES.md`. Do not guess addresses.

## Networks

| | chain id | stable | DEX callback |
|---|---|---|---|
| Robinhood Chain mainnet | 4663 | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals | `uniswapV3SwapCallback` (canonical Uniswap v3) |
| Robinhood Chain testnet | 46630 | test USDC `0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F`, 18 decimals | `synthraV3SwapCallback` |

Both callbacks are implemented, so the same bytecode works on either network. The router's stable unit is derived from `decimals()` at deploy time (1e6 on mainnet, 1e18 on testnet).

RPC endpoints are named in `foundry.toml` (`robinhood_mainnet`, `robinhood_testnet`). The public endpoints rate-limit hard (HTTP 429 on bursts). Fork tests use them with retries; the keeper and app must use a paid provider.

## Build and test

```shell
forge build
forge test                                   # unit + testnet fork suites
FOUNDRY_FORK_RETRIES=5 FOUNDRY_FORK_RETRY_BACKOFF=2000 \
  forge test --match-contract DustMainnetFork -vv   # mainnet fork suite
```

Fork suites fork their endpoint themselves (`vm.createSelectFork`). If an RPC is unreachable or the state is gone they skip instead of failing.

The public mainnet node is not an archive node: measured on 2026-09-03 it only serves state for roughly the latest 6k to 10k blocks (10 to 17 minutes), so a hard-coded pin goes stale within minutes. By default the mainnet suite forks the head, pins 100 blocks behind it, and logs the block; `setUp` runs once per suite, so all tests in a run share that block. For an exactly reproducible replay set `MAINNET_FORK_BLOCK=<n>` against an archive provider. Fork state is cached locally per block, so reruns at the same block barely touch the RPC.

`test/DustMainnetFork.t.sol` deploys the four contracts into a mainnet fork against real USDG and the five launch pools (TSLA, NVDA, AAPL, AMZN, SPY) and runs the full loop: menu, basket, round-up, keeper sweep with TWAP-derived minOuts (same math as `keeper/quote.mjs`), in-kind withdrawal, plus empty-pool and issuer-pause leg skipping and withdrawals while paused. One extra test runs the empty-pool case against the real dead TSLA/USDG 0.05% pool; it needs ~700 storage reads and is skipped unless `MAINNET_FORK_HEAVY=1` (use a paid RPC for it).

## Deploy

`script/Deploy.s.sol` picks the path from `block.chainid` (or `DEPLOY_NETWORK=mainnet|testnet`). The mainnet path hard-requires chain id 4663, logs every address before the first transaction, and pre-checks that each menu pool pairs the stable with its token.

Dry run first. Without `--broadcast` forge only simulates:

```shell
forge script script/Deploy.s.sol --rpc-url robinhood_mainnet -vvvv
```

Mainnet environment variables (all optional; defaults are the verified values in `MAINNET-ADDRESSES.md`):

| var | meaning | default |
|---|---|---|
| `STABLE` | stable token | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| `TREASURY` | fee recipient | `0x0` (fee disabled until the owner calls `setTreasury`) |
| `KEEPER` | sweep and capture keeper | deployer |
| `OWNER` | final `DustSweeper` owner, the multisig | deployer, with a loud warning |
| `FEE_BPS` | sweep fee, max 500 | `100` |
| `MENU_TOKENS` | comma-separated Stock Token addresses | TSLA, NVDA, AAPL, AMZN, SPY |
| `MENU_POOLS` | comma-separated USDG pools, parallel to `MENU_TOKENS` | the verified 0.3% / 0.05% pools |

Ownership is two-step: the script calls `transferOwnership(OWNER)`; the multisig must call `acceptOwnership()`. If `OWNER` is unset the deployer keeps ownership and the log says so; transfer it before launch.

Real deploy (founder only, after the dry run reads correctly):

```shell
TREASURY=0x... KEEPER=0x... OWNER=0x... \
  forge script script/Deploy.s.sol --rpc-url robinhood_mainnet \
  --keystores .secrets/<file> --broadcast -vvvv
```

Testnet:

```shell
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --keystores .secrets/<file> --broadcast -vv
```

## Notes

- Stock Tokens are BeaconProxies. `paused()` and `isBlocked(address)` are answered by the shared registry `0xe10b6f6B275de231345c20D14Ab812db62151b00`. Some tickers (AAPL among the launch five) have a non-1 ERC-8056 `uiMultiplier()`, so raw balances are not displayed shares; UIs must use `balanceOfUI` or scale by the multiplier.
- Never pass `--broadcast` from automation. Deploys are a human action.
