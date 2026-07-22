# M0 findings — Robinhood Chain testnet spike

Date: July 22, 2026. Network: Robinhood Chain testnet (chain ID 46630).

## Verdict so far: GO (fork-verified; live confirmation pending faucet funds)

All five composability tests pass on a fork of the live testnet, executing the
real deployed Stock Token and pool bytecode:

| Test | Result |
|---|---|
| Arbitrary contract receives + holds TSLA | PASS |
| Approve + transferFrom pull into contract, push to third address | PASS |
| Contract buys TSLA with USDC directly on pool | PASS (1000 USDC → ~11.74 TSLA) |
| Contract buys TSLA with WETH | PASS (0.005 WETH → ~4.08 TSLA) |
| Round trip buy + sell back to USDC | PASS |

Remaining for full GO: run `script/ProbeLive.s.sol` broadcast once the dev
wallet has faucet funds (faucet requires a Google-account sign-in, so it's a
manual step). This repeats the same calls with real transactions.

## Key discoveries

1. **Stock Tokens are blocklist-gated, not whitelist-gated.** The token is a
   proxy; its transfer path checks `paused()` on the controller and
   `isBlocked(from/to)`. Unknown contracts pass by default. This is the load-bearing
   fact for Dust: composability is default-open, with issuer kill-switches.
   Design implication: the sweeper must handle a future `isBlocked` or `paused`
   revert gracefully (park the round-up in USDG, never brick the vault).
2. **The deep testnet pools are a Synthra fork, not canonical Uniswap.** Callback
   is `synthraV3SwapCallback` (v3 semantics otherwise identical). The probe
   supports both callback names. M1 must not assume canonical Uniswap artifacts;
   verify per-pool factory (`0x911b4000D3422F482F4062a913885f7b035382Df` is the
   Synthra-style factory with the liquid TSLA pools).
3. **Testnet has no canonical USDG markets.** The docs' USDG address exists on
   mainnet only. Testnet stable liquidity is an 18-decimal "USDC"
   (`0xbf4479C0...`). Two fake/duplicate "USDG" tokens exist on testnet — token
   addresses must always come from config, never from symbol lookup.
4. **Faucet:** 0.01 ETH + 5 each of TSLA/AMZN/PLTR/NFLX/AMD per 24h. Requires
   Cloudflare check + Google account sign-in (use the project account).
5. **Aave and Morpho-style forks already hold Stock Tokens on testnet** ("Aave
   Stock TSLA" aToken is a top-5 TSLA holder) — independent evidence that
   third-party protocols custody Stock Tokens fine.

## Address book (testnet 46630, discovered onchain)

| Contract | Address |
|---|---|
| TSLA Stock Token (proxy) | `0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E` |
| TSLA controller/implementation slotholder | `0x1dF3cA0fD30ED5eeb09eB01938f4E9c5196E6Ca5` |
| Testnet USDC (18 dec) | `0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F` |
| WETH | `0x33e4191705c386532ba27cBF171Db86919200B94` |
| V3-fork factory (Synthra) | `0x911b4000D3422F482F4062a913885f7b035382Df` |
| TSLA/USDC 0.3% pool | `0xFfEf1147c3724a19AB7328F4e361C049ba452dA9` |
| TSLA/WETH 0.3% pool | `0x593e2e0EF3869616Ec3Fbe989dCFf2699D52b69B` |
| High-volume router (unidentified, likely UniversalRouter) | `0x6f308b834595312f734e65e273f2210f43fc48f8` |
| Dev wallet (throwaway) | `0xE819f1c531B7a676ed065E9e3C717e49CD9E41C6` |

## Still open (carry into M1)

- Identify/verify the canonical router ABI (`0x6f30...`) or route via pools directly.
- ERC-4337 EntryPoint address + bundler availability on testnet.
- EIP-7702 support check (`cast` delegation test) on this chain.
- Chainlink feed addresses (needed for non-stable round-up pricing later).
- Whether mainnet pools are canonical Uniswap or also Synthra (affects M1 router integration).
