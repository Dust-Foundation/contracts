# Dust on Robinhood Chain mainnet: deploy runbook

> **Redeploying?** The v1 set this file deployed on 2026-09-03 is deprecated.
> For the fresh deploy with DustCapture v2 (USDG, WETH or ETH-float funding)
> and the keeper and app repoint, follow `MAINNET-REDEPLOY.md`. It reuses the
> command shapes, keystore names and env var names from this file, so this
> file stays the reference for the background and the first-time setup steps
> (keys, bridge routes, multisig, RPC, Fly app, Vercel project).

The founder's step-by-step path from the current repo state to a live, capped
beta on Robinhood Chain mainnet (chain id 4663). Every command is meant to be
run in order, from the repo root of the repo it names (`contracts/`, `keeper/`,
`app/`). Nothing in this file has been run by automation; the real deploy is a
human action.

Conventions:

- **[FOUNDER]** marks a step that needs keys, money, or an account. Nobody and
  nothing else does these.
- Every address below comes from `MAINNET-ADDRESSES.md`. Do not type an address
  from memory; copy it from there. When this runbook creates new addresses
  (the four Dust contracts), it tells you to write them back into that file.
- Paths are relative. Secrets live in `.secrets/` (gitignored) or in the host's
  secret store, never in a tracked file.
- Anonymity applies to every account touched here: Alchemy, Fly, Vercel and
  the multisig signers are project accounts, not personal ones. Check
  `git config user.name` prints `Dust` before any commit.
- No `--broadcast` from automation. No CI job ever holds a key.

Cost picture (ETH is the gas token; observed gas price 0.3 to 0.6 gwei on
2026-09-03, with a floor around 0.02 gwei):

| item | gas (measured) | ETH at 0.5 gwei |
|---|---|---|
| full deploy: 4 contracts + 5 `listStock` + `setModules` + `setKeeper` + `transferOwnership` | ~4.77M (mainnet dry run) | ~0.0024 |
| one 2-leg sweep | ~460k (local fork) | ~0.00023 |
| one 5-leg sweep | ~1.0M (estimate from the 2-leg figure) | ~0.0005 |
| one `captureFor` | ~87k | ~0.00004 |
| `acceptOwnership` through a Safe | ~120k | ~0.00006 |

Funding plan (all in ETH on chain 4663): deployer 0.03, keeper 0.05, smoke-test
wallet 0.005 plus about 20 USDG, each multisig signer 0.01. Roughly 0.1 ETH
funded, of which about 0.01 is actually spent by the end of section E. Gas
spikes on an Orbit chain follow Ethereum L1 fees, hence the 10x margins.

Note the per-sweep cost against the round-up sizes: a 5-leg sweep at 0.5 gwei
costs about 0.0005 ETH, which is around 2 USDG at current prices. Set
`minSweepAmount` (on-chain) and `DUST_MIN_SWEEP` (keeper) so a sweep only fires
once the accrued amount makes the gas worth it. Section B6 has the command.

---

## A. Before deploy

### A0. Repo state is green

From `contracts/`:

```bash
forge build
forge test
FOUNDRY_FORK_RETRIES=5 FOUNDRY_FORK_RETRY_BACKOFF=2000 forge test --match-contract DustMainnetFork -vv
```

Expect the default run to report 52 passed, 0 failed, 1 skipped, and the
mainnet fork suite 9 passed, 1 skipped. If a fork suite skips because the public
RPC is unreachable, retry; never proceed on a red suite.

From `keeper/`:

```bash
npm install
node --check index.mjs && node --check quote.mjs
```

From `app/`:

```bash
npm install
npx tsc --noEmit
npm run build
```

Check the working trees are clean (or contain only changes you have reviewed):

```bash
git -C contracts status --short
git -C keeper status --short
git -C app status --short
```

### A1. [FOUNDER] Create a dedicated deployer key

Never reuse a key from testnet, from Solana, or from a personal wallet. The
deployer becomes the vault's constructor `owner` (which has no powers after
`setModules`) and the sweeper's initial owner (handed to the multisig in B6).

From `contracts/`:

```bash
mkdir -p .secrets
cast wallet new .secrets deployer
```

It asks for a keystore password, writes the encrypted keystore to
`.secrets/deployer`, and prints the new address. Store the password in the
project password manager. Then:

```bash
export DEPLOYER=0x<address printed above>
export DEPLOYER_KEYSTORE=.secrets/deployer
cast wallet address --keystore "$DEPLOYER_KEYSTORE"     # must print $DEPLOYER
```

### A2. [FOUNDER] Fund the deployer with ETH on chain 4663

Target 0.03 ETH. Ways in, from the official bridging page
(https://docs.robinhood.com/chain/bridging/):

- Canonical Arbitrum bridge from Ethereum, about 10 minutes:
  https://portal.arbitrum.io/bridge?destinationChain=robinhood-chain&sourceChain=ethereum
- Faster third-party routes named in the same docs: Relay
  (https://relay.link/bridge/robinhood), Across (https://across.to/?to=robinhood),
  Stargate, Transporter (Chainlink CCIP), LI.FI.

Send to `$DEPLOYER`. Confirm:

```bash
cast balance "$DEPLOYER" --rpc-url robinhood_mainnet --ether
```

### A3. [FOUNDER] Create and fund the keeper hot key

A second fresh key. It can only call `sweep()` and `captureFor()`, both bounded
by the contracts, and is rotated with `setKeeper` if it ever leaks. It is the
only key that will ever sit on a server.

```bash
cast wallet new
```

This prints an address and a private key to the terminal. Put the private key
straight into the project password manager (you paste it into `flyctl secrets
set` in C3). Do not write it to any file in a repo directory.

```bash
export KEEPER=0x<keeper address>
```

Fund `$KEEPER` with 0.05 ETH using the same bridge route as A2, then confirm
with `cast balance "$KEEPER" --rpc-url robinhood_mainnet --ether`.

### A4. [FOUNDER] Decide the treasury address

The fee recipient. Not the deployer, not the keeper. Recommended: the protocol
multisig from A5, or a separate cold address. If you have not decided by deploy
time, leave `TREASURY` unset: the fee stays disabled until the owner calls
`setTreasury` (B6).

```bash
export TREASURY=0x<treasury address>
```

### A5. [FOUNDER] Create the owner multisig

The sweeper owner's whole power set is: list/delist stocks, set fee (5% code
ceiling), set keeper, set minimum sweep, set treasury, pause new sweeps. No
power over user funds. It still must not be one key.

Safe's canonical contracts are present on chain 4663 (read-only `eth_getCode`
plus `VERSION()` on 2026-09-03): SafeL2 1.4.1 at
`0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`, Safe 1.4.1 at
`0x41675C099F32341bf84BFc5382aF534df5C7461a`, SafeProxyFactory 1.4.1 at
`0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`, GnosisSafeL2 1.3.0 at
`0x3E5c63644E683549055b9Be8653de26E0B4CD36E`. Cross-check these against the
`safe-global/safe-deployments` repository before relying on them; they are the
canonical addresses and match the deployed bytecode versions, but this runbook
only verified that code and version strings are there.

1. Open https://app.safe.global and look for Robinhood Chain in the network
   picker. Whether the hosted UI lists chain 4663 could not be confirmed by
   script (the chain list API is bot-gated); check it in a browser.
2. If it is listed: create a 2-of-3 Safe with three signers, each a hardware
   wallet under the project identity, each pre-funded with 0.01 ETH. Send one
   0 ETH self-transaction through the Safe first to prove execution works on
   this chain.
3. If it is not listed: either deploy the Safe with the Safe CLI / protocol-kit
   against the 1.4.1 factory above (custom network: chain id 4663, RPC from A6,
   explorer https://robinhoodchain.blockscout.com), or take the interim path.
4. Interim path (only if a Safe is not workable on launch day): `OWNER` is a
   dedicated hardware-wallet EOA that is not the deployer, disclosed publicly
   as interim, with a dated commitment to hand over to a multisig. The fee and
   menu stay frozen until the handover. User funds are never exposed to this
   key either way.

```bash
export OWNER=0x<multisig address>
```

### A6. [FOUNDER] Provision a paid RPC with two keys

The public RPC returns HTTP 429 on bursts, caps `eth_getLogs` at 10k results,
and keeps state for only the last 10 to 17 minutes. It is fine for `forge`
dry runs and fork tests and nothing else.

Create an Alchemy app on the `robinhood-mainnet` network (the provider the
official docs recommend) and make two API keys:

- **keeper key**: server-side only, goes into Fly secrets in C3.
- **frontend key**: ships inside the Vercel bundle as `NEXT_PUBLIC_EVM_RPC`, so
  set Alchemy's allowed-domains rule to your app domain and keep the request
  cap modest.

URL shape: `https://robinhood-mainnet.g.alchemy.com/v2/<key>`.

```bash
export DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>"
cast chain-id --rpc-url "$DUST_RPC"         # must print 4663
```

Use `$DUST_RPC` (not the public alias) for the broadcast in B3 and for every
`cast send` below; the public node drops bursts.

### A7. [FOUNDER] Prepare a smoke-test wallet

A fresh browser wallet (Rabby or MetaMask) with Robinhood Chain added as a
custom network: chain id 4663, RPC `https://rpc.mainnet.chain.robinhood.com`
(or your frontend Alchemy URL), currency ETH, explorer
`https://robinhoodchain.blockscout.com`. Fund it with 0.005 ETH and about 20
USDG (`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`). USDG can be bought with
ETH on Uniswap on Robinhood Chain (the USDG/WETH 0.01% pool
`0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca` is the deepest) or bridged in
through Stargate. Only ever hold amounts here you are happy to lose.

```bash
export TEST_USER=0x<smoke test wallet>
```

---

## B. Deploy

All from `contracts/`. Keep the shell from section A (the exported vars).

### B1. Set the deploy environment

```bash
export FEE_BPS=100          # 1%; code ceiling is 500
# MENU_TOKENS / MENU_POOLS default to the five verified launch pairs; leave unset.
env | grep -E '^(STABLE|TREASURY|KEEPER|OWNER|FEE_BPS|MENU_TOKENS|MENU_POOLS)=' 
```

Read the printed values against `MAINNET-ADDRESSES.md` and your notes from A3
to A5 one more time. `OWNER` unset means the deployer keeps ownership and the
script says so loudly; only do that on purpose (interim path in A5).

### B2. Dry run (no transaction is sent)

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_mainnet -vvvv
```

Check the log, in this order:

- `chain id: 4663` and `path: MAINNET`
- `deployer:` equals `$DEPLOYER`; `STABLE:` is USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
- `stable decimals: 6 -> unit 1000000`
- the five `menu[i] token ... pool ...` lines match the launch table below
- `TREASURY`, `KEEPER`, `OWNER`, `FEE_BPS` are what you exported
- no `WARNING:` lines unless you intend them
- `ownership transfer STARTED to <OWNER>`
- `SIMULATION COMPLETE` and an estimated gas near 4.8M

Launch menu (token, USDG pool):

| symbol | Stock Token | pool | fee tier |
|---|---|---|---|
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` | `0xf4ACdAEEB7022862A763C9B1B885e11191c889E3` | 0.3% |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3` | 0.05% |
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` | `0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D` | 0.05% |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` | `0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef` | 0.3% |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` | `0xa7Bb1AC63BBaB0C44316E6c8C455213441689167` | 0.05% |

If anything is off, fix the env and rerun the dry run. Do not continue on a
dry run you have not read.

### B3. [FOUNDER] Broadcast

Same script, same env, plus the keystore and `--broadcast`. `--slow` sends one
transaction at a time and waits for each receipt, which is what you want on
this sequencer.

```bash
forge script script/Deploy.s.sol \
  --rpc-url "$DUST_RPC" \
  --keystore "$DEPLOYER_KEYSTORE" --sender "$DEPLOYER" \
  --slow --broadcast -vvvv
```

Enter the keystore password when asked. Expect 11 or 12 transactions (4
creates, 5 `listStock`, `setModules`, then `setKeeper` and
`transferOwnership` when `KEEPER`/`OWNER` differ from the deployer). If the
run stops midway (a 429 or a dropped tx), rerun the same command with
`--resume` appended; forge continues from the broadcast log.

### B4. Read the addresses and verify the wiring

```bash
jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractName)=\(.contractAddress)"' \
  broadcast/Deploy.s.sol/4663/run-latest.json
jq -r '.receipts[] | "\(.transactionHash) block \(.blockNumber) gasUsed \(.gasUsed)"' \
  broadcast/Deploy.s.sol/4663/run-latest.json
```

Export them (the console log also printed them as `DUST_VAULT=` etc.):

```bash
export DUST_VAULT=0x...
export DUST_ROUTER=0x...
export DUST_SWEEPER=0x...
export DUST_CAPTURE=0x...
```

Read-only checks (each must match):

```bash
R=robinhood_mainnet
cast call $DUST_SWEEPER "owner()(address)"        --rpc-url $R   # $DEPLOYER until B6
cast call $DUST_SWEEPER "pendingOwner()(address)" --rpc-url $R   # $OWNER
cast call $DUST_SWEEPER "keeper()(address)"       --rpc-url $R   # $KEEPER
cast call $DUST_SWEEPER "treasury()(address)"     --rpc-url $R   # $TREASURY or 0x0
cast call $DUST_SWEEPER "feeBps()(uint16)"        --rpc-url $R   # 100
cast call $DUST_SWEEPER "paused()(bool)"          --rpc-url $R   # false
cast call $DUST_SWEEPER "menuLength()(uint256)"   --rpc-url $R   # 5
cast call $DUST_SWEEPER "poolFor(address)(address)" 0x322F0929c4625eD5bAd873c95208D54E1c003b2d --rpc-url $R  # TSLA pool 0xf4AC...
cast call $DUST_SWEEPER "stable()(address)"       --rpc-url $R   # USDG
cast call $DUST_VAULT   "router()(address)"       --rpc-url $R   # $DUST_ROUTER
cast call $DUST_VAULT   "sweeper()(address)"      --rpc-url $R   # $DUST_SWEEPER
cast call $DUST_VAULT   "capture()(address)"      --rpc-url $R   # $DUST_CAPTURE
cast call $DUST_ROUTER  "unit()(uint256)"         --rpc-url $R   # 1000000
```

Then record everything in `MAINNET-ADDRESSES.md` under a new heading
`## Dust contracts (deployed <date>)`: the four addresses, the deployer, the
deploy block, and the tx hashes. Before committing `broadcast/`, scan it:

```bash
grep -rnE "/Users/|/home/|@" broadcast/Deploy.s.sol/4663/ && echo "LEAK: fix before commit" || echo clean
```

### B5. Verify source on Blockscout

Constructor args, encoded:

```bash
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
ARGS_VAULT=$(cast abi-encode "constructor(address)" $USDG)
ARGS_ROUTER=$(cast abi-encode "constructor(address,address,uint256)" $USDG $DUST_VAULT 1000000)
ARGS_SWEEPER=$(cast abi-encode "constructor(address,address,address)" $USDG $DUST_VAULT ${TREASURY:-0x0000000000000000000000000000000000000000})
ARGS_CAPTURE=$(cast abi-encode "constructor(address,address,address)" $USDG $DUST_VAULT $DUST_SWEEPER)
```

Use the exact `TREASURY` value the deploy used (zero address if it was unset).
Compiler settings (`via_ir`, optimizer, 200 runs, solc from
`jq -r .metadata.compiler.version out/DustVault.sol/DustVault.json`) are read
from `foundry.toml` automatically.

```bash
V="--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --chain 4663 --watch"
forge verify-contract $DUST_VAULT   src/DustVault.sol:DustVault     --constructor-args $ARGS_VAULT   $V
forge verify-contract $DUST_ROUTER  src/DustRouter.sol:DustRouter   --constructor-args $ARGS_ROUTER  $V
forge verify-contract $DUST_SWEEPER src/DustSweeper.sol:DustSweeper --constructor-args $ARGS_SWEEPER $V
forge verify-contract $DUST_CAPTURE src/DustCapture.sol:DustCapture --constructor-args $ARGS_CAPTURE $V
```

The Blockscout API sits behind a Cloudflare challenge for scripted clients, so
these may fail with an HTML page or a 403 instead of a JSON result. Fallback:
generate the standard JSON input and upload it by hand in the browser.

```bash
mkdir -p .verify
forge verify-contract $DUST_VAULT   src/DustVault.sol:DustVault     --constructor-args $ARGS_VAULT   --show-standard-json-input > .verify/DustVault.json
forge verify-contract $DUST_ROUTER  src/DustRouter.sol:DustRouter   --constructor-args $ARGS_ROUTER  --show-standard-json-input > .verify/DustRouter.json
forge verify-contract $DUST_SWEEPER src/DustSweeper.sol:DustSweeper --constructor-args $ARGS_SWEEPER --show-standard-json-input > .verify/DustSweeper.json
forge verify-contract $DUST_CAPTURE src/DustCapture.sol:DustCapture --constructor-args $ARGS_CAPTURE --show-standard-json-input > .verify/DustCapture.json
grep -l "/Users/\|/home/" .verify/*.json && echo "LEAK: strip absolute paths before upload" || echo clean
```

Then open `https://robinhoodchain.blockscout.com/address/<contract>/contract-verification`
for each address, choose "Solidity (Standard JSON input)", set the compiler
version from the `jq` command above, upload the file, and paste the matching
`ARGS_*` hex as constructor arguments. A third option is
`--verifier sourcify` (Blockscout imports Sourcify matches when the chain is
supported there). Do not commit `.verify/`.

### B6. [FOUNDER] Post-deploy admin

Skip any call whose value the script already set (B4 tells you). Each `cast
send` signs with the deployer keystore because the deployer is still owner
until `acceptOwnership` runs.

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
# only if KEEPER was not in the deploy env
cast send $DUST_SWEEPER "setKeeper(address)" $KEEPER $S
# only if TREASURY was not in the deploy env (fee stays off until this is set)
cast send $DUST_SWEEPER "setTreasury(address)" $TREASURY $S
# minimum accrued before a sweep may run, in USDG base units (6 decimals). Decide the
# number against the per-sweep gas in the cost table; 5 USDG shown.
cast send $DUST_SWEEPER "setMinSweepAmount(uint256)" 5000000 $S
# only if OWNER was not in the deploy env
cast send $DUST_SWEEPER "transferOwnership(address)" $OWNER $S
```

Now the multisig accepts. In the Safe UI: New transaction, Contract
interaction, address `$DUST_SWEEPER`, paste this ABI and pick `acceptOwnership`:

```json
[{"type":"function","name":"acceptOwnership","inputs":[],"outputs":[],"stateMutability":"nonpayable"}]
```

Or use raw data: `cast calldata "acceptOwnership()"` prints `0x79ba5097`;
send it to `$DUST_SWEEPER` with value 0 from the Safe. Collect the signatures,
execute, then confirm:

```bash
cast call $DUST_SWEEPER "owner()(address)"        --rpc-url robinhood_mainnet   # $OWNER
cast call $DUST_SWEEPER "pendingOwner()(address)" --rpc-url robinhood_mainnet   # 0x000...000
```

From here the deployer key has no powers anywhere. Keep the keystore offline
(you still want it for nothing but forensics); never fund it again.

### B7. [FOUNDER] Commit the address book

```bash
cd contracts
git config user.name && git config user.email     # must be the pseudonymous project identity
git diff --stat
git add MAINNET-ADDRESSES.md broadcast/Deploy.s.sol/4663/
git commit -m "mainnet: deploy Dust on Robinhood Chain 4663"
```

Push only after the usual account check.

---

## C. Keeper

All from `keeper/`.

### C1. [FOUNDER] Dry run locally against the live contracts

```bash
cp .env.example .env
```

Fill in `DUST_RPC` (keeper Alchemy URL), `DUST_KEEPER_PK`, and the four
`DUST_*` contract addresses from B4. Leave the chain defaults. Then:

```bash
set -a; source .env; set +a
npm run dry
```

Read the startup lines: chain id 4663 confirmed, every `eth_getCode` check
passed, `decimals 6`, and `keeperAuthorized: true` (if it says false,
`setKeeper` in B6 did not point at this key). With no users yet the tick
simply scans and exits. Delete the local `.env` when done, or keep it only if
`.gitignore` covers it (it does).

### C2. [FOUNDER] Fly app

```bash
curl -L https://fly.io/install.sh | sh          # once
flyctl auth login                                # once, project account
flyctl launch --no-deploy --copy-config          # keeps the checked-in fly.toml: app dust-keeper-evm, region iad
flyctl volumes create keeper_data --size 1 --region iad
```

If the name `dust-keeper-evm` is taken, `flyctl launch` proposes another;
accept it and note it, the health URL in C4 uses it.

### C3. [FOUNDER] Secrets, then deploy in dry-run mode

Set every secret before the first deploy so the machine never boots
half-configured. Start with `DUST_DRY_RUN=1` so the first live process only
logs what it would do.

```bash
flyctl secrets set --stage \
  DUST_KEEPER_PK="0x<keeper private key from A3>" \
  DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>" \
  DUST_SWEEPER="$DUST_SWEEPER" DUST_VAULT="$DUST_VAULT" \
  DUST_ROUTER="$DUST_ROUTER" DUST_CAPTURE="$DUST_CAPTURE" \
  DUST_MIN_SWEEP=5000000 \
  DUST_DRY_RUN=1
flyctl deploy
flyctl scale count 1
flyctl status
flyctl logs
```

`--stage` holds the secrets until `flyctl deploy` so they land in one release.
The image build runs on Fly's builders (Docker is not required locally).

### C4. Health check

```bash
curl -s https://dust-keeper-evm.fly.dev/ | jq
```

Expect HTTP 200, `ok: true`, `keeperAuthorized: true`, `ethBalance` near
0.05, `lowGas: false`, `rpc` with the key redacted, and `ticks` increasing
across two calls a minute apart. A 503 means no tick has completed in three
intervals: read `flyctl logs`.

### C5. [FOUNDER] Go live

After the smoke test's first round-up exists (E2), watch one dry-run tick log
the exact `[dry-run] would send sweep(...)` line with sane `minOuts`, then:

```bash
flyctl secrets unset DUST_DRY_RUN
flyctl logs
```

Unsetting a secret redeploys the machine. State on the volume survives, so the
scan does not restart.

---

## D. App

All from `app/`. The Solana side keeps its existing variables; the EVM side
adds these.

### D1. [FOUNDER] Vercel environment

In the Vercel project (Settings, Environment Variables, scope Production), add:

```
NEXT_PUBLIC_EVM_ENABLED = true
NEXT_PUBLIC_EVM_NETWORK = mainnet
NEXT_PUBLIC_EVM_RPC     = https://robinhood-mainnet.g.alchemy.com/v2/<frontend-key>
NEXT_PUBLIC_DUST_VAULT   = <from B4>
NEXT_PUBLIC_DUST_ROUTER  = <from B4>
NEXT_PUBLIC_DUST_SWEEPER = <from B4>
NEXT_PUBLIC_DUST_CAPTURE = <from B4>
```

Or from the CLI, one at a time (each prompts for the value):

```bash
for v in NEXT_PUBLIC_EVM_ENABLED NEXT_PUBLIC_EVM_NETWORK NEXT_PUBLIC_EVM_RPC \
         NEXT_PUBLIC_DUST_VAULT NEXT_PUBLIC_DUST_ROUTER NEXT_PUBLIC_DUST_SWEEPER NEXT_PUBLIC_DUST_CAPTURE; do
  npx vercel env add $v production
done
```

The frontend key ships to every browser; that is why it is the domain-locked
key from A6 and never the keeper's.

### D2. Copy check before the build

Robinhood's trademark terms forbid "tokenized stocks"; the product term is
"Stock Tokens". Two known leftovers are outside the files this pass touched:

```bash
grep -rn --include=*.tsx --include=*.ts -iE "tokenized" src/ 
```

Fix each hit (`src/app/page.tsx` and the Solana onboarding copy), then a final
sweep for words that must never appear in user-facing text:

```bash
grep -rn --include=*.tsx --include=*.ts -iE "airdrop|points program|\btoken launch\b" src/ && echo "REMOVE before deploy" || echo clean
```

### D3. Local production build with the mainnet env

```bash
cp .env.example .env.local     # fill NEXT_PUBLIC_EVM_ENABLED=true, NEXT_PUBLIC_EVM_RPC and the four NEXT_PUBLIC_DUST_* values
npm run build && npm run start   # http://localhost:4311
```

Open it, dismiss the Solana guide, click the Robinhood tab (it must be
selectable, no SOON badge), connect the smoke-test wallet on chain 4663. The
menu should list TSLA, NVDA, AAPL, AMZN, SPY with logos and no
"being set up" card. Stop the server.

### D4. [FOUNDER] Deploy to Vercel with git metadata hidden

The Vercel CLI attaches git author metadata to a deployment. Hide `.git` for
the duration of the deploy so nothing but the project identity leaves the
machine:

```bash
cd app && mv .git /tmp/dust-git.bak && npx vercel --prod ; mv /tmp/dust-git.bak .git
ls -d .git    # must print .git; if it does not, the mv back failed: fix before anything else
```

`npx vercel login` first if this machine has not logged in (project account).
Then open the production URL and repeat the D3 checks against the live site.

---

## E. Smoke test with tiny real money

Use `$TEST_USER` from A7 in the browser, and `cast` for the on-chain checks.
Every `cast call` below is read-only. Keep the keeper in dry-run until E2.

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
TSLA=0x322F0929c4625eD5bAd873c95208D54E1c003b2d
NVDA=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC
```

### E0. Baseline

```bash
cast call $DUST_SWEEPER "paused()(bool)"          --rpc-url $R   # false
cast call $DUST_SWEEPER "keeper()(address)"       --rpc-url $R   # $KEEPER
cast call $DUST_SWEEPER "minSweepAmount()(uint256)" --rpc-url $R
cast call $USDG "balanceOf(address)(uint256)" $TEST_USER --rpc-url $R   # ~20 USDG = 20000000
cast call $USDG "balanceOf(address)(uint256)" $TREASURY  --rpc-url $R   # note it
```

For the smoke test, if `minSweepAmount` is above what a couple of round-ups
produce, the owner can lower it temporarily (`setMinSweepAmount` from the
multisig) and restore it in E6.

### E1. [FOUNDER] Set a basket

In the app, Basket: TSLA 50%, NVDA 50% (two legs keep sweep gas low). Sign.

```bash
cast call $DUST_SWEEPER "basketLengthOf(address)(uint256)" $TEST_USER --rpc-url $R   # 2
cast call $DUST_SWEEPER "basketNonce(address)(uint256)"    $TEST_USER --rpc-url $R   # 1
```

### E2. [FOUNDER] Make a round-up

In the app, Swap: buy NVDA with 2.58 USDG, round-up to the next dollar
(granularity 1, multiplier 1), default 1% slippage. The app quotes a TWAP
`minOut`; the wallet asks for an approval and then the swap. Sign both.

```bash
cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R   # 420000 (0.42 USDG)
cast call $NVDA "balanceOf(address)(uint256)" $TEST_USER --rpc-url $R              # > 0, NVDA landed in the wallet
```

Repeat with 1.30 USDG of TSLA if you want accrued above `minSweepAmount`
(adds 0.70, total 1.12 USDG). On Blockscout the router tx shows a
`SwapWithRoundUp` event and a USDG transfer to the vault.

Now flip the keeper live (C5).

### E3. Watch the keeper sweep

Within two ticks (`DUST_INTERVAL_MS` is 60s) `flyctl logs` shows the
pre-flight lines (registry not paused, liquidity ok, TWAP ok, quoter within
band), then `sweep ... sent` and `included`. Then:

```bash
cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R          # 0
cast call $DUST_VAULT "tokenBalance(address,address)(uint256)" $TEST_USER $TSLA --rpc-url $R   # > 0 (raw 18-dec)
cast call $DUST_VAULT "tokenBalance(address,address)(uint256)" $TEST_USER $NVDA --rpc-url $R   # > 0
cast call $DUST_VAULT "costBasis(address)(uint256)" $TEST_USER --rpc-url $R              # accrued minus 1% fee, e.g. 1108800 for 1.12 USDG
cast call $USDG "balanceOf(address)(uint256)" $TREASURY --rpc-url $R                     # baseline + 1% of the sweep
curl -s https://dust-keeper-evm.fly.dev/ | jq '{txSent,txIncluded,txDropped,txReverted,lastError}'
```

On Blockscout, the sweep tx carries `Swept`, two `LegBought`, one
`FeeCharged`, and no `LegSkipped`. The app's Vault card shows both holdings
in shares (ERC-8056 display; AAPL would differ from raw, TSLA and NVDA do
not).

### E4. [FOUNDER] Capture everywhere (optional but recommended)

In the app, Capture: set a weekly cap of 5 USDG and approve DustCapture.
Then, from the same wallet but outside the app, send 1.30 USDG to any other
address you control. Within two ticks the keeper logs `captureFor(user,
700000)` and:

```bash
cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R   # 700000, then 0 after the next sweep
cast call $DUST_CAPTURE "remainingThisWeek(address)(uint256)" $TEST_USER --rpc-url $R   # 4300000
```

### E5. [FOUNDER] Withdraw in kind

In the app, Withdraw: all TSLA to the wallet. Sign.

```bash
cast call $DUST_VAULT "tokenBalance(address,address)(uint256)" $TEST_USER $TSLA --rpc-url $R   # 0
cast call $TSLA "balanceOf(address)(uint256)" $TEST_USER --rpc-url $R                          # the withdrawn amount
```

The tx shows a `TokensWithdrawn` event. This is the invariant that matters:
Stock Tokens bought by a sweep leave the vault to the user on demand, with no
signature from anyone else.

### E6. [FOUNDER] Pause drill (multisig)

From the Safe: `setPaused(bool)` with `true` (calldata
`cast calldata "setPaused(bool)" true`). Confirm the keeper logs skip with
"sweeper paused", then withdraw remaining NVDA in the app: it must succeed
while paused. Then `setPaused(false)` and restore `minSweepAmount` if you
lowered it in E0.

### E7. Record

Write the tx hashes (basket, swap, sweep, capture, withdraw, pause) and the
health JSON into the launch notes. No wallet labels that point at a person.

---

## F. Before the public gets in

Everything above produces a working private beta. These gate the public one.

1. **[FOUNDER] External audit.** Book it now; lead time is the long pole.
   Scope: the four contracts at the deployed bytecode plus `keeper/`. The
   internal review in `audit/` is context for the auditors, not a substitute.
   Publish the report in full. A finding that changes bytecode means a fresh
   deploy and an opt-in migration; the contracts are not upgradeable.
2. **[FOUNDER] Legal and geography.** Stock Tokens are not offered to US
   persons; Dust must not become a path around that. Before public launch the
   app needs an eligibility gate: geo-block by IP for excluded jurisdictions,
   an explicit self-attestation on first connect, and Terms of Service plus a
   risk disclosure that counsel has signed off on (fee, non-custodial nature,
   issuer pause and blocklist behaviour, no advice). Have counsel review the
   Robinhood Chain and Stock Token developer terms for third-party apps and
   the trademark usage rules. Screen sanctioned addresses at the app layer as
   well; the issuer's blocklist is theirs, not ours.
3. **[FOUNDER] Bug bounty** live from day one (Immunefi or self-hosted page):
   scope, payouts, disclosure address under the project identity, safe-harbour
   wording.
4. **[FOUNDER] Multisig plus timelock.** Keep the Safe as owner but route fee,
   treasury, and delisting through a `TimelockController` owned by the Safe so
   changes are visible on-chain before they bite. Menu adds can stay
   Safe-direct. Publish the pause policy from `PRODUCTION.md` verbatim.
5. **Monitoring and alerts.** Uptime monitor on the keeper health URL (503 =
   page). Alerts on `lowGas`, `txDropped`, `txReverted`, a burst of
   `LegSkipped` events (issuer pause or dead pool), treasury inflow that does
   not match sweep volume, Alchemy usage near the plan cap, and keeper ETH
   below 0.01. A public status page and a written postmortem habit.
6. **Copy and trademark pass.** Every user-facing string says "Stock Tokens",
   never the phrase the trademark terms forbid (D2 has the grep). Public text
   stays completely silent on the subjects `CLAUDE.md` rules out, in either
   direction; the second grep in D2 catches the obvious ones. Confirm the
   launch logos are ones we are allowed to show for Robinhood Stock Tokens;
   the current files were sourced as xStock icons.
7. **Economics settings.** Decide `minSweepAmount` / `DUST_MIN_SWEEP` against
   real gas, `DUST_MIN_POOL_LIQUIDITY` (SPY's v3 pool is the thinnest at about
   2.3e17), and the fee. Each of these is deterministic and public; none gives
   the team discretion over a user's funds.
8. **Capped beta.** Announce a user or volume cap for the first weeks, watch
   the alerts, then widen.

## Appendix: env block for copy-paste

Fill the blanks from `MAINNET-ADDRESSES.md` and B4, then `source` it in a
shell you will close afterwards. Never commit it.

```bash
export DEPLOYER=0x...            # A1
export DEPLOYER_KEYSTORE=.secrets/deployer
export KEEPER=0x...              # A3
export TREASURY=0x...            # A4
export OWNER=0x...               # A5
export DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>"   # A6
export TEST_USER=0x...           # A7
export FEE_BPS=100
export DUST_VAULT=0x...          # B4
export DUST_ROUTER=0x...
export DUST_SWEEPER=0x...
export DUST_CAPTURE=0x...
```
