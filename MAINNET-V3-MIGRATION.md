# Dust on Robinhood Chain mainnet: v3 migration runbook (post-audit)

The founder's step-by-step path from the live v2 set to the v3 contracts that
answer the CredShields audit (report dated 11 September 2026, 12 findings
against tag `audit-2026-09`), then the keeper on Fly, the app on Vercel, and
the users. Chain id 4663.

Why a full redeploy again: `DustVault.setModules` is one-shot, and every one
of the four contracts changed (the router's measured fill and refund, the
sweeper's pinned quote and on-chain price floor, the capture's aggregate WETH
bound, the vault's SafeTransfer). So v3 is four new addresses, and v2 stays on
chain forever with its withdrawals working. Unlike the v1 to v2 move, v2 is
not empty: at block 60337333 the v2 vault held Stock Token positions in 13 of
the 15 menu tokens and the v2 capture held a 0.0639 WETH float, 13 wallets had
set a basket and 5 had been swept. Section G is therefore a real migration,
not a formality.

This runbook is the companion of `MAINNET-REDEPLOY.md` (v1 to v2) and
`MAINNET-DEPLOY.md` (the first deploy). It reuses their command shapes,
keystore names and env var names exactly. Read `MAINNET-REDEPLOY.md` once
before this one; background that has not changed (why the keeper is
low-privilege, bridge routes, the Safe) is not repeated. Nothing in this file
has been run by automation against the live chain; the dry runs and fork tests
quoted below were run, the broadcasts are yours.

Conventions:

- **[FOUNDER]** marks a step that needs keys, money, or an account.
- Every address comes from `MAINNET-ADDRESSES.md`. Do not type an address from
  memory. Where this runbook creates new addresses it tells you to write them
  back into that file (the `## Dust contracts v3` placeholders are there).
- Paths are relative to the repo they name (`contracts/`, `keeper/`, `app/`).
  Secrets live in `.secrets/` (gitignored) or in the host's secret store,
  never in a tracked file. Never paste a keyed RPC URL into a file.
- Anonymity applies to every account touched here. `git config user.name`
  must print `Dust` in each repo before any commit.
- No `--broadcast` from automation. No CI job ever holds a key.

What is new versus v2, in one table:

| item | v2 (live) | v3 (this runbook) |
|---|---|---|
| DustRouter constructor | `(stable, vault, unit)` | `(stable, vault, unit, factory)`; pool must be the factory's pool for the pair; unspent stable refunded; round-up on the spent amount |
| DustSweeper constructor | `(stable, vault, treasury)` | `(stable, vault, treasury, factory)`; `listStock` requires factory provenance |
| DustCapture constructor | `(stable, vault, sweeper, weth, ethPool)` | `(stable, vault, sweeper, weth, ethPool, factory)`; WETH bound enforced in aggregate per swap; vault credit measured |
| sweep signature | `sweep(user, minOuts, nonce)` | `sweep(user, maxAmount, pools, minOuts, expectedNonce, expectedFeeBps)` |
| sweep price bound | keeper's own minOut | max(minOut, 10-minute pool TWAP minus 300 bps), on-chain, per leg |
| sweep cadence | unlimited | at most one per user per 300 s; nonce consumed per sweep |
| user revocation | none | `clearBasket()` |
| fee | 1% of the gross debit, re-charged on leftover | 1% of what was actually invested, leftover never re-taxed |
| menu at deploy | 5 pairs (10 more listed later) | all 15 verified pairs listed by the script |
| deploy script env | `STABLE TREASURY KEEPER OWNER FEE_BPS MENU_TOKENS MENU_POOLS WETH ETH_POOL` | same plus `FACTORY` (defaults to the canonical Uniswap v3 factory on 4663) |
| deploy gas (dry run, 2026-09-11) | 6.55M | 8.50M (about 0.0021 ETH at the 0.25 gwei the simulation assumed) |
| transactions | 11 or 12 | 21 (4 creates, 15 `listStock`, `setModules`, `setKeeper`) or 22 with `OWNER` set |
| keeper | runs against v2 | refuses to start against v2 (probes `MAX_SWEEP_SLIPPAGE_BPS()`); state file format 2, new path |
| app | v2 only | v3 plus a "Your old Dust balance" card for wallets that still hold something on v2 |
| solc | floating `^0.8.24` | pinned `0.8.35` in every file and in `foundry.toml` |

Trust model: tighter, not different. Every keeper power is bounded on-chain and
the user can now revoke both surfaces alone (`clearBasket` on the sweeper,
`setWeeklyCap(0)` on the capture). The one accepted limitation from the audit
that a user should know about is I001: a persistently skipped basket leg
returns its slice to the accrued balance, which is re-split over the whole
basket next time, so the realized allocation drifts toward the buyable legs.
`AUDIT-SCOPE.md` "Known limitations" has the full list.

---

## A. Pre-flight

### A0. Repo state is green

From `contracts/`:

```bash
forge build
forge test
FOUNDRY_FORK_RETRIES=5 FOUNDRY_FORK_RETRY_BACKOFF=2000 forge test --match-contract DustMainnetFork -vv
```

Expect the default run to report **138 passed, 0 failed, 0 skipped** across 7
suites: DustAuditV3 22, DustUnit 22, DustCapture 33, DustCaptureAdversarial
19, ComposabilityProbe 5, DustForkTest (testnet 46630) 13, DustMainnetFork 24.
Measured on 2026-09-11: the four mock suites 96 passed, DustMainnetFork 24
passed pinned at block 60337295, DustForkTest 13 passed. The mainnet fork suite
prints `fill ... == quoter, on-chain TWAP floor ...` for the SPY leg and a
`LegSkipped` line for the thin TSLA/USDG 0.05% pool; both are expected. The
public RPC is not an archive node, so if the fork suite fails with a missing
block, rerun; never proceed on a red suite. For a deterministic replay pass the
paid RPC on the command line only:

```bash
MAINNET_FORK_BLOCK=<head minus 200> forge test --match-contract DustMainnetFork --fork-url "$DUST_RPC"
```

From `keeper/`:

```bash
npm install
npm run check          # node --check index.mjs && node --check quote.mjs
grep -n "^  \"version\"" package.json      # 0.3.0
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

The `out/` artifacts in `contracts/` are gitignored but were tracked before the
ignore rule landed, so they show as modified. Leave them out of the v3 commit
(`git add` the sources, tests, scripts, docs and `foundry.toml` explicitly) or
untrack them first with `git rm -r --cached out/`.

### A1. Commit and tag the audited-response revision

The auditors need a frozen revision to retest against. Commit the v3 work in
`contracts/` with the project identity, then tag it `audit-2026-09-v3`. The
assistant creates the tag for you on request once the commit exists (it never
commits or pushes on its own); the commands, if you do it yourself:

```bash
cd contracts
git config user.name && git config user.email          # Dust / the project pseudonymous email
grep -rnE "/Users/|/home/|alch_gw|@gmail" src test script *.md foundry.toml && echo "LEAK: fix first" || echo clean
git add src test script foundry.toml AUDIT-SCOPE.md README.md MAINNET-V3-MIGRATION.md MAINNET-ADDRESSES.md
git commit -m "v3: respond to the September 2026 audit (12 findings), factory provenance, pinned sweeps, TWAP floor, clearBasket, SafeTransfer, solc 0.8.35"
git tag -a audit-2026-09-v3 -m "v3 contracts: response to the CredShields audit of audit-2026-09"
git tag --points-at HEAD                                 # audit-2026-09-v3
```

Push the commit and the tag only after the usual account check (`gh auth
status` must show the project account, not a personal one):

```bash
git push origin HEAD && git push origin audit-2026-09-v3
```

The `broadcast/Deploy.s.sol/4663/dry-run/` files were rewritten by the dry
runs; they scan clean but carry no value. Commit them or discard them
(`git checkout -- broadcast/ && git clean -f broadcast/`), your call, before
B3 writes the real broadcast record.

### A2. [FOUNDER] Deployer key and gas

Reuse `.secrets/deployer` (address `0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b`,
the v2 deployer, interim owner and treasury). It held 0.036 ETH at block
60337333; the deploy needs about 0.0021 ETH at the simulated gas price, so
budget 0.01 for a wide margin over a gas spike.

```bash
export DEPLOYER=0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b
export DEPLOYER_KEYSTORE=.secrets/deployer
cast wallet address --keystore "$DEPLOYER_KEYSTORE"                # must print $DEPLOYER
cast balance "$DEPLOYER" --rpc-url robinhood_mainnet --ether       # >= 0.01
```

### A3. Keeper key stays the same

`.secrets/keeper` / Fly secret `DUST_KEEPER_PK`, address
`0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD`. It held 0.049 ETH at block
60337333. The script calls `setKeeper` for you through the `KEEPER` env var.

```bash
export KEEPER=0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD
cast call 0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899 "keeper()(address)" --rpc-url robinhood_mainnet   # $KEEPER
cast balance "$KEEPER" --rpc-url robinhood_mainnet --ether                                            # > 0.02
```

### A4. [FOUNDER] Treasury and owner

Treasury stays the deployer for now (same as v2). Ownership: the Safe from
`MAINNET-DEPLOY.md` A5 if it is ready, otherwise the interim path (`OWNER`
unset, the script warns loudly and you hand over later with
`transferOwnership` + `acceptOwnership`). The audit rated two of its findings
(L002, M004's owner-driven variants) as "a function of key management" and
said the multisig handover removes the remaining likelihood without code; do
it before the public beta.

```bash
export TREASURY=0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b
export OWNER=0x<multisig address>          # or leave unset on purpose (interim path)
```

### A5. [FOUNDER] Paid RPC

Same Alchemy app as before. Keeper key for broadcasts and `cast send`, the
public alias for dry runs and reads. Only ever in the shell.

```bash
export DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>"
cast chain-id --rpc-url "$DUST_RPC"         # 4663
```

### A6. Record the v2 state you are leaving

Read-only. Numbers in the comments are the 2026-09-11 readings at block
60337333; yours will differ slightly.

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
export OLD_VAULT=0xC6d3FCA5aa8274c03d015d914ae102f3FF344137
export OLD_ROUTER=0x6A2A77F4ccb7ca9d5Af36EDb8491Af201bF209b3
export OLD_SWEEPER=0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899
export OLD_CAPTURE=0xc33e4EB6099bd96127D6016E9EdE1234d3a69406

cast call $OLD_SWEEPER "owner()(address)"          --rpc-url $R   # $DEPLOYER (interim)
cast call $OLD_SWEEPER "paused()(bool)"            --rpc-url $R   # false (D1 flips it)
cast call $OLD_SWEEPER "menuLength()(uint256)"     --rpc-url $R   # 15
cast call $USDG "balanceOf(address)(uint256)" $OLD_VAULT --rpc-url $R      # 0 accrued (nothing waiting to be swept)
cast call $WETH "balanceOf(address)(uint256)" $OLD_CAPTURE --rpc-url $R    # 63947342248175031 = the ETH floats parked on v2
cast call $USDG "balanceOf(address)(uint256)" $OLD_ROUTER --rpc-url $R     # 0 (H001 residue check: the v2 router holds nothing)
for T in 0x322F0929c4625eD5bAd873c95208D54E1c003b2d 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC \
         0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 0x12f190a9F9d7D37a250758b26824B97CE941bF54 \
         0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; do
  cast call $T "balanceOf(address)(uint256)" $OLD_VAULT --rpc-url $R       # non-zero: users hold positions on v2
done
```

Who is on v2 (for the notice in G3):

```bash
cast logs --address $OLD_SWEEPER "BasketSet(address indexed user, uint256 nonce, uint256 legs)" \
  --from-block 53708685 --to-block latest --rpc-url "$DUST_RPC" --json | jq -r '[.[].topics[1]] | unique | length'   # 13 on 2026-09-11
cast logs --address $OLD_CAPTURE "WeeklyCapSet(address indexed user, uint256 weeklyCap)" \
  --from-block 53708685 --to-block latest --rpc-url "$DUST_RPC" --json | jq -r '[.[].topics[1]] | unique | length'
```

Do not pause anything yet. v2 keeps working until v3 is verified (section C).

### A7. Fly and Vercel, as they are

```bash
flyctl status -a dust-keeper-evm
flyctl secrets list -a dust-keeper-evm      # names only
curl -s https://dust-keeper-evm.fly.dev/ | jq '{ok, sweeperMode, captureMode, keeperAuthorized, users, ticks}'
```

The running keeper is the v2 image: no `sweeperMode` field yet, `captureMode:
"v2"`, `users` around 13. In Vercel, note the current values of the four
`NEXT_PUBLIC_DUST_*` variables (they are the v2 set) and whether
`NEXT_PUBLIC_DUST_DEPLOY_BLOCK` is set. Nothing changes here until E and F.

### A8. [FOUNDER] Smoke-test wallet

The same browser wallet as before, with a v2 basket, an ETH float on v2 and
possibly USDG/WETH allowances to the v2 capture; it is the first wallet you
migrate in G2. It needs about 0.01 ETH for gas plus a 0.002 float on v3.

```bash
export TEST_USER=0x<smoke test wallet>
```

---

## B. Deploy v3

All from `contracts/`. Keep the shell from section A.

### B1. Set the deploy environment

```bash
export FEE_BPS=100          # 1%; code ceiling is 500
# MENU_TOKENS / MENU_POOLS default to all 15 verified pairs; leave unset.
# WETH / ETH_POOL / FACTORY default to the verified mainnet values; leave unset.
env | grep -E '^(STABLE|TREASURY|KEEPER|OWNER|FEE_BPS|MENU_TOKENS|MENU_POOLS|WETH|ETH_POOL|FACTORY)='
```

If you set `FACTORY` by hand it must be
`0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`. Every pool the script lists, and
the ETH pool, must round-trip through `factory.getPool(token0, token1, fee)`;
the script reverts otherwise, and so would the contracts' own constructors and
`listStock`.

### B2. Dry run (no transaction is sent)

```bash
forge script script/Deploy.s.sol --rpc-url robinhood_mainnet -vvvv
```

Check the log, in this order (this is the 2026-09-11 dry run, verbatim apart
from the addresses the simulation invents):

- `chain id: 4663` and `path:     MAINNET`
- `deployer:` equals `$DEPLOYER`; `STABLE:` is USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
- `TREASURY`, `KEEPER`, `OWNER`, `FEE_BPS` are what you exported
- `WETH:       0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`
- `ETH_POOL:   0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca`
- `FACTORY:    0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`
- fifteen `menu[i] token ... pool ...` lines, i = 0 to 14, matching the launch
  table and the "Menu expansion (2026-09-09)" table in `MAINNET-ADDRESSES.md`
  (order: TSLA, NVDA, AAPL, AMZN, SPY, MSFT, GOOGL, META, NFLX, AMD, PLTR, QQQ,
  GLD, SPCX, MSTR)
- `stable decimals: 6 -> unit 1000000`
- `ETH_POOL oracle cardinality 2500 (next 2500), WETH is token0`
- the two `WARNING: OWNER unset` lines only if you chose the interim path; no
  `WARNING: TREASURY unset`
- `ETH_POOL observationCardinalityNext 2500 >= 64, no oracle change needed`
- `DUST_FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA`
- `DUST_KEEPER=0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD`, `DUST_TREASURY=` your treasury, `DUST_FEE_BPS=100`
- `SIMULATION COMPLETE` and `Estimated total gas used for script:` near 8.50M

If anything is off, fix the env and rerun. Do not continue on a dry run you
have not read.

### B3. [FOUNDER] Broadcast

```bash
forge script script/Deploy.s.sol \
  --rpc-url "$DUST_RPC" \
  --keystore "$DEPLOYER_KEYSTORE" --sender "$DEPLOYER" \
  --slow --broadcast -vvvv
```

Enter the keystore password when asked. Expect 21 transactions (4 creates,
15 `listStock`, `setModules`, `setKeeper`), 22 if `OWNER` is set
(`transferOwnership`). The oracle call is a logged no-op on mainnet. If the
run stops midway (a 429 or a dropped tx), rerun the same command with
`--resume` appended; forge continues from the broadcast log. Until
`setModules` has run the new vault is inert and until all 15 `listStock` calls
have run the menu is short; C1 catches both.

### B4. Read the addresses

```bash
jq -r '.transactions[] | select(.transactionType=="CREATE") | "\(.contractName)=\(.contractAddress)"' \
  broadcast/Deploy.s.sol/4663/run-latest.json
jq -r '.receipts[] | "\(.transactionHash) block \(.blockNumber) gasUsed \(.gasUsed)"' \
  broadcast/Deploy.s.sol/4663/run-latest.json
jq -r '[.receipts[].blockNumber] | "deploy blocks \(min) to \(max)"' broadcast/Deploy.s.sol/4663/run-latest.json
```

Export them (the console log also printed them as `DUST_VAULT=` etc.), and
keep the first block number: it is `NEXT_PUBLIC_DUST_DEPLOY_BLOCK` in F1.

```bash
export DUST_VAULT=0x...
export DUST_ROUTER=0x...
export DUST_SWEEPER=0x...
export DUST_CAPTURE=0x...
export DUST_DEPLOY_BLOCK=<first block above, as a decimal>
```

Scan the broadcast record before it is ever committed:

```bash
grep -rnE "/Users/|/home/|alch_gw|@" broadcast/Deploy.s.sol/4663/run-latest.json && echo "LEAK: fix before commit" || echo clean
```

### B5. Verify source on Blockscout

Constructor args, encoded. All three module constructors gained the factory.

```bash
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
ETH_POOL=0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca
FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
ARGS_VAULT=$(cast abi-encode "constructor(address)" $USDG)
ARGS_ROUTER=$(cast abi-encode "constructor(address,address,uint256,address)" $USDG $DUST_VAULT 1000000 $FACTORY)
ARGS_SWEEPER=$(cast abi-encode "constructor(address,address,address,address)" $USDG $DUST_VAULT ${TREASURY:-0x0000000000000000000000000000000000000000} $FACTORY)
ARGS_CAPTURE=$(cast abi-encode "constructor(address,address,address,address,address,address)" $USDG $DUST_VAULT $DUST_SWEEPER $WETH $ETH_POOL $FACTORY)
```

```bash
V="--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --chain 4663 --watch"
forge verify-contract $DUST_VAULT   src/DustVault.sol:DustVault     --constructor-args $ARGS_VAULT   $V
forge verify-contract $DUST_ROUTER  src/DustRouter.sol:DustRouter   --constructor-args $ARGS_ROUTER  $V
forge verify-contract $DUST_SWEEPER src/DustSweeper.sol:DustSweeper --constructor-args $ARGS_SWEEPER $V
forge verify-contract $DUST_CAPTURE src/DustCapture.sol:DustCapture --constructor-args $ARGS_CAPTURE $V
```

The compiler is pinned (`solc = "0.8.35"`, `via_ir`, 200 runs) so the
verifier settings are unambiguous now; that was audit finding L005. If the
Blockscout API answers with a Cloudflare page, use the standard-JSON fallback
from `MAINNET-DEPLOY.md` B5 (add `--show-standard-json-input >
.verify/<Name>.json`, scan for absolute paths, upload by hand). The sweeper's
and capture's standard JSON now carry `src/libraries/SafeTransfer.sol`,
`TickMath.sol` and `FullMath.sol`; the router and vault carry `SafeTransfer.sol`.
Do not commit `.verify/`.

### B6. [FOUNDER] Post-deploy admin

Skip any call whose value the script already set. Each `cast send` signs with
the deployer keystore because the deployer is owner until `acceptOwnership`.

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
# only if KEEPER was not in the deploy env
cast send $DUST_SWEEPER "setKeeper(address)" $KEEPER $S
# only if TREASURY was not in the deploy env (fee stays off until this is set)
cast send $DUST_SWEEPER "setTreasury(address)" $TREASURY $S
# only if OWNER was not in the deploy env and the Safe is ready
cast send $DUST_SWEEPER "transferOwnership(address)" $OWNER $S
```

Leave `minSweepAmount` at 0 until the smoke test in G2 has swept once; G4 sets
the real number. A fresh sweeper starts unpaused with no baskets, so nothing
can sweep before a user sets one.

If `OWNER` is a Safe, accept from the Safe as in `MAINNET-DEPLOY.md` B6
(`acceptOwnership()` calldata `0x79ba5097`), then confirm `owner()` and
`pendingOwner()`.

---

## C. Verify the wiring by cast

Every call is read-only and every value must match. Run this before anything
touches v2 or the keeper.

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
ETH_POOL=0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca
FACTORY=0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
QUOTER=0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7
SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
SPY_POOL=0xa7Bb1AC63BBaB0C44316E6c8C455213441689167

# vault: modules wired once, to the three new addresses
cast call $DUST_VAULT "stable()(address)"   --rpc-url $R   # USDG
cast call $DUST_VAULT "router()(address)"   --rpc-url $R   # $DUST_ROUTER
cast call $DUST_VAULT "sweeper()(address)"  --rpc-url $R   # $DUST_SWEEPER
cast call $DUST_VAULT "capture()(address)"  --rpc-url $R   # $DUST_CAPTURE

# sweeper: roles, factory, menu, bounds
cast call $DUST_SWEEPER "owner()(address)"                 --rpc-url $R   # $DEPLOYER until acceptOwnership (or $OWNER after)
cast call $DUST_SWEEPER "pendingOwner()(address)"          --rpc-url $R   # $OWNER, or 0x0 if OWNER unset
cast call $DUST_SWEEPER "keeper()(address)"                --rpc-url $R   # 0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD
cast call $DUST_SWEEPER "treasury()(address)"              --rpc-url $R   # $TREASURY
cast call $DUST_SWEEPER "feeBps()(uint16)"                 --rpc-url $R   # 100
cast call $DUST_SWEEPER "paused()(bool)"                   --rpc-url $R   # false
cast call $DUST_SWEEPER "minSweepAmount()(uint256)"        --rpc-url $R   # 0 (G4 sets it)
cast call $DUST_SWEEPER "menuLength()(uint256)"            --rpc-url $R   # 15
cast call $DUST_SWEEPER "factory()(address)"               --rpc-url $R   # $FACTORY
cast call $DUST_SWEEPER "stable()(address)"                --rpc-url $R   # USDG
cast call $DUST_SWEEPER "vault()(address)"                 --rpc-url $R   # $DUST_VAULT
cast call $DUST_SWEEPER "poolFor(address)(address)" 0x322F0929c4625eD5bAd873c95208D54E1c003b2d --rpc-url $R  # TSLA 0xf4AC...89E3
cast call $DUST_SWEEPER "poolFor(address)(address)" 0xec262a75e413fAfD0dF80480274532C79D42da09 --rpc-url $R  # MSTR 0x1757...53EA
cast call $DUST_SWEEPER "MAX_FEE_BPS()(uint16)"            --rpc-url $R   # 500
cast call $DUST_SWEEPER "MAX_SWEEP_SLIPPAGE_BPS()(uint16)" --rpc-url $R   # 300
cast call $DUST_SWEEPER "TWAP_WINDOW()(uint32)"            --rpc-url $R   # 600
cast call $DUST_SWEEPER "MIN_SWEEP_INTERVAL()(uint32)"     --rpc-url $R   # 300

# router
cast call $DUST_ROUTER "stable()(address)"   --rpc-url $R   # USDG
cast call $DUST_ROUTER "vault()(address)"    --rpc-url $R   # $DUST_VAULT
cast call $DUST_ROUTER "unit()(uint256)"     --rpc-url $R   # 1000000
cast call $DUST_ROUTER "factory()(address)"  --rpc-url $R   # $FACTORY
cast call $USDG "balanceOf(address)(uint256)" $DUST_ROUTER --rpc-url $R   # 0, and it must read 0 after every swap forever

# capture
cast call $DUST_CAPTURE "stable()(address)"          --rpc-url $R   # USDG
cast call $DUST_CAPTURE "vault()(address)"           --rpc-url $R   # $DUST_VAULT
cast call $DUST_CAPTURE "sweeper()(address)"         --rpc-url $R   # $DUST_SWEEPER
cast call $DUST_CAPTURE "weth()(address)"            --rpc-url $R   # $WETH
cast call $DUST_CAPTURE "ethPool()(address)"         --rpc-url $R   # $ETH_POOL
cast call $DUST_CAPTURE "factory()(address)"         --rpc-url $R   # $FACTORY
cast call $DUST_CAPTURE "wethIsToken0()(bool)"       --rpc-url $R   # true
cast call $DUST_CAPTURE "MAX_SLIPPAGE_BPS()(uint16)" --rpc-url $R   # 200
cast call $DUST_CAPTURE "TWAP_WINDOW()(uint32)"      --rpc-url $R   # 600
cast call $DUST_CAPTURE "WEEK()(uint64)"             --rpc-url $R   # 604800
```

Menu provenance, all 15 at once (each line must print `ok`):

```bash
for i in $(seq 0 14); do
  T=$(cast call $DUST_SWEEPER "menu(uint256)(address)" $i --rpc-url $R)
  P=$(cast call $DUST_SWEEPER "poolFor(address)(address)" $T --rpc-url $R)
  F=$(cast call $P "fee()(uint24)" --rpc-url $R)
  T0=$(cast call $P "token0()(address)" --rpc-url $R); T1=$(cast call $P "token1()(address)" --rpc-url $R)
  G=$(cast call $FACTORY "getPool(address,address,uint24)(address)" $T0 $T1 $F --rpc-url $R)
  [ "$(echo $G | tr A-F a-f)" = "$(echo $P | tr A-F a-f)" ] && echo "menu[$i] $T pool $P fee $F ok" || echo "menu[$i] $T pool $P MISMATCH"
done
```

The on-chain sweep floor against the live quoter, for 1.00 USDG into SPY. The
floor is the 10-minute TWAP output minus 3%; the quote is spot minus the 0.05%
pool fee; in a calm market floor/quote lands between 0.96 and 0.975.

```bash
FLOOR=$(cast call $DUST_SWEEPER "twapFloor(address,uint256)(uint256)" $SPY_POOL 1000000 --rpc-url $R | cut -d' ' -f1)
QUOTE=$(cast call $QUOTER \
  "quoteExactInputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
  "($USDG,$SPY,1000000,500,0)" --rpc-url $R | head -1 | cut -d' ' -f1)
echo "quote $QUOTE, floor $FLOOR, ratio $(echo "scale=4; $FLOOR/$QUOTE" | bc)"   # 0.96 to 0.975
```

And the capture bound, unchanged from v2 (TWAP plus 2% for exact-out WETH):

```bash
BOUND=$(cast call $DUST_CAPTURE "maxWethInFor(uint256)(uint256)" 1000000 --rpc-url $R | cut -d' ' -f1)
QUOTE=$(cast call $QUOTER \
  "quoteExactOutputSingle((address,address,uint256,uint24,uint160))(uint256,uint160,uint32,uint256)" \
  "($WETH,$USDG,1000000,100,0)" --rpc-url $R | head -1 | cut -d' ' -f1)
echo "quote $QUOTE wei, bound $BOUND wei, ratio $(echo "scale=4; $BOUND/$QUOTE" | bc)"   # 1.00 to 1.05
```

Now fill the `## Dust contracts v3` section of `MAINNET-ADDRESSES.md` (H1).

---

## D. Freeze v2

### D1. [FOUNDER] Pause sweeps on the v2 sweeper

This is the owner's one bounded emergency power and it does exactly one
thing: `sweep` on v2 reverts `Paused` from now on. It cannot touch the v2
vault. `withdrawAccrued`, `withdrawToken` on the v2 vault and `withdrawEth` on
the v2 capture keep working forever; the legacy card in the app (G1) calls
exactly those.

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
cast send $OLD_SWEEPER "setPaused(bool)" true $S
cast call $OLD_SWEEPER "paused()(bool)" --rpc-url robinhood_mainnet     # true
```

If the Safe already owns the v2 sweeper, send `setPaused(true)` from the Safe
(calldata `cast calldata "setPaused(bool)" true` = `0x16c38b3c0000000000000000000000000000000000000000000000000000000000000001`).

Captures on v2 have no pause (DustCapture has no owner, by design). They stop
because the keeper moves: the v3 keeper only knows the v3 capture. Between D1
and the moment the new keeper is live (E3), the old keeper still running on
Fly can pull a round-up into the v2 vault as accrued USDG, where it sits
withdrawable through the legacy card. Do D1 and section E back to back to
keep that window to minutes. Users who want a hard stop on v2 also set their
v2 weekly cap to 0 and revoke the v2 allowances (G1 covers the allowances).

The dry-run leftover check from A6 stays true after the pause:

```bash
cast call $USDG "balanceOf(address)(uint256)" $OLD_ROUTER --rpc-url robinhood_mainnet   # 0
```

---

## E. Keeper

All from `keeper/`. The Fly app is `dust-keeper-evm` with the volume
`keeper_data` mounted at `/data`. The v2 keeper writes
`/data/keeper-state-v2.json`; the v3 keeper gets its own file,
`/data/keeper-state-v3.json`, set in `fly.toml`. A fresh path means no race
with the old process (the v1 to v2 runbook needed a pause-then-delete dance;
this one does not) and the old file stays on the volume as a record until you
remove it in E5. The v3 keeper refuses to start against v2 (it probes
`MAX_SWEEP_SLIPPAGE_BPS()` at startup), so the address swap and the image swap
have to land together: stage the secrets, then deploy.

### E1. [FOUNDER] Dry run locally against v3

```bash
cp .env.example .env
```

Fill in `DUST_RPC` (keeper Alchemy URL), `DUST_KEEPER_PK`, and the four
`DUST_*` addresses from B4. Leave the chain defaults. Point the state at a
scratch file:

```bash
set -a; source .env; set +a
DUST_STATE_PATH=./.keeper-state.local.json npm run dry
```

Read the startup lines, in this order:

- `chain id 4663 ok`
- `contract code present for sweeper, vault, router, capture` (order may differ)
- `stable 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 decimals 6`
- `sweeper contract is v3: on-chain floor = 600s TWAP - 300 bps per leg, min 300s between sweeps per user`
- `capture contract is v2: WETH/ETH funding enabled (pool 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, fee 100, WETH is token0)`
  (the capture module is still called "v2" by the keeper: it means the
  WETH/ETH-funded capture design, which v3 kept)
- `keeperAuthorized: true` (false means `setKeeper` did not run; back to B6)
- `no state file at .keeper-state.local.json; starting fresh`, a scan from
  `head - 5000`, one tick, exit 0

If it dies with `FATAL: DUST_SWEEPER=0x6FE0... is a v2 DustSweeper`, `.env`
still has the v2 sweeper. Delete `.env` and `.keeper-state.local.json` when
done (both gitignored; one holds a key).

### E2. [FOUNDER] Stage the v3 addresses on Fly

`--stage` holds them until the next deploy, so the running v2 keeper is not
restarted early.

```bash
flyctl secrets set --stage -a dust-keeper-evm \
  DUST_VAULT="$DUST_VAULT" DUST_ROUTER="$DUST_ROUTER" \
  DUST_SWEEPER="$DUST_SWEEPER" DUST_CAPTURE="$DUST_CAPTURE" \
  DUST_MIN_SWEEP=0 \
  DUST_DRY_RUN=1
```

`DUST_MIN_SWEEP=0` lets the smoke-test sweep in G2 run at a sub-dollar size;
G4 restores it. `DUST_DRY_RUN=1` keeps the first ticks against the new
contracts read-only.

### E3. [FOUNDER] State path, then deploy

`fly.toml` in the working tree already carries the new path; confirm, and
confirm the version:

```bash
grep -n "DUST_STATE_PATH" fly.toml        # DUST_STATE_PATH = '/data/keeper-state-v3.json'
grep -n '"version"' package.json          # 0.3.0
git status --short                        # the v3 keeper changes, reviewed
flyctl deploy
flyctl logs -a dust-keeper-evm
```

Expect the E1 startup lines, `no state file at keeper-state-v3.json; starting
fresh`, a scan from `head - 5000` (finding nobody yet is normal: baskets live
on the new sweeper), then a tick per minute with `[dry-run]` in the tick line.

If the logs show `FATAL: ... is a v2 DustSweeper`, a staged secret did not
apply (`flyctl secrets list` shows a digest per name; re-set without
`--stage`). If they show `state file belongs to chain 4663 / sweeper 0x6FE0...`,
`fly.toml` still names the v2 path.

### E4. Health

```bash
curl -s https://dust-keeper-evm.fly.dev/ | jq
```

Expect HTTP 200, `ok: true`, `keeperAuthorized: true`, `sweeperMode: "v3"`,
`sweeper: {slippageBps: 300, twapWindowSec: 600, minIntervalSec: 300}`,
`sweepRequotes: 0`, `sweepLegsNoTwap: 0`, `captureMode: "v2"`,
`captureBySource: {usdg: 0, weth: 0, eth: 0}`, `lowGas: false`, `rpc` with
the key redacted, and `ticks` increasing across two calls a minute apart.

### E5. [FOUNDER] Go live, then tidy the volume

After the smoke test's first round-up exists on v3 (G2), watch one dry-run
tick log the `[dry-run] ... would send captureFromEth(...)` line and one
`[dry-run] ... would send sweep(...)` line with `maxAmount`, 1 pool, a minOut
at or above the contract floor, `nonce` and `feeBps 100`, then:

```bash
flyctl secrets unset -a dust-keeper-evm DUST_DRY_RUN
flyctl logs -a dust-keeper-evm
```

Unsetting a secret redeploys the machine; the v3 state file on the volume
survives. Once the new keeper has ticked live for a day, remove the v2 file:

```bash
flyctl ssh console -a dust-keeper-evm -C "rm -f /data/keeper-state-v2.json"
flyctl ssh console -a dust-keeper-evm -C "ls -la /data"     # keeper-state-v3.json only
```

Commit the keeper repo (`fly.toml`, `index.mjs`, `quote.mjs`, `README.md`,
`.env.example`, `package.json`) with the project identity after the same leak
grep as A1.

---

## F. App

All from `app/`. Solana variables untouched. Four EVM addresses change, one
block number is added, and the three legacy names should be set explicitly so
the code defaults are not load-bearing.

### F1. [FOUNDER] Vercel environment

In the Vercel project (Settings, Environment Variables, scope Production):

```
NEXT_PUBLIC_DUST_VAULT          = <DUST_VAULT from B4>
NEXT_PUBLIC_DUST_ROUTER         = <DUST_ROUTER from B4>
NEXT_PUBLIC_DUST_SWEEPER        = <DUST_SWEEPER from B4>
NEXT_PUBLIC_DUST_CAPTURE        = <DUST_CAPTURE from B4>
NEXT_PUBLIC_DUST_DEPLOY_BLOCK   = <DUST_DEPLOY_BLOCK from B4, decimal>
NEXT_PUBLIC_DUST_V2_VAULT       = 0xC6d3FCA5aa8274c03d015d914ae102f3FF344137
NEXT_PUBLIC_DUST_V2_CAPTURE     = 0xc33e4EB6099bd96127D6016E9EdE1234d3a69406
NEXT_PUBLIC_DUST_V2_SWEEPER     = 0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899
```

Or from the CLI (remove, then add; each `add` prompts for the value):

```bash
for v in NEXT_PUBLIC_DUST_VAULT NEXT_PUBLIC_DUST_ROUTER NEXT_PUBLIC_DUST_SWEEPER NEXT_PUBLIC_DUST_CAPTURE; do
  npx vercel env rm $v production --yes
  npx vercel env add $v production
done
for v in NEXT_PUBLIC_DUST_DEPLOY_BLOCK NEXT_PUBLIC_DUST_V2_VAULT NEXT_PUBLIC_DUST_V2_CAPTURE NEXT_PUBLIC_DUST_V2_SWEEPER; do
  npx vercel env add $v production
done
```

`NEXT_PUBLIC_DUST_DEPLOY_BLOCK` is the floor for the app's event scans (share
card counts, activity feed); left at the v2 default it only makes the first
scan longer. The `V2` trio drives the "Your old Dust balance" card; once
nobody holds anything on v2 (H1 says how to check), set
`NEXT_PUBLIC_DUST_V2_VAULT` and `NEXT_PUBLIC_DUST_V2_CAPTURE` to
`0x0000000000000000000000000000000000000000` to hide it.

### F2. Version bump and copy check

The live site shows its version and every production deploy bumps it. This is
a feature release: `0.5.1` to `0.6.0`.

```bash
npm version minor --no-git-tag-version      # 0.5.1 -> 0.6.0 in package.json
grep -rn --include=*.tsx --include=*.ts -iE "tokenized" src/ && echo "FIX: the product term is Stock Tokens" || echo clean
grep -rn --include=*.tsx --include=*.ts -iE "airdrop|token launch" src/ && echo "REVIEW before deploy" || echo clean
```

### F3. Local production build with the v3 env

```bash
cp .env.example .env.local     # NEXT_PUBLIC_EVM_ENABLED=true, NEXT_PUBLIC_EVM_RPC, the four NEXT_PUBLIC_DUST_* from B4, NEXT_PUBLIC_DUST_DEPLOY_BLOCK
npm run build && npm run start   # http://localhost:4311
```

Connect the smoke-test wallet on chain 4663 and check, in order:

- the footer shows `v0.6.0`
- the menu lists all 15 Stock Tokens
- "Your old Dust balance" appears under the checklist, listing the v2 Stock
  Token positions, the v2 ETH float ("Withdraw all") and, if present, the USDG
  and WETH allowances to the v2 capture with "Revoke"
- the basket builder shows "Save basket" (the v3 sweeper has none for you) and
  the "Stop sweeps" button appears only once a basket is saved
- a swap in the swap panel that fills only partly shows the "Only $X of your
  $Y was filled; the rest was refunded" toast (hard to provoke on the deep
  launch pools; the fork test covers it)

If the legacy card is missing while the wallet still holds something on v2,
the `NEXT_PUBLIC_DUST_V2_*` values are wrong or equal the live set. Stop the
server and delete `.env.local`.

### F4. [FOUNDER] Deploy to Vercel with git metadata hidden

```bash
cd app && mv .git /tmp/dust-git.bak && npx vercel --prod ; mv /tmp/dust-git.bak .git
ls -d .git    # must print .git; if it does not, the mv back failed: fix before anything else
```

Open the production URL and repeat the F3 checks against the live site. Then
commit the app repo (`v0.6.0: v3 contracts, legacy withdraw card, Stop sweeps,
partial-fill toast`) with the project identity.

---

## G. User migration

### G1. What the legacy card does

Any wallet that connects to the new app and still holds something on v2 sees
a card titled "Your old Dust balance" with the line "Dust moved to new
contracts after the audit. Withdraw here, then set up again above; nothing
else changes." It reads the v2 vault and v2 capture directly and offers only
withdrawals and revocations, one transaction each, signed by the user:

- uninvested change: `withdrawAccrued(amount, wallet)` on the v2 vault
- each Stock Token position: `withdrawToken(token, amount, wallet)` on the v2
  vault (tokens go to the wallet in kind; the token list is the v2 menu plus
  the user's v2 basket)
- ETH float: `withdrawEth(amount, wallet)` on the v2 capture ("Withdraw all")
- USDG and WETH allowances to the v2 capture: `approve(v2capture, 0)`

The card disappears when everything reads zero. Nothing on v2 is swept or
pulled after D1 and E3, so a user who ignores the card loses nothing and can
come back for it in a year. The v2 weekly cap is not shown; it is inert
without a keeper, and a user who wants it at zero anyway calls
`setWeeklyCap(0)` on the v2 capture from Blockscout.

On v3 the same wallet starts from scratch: baskets live on the sweeper, caps
and floats on the capture, allowances are per contract. The first-run
checklist walks them through it.

### G2. [FOUNDER] Your own wallet, first

Use `$TEST_USER` in the browser; `cast` for checks. Keep the keeper in dry-run
until the round-up exists.

```bash
R=robinhood_mainnet
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
```

1. Leave v2. In the legacy card: withdraw every Stock Token position, then
   "Withdraw all" on the ETH float, then "Revoke" on any USDG or WETH
   allowance shown. Optionally `setWeeklyCap(0)` on `$OLD_CAPTURE` via
   Blockscout write-contract. Confirm:

   ```bash
   cast call $OLD_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R                # 0
   cast call $OLD_VAULT "tokenBalanceOf(address,address)(uint256)" $TEST_USER $SPY --rpc-url $R   # 0 (repeat per token you held)
   cast call $OLD_CAPTURE "ethBalance(address)(uint256)" $TEST_USER --rpc-url $R                  # 0
   cast call $USDG "allowance(address,address)(uint256)" $TEST_USER $OLD_CAPTURE --rpc-url $R     # 0
   cast call $WETH "allowance(address,address)(uint256)" $TEST_USER $OLD_CAPTURE --rpc-url $R     # 0
   ```

   The card is gone from the page once these read zero.

2. Set a basket on v3. Basket: SPY 100% (one leg keeps the smoke-test sweep
   cheap and the SPY pool is the one the fork tests exercise). Sign.

   ```bash
   cast call $DUST_SWEEPER "basketLengthOf(address)(uint256)" $TEST_USER --rpc-url $R   # 1
   cast call $DUST_SWEEPER "basketNonce(address)(uint256)"    $TEST_USER --rpc-url $R   # 1
   cast call $DUST_SWEEPER "lastSweepAt(address)(uint256)"    $TEST_USER --rpc-url $R   # 0
   ```

3. Opt in to Capture everywhere on v3: weekly cap 5 USDG, then ETH row,
   deposit 0.002, sign both.

   ```bash
   cast call $DUST_CAPTURE "configOf(address)(uint96,uint96,uint64)" $TEST_USER --rpc-url $R   # 5000000, 0, <timestamp>
   cast call $DUST_CAPTURE "ethBalance(address)(uint256)" $TEST_USER --rpc-url $R               # 2000000000000000
   ```

4. Make a round-up: from `$TEST_USER`, outside the app, send 0.001 ETH to
   another address you control. Within two ticks the keeper logs `capture
   <user>: owed 0.xx, weekly headroom 5` and a `[dry-run] ... would send
   captureFromEth(...)`. Flip the keeper live (E5). The next tick sends;
   verify:

   ```bash
   cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R   # the round-up (0 if the sweep already ran)
   ```

5. Watch the sweep. With `minSweepAmount` 0 and `DUST_MIN_SWEEP=0`, the tick
   after the capture sweeps. The log shows the quote (`accrued`, `1 legs`,
   `minOuts`, `maxAmount`, `nonce 1`, `feeBps 100`, the contract floor and the
   keeper's own floor) then `sent` and `included`.

   ```bash
   cast call $DUST_VAULT "accruedStable(address)(uint256)" $TEST_USER --rpc-url $R                    # 0 (or a residue of at most 2 raw units)
   cast call $DUST_VAULT "tokenBalanceOf(address,address)(uint256)" $TEST_USER $SPY --rpc-url $R       # > 0
   cast call $DUST_SWEEPER "basketNonce(address)(uint256)" $TEST_USER --rpc-url $R                    # 2 (consumed by the sweep)
   cast call $DUST_SWEEPER "lastSweepAt(address)(uint256)" $TEST_USER --rpc-url $R                    # the sweep block's timestamp
   cast call $USDG "balanceOf(address)(uint256)" $DUST_SWEEPER --rpc-url $R                           # 0 (the sweeper keeps nothing)
   cast call $USDG "balanceOf(address)(uint256)" $TREASURY --rpc-url $R                               # up by 1% of what was invested
   ```

   On Blockscout the sweep tx carries `Swept(user, stableIn, invested, fee,
   returned)`, one `LegBought`, one `FeeCharged`, no `LegSkipped`. The keeper
   re-reads `basketNonce` before every send, so a second sweep in the same 5
   minutes is not attempted; if you force one it reverts `TooSoon`.

6. Try the veto. In the basket builder at the bottom of the page, "Stop
   sweeps", confirm, sign. `basketLengthOf` reads 0, `basketNonce` reads 3,
   the checklist shows "Basket saved" unticked, and the keeper logs the
   `BasketCleared` and drops you from its sweep set. Save the basket again
   (nonce 4) when you are done.

7. Withdraw in kind: Vault card, withdraw the SPY to the wallet. Then
   "Withdraw all" on the v3 ETH float if you do not want to keep it parked.
   Both work in every state; that is the property the whole design rests on.

### G3. Tell the users

Thirteen wallets set a basket on v2. Post the notice in the Telegram channel
and on X, pin it in Telegram for two weeks, and link it from the app's
legacy card copy if you want (the card already says the essentials).

Telegram (long form):

> Dust moved to new contracts today.
>
> The first external audit of our Robinhood Chain contracts came back on 11 September with 12 findings: one high, four medium, five low, two informational. We fixed all of them in a new set of four contracts and redeployed. The old set could not be patched in place; the vault is wired once, on purpose, so nothing could be swapped under your feet later. That cuts both ways, and today it means a move.
>
> What you need to do: open the app and connect. If you had anything in the old contracts, a card at the top says "Your old Dust balance". Withdraw your Stock Tokens, your uninvested change and your ETH float from there, and revoke the old allowances. Then set your basket and cap again, exactly as you did the first time. Ten minutes, a few signatures, and only you can sign them.
>
> What changed under the hood, in plain terms. Swaps that only partly fill now refund the rest to you in the same transaction (the high finding: the old router kept it). The fee is now charged only on what a sweep actually buys, never on money that came back to you. Every sweep has a price floor the contract reads from the pool's own 10-minute average, so a bad keeper cannot buy you a worse price than 3% under it. You can stop sweeps yourself with one click ("Stop sweeps"), and a sweep can run at most once every five minutes per wallet. The compiler version is pinned so anyone can rebuild the exact bytecode.
>
> Nothing was lost and nothing was at risk on the old contracts as far as we know; the audit measured, we fixed, we moved. Withdrawals from the old contracts work forever, so there is no deadline. The full report, our response to each finding and the new addresses are in the repo.
>
> Questions here, we read everything.

X (thread, three posts):

> 1/ Dust's first external audit came back: 12 findings, 1 high, 4 medium, 5 low, 2 info. All fixed. We redeployed the Robinhood Chain contracts today because the vault is wired once by design and cannot be patched in place.
>
> 2/ If you used Dust before today: connect, find "Your old Dust balance", withdraw and revoke, then set your basket and cap again. Withdrawals from the old contracts work forever, so no deadline, but the keeper only sweeps the new ones.
>
> 3/ What changed: partial swaps refund you in the same tx, the fee applies only to what a sweep actually buys, every sweep has an on-chain price floor from the pool's 10-minute average, and you can stop sweeps yourself with one click. Report, responses and addresses are in the repo.

Keep it to this. No price talk, no expectations, nothing that reads as a
promise. If someone asks about $DUST, the answer is that this change is about
the contracts and does not touch the token.

### G4. [FOUNDER] Restore the production floors

After your own sweep in G2 has landed:

```bash
S="--rpc-url $DUST_RPC --keystore $DEPLOYER_KEYSTORE --from $DEPLOYER"
cast send $DUST_SWEEPER "setMinSweepAmount(uint256)" 5000000 $S      # 5 USDG; from the Safe instead if it owns the sweeper
flyctl secrets set -a dust-keeper-evm DUST_MIN_SWEEP=5000000         # or unset it if A7 showed it was never set
```

Leave your own basket, cap and float on v3 as you want them for everyday use.

---

## H. After

### H1. Address book

`MAINNET-ADDRESSES.md` carries a `## Dust contracts v3` section with
placeholders. Fill the four addresses, the deploy block range, the tag, the tx
hashes reference and the Blockscout status. Mark the v2 section "superseded
2026-09-xx, sweeps paused, withdrawals work forever". Then:

```bash
cd contracts
git config user.name && git config user.email     # project identity
grep -rnE "/Users/|/home/|alch_gw|@gmail" MAINNET-ADDRESSES.md broadcast/Deploy.s.sol/4663/run-latest.json && echo "LEAK" || echo clean
git add MAINNET-ADDRESSES.md broadcast/Deploy.s.sol/4663/
git commit -m "mainnet: deploy Dust v3 (post-audit) on Robinhood Chain 4663"
```

Push only after the account check. Update the two lines in `AUDIT-SCOPE.md`
that say v3 is not deployed yet ("Deployed instances" table becomes the v3
set, with v2 listed as superseded) in the same commit.

To know when the legacy card can be hidden (F1), check the v2 vault's Stock
Token balances and the v2 capture's WETH balance from A6; all zero means
everyone left.

### H2. Notify CredShields

Through the channel the engagement runs on (the repository they were given
access to, or the thread the report arrived in). Suggested text:

> Subject: Dust contracts, response to the 11 September report, retest revision
>
> Thanks for the report. We have responded to all twelve findings and redeployed. The revision for retest is tag `audit-2026-09-v3` in the same repository (the audited revision was `audit-2026-09`, commit 01b014f). `AUDIT-SCOPE.md` at that tag has the per-finding table with file and line references and the name of the test that reproduces each scenario; `test/DustAuditV3.t.sol` holds 22 of those reproductions against mocks and `test/DustMainnetFork.t.sol` the ones that run against live mainnet state (the H001 partial fill against the thin TSLA/USDG 0.05% pool, the M003 price move, the L001 frozen treasury on real USDG). Full suite: 138 passing, 0 skipped. The mainnet addresses of the v3 set are in `MAINNET-ADDRESSES.md`; the v2 sweeper is paused and its vault remains withdrawable.
>
> Summary of the responses:
>
> | ID | Status | Response |
> |---|---|---|
> | H001 | Fixed | Router requires the factory-canonical pool for (stable, tokenOut, fee); spent stable and tokens received are measured as balance deltas, both non-zero, tokensOut >= minOut with minOut > 0; the unspent remainder is refunded before the round-up is computed on the spent amount; the callback pays at most amountIn in aggregate; the event reports the spent amount. |
> | M001 | Fixed | Legs are sliced from amount * 10000 / (10000 + feeBps); the fee is feeBps of what was actually invested, charged after the legs; leftover is re-accrued untaxed and never re-taxed. |
> | M002 | Fixed | buyLeg credits the vault's measured balance delta and requires it to be non-zero. |
> | M003 | Fixed | clearBasket() revocation; per-leg on-chain floor of the pool's 10-minute TWAP output less 300 bps (minOut can only tighten it; a pool without oracle history is skipped, not fatal); basketNonce consumed per sweep; MIN_SWEEP_INTERVAL of 300 s per user. |
> | M004 | Fixed | sweep(user, maxAmount, pools, minOuts, expectedNonce, expectedFeeBps): AmountAboveQuote, PoolMismatch (delisted legs skipped regardless), FeeChanged, StaleBasket, LengthMismatch. |
> | L001 | Fixed for the treasury; sweeper-freeze variant accepted | The fee transfer is a non-reverting call; on failure the fee is zero for that sweep, FeeSkipped is emitted and the amount returns to the user. An issuer freeze of the immutable sweeper address stops sweeping until a redeploy and leaves balances and withdrawals untouched; documented as accepted. |
> | L002 | Fixed | listStock requires pool == factory.getPool(token0, token1, fee); the leg callback pays at most legIn in aggregate and buyLeg reverts SlippageExceeded if the measured spend exceeds legIn. |
> | L003 | Fixed | src/libraries/SafeTransfer.sol for every token movement in all four contracts: accepts no return data or true, bubbles the token's own revert data, reverts TransferFailed() (the selector the contracts already declared) on a false return or a codeless address. The if (!...) revert wrappers are gone. |
> | L004 | Fixed | _paySwap decrements pending.wethLimit in storage per callback; the vault's stable delta must equal amountOut (PartialFill otherwise); the constructor takes the factory and requires ethPool == factory.getPool(weth, stable, fee); NatSpec states the aggregate bound. |
> | L005 | Fixed | pragma solidity 0.8.35 in all seven files (deviation from upstream noted in the two vendored libraries), solc = "0.8.35" in foundry.toml. |
> | I001 | Accepted | Documented in the DustSweeper NatSpec and in AUDIT-SCOPE.md "Known limitations". |
> | I002 | Fixed | The delisted-leg skip runs before the ZeroMinOut check. |
>
> Two deliberate deviations from the literal recommendations, both documented in AUDIT-SCOPE.md: the M001 slicing uses amount * 10000 / (10000 + feeBps) rather than amount minus the fee so the fee fits exactly on a full fill (residue at most two raw units), and L003 uses a small vendored helper rather than OpenZeppelin's SafeERC20 so the existing TransferFailed selector survives for the keeper and app. We would welcome a retest against the tag; please tell us what you need from us for it.

### H3. Notify QuillAudits

If a second review is booked or quoted against `audit-2026-09`, move its
scope:

> Subject: Dust contracts, scope moved to tag audit-2026-09-v3
>
> The revision to review is now tag `audit-2026-09-v3` (previously `audit-2026-09`). It is the response to a first review that returned 12 findings; the per-finding table, the trust model and the invariants we would like checked are in `AUDIT-SCOPE.md` at that tag. In-scope files are unchanged in number: the four contracts, the interface file, the vendored TickMath and FullMath, plus the new `src/libraries/SafeTransfer.sol` and the deploy script for wiring correctness. Pragma is pinned to 0.8.35 and the suite is 138 passing (mock, mainnet fork and testnet fork). The contracts are deployed on Robinhood Chain 4663 at the addresses in `MAINNET-ADDRESSES.md`; the previous set is paused for sweeps and withdrawable. The first report can be shared under its confidentiality terms if useful for the retest angle.

### H4. Monitoring to add

The v3 keeper health JSON has new counters worth alerting on next to the old
ones (`lowGas`, `txDropped`, `txReverted`): `sweepRequotes` climbing every
tick for the same user (a quote that never lands: fee or menu change, or a
user who cleared their basket mid-quote), `sweepLegsNoTwap` above zero (a
listed pool lost its oracle history), and any `FeeSkipped` warning in the logs
(the treasury refused a transfer). On-chain: `LegSkipped` bursts, and the
router's USDG balance, which must read 0 at every block.

---

## I. If something goes wrong

- **Dry run fails a precheck** (`Deploy: factory does not know this pool`,
  `pool not from the configured factory`, decimals): the env is wrong.
  Nothing was sent. Fix and rerun B2.
- **Broadcast stopped midway**: rerun B3 with `--resume`. Until `setModules`
  ran the vault is inert; until 15 `listStock` calls ran `menuLength` is
  short. C catches both.
- **New keeper dies with `is a v2 DustSweeper`**: a staged address did not
  apply. `flyctl secrets list`, re-set without `--stage`, redeploy.
- **New keeper dies with `state file belongs to ... sweeper 0x6FE0...`**:
  `fly.toml` still points at `keeper-state-v2.json`. Fix, redeploy.
- **Keeper logs `contract refused the quote with TooSoon` or `AmountAboveQuote`
  every tick**: normal once or twice (a round-up landed between quote and
  send); every tick for an hour means the clock or the quote path is wrong,
  set `DUST_DRY_RUN=1` and read the quote lines.
- **App shows "Save basket" for a wallet that has one on v3**: a Vercel
  variable points at v2. F1, then F4.
- **Legacy card missing for a wallet that holds v2 positions**: the
  `NEXT_PUBLIC_DUST_V2_*` values are zero, wrong, or equal the live set.
- **A user cannot withdraw a Stock Token from v2 or v3**: check the issuer's
  registry (`0xe10b6f6B275de231345c20D14Ab812db62151b00`, `paused()` and
  `isBlocked(address)`); Dust cannot override an issuer pause or block. USDG
  and ETH withdrawals do not depend on the registry.
- **You need to go back to v2** (nothing custodial is at risk either way):
  `setPaused(false)` on the v2 sweeper, stage the four v2 addresses on Fly,
  check out the last v2 keeper commit (the v3 keeper refuses v2), point
  `fly.toml` at `keeper-state-v2.json`, redeploy; put the v2 addresses back in
  Vercel and redeploy the app at the previous version. Users who already
  moved to v3 keep their v3 positions and withdraw them from the v3 vault at
  any time (the app's Withdraw card works against whichever set is
  configured; for the other set, Blockscout write-contract).

## Appendix: env block for copy-paste

Fill the blanks from `MAINNET-ADDRESSES.md` and B4, then `source` it in a
shell you will close afterwards. Never commit it.

```bash
export DEPLOYER=0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b       # A2
export DEPLOYER_KEYSTORE=.secrets/deployer
export KEEPER=0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD         # A3, unchanged
export TREASURY=0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b       # A4, interim
export OWNER=0x...               # A4, or leave unset on purpose
export DUST_RPC="https://robinhood-mainnet.g.alchemy.com/v2/<keeper-key>"   # A5
export TEST_USER=0x...           # A8
export FEE_BPS=100
export OLD_VAULT=0xC6d3FCA5aa8274c03d015d914ae102f3FF344137      # A6, v2 (superseded)
export OLD_ROUTER=0x6A2A77F4ccb7ca9d5Af36EDb8491Af201bF209b3
export OLD_SWEEPER=0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899
export OLD_CAPTURE=0xc33e4EB6099bd96127D6016E9EdE1234d3a69406
export DUST_VAULT=0x...          # B4, v3
export DUST_ROUTER=0x...
export DUST_SWEEPER=0x...
export DUST_CAPTURE=0x...
export DUST_DEPLOY_BLOCK=        # B4, first receipt block
```
