# Dust on Arc mainnet (chain id 5042)

Verified on-chain 2026-09-17 against `https://rpc.mainnet.arc.io` and
`https://arc.drpc.org`. Arc facts that shape the deployment:

- USDC is the stable AND the gas token. The ERC-20 at
  `0x3600000000000000000000000000000000000000` reports 6 decimals; the same
  balance is the 18-decimal native balance (1 USDC = 1e6 units = 1e18 wei).
  Transfers route through a system contract at `0x1800...0000` and a protocol
  blocklist at `0x1800...0001`; `test/arc/ArcNativeMock.sol` stands in for
  both inside a Foundry fork.
- A native USDC payment emits one ordinary USDC `Transfer` log, so the
  keeper's outside-spend detection is unchanged.
- Base fee floor 20 gwei (transactions under it may never be mined), cap
  20,000 gwei. `eth_getLogs` serves about 2,000 blocks per call.
- No tokenized stocks exist on Arc yet (2026-09-17). USYC is Teller-minted,
  not swappable. EURC's pool is too thin for the menu. The launch menu is
  cirBTC only; add pairs with `listStock` as liquidity arrives.

## Chain infrastructure

| | address |
|---|---|
| USDC (stable, gas) | `0x3600000000000000000000000000000000000000` (6 dec as ERC-20) |
| Uniswap-v3-style factory | `0xf0db7b58379503491d857dB50AC9ece64c653918` (owner `0xbCA30b5429935205037069cF5b8A165F55d05a75`) |
| cirBTC (Circle Bitcoin) | `0x171A4217b86A807A64eB94757Db6849fb4bDbAA0` (8 decimals) |
| cirBTC/USDC 0.01% pool | `0x82916bee18fCEF517B26C72d7Cb5F13694E1dB41` (~6.6M USDC + 83 BTC, cardinality 600) |
| WETH (bridged) | `0x128cC466B61f542da60c70e3aA11c10e19B84EDB` (18 decimals) |
| WETH/USDC 0.05% pool | `0xE17939B09faf35CA3aDE4ab040dB955945134874` (empty, cardinality 1; deliberate) |
| EURC | `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` (6 dec), pool 0.05% `0x6fd5F2fb831940DcD61A98c5B3aCB7D8C6f3bFc1` (~8k, NOT listed) |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |
| Explorer | https://explorer.arc.io |

Not on Arc: a Stock Token issuer registry (keeper runs `DUST_REGISTRY=off`),
a verified QuoterV2 (keeper runs `DUST_QUOTER=off`; unused with USDC-only
capture).

## Design: same bytecode, USDC only

The four contracts are the audited v3 code (tag `audit-2026-09-v3`) with no
changes. `DustCapture` is constructed with Arc's bridged WETH and the empty
WETH/USDC pool so the constructor's checks pass; `test/arc/DustArcFork.t.sol`
shows the WETH and ETH-float paths fail closed there (no liquidity; the
bridged WETH has no payable deposit) and only `captureFor` (USDC allowance)
is live. The keeper is configured to never call the other two
(`DUST_CAPTURE_SOURCES=usdc`).

## Deploy

Dry run against a fork (no key needed):

```shell
DEPLOY_NETWORK=arc forge script script/Deploy.s.sol --rpc-url arc_mainnet \
  --sender 0x82916bee18fCEF517B26C72d7Cb5F13694E1dB41 --unlocked -vv
```

Real deploy (founder only; the deployer needs USDC on Arc for gas, about
8.3M gas at ~40 gwei = under $0.50):

```shell
TREASURY=0x... KEEPER=0x... OWNER=0x... DEPLOY_NETWORK=arc \
  forge script script/Deploy.s.sol --rpc-url arc_mainnet \
  --keystores .secrets/<file> --broadcast -vvvv
```

Then record the printed `DUST_*` addresses below, set them as Fly secrets on
`dust-keeper-arc` (see `keeper/fly.arc.toml`) and as `NEXT_PUBLIC_ARC_DUST_*`
on Vercel.

## Dust contracts (Arc)

Not deployed yet. Fill in from the deploy log:

| contract | address |
|---|---|
| DustVault | |
| DustRouter | |
| DustSweeper | |
| DustCapture | |

- Deploy block: (set `NEXT_PUBLIC_ARC_DEPLOY_BLOCK`)
- Menu: cirBTC via the pool above. Fee 100 bps.
