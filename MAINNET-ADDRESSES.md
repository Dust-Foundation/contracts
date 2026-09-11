# Robinhood Chain MAINNET address book (chain id 4663)

Discovered and verified on-chain (eth_call / eth_getCode) by the mainnet-discovery research pass, 2026-09-03.
Only addresses marked verified were confirmed on-chain; treat anything else as needing verification before use.

## Chain
- Chain id: 4663 (0x1237)
- Public RPC: https://rpc.mainnet.chain.robinhood.com (aggressively rate-limited; use a paid provider such as Alchemy for the keeper and app)
- Explorer: https://robinhoodchain.blockscout.com (Blockscout; API is Cloudflare-gated for scripts)
- Gas: ETH. Blocks ~0.1s. Observed gas price ~0.4-0.6 gwei.

## Stable + core
- USDG (Global Dollar): 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 — 6 decimals (verified). Paxos EIP-1967 proxy with pause() and per-address freeze.
- WETH: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 — 18 decimals (verified).

## DEX (canonical Uniswap — NOT the Synthra fork seen on testnet)
- Swap callback pools invoke: uniswapV3SwapCallback (selector 0xfa461e33). Dust contracts already implement it.
- Uniswap v3 Factory: 0x1f7d7550b1b028f7571e69a784071f0205fd2efa (verified: feeAmountTickSpacing 100/500/3000/10000)
- QuoterV2: 0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7 (verified)
- SwapRouter02: 0xcaf681a66d020601342297493863e78c959e5cb2 (verified)
- UniversalRouter: 0x8876789976decbfcbbbe364623c63652db8c0904
- Permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3
- Best v3 fee tier per stock vs USDG: TSLA 0.3% (3000), NVDA 0.05% (500), AAPL 0.05% (500), AMZN 0.3% (3000), SPY 0.05% (500). Other tiers may be initialized but EMPTY (revert) — always use explicit per-stock pool config.
- Note: some Stock/USDG liquidity is deepest on Uniswap v4 (PoolManager), e.g. SPY. v3 pools are sufficient for $1-$100 round-ups today; a v4 route is a later optimization.

## Stock Tokens (all OpenZeppelin BeaconProxy, 18 decimals)
- Shared beacon + AccessControlsRegistry: 0xe10b6f6B275de231345c20D14Ab812db62151b00 — paused() and isBlocked(address) live HERE, not on the token.
- Current implementation (Stock): 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2
- Gating: blocklist (default-open) — third-party contracts can hold/transfer, same model as testnet. approve()/permit() are ALSO gated by pause/blocklist.
- ERC-8056 UI multiplier: raw balances are not share counts for some tickers; display must use uiMultiplier()/balanceOfUI().

### Verified token addresses
- AAPL: 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, decimals 18, 'Apple • Robinhood Token', totalSupply 14620.974, paused=false, uiMultiplier 1.00056608 (non-1: raw balance != UI shares)
- AMD: 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC, decimals 18, 'AMD • Robinhood Token', totalSupply 3850.787, paused=false, uiMultiplier 1.0
- AMZN: 0x12f190a9F9d7D37a250758b26824B97CE941bF54, decimals 18, 'Amazon • Robinhood Token', totalSupply 7590.83, paused=false, uiMultiplier 1.0
- CHAIN: chainId 0x1237 (4663) confirmed; public RPC https://rpc.mainnet.chain.robinhood.com (rate-limited: 429 on bursts, large JSON-RPC batches rejected); explorer https://robinhoodchain.blockscout.com (API behind Cloudflare challenge); Alchemy robinhood-mainnet recommended by docs; sequencer feed wss://feed.mainnet.chain.robinhood.com
- COIN: 0x6330D8C3178a418788dF01a47479c0ce7CCF450b, decimals 18, 'Coinbase • Robinhood Token', totalSupply 6299.568, paused=false
- GOOGL: 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, decimals 18, 'Alphabet Class A • Robinhood Token', totalSupply 6951.76, paused=false, uiMultiplier 1.0 (no GOOG class C token exists)
- META: 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, decimals 18, 'Meta Platforms • Robinhood Token', totalSupply 2113.625, paused=false, uiMultiplier 1.0
- MSFT: 0xe93237C50D904957Cf27E7B1133b510C669c2e74, decimals 18, 'Microsoft • Robinhood Token', totalSupply 3656.257, paused=false, uiMultiplier 1.0
- MSTR: 0xec262a75e413fAfD0dF80480274532C79D42da09, decimals 18, 'Strategy Inc. • Robinhood Token', totalSupply 10839.201, paused=false
- NFLX: 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8, decimals 18, 'Netflix • Robinhood Token', totalSupply 4674.883, paused=false, uiMultiplier 1.0
- NVDA: 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, decimals 18, 'NVIDIA • Robinhood Token', totalSupply 60019.958, paused=false, uiMultiplier 1.0
- PLTR: 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A, decimals 18, 'Palantir Technologies • Robinhood Token', totalSupply 9180.981, paused=false, uiMultiplier 1.0
- QCOM: 0x0f17206447090e464C277571124dD2688E48AEA9, decimals 18, 'Qualcomm • Robinhood Token', totalSupply 195.175, paused=false
- QQQ: 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68, decimals 18, 'Invesco QQQ • Robinhood Token', totalSupply 5581.84, paused=false, uiMultiplier 1.0
- SPY: 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, decimals 18, 'SPDR S&P 500 ETF Trust • Robinhood Token', totalSupply 17925.663, paused=false, uiMultiplier 1.0
- TSLA: 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, decimals 18, name 'Tesla • Robinhood Token', totalSupply 8410.032, paused=false, uiMultiplier 1.0, uid 0x00000000000000000000000000000000cfece3244ea34bb29414dd9488b32d9f
- USDG: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, decimals 6 (CONFIRMED), name 'Global Dollar', totalSupply ~583.4M, proxy (170-byte code), paused()=false
- USDG: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; decimals()=6; symbol USDG; name 'Global Dollar'; 170-byte proxy
- WETH: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, decimals 18, symbol WETH (L2 WETH per docs)
- WETH: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; 18 dec; matches SwapRouter02.WETH9() and QuoterV2.WETH9()

### Verified pools
- usdg_duplicates: Only one USDG-symbol token with DEX liquidity on chain 'robinhood' per DexScreener (24 pairs, ~$15M) and GeckoTerminal (deepest USDG/WETH 0.01% pool ~$23.7M): 0x5fc5...d168. Explorer-wide symbol scan NOT possible (Blockscout behind Cloudflare challenge for scripted access) so unlisted fakes cannot be excluded. Robinhood docs explicitly warn tokens with matching names but different addresses are not legitimate.  (NOT verified on-chain)
- mainnet_dex_semantics: Deepest USDG/WETH pool 0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca: factory()=0x1f7d7550b1b028f7571e69a784071f0205fd2efa, fee 100, token0 WETH, token1 USDG; factory getPool(WETH,USDG,100) returns it, getPool(USDG,WETH,500)=0x69bfaf19c9f377bb306a89aed9f6b07e2c1a8d9a, feeAmountTickSpacing(100)=1,(3000)=60, owner 0x05c420bc4823e039aa4da645edde743486daaa25 (24,535-byte factory); pool bytecode contains uniswapV3SwapCallback selector 0xfa461e33 -> Uniswap-v3 semantics with the CANONICAL callback name, not the testnet Synthra fork. 0x1F98431c8aD98523631AE4a59f267346ea31F984 (canonical Arbitrum v3 factory address) has 2,109 bytes of code here but returns empty for owner()/getPool -> not a v3 factory; never assume canonical addresses.
- stock_token_pool_venues: GeckoTerminal labels many USDG/stock pairs as Uniswap V4 pools (32-byte ids): AAPL 0.3%, PLTR 1%, MSFT 0.3%, META 0.3%, AMD 1%, MU 1%, NVDA 0.3%; v3 pools: NVDA/USDG 0.05% 0xd4eb21209c4d6093f80b5b84f5c45cc093ea14a3 (~$7.5M), DELL/USDG 1%, UPS, RBLX. NVDA token 0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec verified symbol NVDA, 18 decimals. TSLA not seen in the USDG search results (not exhaustive).  (NOT verified on-chain)
- live_kill_switch_state: registry.paused()=false; TSLA tokenPaused()=false, oraclePaused()=false, uiMultiplier()=1e18; isBlocked=false for Uniswap v4 PoolManager, v3 TSLA/USDG pool, SwapRouter02, Morpho, Wintermute MEV bot, 0xdEaD
- contracts_hold_stock_tokens_evidence: TSLA: 51,701 holders, 7.05M transfers. #1 holder is Uniswap v4 PoolManager 0x8366a39CC670B4001A1121B8F6A443A643e40951 (3,098 TSLA; also #1 for NVDA 21,230 and SPY 8,375). Other contract holders: Uniswap v3 pools 0xf4ACdAEE… (TSLA/USDG 0.3%, 162 TSLA), 0xA953CA88… (WETH/TSLA 0.3%), 0xd7C78668… (TSLA/0xc1a0… 1%), Morpho 0x9D53d5E3… (4.36 NVDA, 10.26 SPY, 0.06 TSLA), SafeProxy multisigs, TimelockController, StockVault 0x49EF9869… (82 TSLA), CreditVault 0x57B8f68e… (45.6 TSLA), AlgebraPool, RamsesV3Pool, UniswapV2Pair, V2FeeEscrow, Wintermute MEV bot contract.
- mainnet_dex_is_canonical_uniswap_not_synthra: Uniswap v3 factory 0x1f7d7550b1b028f7571e69a784071f0205fd2efa (code present; pools report factory()=this) matches Uniswap's official Robinhood Chain deployment page; also SwapRouter02 0xcaf681a66d020601342297493863e78c959e5cb2, QuoterV2 0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7, UniversalRouter 0x8876789976decbfcbbbe364623c63652db8c0904, NonfungiblePositionManager 0x73991a25c818bf1f1128deaab1492d45638de0d3, Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3; v4 PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951, V4Quoter 0x8dc178efb8111bb0973dd9d722ebeff267c98f94, StateView 0xf3334192d15450cdd385c8b70e03f9a6bd9e673b, v4 PositionManager 0x58daec3116aae6d93017baaea7749052e8a04fa7. Callback is uniswapV3SwapCallback (canonical), unlike testnet's synthraV3SwapCallback.
- tsla_usdg_pools_and_quotes: getPool(TSLA,USDG): 0.01% 0x7868622Ff2C3b1B6C8acb15fE0bDAEBF043DDa48 (empty), 0.05% 0xc4f0172D6ac8DD294Dd1137D047d5E1893760236 (empty), 0.3% 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3 (~339,309 USDG + 162.4 TSLA, liquidity 3.36e17), 1% 0xB349FB08C2712f3A70Bad40a4d006b68d67e888b (tiny). TSLA/WETH 0.3% 0xA953CA88ff430e9487c60cA34d757414f4efdA07. QuoterV2 read-only: 100 USDG -> 0.26116 TSLA (0.3%); 2.58 USDG -> 0.006738 TSLA; 100 USDG -> 0.12892 SPY (0.3%); 0.05% and 0.01% quotes revert (no liquidity). v4 PoolManager holds far more (46.7M USDG-units? = 46,694,300 USDG and 3,098 TSLA) so deepest routing is v4.
- uniswap_v3_factory: 0x1f7d7550b1b028f7571e69a784071f0205fd2efa; code 24535 B; feeAmountTickSpacing(100)=1,(500)=10,(3000)=60,(10000)=200; owner()=0x05c420bc4823e039aa4da645edde743486daaa25 (contract, 7266 B, its owner()=0x2BAD8182C09F50c8318d769245beA52C32Be46CD which also is v4 PoolManager.owner())
- uniswap_v3_swapRouter02: 0xcaf681a66d020601342297493863e78c959e5cb2; code 24497 B; factory()==0x1f7d...; WETH9()==0x0bd7...; top swap sender on TSLA pools
- uniswap_universalRouter: 0x8876789976decbfcbbbe364623c63652db8c0904; code 24546 B; same address listed for v3 and v4; second-largest sender on TSLA/WETH pool
- swap_callback_selector: uniswapV3SwapCallback(int256,int256,bytes) = 0xfa461e33; found 2x in TSLA/USDG-500 pool runtime bytecode; synthraV3SwapCallback 0x13abb0ca 0x; pancakeV3SwapCallback 0x23a69e75 0x; algebraSwapCallback 0x2c8958f6 0x; uniswapV3MintCallback 0xd3487997 1x; swap(address,bool,int256,uint160,bytes) 0x128acb08 1x
- pool_bytecode_canonical: TSLA/USDG-3000 pool runtime 22142 bytes == Ethereum mainnet canonical UniswapV3Pool (0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640) length; 359 differing bytes in 82 regions, all within immutable constants (token0, token1, factory, fee, tickSpacing, maxLiquidityPerTick); pool.factory() returns 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
- v3_pool TSLA/USDG 0.01%: 0x7868622ff2c3b1b6c8acb15fe0bdaebf043dda48; token0 TSLA token1 USDG; liquidity 0; balances 1 wei / 2 wei (dead)
- v3_pool TSLA/USDG 0.05%: 0xc4f0172d6ac8dd294dd1137d047d5e1893760236; liquidity 0; slot0 at MIN_SQRT_RATIO (tick -887272), balances 13/23 wei; quoter reverts; sell quote reverts SPL (unusable)
- v3_pool TSLA/USDG 0.3% (BEST): 0xf4acdaeeb7022862a763c9b1b885e11191c889e3; token0 TSLA token1 USDG; liquidity 3.357e17; balances 160.49 TSLA + 338,060 USDG; spot 381.75 USDG/TSLA; quotes 1/10/100/1000 USDG -> 0.002612/0.026116/0.261160/2.611245 TSLA (cost vs spot 0.301/0.301/0.302/0.316%); 0.01 TSLA -> 3.806 USDG; 1235 swaps in 200k blocks (~5h), USDG leg median $72.7 p10 $3.16 p90 $1,649
- v3_pool TSLA/USDG 1%: 0xb349fb08c2712f3a70bad40a4d006b68d67e888b; liquidity 6.69e12; 0.014 TSLA + 34.16 USDG; exhausts at ~4 USDG (10 USDG quote hits price limit)
- v3_pool TSLA/WETH 0.3%: 0xa953ca88ff430e9487c60ca34d757414f4efda07; token0 WETH token1 TSLA; liquidity 1.70e21; 36.54 WETH + 135.45 TSLA; 1180 swaps/200k blocks; no TSLA/WETH pools at 100/500/10000
- v3_pool NVDA/USDG 0.05% (BEST): 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; token0 USDG token1 NVDA; liquidity 4.265e18; 6,170,716 USDG + 5,146.9 NVDA; spot 229.44; quotes 1/10/100/1000 USDG cost vs spot 0.050/0.050/0.050/0.051%; >10,000 Swap events in 200k blocks (RPC limit hit)
- v3_pool NVDA/USDG others: 0.01% 0xb75d2D02B0Ec3DE50d32e40A4F1A8DAE8acC4333 L=0 (82.9 USDG + 0.0028 NVDA); 0.3% 0xB944cec30Bd4175855215D767ADC81F39e5f7E2B L=2.54e16 (27,704 USDG + 32.6 NVDA, cost 0.30-0.58%); 1% 0xc277560DF3689A401bA7deDd7626168b234Ceb5e L=0
- v3_pool NVDA/WETH: 0.05% 0x62AB521f71431f78ac374CdbadC6cda3c8916b6C L=1.646e22 (81.1 WETH + 1,571.7 NVDA, >10k swaps/200k blocks); 0.3% 0xC0Be1cb0f674D9737C72B2A63fC542361185b807 L=3.89e21 (116.4 WETH + 1,280 NVDA); 1% 0x8b6a6416A5d1040EfCfa6234dA6AA1265DfE123e L=0; 0.01% none
- v3_pool AAPL/USDG 0.05% (BEST): 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D; token0 USDG token1 AAPL; liquidity 3.32e17; 212,762 USDG + 335.1 AAPL; spot 327.90; quotes cost vs spot 0.050/0.050/0.052/0.067% for 1/10/100/1000 USDG
- v3_pool AAPL/USDG others: 0.3% 0x783C9bbB765047CFdD2b84b92b2Ca9F11D34b7Ed L=1.16e17 (105,036 USDG + 120.5 AAPL; cost 0.30-0.35%); 1% 0x3714aa8105DE1f384481B425788Af413748C1837 L=4.58e15 (1,197 USDG + 2.6 AAPL); 0.01% none
- v3_pool AAPL/WETH: 0.05% 0x8bb3514e2204E1cDF3Ac149EFEe7Ff04D91B719f L=1.58e21 (17.6 WETH + 166.9 AAPL); 0.01% 0xe4D4BA605B042054Bd8815D515D98DdF46232622 L=0; 0.3%/1% none
- v3_pool AMZN/USDG 0.3% (BEST): 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef; token0 AMZN token1 USDG; liquidity 7.75e17; 663.8 AMZN + 250,923 USDG; spot 258.88; quotes cost vs spot 0.301/0.301/0.302/0.309% for 1/10/100/1000 USDG
- v3_pool AMZN/USDG others and AMZN/WETH: AMZN/USDG 0.01% 0x7b242Dfa849419242E3733308D5c91Fe2A7dAe7e L=0; 0.05% none; 1% 0x25967b7CA2d06aa46E47e188231cA78c87Ef1FD7 L=0. AMZN/WETH 0.3% 0x8B2A73a8234cfc12b8B53ae048D0Ddf76BFaC37C L=0; other tiers none (no WETH route for AMZN)
- v3_pool SPY/USDG 0.05% (BEST v3): 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167; token0 SPY token1 USDG; liquidity 2.34e17; 43.3 SPY + 82,880 USDG; spot 774.33; quotes cost vs spot 0.050/0.050/0.052/0.067% for 1/10/100/1000 USDG
- v3_pool SPY/USDG others and SPY/WETH: SPY/USDG 0.3% 0xA43b424Bc609495AED4BCD88d654934b510B0aD9 L=1.6e16 (9.84 SPY + 13,588 USDG; cost 0.30-0.53%); 0.01%/1% none. SPY/WETH 0.05% 0xDDCBBa3666f578E3F09516f21Ff85BFee859AB5e L=8.55e22 (deep); other tiers none
- v3_pool USDG/WETH: 0.01% 0x52e65b17fb6e5ba00ed806f37afcd2daa50271ca L=7.23e18 (3,672 WETH + 14,586,864 USDG; implied ETH ~3,972 USDG); 0.05% 0x69bfaf19c9f377bb306a89aed9f6b07e2c1a8d9a (555 WETH + 2.64M USDG); 0.3% 0xa9188730fe85be88ad499d7d52b099e800fb0334 (58.7 WETH + 1.65M USDG); 1% 0x5f009e071f07e92b6c624e83f52f17bbda34680d (0.053 WETH + 317 USDG). All token0=WETH token1=USDG
- uniswap_v4_contracts: PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951 (24009 B, owner() 0x2BAD8182C09F50c8318d769245beA52C32Be46CD); StateView 0xf3334192d15450cdd385c8b70e03f9a6bd9e673b (3531 B, poolManager()==PoolManager); V4 Quoter 0x8dc178efb8111bb0973dd9d722ebeff267c98f94 (6118 B, quotes work); PositionManager 0x58daec3116aae6d93017baaea7749052e8a04fa7 and PositionDescriptor 0x9639443158e8c5efa35bd45287bf2effd3d8dc06 (listed, not verified on-chain); UniversalRouter shared with v3
- v4_pool TSLA/USDG 0.3%/60 hooks=0: poolId 0x8517f8071ae5b831b738052f12125e8e3d6c158b78728aa44ce3b25e5104d32e; liquidity 9.01e16 (v3 0.3% pool is 3.7x deeper); 822 swaps in 200k blocks vs 1235 on v3; other TSLA/USDG v4 pools have exotic fees (5%-95%) or are empty
- v4_pool SPY/USDG 0.3%/60 hooks=0 (DEEPEST SPY/USDG VENUE): poolId 0xfe2a80bb5618fd14984b92ca6d45bf5ba67443ddb1435e28b2e48df2fc1526cd == keccak256(abi.encode(PoolKey(SPY,USDG,3000,60,0x0))) verified; liquidity 2.176e19 (~93x v3 SPY/USDG-500); slot0 spot 772.06; V4 Quoter 1/10/100/1000 USDG -> 0.001291/0.012907/0.129070/1.290695 SPY (flat 774.78 effective, fee-only cost). Also v4 SPY/USDG 0.05%/5 poolId 0xe5923c8a8be481ec89a2ca784a2bbfa4235de6d88f92260fd66b660c4babf907 L=1.66e18 (7x v3)
- v4_pool AMZN/USDG: hook-less: 0.25%/25 poolId 0x751e89b1e830a959e282377cf53bacc046ff7d6b67c6209504c3db692992c3cd L=2.01e16; 0.3%/60 poolId 0xd32646872e6712af8cf778e34b6bbef1d2ae0bddd83764e1b07333518ad59333 L=6.94e15; both ~38-110x shallower than v3 AMZN/USDG-3000; 29 AMZN/USDG v4 pools total, rest exotic-fee or hooked launchpad pools
- v4_hooked_pools_note: Many dynamic-fee (fee=8388608) hooked v4 pools pair stock tokens with launchpad tokens and some with USDG (hooks e.g. 0x344a66ee5826d8cb59a6f4e1fd802baf2d64a5c7, 0x4e3468951d49f2eea976ed0d6e75ffcb44a9a544); one SPY/USDG hooked pool has L 8.1e16. Not suitable as Dust routes
- unidentified_active_routers: Top Swap senders on TSLA pools besides SwapRouter02/UniversalRouter: 0x65050a9b7e5075a2ba5ced7b1b64ee66262c40dc (167), 0x39b38686a19836ac10162c490e4558e120cbbe5f (161), 0x1521027b665fa38fa4a642991607ad708376dd7b (142) over 200k blocks

### Other infra facts
- mainnet_rpc_live: yes; eth_blockNumber 0x331d1da (53,600,730) then 0x331dd9e ~10 min later (~5 blocks/s); HTTP/2 200 behind Cloudflare/Envoy
- official_mainnet_explorer: https://robinhoodchain.blockscout.com (Blockscout). Verify API: https://robinhoodchain.blockscout.com/api/ . Testnet explorer explorer.testnet.chain.robinhood.com; mainnet does NOT follow that URL pattern
- usdg_mainnet_address: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
- usdg_symbol: USDG
- usdg_name: Global Dollar
- usdg_decimals: 6 (codebase assumption of 6 for mainnet USDG is CORRECT; DustRouter unit must be 1e6)
- usdg_total_supply: 582906615101626 raw = ~582,906,615.10 USDG
- usdg_is_proxy: EIP-1967 proxy (170-byte proxy bytecode); implementation 0x68184c449e1a8f34fa18d289737129fd27b66f8f (18,644 bytes); owner() 0xcfa0388f5ddf905fdc08c45c716c15dc10a14c6f; paused()=false; isFrozen(address)=exists and returns
- usdg_oft_wrapper: 0x0d54755f5106BfdB43f7a35f5D49a23F940628d1 (LayerZero OFT wrapper for bridging; NOT verified on-chain)
- weth_mainnet_address: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 (symbol WETH, name WETH, 18 decimals)
- deploy_cost_estimate: Full Dust deploy = 4.53M gas (Vault 700,980 + Router 656,261 + Sweeper 1,996,924 + Capture 510,280 + 6 config calls) from the real testnet broadcast -> ~0.0016 ETH at 0.352 gwei, ~0.00009 ETH at the 0.02 gwei floor; Dust
- public_rpc_rate_limits: Docs: public endpoint 'rate-limited and not recommended for production use', no number given. Observed: ~12 sequential eth_calls from one IP returned HTTP 429 Too Many Requests. Third-party pages claim '100 rps per IP, 1
- paid_rpc_providers: Alchemy is the docs' recommended provider: https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY} and wss://robinhood-mainnet.g.alchemy.com/v2/{API_KEY} (testnet: robinhood-testnet). Also listed: QuickNode, Blockdaemon, dR
- official_protocol_contracts: Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3 (9,152 bytes code); L2 Multicall 0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1 (3,339 bytes); Multicall3 canonical 0xcA11bde05977b3631167028862bE2a173976CA11 present (3,808
- codebase_mainnet_gaps_observed: app/src/lib/chain.ts defines only the testnet chain (46630, explorer.testnet...); app/src/lib/contracts.ts STABLE is the 18-dec testnet USDC 0xbf4479...; keeper/index.mjs hardcodes testnet addresses; foundry.toml already
- mainnet_chain_id: 0x1237 = 4663; RPC https://rpc.mainnet.chain.robinhood.com; block ~53,596,629 at time of check; ArbOS version 116 (ArbSys.arbOSVersion)
- stock_token_gating_model: BLOCKLIST, default-open. Stock.sol: transfer/transferFrom/approve/permit gated by onlyNotPaused + onlyNotBlocked(from,to,msg.sender,spender). isBlocked = mapping(address=>bool) on AccessControlsRegistry (default false). 
- stock_token_architecture: Each Stock Token is an OZ BeaconProxy (569 bytes); EIP-1967 beacon slot -> 0xe10b6f6B275de231345c20D14Ab812db62151b00 which is both IBeacon (implementation()) and the AccessControlsRegistry (roles, isBlocked, paused). Al
- blocklist_history: 246 Blocked and 4 Unblocked events since genesis, 177 unique addresses, all between blocks 43,543 and 495,713 (June 9-29 2026, before the July 1 public launch); 0 new blocks since launch. 176/176 checked blocked addresse
- issuer_role_holders_are_EOAs: All registry role holders are plain EOAs (code size 0): DEFAULT_ADMIN 0xd6f8378f8e440c65f8382f5f2728c78dfd55b66d; BLOCKER_ROLE 0x913ca87347391218e5de2c17c5a0aeba8b0b28fd; PAUSER_ROLE 0xe7bcb188254bc6ebbff63014dfed4cd4a02
- usdg_mainnet: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168: symbol USDG, name 'Global Dollar', decimals 6 (docs claim confirmed), totalSupply ~583.5M, ERC-1967 proxy -> impl 0x68184c449e1a8f34fa18d289737129fd27b66f8f (verified 'USDG', P
- official_stock_token_address_book: Official assets API (194 tokens, all chainId 4663, 18 dec, ACTIVE): TSLA 0x322F0929c4625eD5bAd873c95208D54E1c003b2d (also named as Securities Ledger in Tesla Final Terms, ISIN JE00BX9H9838); NVDA 0xd0601CE157Db5bdC3162Bb
- USDG: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, decimals 6 (CONFIRMED), name 'Global Dollar', totalSupply ~583.4M, proxy (170-byte code), paused()=false
- WETH: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, decimals 18, symbol WETH (L2 WETH per docs)
- STOCK_TOKEN_REGISTRY_BEACON: 0xe10b6f6b275de231345c20d14ab812db62151b00 = AccessControlsRegistry (IBeacon + AccessControl); implementation()=0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2; paused()=false; isBlocked(address) getter lives HERE (not on tok
- STOCK_IMPLEMENTATION: 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2 = Stock (11614 bytes; Stock is IStock, AccessControlled, OraclePausable, ERC20ScaledUIUpgradeable + ERC20Permit). transfer/transferFrom/approve/permit gated by onlyNotPaused and
- STOCK_FACTORY: proxy 0x4783C67b63dE2B358Ac5951a7D41F47A38F3C046 (ERC1967Proxy) -> impl 0xEe351E53BCe6AAF106428358838197C91e36EE0E StockFactory (UUPS). tokenAddress(bytes32 uid)->address; event Deployed(bytes32 indexed uid, address stoc
- OFFICIAL_TOKEN_LIST: REST https://api.robinhood.com/rhj/assets (no auth, 60 req/s): 194 assets, fields id(=uid), tokenSymbol, tokenName, deployments[{contractAddress, chainId 4663}], tokenDecimals 18, currentMultiplier, pendingMultiplier, st
- LIVE_TOKEN_COUNT: 194 listed in REST, all verified on-chain (283-byte BeaconProxy, beacon 0xe10b..., decimals 18, symbol match, paused=false); 193 with totalSupply>0 (BND supply 0); 203 deployed by factory (9 extra unlisted: WEEK supply 5
- DECIMALS: All 194 Stock Tokens decimals()=18 (same as testnet). USDG decimals()=6. Non-1 uiMultiplier on AAPL, DELL, CRWD(4.0), CCL, SGOV, MU, F, ORCL, COST, ASML: raw balances != displayed shares
- PRIVILEGED_ROLE_HOLDERS: 13 roles, 13 distinct addresses, all code-length 0 (EOA/undeployed): DEFAULT_ADMIN 0xd6f8378f8e440c65f8382f5f2728c78dfd55b66d; BEACON_UPGRADER 0xcd8c6182e7c6ca3b5156d6a90a67719d7e2be094 (hasRole confirmed); PAUSER 0xe7bc
- CHAIN: chainId 0x1237 (4663) confirmed; public RPC https://rpc.mainnet.chain.robinhood.com (rate-limited: 429 on bursts, large JSON-RPC batches rejected); explorer https://robinhoodchain.blockscout.com (API behind Cloudflare ch
- chain_id: eth_chainId=0x1237 (4663); block ~53,600,000 on 2026-09-03; 200k blocks spanned 20,809 s (~0.104 s/block)
- USDG: 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; decimals()=6; symbol USDG; name 'Global Dollar'; 170-byte proxy
- WETH: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; 18 dec; matches SwapRouter02.WETH9() and QuoterV2.WETH9()
- dex_venue_conclusion: Canonical Uniswap v3 (official Uniswap Labs deployment list) plus canonical Uniswap v4; NOT the Synthra fork. Testnet Synthra factory 0x911b4000D3422F482F4062a913885f7b035382Df and router 0x6f308b834595312f734e65e273f221
- uniswap_v3_quoterV2: 0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7; code 8273 B; factory()==0x1f7d...; WETH9()==0x0bd7...; quoteExactInputSingle works via eth_call
- uniswap_v3_nonfungiblePositionManager: 0x73991a25c818bf1f1128deaab1492d45638de0d3; factory()==0x1f7d...
- permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3; code 9152 B
- stock_token_architecture: All five are identical 283-byte beacon proxies (same codehash) reading implementation() from beacon 0xe10b6f6b275de231345c20d14ab812db62151b00 -> impl 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2 (11614 B). Impl bytecode c
- robinhood_asset_registry_api: GET https://api.robinhood.com/rhj/assets returns 194 assets, all deployments chainId 4663, all ASSET_STATUS_ACTIVE, tokenDecimals 18, fields: id(uid), tokenSymbol, tokenName, deployments[].contractAddress, currentMultipl
- v4_pool NVDA/USDG and AAPL/USDG: None found: 1515 (NVDA) and 443 (AAPL) v4 Initialize events exist but none with USDG or WETH as counterparty (2-topic queries per currency slot, client-side filtered). Caveat: this RPC returned [] for 3-topic filters eve
- explorer_access: robinhoodchain.blockscout.com and explorer.mainnet.chain.robinhood.com API are Cloudflare-challenge gated for scripted curl; verified-source retrieval was not possible, so callback identification relied on bytecode selec

## Dust contracts v1 (deployed 2026-09-03, chain 4663) - DEPRECATED

Superseded by the v2 set below (DustCapture v2 with USDG, WETH and ETH-float funding; DustVault.setModules is one-shot, so all four were redeployed). The v1 vault was empty when abandoned. The v1 sweeper can be paused (MAINNET-REDEPLOY.md A6), not required since the vault is empty; withdrawals from the v1 vault keep working forever. Do not point the keeper or the app at these addresses. Kept here so nobody mistakes them for live.

| Contract | Address |
|---|---|
| DustVault (v1) | 0x572557f8f96cbd1db0560fe36bfdd674bc28493f |
| DustRouter (v1) | 0x3e83593d9d3f0f29410209070688ad2ea38b0d16 |
| DustSweeper (v1) | 0xa14a1fc162b5b54402ec234eae884258e4940492 |
| DustCapture (v1, USDG allowance only, constructor (stable, vault, sweeper)) | 0x8f615ec31a52e24a6979111a4d1af2d68497ee68 |

- Stable: USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (unit 1e6)
- Owner (interim): deployer 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b
- Treasury (interim): 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b
- Keeper: 0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD
- Fee: 100 bps. Menu: TSLA, NVDA, AAPL, AMZN, SPY (pools as listed above). Deploy block range 0x332c5a3-0x332c618. minSweepAmount 0.

## Dust contracts v2 (Capture v2; deployed 2026-09-03, chain 4663) — SUPERSEDED by v3 on 2026-09-11 (sweeper to be paused; vault stays withdrawable)

Deployed from script/Deploy.s.sol (mainnet path). Live addresses for the keeper (Fly secrets DUST_VAULT/DUST_ROUTER/DUST_SWEEPER/DUST_CAPTURE) and the app (Vercel NEXT_PUBLIC_DUST_VAULT/ROUTER/SWEEPER/CAPTURE).

| Contract | Address |
|---|---|
| DustVault | 0xC6d3FCA5aa8274c03d015d914ae102f3FF344137 |
| DustRouter | 0x6A2A77F4ccb7ca9d5Af36EDb8491Af201bF209b3 |
| DustSweeper | 0x6FE03c5aE5aACCAdCde8fe004F5c543Abeb63899 |
| DustCapture (v2; constructor (stable, vault, sweeper, weth, ethPool)) | 0xc33e4EB6099bd96127D6016E9EdE1234d3a69406 |

- Stable: USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (unit 1e6)
- WETH (capture.weth()): 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
- ETH pool (capture.ethPool()): WETH/USDG 0.01% 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, token0 = WETH, observation cardinality 2500
- Capture bounds (constants): MAX_SLIPPAGE_BPS 200 (TWAP + 2%), TWAP_WINDOW 600 s, WEEK 604800 s
- Deployer: 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b
- Owner: 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b (interim deployer, or the Safe once acceptOwnership has run)
- Treasury: 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b (interim, same as deployer)
- Keeper: 0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD (unchanged from v1)
- Fee: 100 bps. Menu: TSLA, NVDA, AAPL, AMZN, SPY (pools as listed above). minSweepAmount: 0 on-chain (the keeper-side DUST_MIN_SWEEP floor applies).
- Deploy blocks 53708685 to 53708895. Tx hashes: see broadcast/Deploy.s.sol/4663/run-latest.json.
- Blockscout verification: <verified / pending> for each of the four.

## Menu expansion (2026-09-09): ten more Stock Tokens

Verified 2026-09-09 against the canonical Uniswap v3 factory: each pool pairs the Stock Token with USDG, has liquidity above the keeper floor (1e16), serves a 15-minute TWAP (observation cardinality 1400 or more), and shows no measurable price impact on a $100 buy. Chosen as the deepest USDG tier per token. 204 Stock Token proxies exist on the shared beacon; COIN and QCOM have no usable v3 USDG pool and were skipped.

| Ticker | Token | Pool (fee) |
|---|---|---|
| MSFT | 0xe93237C50D904957Cf27E7B1133b510C669c2e74 | 0xeb60bcd1d920ad6e102690ccfc6fb488899e1510 (3000) |
| GOOGL | 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3 | 0x34d0dc122cf9a8eb296fc5e0d3a233625d7d19b7 (500) |
| META | 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35 | 0x107a7cb40d8665360ba10e59471af06150a50922 (3000) |
| NFLX | 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8 | 0x59895c0302f41aeaa129d2fa2442cec01e7ef45e (3000) |
| AMD | 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC | 0x48d284a2a4d3dc1b3da08231fe44317e7e7aa51f (3000) |
| PLTR | 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A | 0x851680416a4f4e1c463d45171d61acddbc8554c0 (3000) |
| QQQ | 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68 | 0xd60a5d14db690b7afad71f76b108071d7175597d (500) |
| GLD | 0xc9a981fee1f9dec688bb123ccdecc63d0debfc4e | 0x7a6a053eccf1446a2633e05aa6d40d09381997ec (3000) |
| SPCX | 0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea | 0xc61284332117c3fb23a2a56cceffd07f7af60029 (500) |
| MSTR | 0xec262a75e413fAfD0dF80480274532C79D42da09 | 0x17578c0e0d15da44f31677263114f71ae76653ea (10000) |

Other deep candidates for later: SGOV, AMC, HIMS, GME, DJT, RDDT, SLV, USO, RIVN, MU, RBLX, SNAP, COST, LLY.

## Dust contracts v3 (post-audit; deployed 2026-09-11, chain 4663) — LIVE

Response to the CredShields audit of tag `audit-2026-09` (12 findings, all
addressed; see AUDIT-SCOPE.md "Findings and responses (v3)"). All four
contracts are redeployed because DustVault.setModules is one-shot. Deploy path:
MAINNET-V3-MIGRATION.md. Once these are filled, the v2 set above is superseded:
its sweeper is paused (setPaused(true)), the keeper and the app point here, and
withdrawals from the v2 vault and v2 capture keep working forever.

| Contract | Address |
|---|---|
| DustVault (v3; constructor (stable)) | 0x56339d95d02f6dd2f0fa0e00ea97b7b6d0454c07 |
| DustRouter (v3; constructor (stable, vault, unit, factory)) | 0xf9509abb2dd102ab9355b80d0742e76cc034667a |
| DustSweeper (v3; constructor (stable, vault, treasury, factory)) | 0xd1c68bf727468fee677ba1606ccb4d0c1cc766e5 |
| DustCapture (v3; constructor (stable, vault, sweeper, weth, ethPool, factory)) | 0xce125dfac93cfb344f399fbd4ccdbdd40b31351e |

- Source revision: tag `audit-2026-09-v3` (commit 2d5c289). solc 0.8.35, via_ir, 200 runs.
- Stable: USDG 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 (unit 1e6)
- Factory (router/sweeper/capture .factory()): canonical Uniswap v3 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA
- WETH (capture.weth()): 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
- ETH pool (capture.ethPool()): WETH/USDG 0.01% 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca, token0 = WETH
- Sweeper bounds (constants): MAX_FEE_BPS 500, MAX_SWEEP_SLIPPAGE_BPS 300 (10-minute TWAP minus 3% per leg), TWAP_WINDOW 600 s, MIN_SWEEP_INTERVAL 300 s
- Capture bounds (constants): MAX_SLIPPAGE_BPS 200 (TWAP + 2%, aggregate per swap), TWAP_WINDOW 600 s, WEEK 604800 s
- Deployer: 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b
- Owner: 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b (interim deployer, or the Safe once acceptOwnership has run)
- Treasury: 0xc1a4b14232d1deFeAf2D0C018a504dDeb0ab5d2b (interim, same as deployer)
- Keeper: 0x2A08Fb9EFdc0cD8eC6384107F3eA0A97454abFdD (unchanged)
- Fee: 100 bps on the stable actually invested. Menu: all 15 pairs (launch five plus the 2026-09-09 expansion), listed by the deploy script. minSweepAmount: 0 on-chain (keeper-side DUST_MIN_SWEEP floor applies; 5000000 planned after the smoke test).
- Deploy blocks 60364387 to 60364502. Tx hashes: see broadcast/Deploy.s.sol/4663/run-latest.json. NEXT_PUBLIC_DUST_DEPLOY_BLOCK = 60364387.
- Blockscout verification: <verified / pending> for each of the four.
- Dry run 2026-09-11 (not broadcast): 21 transactions, 8,504,172 gas, about 0.0021 ETH at 0.25 gwei.
