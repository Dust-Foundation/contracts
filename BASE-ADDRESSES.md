# Dust on Base mainnet (chain id 8453)

Verified on-chain 2026-09-19 (Base block ~51,526,400) via `cast` against
`https://base-rpc.publicnode.com`. Base facts that shape the deployment:

- Gas is ETH; USDC (`0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, 6 dec) is the stable.
- Coinbase's tokenized stocks ("cbStocks", launched 2026-08-24, custodied via
  Alpaca under ADGM) are **B20 precompiles**: one byte of code (`0xef`), the
  token logic lives in the Base node. They expose a full ERC-20 surface plus
  `multiplier()` (WAD share multiplier; GOOGLc is already 1.000377 after a
  dividend) and `scaledBalanceOf`. Transfer policy is a **blocklist** (policy id 5
  on every scope): arbitrary contracts can receive and hold them today, and a
  simulated transfer from a pool to Multicall3 and to the Slipstream router
  succeeds. The issuer can block an address (transfers then revert with
  `PolicyForbids`), burn a blocked balance, or pause transfers. Eligibility is
  non-US, Regulation S. Same risk class as Robinhood's Stock Token registry.
- **Foundry cannot execute the precompiles**: `test/base/DustBaseFork.t.sol`
  etches a plain 8-decimal ERC-20 stand-in at each cbStock address and seeds the
  pool balances; AERO, WETH, USDC and every Slipstream pool are real.
- Liquidity for cbStocks lives on **Aerodrome Slipstream**, all on the current
  CLFactory at tick spacing 10, fee 500 (0.05%), 20 to 300x deeper than the
  best Uniswap v3 pool per stock. Slipstream fees are dynamic (the WETH/USDC
  pool read 639, 684 and 624 within a day): never cache a fee.
- Public RPC `mainnet.base.org` caps `eth_getLogs` at 2,000 blocks and rate
  limits around 5 requests/s; the keeper and the app use Alchemy.

## Why the contracts are unchanged: SlipstreamFactoryAdapter

The Dust contracts verify a pool with one call, `factory.getPool(t0, t1, pool.fee()) == pool`,
and never read `pool.factory()`. Slipstream keys pools by tick spacing and its
fee is dynamic, so `src/SlipstreamFactoryAdapter.sol` answers that call by
walking a fixed (factory, tickSpacing) list and returning the first canonical
pool whose live fee matches. No owner, no setters. The four core contracts are
the audited v3 bytecode. The adapter is new code (about 40 lines) and is the
only thing a follow-up audit needs to read.

Slot order (decides ties when two tick spacings carry the same fee):

| # | factory | tickSpacing | why here |
|---|---|---|---|
| 0 | legacy `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | 100 | deep AERO/USDC and WETH/USDC pools; no cbStock pair exists on this factory. A thin ts-10 AERO pool on the current factory (liquidity 0) would otherwise shadow the deep one for the same 0.05% fee |
| 1 | current `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | 10 | every cbStock/USDC pool |
| 2 | current | 50 | |
| 3 | legacy | 2000 | AERO 1% pool |
| 4-7 | current | 1, 100, 200, 2000 | |
| 8-10 | legacy | 1, 50, 200 | |
| 11-12 | mid `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` | 100, 200 | |

`legacyCLFactory()` on both newer factories returns the original `0x5e7B...`;
the Slipstream SwapRouter `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` and
QuoterV2 `0x514c8B5f54112481E28028F1166Bd78501089259` both report
`factory() = 0xf8f2...` and route legacy pools transparently. The keeper's spot
cross-check uses that QuoterV2 with `DUST_QUOTER_KIND=slipstream` (int24
tickSpacing in the params struct).

## Assets and pools (launch menu)

| asset | token | decimals | pool (USDC pair) | factory / ts / fee | USDC in pool | oracle cardinality |
|---|---|---|---|---|---|---|
| NVDAc | `0xb20000000000000000000078ee7ce2fE4908108C` | 8 | `0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9` | current / 10 / 500 | 1,476,505 | 2048 |
| AAPLc | `0xb200000000000000000000C2e324d24d7eEcd1fb` | 8 | `0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0` | current / 10 / 500 | 1,097,723 | 2048 |
| METAc | `0xb2000000000000000000008bC8786B856E61707C` | 8 | `0xEAF57753BC382E0324a1D43F72E7027705a2273E` | current / 10 / 500 | 1,120,857 | 2048 |
| GOOGLc | `0xb2000000000000000000002D0BA3164cc74f58B7` | 8 | `0xB1987CAD1682841b4b641d50E520777eC5Ab5542` | current / 10 / 500 | 1,249,044 | 2048 |
| AERO | `0x940181a94A35A4569E4529A3CDfB74e38FD98631` | 18 | `0xa4FDd479eda160671636e2eCF8f993Cbf86258a8` | legacy / 100 / 500 | 244,312 | 360 |
| WETH (capture) | `0x4200000000000000000000000000000000000006` | 18 | `0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59` | legacy / 100 / dynamic | 7,369,777 | 3010 |

Listable later with one `listStock` each (all current factory, ts 10, fee 500,
cardinality in brackets): AMZNc `0xb200000000000000000000d9192b6B456483C2E8` pool
`0xd03Bc8C7F2FAedCe2aac81bF0444AEA08Ea06E9b` (360); MSFTc `0xB200000000000000000000Ab99cFa739E253872B`
pool `0x7103eB3c9590d1281f7dc03b2A9EE27C39dF5D54` (360); TSLAc `0xb2000000000000000000001e800a7f5189430cD0`
pool `0x469337fDcc5E8f38e2E4B670B04F57865D13a7BB` (360); MSTRc `0xb2000000000000000000004884b426556b92883d`
pool `0x8b27f626ab668197000BC722A1012022CAeD10E2` (1000); SNDKc `0xb200000000000000000000397293Cb8cda9a10c5`
pool `0x5A8236f575471e7BfCA2C8462a200c28f737246E` (1000); SPCXc `0xb2000000000000000000007b9fcbd005511aCBd5`
pool `0x0bf58fe0FAc935Ac69595c19B12Ba0d75E3F8c0E` (360). The 360-cardinality
pools cover about 12 minutes of 2-second blocks; call
`increaseObservationCardinalityNext` before relying on them.

## Deploy

Dry run against a fork (no key):

```shell
DEPLOY_NETWORK=base forge script script/Deploy.s.sol --rpc-url base_mainnet \
  --sender 0x4200000000000000000000000000000000000006 --unlocked -vv
```

Real deploy (founder only; the deployer needs ETH on Base, about 9M gas at
sub-gwei prices plus L1 data fees, well under $2):

```shell
TREASURY=0x... KEEPER=0x... DEPLOY_NETWORK=base \
  forge script script/Deploy.s.sol --rpc-url <alchemy base url> \
  --keystores .secrets/<file> --sender <deployer> --broadcast -vvvv
```

The script deploys the adapter first (or reuses `FACTORY` if set), checks it
resolves every menu pool and the WETH pool, then deploys the four core
contracts, lists the menu and sets the keeper.

## Dust contracts (Base) — LIVE, deployed 2026-09-19

Block 51527574, 12 transactions, deployer / interim owner / treasury
`0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b`. Tx hashes in
`broadcast/Deploy.s.sol/8453/run-latest.json`.

| contract | address |
|---|---|
| SlipstreamFactoryAdapter | `0x572557F8f96cbd1DB0560fE36bFdD674bC28493F` |
| DustVault | `0x3E83593D9D3f0F29410209070688AD2eA38b0d16` |
| DustRouter | `0xa14a1fC162b5B54402ec234EAE884258E4940492` |
| DustSweeper | `0x2DAfa662dF120D505d2D6aDa6f934584C012e2eD` |
| DustCapture | `0x9DacF353fFa758EE8f2bE682b53fEe75a94e05F1` |

- Keeper: `0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD` (same key as the other chains)
- Fee 100 bps. Menu: NVDAc, AAPLc, METAc, GOOGLc, AERO via the pools above.
- `NEXT_PUBLIC_BASE_DEPLOY_BLOCK=51527574`
- Address collision by CREATE, as on Arc: the deployer's nonces 0..3 here
  produced the same addresses as Arc's adapter-less set, so the Base
  ADAPTER is Arc's vault address, the Base VAULT is Arc's router, and the Base
  ROUTER is Arc's sweeper (and Robinhood's retired v1 sweeper). The app gates
  every screen on the wallet's actual chain; never rely on an address alone.
