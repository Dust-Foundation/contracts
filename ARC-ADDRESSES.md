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

## Dust contracts (Arc) — LIVE, deployed 2026-09-18

Same bytecode as Robinhood Chain v3 (tag `audit-2026-09-v3`). Deploy blocks
21416559 to 21416560, deployer / interim owner / treasury
`0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b`. Tx hashes in
`broadcast/Deploy.s.sol/5042/run-latest.json`.

| contract | address |
|---|---|
| DustVault | `0x572557F8f96cbd1DB0560fE36bFdD674bC28493F` |
| DustRouter | `0x3E83593D9D3f0F29410209070688AD2eA38b0d16` |
| DustSweeper | `0xa14a1fC162b5B54402ec234EAE884258E4940492` |
| DustCapture | `0x7dFC4707017967b30c93D4dB69FA928852e7E825` |

- Keeper: `0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD` (same key as Robinhood Chain)
- Fee: 100 bps. Menu: cirBTC via `0x82916bee18fCEF517B26C72d7Cb5F13694E1dB41`.
- Verified after deploy: vault modules wired, keeper set, `poolFor(cirBTC)`
  resolves, `twapFloor` on the cirBTC pool answers (126,784 sats per 100 USDC
  at deploy).
- `NEXT_PUBLIC_ARC_DEPLOY_BLOCK=21416559`
- Ownership stays with the deployer until the multisig move (same as Robinhood).
- Address collision, by design of CREATE: the deployer's first four deploys on
  Arc landed on the same addresses as its first four on Robinhood Chain, which
  are the DEPRECATED v1 set there (see MAINNET-ADDRESSES.md). So
  `0xa14a...0492` is the live Arc sweeper AND the retired Robinhood v1
  sweeper. A wallet on the wrong network can therefore send a transaction
  that reaches a real, wrong contract instead of failing; the app gates every
  screen on the wallet's actual chain (v0.8.1) for this reason.
