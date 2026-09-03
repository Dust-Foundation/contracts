# Dust on Robinhood Chain mainnet: redeploy runbook (Capture v2)

The founder's step-by-step path from the live v1 set to a fresh set of the four
Dust contracts with DustCapture v2 (round-ups funded from USDG, WETH or an ETH
float), then repointing the keeper on Fly and the app on Vercel. Chain id 4663.

Why a full redeploy and not a swap of one contract: `DustVault.setModules` is
one-shot. The vault only ever accepts the router, sweeper and capture it was
wired to on day one, so a new capture means a new vault, and a new vault means
a new router and sweeper. The live v1 vault holds nothing (checked in A6), so
abandoning it costs nobody anything.

This runbook is the companion of `MAINNET-DEPLOY.md` (the original 27-step
deploy). It reuses that file's command shapes, keystore names and env var names
exactly. Read that file once before this one; the background (why the keeper is
low-privilege, why the owner is a multisig, what the fee does) is not repeated
here. Nothing in this file has been run by automation; the real deploy is a
human action.

Conventions:

- **[FOUNDER]** marks a step that needs keys, money, or an account.
- Every address comes from `MAINNET-ADDRESSES.md`. Do not type an address from
  memory. When this runbook creates new addresses it tells you to write them
  back into that file.
- Paths are relative to the repo they name (`contracts/`, `keeper/`, `app/`).
  Secrets live in `.secrets/` (gitignored) or in the host's secret store, never
  in a tracked file.
- Anonymity applies to every account touched here. Check `git config user.name`
  prints `Dust` before any commit.
- No `--broadcast` from automation. No CI job ever holds a key.

What is new versus the first deploy, in one table:

| item | v1 (live) | v2 (this runbook) |
|---|---|---|
| DustCapture constructor | `(stable, vault, sweeper)` | `(stable, vault, sweeper, weth, ethPool)` |
| funding sources | USDG allowance | USDG allowance, WETH allowance, ETH float parked in the contract |
| deploy script env | `STABLE TREASURY KEEPER OWNER FEE_BPS MENU_TOKENS MENU_POOLS` | same plus `WETH` and `ETH_POOL` (both default to the verified mainnet values) |
| script side effect | none | calls `increaseObservationCardinalityNext(64)` on `ETH_POOL` only if its buffer is below 64 (mainnet is at 2500, so a logged no-op) |
| deploy gas (dry run, 2026-09-03) | 4.77M | 6.55M (about 0.0041 ETH at the 0.63 gwei the simulation assumed) |
| keeper startup | | detects v1 vs v2 by calling `weth()` / `ethPool()`; on v2 it refuses to start unless `weth()` equals `DUST_WETH` and `ethPool()` pairs WETH with USDG |
| keeper state file | | bound to the sweeper address; must be removed before the new keeper starts |
| app | USDG approve only | cap, then three funding rows: USDG approve, WETH approve, deposit ETH |

Trust model: unchanged. No owner, no pause, no admin on DustCapture. Every
keeper power is bounded on-chain: the user's weekly cap in USDG (all sources
together), the user's allowance or float, and for WETH pulls the pool's own
10-minute TWAP plus 2%. A user with cap 0 cannot be pulled from by any path,
and `withdrawEth` works in every state.

---

## A. Before redeploy

### A0. Repo state is green

From `contracts/`:

```bash
forge build
forge test
FOUNDRY_FORK_RETRIES=5 FOUNDRY_FORK_RETRY_BACKOFF=2000 forge test --match-contract DustMainnetFork -vv
```

Expect the default run to report 84 passed, 0 failed, 1 skipped (DustCapture
32, DustUnit 17, DustFork 13, ComposabilityProbe 5, DustMainnetFork 17 plus the
opt-in heavy test skipped), and the mainnet fork suite alone 17 passed, 1
skipped. The fork suite prints a line like `0.53 USDG exact-out: quoter ... wei,
TWAP+2% bound ... wei`; the bound must sit a few percent above the quote. If a
fork suite skips because the public RPC is unreachable, retry; never proceed on
a red suite.

From `keeper/`:

```bash
npm install
npm run check          # node --check index.mjs && node --check quote.mjs
```

From `app/`:

```bash
npm install
npx tsc --noEmit
npm run build
```

Check the working trees contain only changes you have reviewed:

```bash
git -C contracts status --short
git -C keeper status --short
git -C app status --short
```

### A1. [FOUNDER] Deployer key

The v1 deployer (`.secrets/deployer`, address in `MAINNET-ADDRESSES.md`) is
still the interim owner and treasury of the v1 sweeper. Reuse it if it has
never left this machine and still holds ETH; otherwise make a fresh one exactly
as in `MAINNET-DEPLOY.md` A1:

```bash
mkdir -p .secrets
cast wallet new .secrets deployer2       # only if you are not reusing .secrets/deployer
```

Then, whichever keystore you use:

```bash
export DEPLOYER=0x<deployer address>
export DEPLOYER_KEYSTORE=.secrets/deployer      # or .secrets/deployer2
cast wallet address --keystore "$DEPLOYER_KEYSTORE"     # must print $DEPLOYER
```

### A2. [FOUNDER] Deployer has gas

The dry run in B2 prints the exact estimate; budget 0.01 ETH to leave a 2x
margin over the 0.0041 measured.

```bash
cast balance "$DEPLOYER" --rpc-url robinhood_mainnet --ether     # >= 0.01
```

Top up through the bridge routes listed in `MAINNET-DEPLOY.md` A2 if needed.

### A3. Keeper key stays the same

The keeper hot key is not rotated by this redeploy. Its private key is already
a Fly secret (`DUST_KEEPER_PK`) and it holds gas. The new sweeper gets it via
the `KEEPER` env var, so the script calls `setKeeper` for you.

```bash
export KEEPER=0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD
cast call 0xa14a1fc162b5b54402ec234eae884258e4940492 "keeper()(address)" --rpc-url robinhood_mainnet   # must print $KEEPER
cast balance "$KEEPER" --rpc-url robinhood_mainnet --ether                                            # > 0.01
```

If you do want to rotate the key while you are at it, follow
`MAINNET-DEPLOY.md` A3 and change `DUST_KEEPER_PK` in C3 as well.

### A4. [FOUNDER] Treasury and owner

Use the same values the v1 deploy used unless the multisig from
`MAINNET-DEPLOY.md` A5 is ready now. In the interim both were the deployer.
Leaving `OWNER` unset keeps ownership with the deployer and the script warns
loudly; leaving `TREASURY` unset disables the fee until `setTreasury`.

```bash
export TREASURY=0x<treasury address>
export OWNER=0x<multisig address>          # or leave unset on purpose (interim path)
```

### A5. [FOUNDER] Paid RPC

Same Alchemy app and keys as the first deploy. Use the keeper key for
broadcasts and `cast send`; the public alias only for dry runs and reads.

```bash
export DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>"
cast chain-id --rpc-url "$DUST_RPC"         # must print 4663
```

### A6. Confirm the v1 set is empty, then freeze it

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
export OLD_VAULT=0x572557f8f96cbd1db0560fe36bfdd674bc28493f
export OLD_ROUTER=0x3e83593d9d3f0f29410209070688ad2ea38b0d16
export OLD_SWEEPER=0xa14a1fc162b5b54402ec234eae884258e4940492
export OLD_CAPTURE=0x8f615ec31a52e24a6979111a4d1af2d68497ee68

cast call $USDG "balanceOf(address)(uint256)" $OLD_VAULT --rpc-url $R      # 0
for T in 0x322F0929c4625eD5bAd873c95208D54E1c003b2d 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC \
         0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 0x12f190a9F9d7D37a250758b26824B97CE941bF54 \
         0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; do
  cast call $T "balanceOf(address)(uint256)" $OLD_VAULT --rpc-url $R       # 0 for each
done
cast call $OLD_SWEEPER "owner()(address)"         --rpc-url $R             # $DEPLOYER (interim) or the multisig
cast call $OLD_SWEEPER "minSweepAmount()(uint256)" --rpc-url $R            # note it; 0 on 2026-09-03
```

If any balance is not zero, someone still has a position in v1. Stop, leave
the app pointed at v1, and have them withdraw in kind first (withdrawals never
depend on anyone). Only an empty vault gets abandoned.

Once it is empty, pause the old sweeper so nothing can ever sweep into the
abandoned set again. This is the owner's bounded pause power; withdrawals from
the old vault keep working regardless.

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
cast send $OLD_SWEEPER "setPaused(bool)" true $S
cast call $OLD_SWEEPER "paused()(bool)" --rpc-url $R                        # true
```

If the multisig already owns the old sweeper, send `setPaused(true)` from the
Safe instead (calldata `cast calldata "setPaused(bool)" true`).

### A7. [FOUNDER] Smoke-test wallet

The same browser wallet as `MAINNET-DEPLOY.md` A7 works (it is the one with
the 20 USDG allowance to the v1 capture, cleaned up in E1). It needs about
0.01 ETH this time: gas for a handful of transactions, 0.002 ETH to park as a
float, and 0.001 ETH for the outside send in E4. USDG is optional for this
smoke test; the point is to fund a round-up without any.

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
# WETH / ETH_POOL default to the verified mainnet WETH and the WETH/USDG 0.01% pool; leave unset.
env | grep -E '^(STABLE|TREASURY|KEEPER|OWNER|FEE_BPS|MENU_TOKENS|MENU_POOLS|WETH|ETH_POOL)='
```

Read the printed values against `MAINNET-ADDRESSES.md` one more time. If you
set `WETH` or `ETH_POOL` by hand they must be
`0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` and
`0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`; the script reverts on any pool
that does not pair exactly WETH with USDG, and the keeper refuses to start on
any other WETH.

### B2. Dry run (no transaction is sent)

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_mainnet -vvvv
```

Check the log, in this order:

- `chain id: 4663` and `path: MAINNET`
- `deployer:` equals `$DEPLOYER`; `STABLE:` is USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
- `TREASURY`, `KEEPER`, `OWNER`, `FEE_BPS` are what you exported
- `WETH: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- `ETH_POOL: 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`
- the five `menu[i] token ... pool ...` lines match the launch table in `MAINNET-DEPLOY.md` B2
- `stable decimals: 6 -> unit 1000000`
- `ETH_POOL oracle cardinality 2500 (next 2500), WETH is token0`
- no `WARNING:` lines unless you intend them
- `ETH_POOL observationCardinalityNext 2500 >= 64, no oracle change needed`
- `DUST_CAPTURE funds round-ups from USDG (wallet allowance), WETH (wallet allowance) and an ETH float held as WETH`
- `ownership transfer STARTED to <OWNER>` (or the `OWNER IS THE DEPLOYER` line if that is what you chose)
- `SIMULATION COMPLETE` and `Estimated total gas used for script:` near 6.55M

If anything is off, fix the env and rerun the dry run. Do not continue on a
dry run you have not read.

### B3. [FOUNDER] Broadcast

Same script, same env, plus the keystore and `--broadcast`. `--slow` sends one
transaction at a time and waits for each receipt.

```bash
forge script script/Deploy.s.sol \
  --rpc-url "$DUST_RPC" \
  --keystore "$DEPLOYER_KEYSTORE" --sender "$DEPLOYER" \
  --slow --broadcast -vvvv
```

Enter the keystore password when asked. Expect 11 or 12 transactions (4
creates, 5 `listStock`, `setModules`, then `setKeeper` and
`transferOwnership` when `KEEPER`/`OWNER` differ from the deployer). The
oracle call is skipped on mainnet, so no extra transaction there. If the run
stops midway (a 429 or a dropped tx), rerun the same command with `--resume`
appended; forge continues from the broadcast log.

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

Read-only checks (each must match). The first block is the v1 checklist; the
second block is new for Capture v2.

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
ETH_POOL=0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca
QUOTER=0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7

cast call $DUST_SWEEPER "owner()(address)"        --rpc-url $R   # $DEPLOYER until B6 (or if OWNER unset)
cast call $DUST_SWEEPER "pendingOwner()(address)" --rpc-url $R   # $OWNER, or 0x0 if OWNER unset
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

# Capture v2
cast call $DUST_CAPTURE "stable()(address)"          --rpc-url $R   # USDG
cast call $DUST_CAPTURE "vault()(address)"           --rpc-url $R   # $DUST_VAULT
cast call $DUST_CAPTURE "sweeper()(address)"         --rpc-url $R   # $DUST_SWEEPER
cast call $DUST_CAPTURE "weth()(address)"            --rpc-url $R   # $WETH
cast call $DUST_CAPTURE "ethPool()(address)"         --rpc-url $R   # $ETH_POOL
cast call $DUST_CAPTURE "wethIsToken0()(bool)"       --rpc-url $R   # true
cast call $DUST_CAPTURE "MAX_SLIPPAGE_BPS()(uint16)" --rpc-url $R   # 200
cast call $DUST_CAPTURE "TWAP_WINDOW()(uint32)"      --rpc-url $R   # 600
cast call $DUST_CAPTURE "WEEK()(uint64)"             --rpc-url $R   # 604800
```

Sanity-check the on-chain price bound against the live quoter for 1.00 USDG of
exact output. The bound is the 10-minute TWAP plus 2%, the quote is spot plus
the 0.01% pool fee, so in a calm market the bound lands 1% to 4% above the
quote. Much more than that means the price moved in the last ten minutes; wait
and rerun. Below the quote is impossible unless the price jumped more than 2%
in ten minutes.

```bash
BOUND=$(cast call $DUST_CAPTURE "maxWethInFor(uint256)(uint256)" 1000000 --rpc-url $R | cut -d' ' -f1)
QUOTE=$(cast call $QUOTER \
  "quoteExactOutputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
  "($WETH,$USDG,1000000,100,0)" --rpc-url $R | head -1 | cut -d' ' -f1)
echo "quote $QUOTE wei, bound $BOUND wei, ratio $(echo "scale=4; $BOUND/$QUOTE" | bc)"   # ratio 1.00 to 1.05
```

For scale: on 2026-09-03 the quoter returned about 3.995e14 wei for 1 USDG
(about 2503 USDG per ETH).

Then record everything in `MAINNET-ADDRESSES.md` in the `## Dust contracts v2`
section (placeholders are already there): the four addresses, the deployer,
the deploy block, the tx hashes. Before committing `broadcast/`, scan it:

```bash
grep -rnE "/Users/|/home/|@" broadcast/Deploy.s.sol/4663/ && echo "LEAK: fix before commit" || echo clean
```

### B5. Verify source on Blockscout

Constructor args, encoded. Only the capture line differs from
`MAINNET-DEPLOY.md` B5 (five arguments now).

```bash
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
ETH_POOL=0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca
ARGS_VAULT=$(cast abi-encode "constructor(address)" $USDG)
ARGS_ROUTER=$(cast abi-encode "constructor(address,address,uint256)" $USDG $DUST_VAULT 1000000)
ARGS_SWEEPER=$(cast abi-encode "constructor(address,address,address)" $USDG $DUST_VAULT ${TREASURY:-0x0000000000000000000000000000000000000000})
ARGS_CAPTURE=$(cast abi-encode "constructor(address,address,address,address,address)" $USDG $DUST_VAULT $DUST_SWEEPER $WETH $ETH_POOL)
```

Use the exact `TREASURY` value the deploy used (zero address if it was unset).

```bash
V="--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --chain 4663 --watch"
forge verify-contract $DUST_VAULT   src/DustVault.sol:DustVault     --constructor-args $ARGS_VAULT   $V
forge verify-contract $DUST_ROUTER  src/DustRouter.sol:DustRouter   --constructor-args $ARGS_ROUTER  $V
forge verify-contract $DUST_SWEEPER src/DustSweeper.sol:DustSweeper --constructor-args $ARGS_SWEEPER $V
forge verify-contract $DUST_CAPTURE src/DustCapture.sol:DustCapture --constructor-args $ARGS_CAPTURE $V
```

If the Blockscout API answers with a Cloudflare page or a 403, use the
standard-JSON fallback from `MAINNET-DEPLOY.md` B5 (same commands, add
`--show-standard-json-input > .verify/<Name>.json`, scan for absolute paths,
upload by hand). The capture's standard JSON now also carries
`src/libraries/TickMath.sol` and `src/libraries/FullMath.sol`, which is
expected. Do not commit `.verify/`.

### B6. [FOUNDER] Post-deploy admin

Skip any call whose value the script already set (B4 tells you). Each `cast
send` signs with the deployer keystore because the deployer is owner until
`acceptOwnership` runs.

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
# only if KEEPER was not in the deploy env
cast send $DUST_SWEEPER "setKeeper(address)" $KEEPER $S
# only if TREASURY was not in the deploy env (fee stays off until this is set)
cast send $DUST_SWEEPER "setTreasury(address)" $TREASURY $S
# only if OWNER was not in the deploy env
cast send $DUST_SWEEPER "transferOwnership(address)" $OWNER $S
```

Leave `minSweepAmount` at its fresh-deploy value of 0 until the smoke test in
section E is done; E6 sets the real number. A fresh sweeper starts unpaused
with an empty basket for every user, so nothing can sweep before you set a
basket in E2 anyway.

If `OWNER` is a Safe, accept from the Safe exactly as in `MAINNET-DEPLOY.md`
B6 (`acceptOwnership()` calldata `0x79ba5097`), then confirm:

```bash
cast call $DUST_SWEEPER "owner()(address)"        --rpc-url robinhood_mainnet   # $OWNER
cast call $DUST_SWEEPER "pendingOwner()(address)" --rpc-url robinhood_mainnet   # 0x000...000
```

### B7. [FOUNDER] Commit the address book

`MAINNET-ADDRESSES.md` already marks the v1 set as deprecated and carries the
v2 placeholders. Fill them, then:

```bash
cd contracts
git config user.name && git config user.email     # must be the pseudonymous project identity
git diff --stat
grep -nE "/Users/|/home/" MAINNET-ADDRESSES.md broadcast/Deploy.s.sol/4663/run-latest.json && echo "LEAK" || echo clean
git add MAINNET-ADDRESSES.md broadcast/Deploy.s.sol/4663/
git commit -m "mainnet: redeploy Dust with Capture v2 on Robinhood Chain 4663"
```

Push only after the usual account check (`gh auth status` must show the
project account).

---

## C. Keeper

All from `keeper/`. The Fly app is `dust-keeper-evm` with the volume
`keeper_data` mounted at `/data`; the state file is `/data/keeper-state.json`
(set in `fly.toml`). That file is bound to the chain id and the sweeper
address: pointed at the new sweeper with the old file in place, the keeper
exits with `FATAL: state file belongs to chain 4663 / sweeper 0xa14a...` and
never ticks. C3 removes it at the right moment.

### C1. [FOUNDER] Dry run locally against the new contracts

```bash
cp .env.example .env
```

Fill in `DUST_RPC` (keeper Alchemy URL), `DUST_KEEPER_PK`, and the four
`DUST_*` contract addresses from B4. Leave the chain defaults, including
`DUST_WETH` (it must equal the new capture's `weth()`, which it does by
default). Point `DUST_STATE_PATH` at a scratch file so the local run does not
mix with anything:

```bash
set -a; source .env; set +a
DUST_STATE_PATH=./.keeper-state.local.json npm run dry
```

Read the startup lines, in this order:

- `chain id 4663 ok`
- a code-present line for every configured contract
- `decimals 6`
- `capture contract is v2: WETH/ETH funding enabled (pool 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, fee 100, WETH is token0)`
- `keeperAuthorized: true` (false means the new sweeper's `keeper()` is not this key; go back to B6)
- a fresh scan from `head - 5000` to head, one tick, exit 0

If it prints `capture contract is v1: WETH/ETH funding disabled`, the
`DUST_CAPTURE` in `.env` is still the v1 address. If it dies with a `weth()`
mismatch or a pool-pairing error, the address is wrong or not a Dust capture.

Delete `.env` and `.keeper-state.local.json` when done (`.gitignore` covers
both, but they hold a key and a machine path respectively).

### C2. [FOUNDER] Check the Fly app and what is set

```bash
flyctl status -a dust-keeper-evm
flyctl secrets list -a dust-keeper-evm      # names only, never values
```

Note whether `DUST_MIN_SWEEP` and `DUST_DRY_RUN` are among the secrets. For
the smoke test the keeper-side sweep floor must not block a sub-dollar sweep,
and the first ticks against a new deployment should be dry.

### C3. [FOUNDER] Stage the new addresses, remove the old state, deploy

Stage the secrets first. `--stage` holds them until the next deploy, so the
running v1 keeper is not restarted by this step.

```bash
flyctl secrets set --stage -a dust-keeper-evm \
  DUST_VAULT="$DUST_VAULT" DUST_ROUTER="$DUST_ROUTER" \
  DUST_SWEEPER="$DUST_SWEEPER" DUST_CAPTURE="$DUST_CAPTURE" \
  DUST_MIN_SWEEP=0 \
  DUST_DRY_RUN=1
```

`DUST_MIN_SWEEP=0` only matters if C2 showed it set; it is restored in E6.
The keeper reads the on-chain `minSweepAmount` too, which is 0 on the fresh
sweeper until E6.

Now the state file. The old keeper rewrites it after every tick, so removing
it and then waiting minutes for an image build would let the old process put
it back. Pause the old process first, then remove the file, then deploy. The
one-liner form is

```bash
flyctl ssh console -a dust-keeper-evm -C "rm -f /data/keeper-state.json"
```

but on its own it races the running keeper, so do it in an interactive
session with the pause in front (the image is `node:22-slim`; the loop below
needs nothing but `sh`, and `node` is not PID 1 there):

```bash
flyctl ssh console -a dust-keeper-evm
# inside the machine:
for p in /proc/[0-9]*; do case "$(tr '\0' ' ' < $p/cmdline 2>/dev/null)" in *index.mjs*) kill -STOP ${p#/proc/};; esac; done
rm -f /data/keeper-state.json
ls -la /data                       # no keeper-state.json
exit
```

The health check goes red while the process is paused; that is fine, the
machine is about to be replaced. Deploy right away:

```bash
flyctl deploy
flyctl logs -a dust-keeper-evm
```

Expect the same startup lines as C1, with `capture contract is v2: ...` and
`keeperAuthorized: true`, then a fresh scan from `head - 5000` (no users found
yet is normal) and a tick per minute.

If instead the logs show `FATAL: state file belongs to chain 4663 / sweeper
0xa14a...`, the old file survived. The machine is now running the new image
and restarting on failure; run the interactive `rm -f /data/keeper-state.json`
again between restarts and then `flyctl machine restart <machine id>` (id from
`flyctl status`).

### C4. Health check

```bash
curl -s https://dust-keeper-evm.fly.dev/ | jq
```

Expect HTTP 200, `ok: true`, `keeperAuthorized: true`, `captureMode: "v2"`,
`captureBySource: {usdg: 0, weth: 0, eth: 0}`, `lowGas: false`, `rpc` with
the key redacted, and `ticks` increasing across two calls a minute apart.

### C5. [FOUNDER] Go live

After the smoke test's first round-up exists (E4), watch one dry-run tick log
the `[dry-run] ... would send captureFromEth(...)` line with a sane
`maxWethIn`, then:

```bash
flyctl secrets unset -a dust-keeper-evm DUST_DRY_RUN
flyctl logs -a dust-keeper-evm
```

Unsetting a secret redeploys the machine. State on the volume survives (it now
belongs to the new sweeper), so the scan does not restart.

---

## D. App

All from `app/`. The Solana variables are untouched. The four EVM contract
variables change; everything else stays.

### D1. [FOUNDER] Vercel environment

In the Vercel project (Settings, Environment Variables, scope Production),
change these four to the B4 values:

```
NEXT_PUBLIC_DUST_VAULT   = <from B4>
NEXT_PUBLIC_DUST_ROUTER  = <from B4>
NEXT_PUBLIC_DUST_SWEEPER = <from B4>
NEXT_PUBLIC_DUST_CAPTURE = <from B4>
```

Or from the CLI (remove, then add; each `add` prompts for the value):

```bash
for v in NEXT_PUBLIC_DUST_VAULT NEXT_PUBLIC_DUST_ROUTER NEXT_PUBLIC_DUST_SWEEPER NEXT_PUBLIC_DUST_CAPTURE; do
  npx vercel env rm $v production --yes
  npx vercel env add $v production
done
```

Two optional variables exist now and can stay unset: `NEXT_PUBLIC_EVM_WETH`
(defaults to mainnet WETH; the app also reads `capture.weth()` and prefers it)
and `NEXT_PUBLIC_EVM_QUOTER` (defaults to QuoterV2; used only to size the WETH
allowance in dollars). `NEXT_PUBLIC_EVM_RPC`, `NEXT_PUBLIC_EVM_ENABLED` and
`NEXT_PUBLIC_EVM_NETWORK` are unchanged.

### D2. Copy check before the build

Same two greps as `MAINNET-DEPLOY.md` D2; both must be clean:

```bash
grep -rn --include=*.tsx --include=*.ts -iE "tokenized" src/ && echo "FIX: the product term is Stock Tokens" || echo clean
grep -rn --include=*.tsx --include=*.ts -iE "airdrop|points program|\btoken launch\b" src/ && echo "REMOVE before deploy" || echo clean
```

### D3. Local production build with the new env

```bash
cp .env.example .env.local     # fill NEXT_PUBLIC_EVM_ENABLED=true, NEXT_PUBLIC_EVM_RPC and the four NEXT_PUBLIC_DUST_* values from B4
npm run build && npm run start   # http://localhost:4311
```

Open it, click the Robinhood tab, connect the smoke-test wallet on chain 4663.
The menu lists TSLA, NVDA, AAPL, AMZN, SPY. The Capture everywhere card shows
the weekly cap control and, once a cap is set, a "Fund your round-ups" section
with three rows: USDG (approve), WETH (approve), and ETH (Deposit ETH /
Withdraw all). If the card only shows a USDG approve, the build picked up the
v1 capture address. Stop the server and delete `.env.local`.

### D4. [FOUNDER] Deploy to Vercel with git metadata hidden

```bash
cd app && mv .git /tmp/dust-git.bak && npx vercel --prod ; mv /tmp/dust-git.bak .git
ls -d .git    # must print .git; if it does not, the mv back failed: fix before anything else
```

Then open the production URL and repeat the D3 checks against the live site.

---

## E. Founder wallet actions and end-to-end smoke test

Use `$TEST_USER` from A7 in the browser, and `cast` for the on-chain checks.
Every `cast call` below is read-only. Keep the keeper in dry-run until E4.

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
```

### E1. [FOUNDER] Clean up the v1 grants

The smoke-test wallet still has a 20 USDG allowance and a weekly cap on the
v1 capture. Neither can be used against you (the keeper only knows the new
addresses, and the old sweeper is paused), but leave nothing granted to a
contract you abandoned.

From a wallet UI: open the wallet's token approvals view for USDG on
Robinhood Chain and revoke the approval to `$OLD_CAPTURE`. Or with `cast`, if
the wallet is a keystore (never paste a browser wallet's seed anywhere):

```bash
W="--rpc-url $DUST_RPC --keystore .secrets/<smoke test keystore> --from $TEST_USER"
cast send $USDG "approve(address,uint256)" $OLD_CAPTURE 0 $W
cast send $OLD_CAPTURE "setWeeklyCap(uint96)" 0 $W
```

The same two calls from a browser wallet: Blockscout,
`https://robinhoodchain.blockscout.com/address/<address>?tab=write_contract`,
connect, `approve(spender = $OLD_CAPTURE, value = 0)` on USDG and
`setWeeklyCap(0)` on the old capture. Confirm:

```bash
cast call $USDG "allowance(address,address)(uint256)" $TEST_USER $OLD_CAPTURE --rpc-url $R   # 0
cast call $OLD_CAPTURE "remainingThisWeek(address)(uint256)" $TEST_USER --rpc-url $R          # 0
```

### E2. [FOUNDER] Set a basket on the new sweeper

Baskets live on the sweeper, so the new one has none. In the app, Basket:
SPY 100% (one leg keeps the smoke-test sweep cheap and the SPY pool is the
one the fork tests exercise). Sign.

```bash
cast call $DUST_SWEEPER "basketLengthOf(address)(uint256)" $TEST_USER --rpc-url $R   # 1
cast call $DUST_SWEEPER "basketNonce(address)(uint256)"    $TEST_USER --rpc-url $R   # 1
```

### E3. [FOUNDER] Opt in to Capture everywhere and fund it with ETH

In the app, Capture everywhere:

1. Weekly cap 5 USDG, "Set weekly cap". Sign.
2. In "Fund your round-ups", ETH row: enter 0.002 and "Deposit ETH". Sign.
   Skip the USDG and WETH rows for now; a USDG allowance would be drawn first
   and the point of this test is the ETH path.

```bash
cast call $DUST_CAPTURE "configOf(address)(uint96,uint96,uint64)" $TEST_USER --rpc-url $R   # 5000000, 0, <timestamp>
cast call $DUST_CAPTURE "remainingThisWeek(address)(uint256)" $TEST_USER --rpc-url $R        # 5000000
cast call $DUST_CAPTURE "ethBalance(address)(uint256)" $TEST_USER --rpc-url $R               # 2000000000000000 (0.002 ETH)
cast call $WETH "balanceOf(address)(uint256)" $DUST_CAPTURE --rpc-url $R                     # 2000000000000000 (held as WETH)
```

The deposit tx on Blockscout shows `EthDeposited(user, 2000000000000000)` on
the capture and a `Deposit` on WETH. The keeper logs `capture opt-in: <user>
(cap 5/week, block N)` within a tick.

To also try the WETH-wallet path later, wrap some ETH and use the WETH row's
"Approve ... WETH" button; the keeper then draws WETH from the wallet before
touching the float.

### E4. [FOUNDER] The round-up: an outside ETH send

From `$TEST_USER`, outside the app, send 0.001 ETH to any other address you
control (a plain transfer from the wallet). At about 2500 USDG per ETH that
is 2.50 USDG of spending, rounded up to the next dollar: a round-up near 0.50
USDG. The exact number depends on the ETH price at that minute.

Within two ticks `flyctl logs -a dust-keeper-evm` shows, in order:

```
capture <user>: owed 0.49xxxx, weekly headroom 5
capture <user>: 0.49xxxx USDG from ETH float (up to 0.000xxx WETH in, spot 0.000xxx, bound 0.000xxx)
  [dry-run] capture <user> [ETH float]: would send captureFromEth(<user>, 49xxxx, <maxWethIn>) to <DUST_CAPTURE>
```

Check the numbers: `maxWethIn` is at most the `bound` and about 0.5% above
`spot`; the bound is roughly 2% above spot. If the line says `skipped: price
moved more than 2% vs the TWAP`, wait a tick. If the round-up is missing
entirely, the send did not show up as an outside spend: confirm the keeper's
RPC is the Alchemy URL (native ETH is read through `alchemy_getAssetTransfers`;
on any other provider the log says `native ETH capture disabled` once, and
only USDG and WETH spends count).

Now flip the keeper live (C5). The next tick sends for real:

```
capture <user> [ETH float]: sent 0x<hash>
capture <user> [ETH float]: included in block N (gas ...)
```

Verify on-chain:

```bash
cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R                # 49xxxx, the round-up (0 if the sweep already ran)
cast call $DUST_CAPTURE "ethBalance(address)(uint256)" $TEST_USER --rpc-url $R                # 0.002 ETH minus the WETH spent
cast call $DUST_CAPTURE "remainingThisWeek(address)(uint256)" $TEST_USER --rpc-url $R         # 5000000 minus the round-up
cast logs --address $DUST_CAPTURE \
  "CapturedFrom(address indexed user, uint8 source, uint256 assetIn, uint256 amountOut)" \
  --from-block <deploy block from B4> --to-block latest --rpc-url $DUST_RPC
```

Exactly one `CapturedFrom` log: `source` 2 (ETH float), `assetIn` the WETH
paid (equal to the `spot` figure in the keeper log unless the price moved
between the quote and the block; never above `maxWethIn`), `amountOut` the
round-up. On Blockscout the same tx carries `Captured`, a WETH
`Transfer` from the capture to the pool, a USDG `Transfer` from the pool to
the vault, and the vault's `Accrued`. The capture contract holds no USDG at
any point.

### E5. Watch the sweep, then the Stock Token balance

With `minSweepAmount` at 0 (fresh deploy) and `DUST_MIN_SWEEP=0`, the tick
after the capture sweeps. `flyctl logs` shows the pre-flight lines (registry
not paused, liquidity ok, TWAP ok, quoter within band), then
`sweep <user>: accrued 0.49xxxx, 1 legs, minOuts [...], nonce 1`, `sent` and
`included`.

```bash
cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R                    # 0
cast call $DUST_VAULT "tokenBalance(address,address)(uint256)" $TEST_USER $SPY --rpc-url $R         # > 0 (raw 18-dec; 0.5 USDG is about 6.5e14)
cast call $DUST_VAULT "costBasis(address)(uint256)" $TEST_USER --rpc-url $R                        # the round-up minus 1% fee
cast call $USDG "balanceOf(address)(uint256)" $TREASURY --rpc-url $R                               # previous value plus 1% of the round-up
curl -s https://dust-keeper-evm.fly.dev/ | jq '{captureMode,captureBySource,captureSkippedPriceMove,txSent,txIncluded,txDropped,txReverted,lastError}'
```

`captureBySource.eth` is 1. On Blockscout the sweep tx carries `Swept`, one
`LegBought`, one `FeeCharged`, no `LegSkipped`. The app's Vault card shows the
SPY holding. This is the whole loop: ETH left the wallet in an ordinary
transfer, and a slice of a Stock Token landed in the user's vault position
with nobody but the user's own cap and float deciding how much.

### E6. [FOUNDER] Withdraw the float, withdraw in kind, restore settings

In the app, Capture everywhere, ETH row: "Withdraw all". Sign. This exercises
`withdrawEth` through the real WETH contract (the only way ETH ever leaves the
capture, and it works with any cap, including 0).

```bash
cast call $DUST_CAPTURE "ethBalance(address)(uint256)" $TEST_USER --rpc-url $R     # 0
cast call $WETH "balanceOf(address)(uint256)" $DUST_CAPTURE --rpc-url $R           # 0 (or only other users' floats)
```

The tx shows `EthWithdrawn(user, to, amount)`. Then, Vault: withdraw all SPY
to the wallet; `tokenBalance` goes to 0 and the SPY `balanceOf` the wallet
goes up. Same invariant as in v1: Stock Tokens bought by a sweep leave the
vault to the user on demand.

Now set the production floors. The per-sweep gas table in
`MAINNET-DEPLOY.md` still applies; 5 USDG shown.

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
cast send $DUST_SWEEPER "setMinSweepAmount(uint256)" 5000000 $S      # from the Safe instead if it already owns the sweeper
flyctl secrets set -a dust-keeper-evm DUST_MIN_SWEEP=5000000         # or unset it if C2 showed it was never set
```

Leave your own cap and funding on the new capture as you want them for
everyday use (the app lets you top up the float or approve USDG / WETH any
time; "Turn off capture everywhere" sets the cap to 0 and touches nothing
else).

### E7. Record

Write the tx hashes (deploy block range, basket, deposit, outside send,
capture, sweep, withdrawals) and the health JSON into the launch notes and
`MAINNET-ADDRESSES.md`. No wallet labels that point at a person.

---

## F. If something goes wrong

- **Dry run fails a precheck** (`ETH_POOL does not pair WETH with STABLE`,
  `WETH has no code`, decimals): the env is wrong. Nothing was sent. Fix and
  rerun B2.
- **Broadcast stopped midway**: rerun B3 with `--resume`. Until `setModules`
  has run the new vault is inert; until `listStock` has run five times the
  menu is short. B4 catches both.
- **New keeper dies with the state-file FATAL**: C3's fallback (remove the
  file, restart the machine).
- **Keeper starts but `captureMode` is `v1`**: `DUST_CAPTURE` on Fly is still
  the v1 address. Stage the right one and redeploy; remove the state file
  again only if the sweeper address also changed.
- **App shows only a USDG approve under Capture everywhere**: a Vercel
  variable still points at v1. D1, then D4.
- **You need to go back to v1** (nothing custodial is at risk either way; the
  v1 vault is empty and paused for sweeps): unpause the old sweeper
  (`setPaused(false)`), stage the four old addresses on Fly, remove the state
  file as in C3, redeploy the keeper, put the old addresses back in Vercel and
  redeploy the app. Users would be back on USDG-only funding.

## Appendix: env block for copy-paste

Fill the blanks from `MAINNET-ADDRESSES.md` and B4, then `source` it in a
shell you will close afterwards. Never commit it.

```bash
export DEPLOYER=0x...            # A1
export DEPLOYER_KEYSTORE=.secrets/deployer
export KEEPER=0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD   # A3, unchanged
export TREASURY=0x...            # A4
export OWNER=0x...               # A4, or leave unset on purpose
export DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>"   # A5
export TEST_USER=0x...           # A7
export FEE_BPS=100
export OLD_VAULT=0x572557f8f96cbd1db0560fe36bfdd674bc28493f     # A6, v1 (deprecated)
export OLD_ROUTER=0x3e83593d9d3f0f29410209070688ad2ea38b0d16
export OLD_SWEEPER=0xa14a1fc162b5b54402ec234eae884258e4940492
export OLD_CAPTURE=0x8f615ec31a52e24a6979111a4d1af2d68497ee68
export DUST_VAULT=0x...          # B4, v2
export DUST_ROUTER=0x...
export DUST_SWEEPER=0x...
export DUST_CAPTURE=0x...
```
