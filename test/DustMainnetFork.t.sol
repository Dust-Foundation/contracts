// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IV3Factory, IV3PoolMeta, IDustVault} from "../src/interfaces/IDust.sol";
import {MockSwapPool} from "./mocks/SweeperMocks.sol";

interface IPoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);

    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface IStockToken {
    function symbol() external view returns (string memory);
    function paused() external view returns (bool);
    function uiMultiplier() external view returns (uint256);
    function balanceOfUI(address) external view returns (uint256);
}

interface IRegistry {
    function paused() external view returns (bool);
    function isBlocked(address) external view returns (bool);
}

/// Stand-in for an initialized Uniswap v3 pool with zero liquidity: same
/// token pairing and fee tier as the real TSLA/USDG 0.05% pool, an oracle that
/// forwards to the live TSLA/USDG 0.3% pool (so the v3 TWAP floor can be
/// computed), and a swap that fills nothing. The test maps it into the real
/// factory with vm.mockCall so listStock's provenance check accepts it.
contract EmptyPoolStub {
    address public immutable token0;
    address public immutable token1;
    address public immutable oracle;
    address public immutable factory;

    constructor(address t0, address t1, address _oracle, address _factory) {
        token0 = t0;
        token1 = t1;
        oracle = _oracle;
        factory = _factory;
    }

    function fee() external pure returns (uint24) {
        return 500;
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory) {
        return IV3Pool(oracle).observe(secondsAgos);
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        return (0, 0);
    }
}

/// Minimal exact-input swapper that pays the pool from its own balance; used
/// to move a live pool's spot price away from its TWAP.
contract PoolSwapper {
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function buy(address pool, address tokenIn, uint256 amountIn) external returns (int256 a0, int256 a1) {
        bool zeroForOne = IV3Pool(pool).token0() == tokenIn;
        (a0, a1) = IV3Pool(pool).swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, abi.encode(tokenIn)
        );
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address tokenIn = abi.decode(data, (address));
        int256 owed = IV3Pool(msg.sender).token0() == tokenIn ? a0 : a1;
        require(owed > 0, "nothing owed");
        require(IERC20(tokenIn).transfer(msg.sender, uint256(owed)), "pay");
    }
}

/// End-to-end against REAL Robinhood Chain mainnet state (chain id 4663), in a
/// local fork. Nothing here broadcasts; the fork is a simulation. The v3 Dust
/// contracts are deployed fresh into the fork against real USDG (6 decimals),
/// the canonical Uniswap v3 factory and the five verified launch pools, then
/// the full loop runs: menu -> basket -> round-up -> keeper sweep with
/// TWAP-derived minOuts -> in-kind withdraw. The audit reproductions (H001
/// against the thin TSLA/USDG 0.05% pool, M003 against a moved price, L001
/// against a frozen treasury on real USDG) live here too.
///
/// The public RPC rate-limits hard (HTTP 429 on bursts). Run with retries:
///   FOUNDRY_FORK_RETRIES=5 FOUNDRY_FORK_RETRY_BACKOFF=2000 \
///     forge test --match-contract DustMainnetFork -vv
///
/// Fork block: the public node is NOT an archive node. Measured 2026-09-03 it
/// serves state for only the most recent ~6k-10k blocks (about 10-17 minutes),
/// so a hard-coded pin goes stale within minutes. Default behaviour: fork the
/// head, re-pin FORK_LAG blocks back, and log the block. setUp runs once per
/// suite, so every test in a run shares that one block. For a fully
/// deterministic replay set MAINNET_FORK_BLOCK=<n> against an archive provider.
/// If the RPC is unreachable the suite is skipped rather than failed.
contract DustMainnetForkTest is Test {
    // ---- MAINNET-ADDRESSES.md (verified 2026-09-03). Never guess an address. ----
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00; // paused()/isBlocked() live here
    address constant QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address constant USDG_WETH_POOL_100 = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // deepest USDG holder (whale)
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18 decimals, upgradeable L2 WETH with deposit()/withdraw()
    /// DustCapture v2 swap venue + TWAP source: the WETH/USDG 0.01% pool (token0 = WETH, cardinality 2500)
    address constant ETH_POOL = USDG_WETH_POOL_100;

    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9; // uiMultiplier != 1
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;

    address constant P_TSLA = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3; // 0.3%
    address constant P_NVDA = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // 0.05%
    address constant P_AAPL = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D; // 0.05%
    address constant P_AMZN = 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef; // 0.3%
    address constant P_SPY = 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167; // 0.05%
    /// TSLA/USDG 0.05% pool: the THIN pool of audit finding H001 (liquidity ~3.9e16
    /// on 2026-09-11, no oracle history). Empty at launch, funded since.
    address constant P_TSLA_THIN = 0xc4f0172D6ac8DD294Dd1137D047d5E1893760236;
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // canonical Uniswap v3 factory

    // ---- menu expansion (2026-09-09) ----
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant NFLX = 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8;
    address constant AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
    address constant PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address constant QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address constant P_MSFT = 0xeb60bCD1D920ad6E102690CCFC6fB488899E1510;
    address constant P_GOOGL = 0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7;
    address constant P_META = 0x107a7Cb40d8665360ba10E59471Af06150A50922;
    address constant P_NFLX = 0x59895C0302F41aEaa129D2fa2442CEc01E7eF45E;
    address constant P_AMD = 0x48D284A2A4d3DC1b3Da08231Fe44317e7e7Aa51f;
    address constant P_PLTR = 0x851680416A4f4E1c463d45171d61ACDdBc8554c0;
    address constant P_QQQ = 0xD60A5d14dB690B7Afad71F76B108071D7175597d;
    address constant P_GLD = 0x7A6A053eCCf1446A2633E05aA6D40D09381997ec;
    address constant P_SPCX = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029;
    address constant P_MSTR = 0x17578C0e0D15da44f31677263114F71aE76653EA;

    /// blocks behind head to pin at when MAINNET_FORK_BLOCK is unset (~10 s)
    uint256 constant FORK_LAG = 100;
    uint256 constant TWAP_WINDOW = 900; // mirrors keeper/quote.mjs
    uint256 constant TOLERANCE_BPS = 300; // mirrors keeper/quote.mjs

    uint256 UNIT; // derived from USDG.decimals(), expected 1e6

    DustVault vault;
    DustRouter router;
    DustSweeper sweeper;
    DustCapture capture;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");

    address[5] TOKENS = [TSLA, NVDA, AAPL, AMZN, SPY];
    address[5] POOLS = [P_TSLA, P_NVDA, P_AAPL, P_AMZN, P_SPY];

    function setUp() public {
        uint256 blk = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (blk == 0) {
            // Discover the L2 head over raw RPC and pin a little behind it.
            // NOTE: inside the fork `block.number` is the parent-chain (L1)
            // height, as on every Arbitrum Orbit chain, so it cannot be used here.
            try vm.rpc("robinhood_mainnet", "eth_blockNumber", "[]") returns (bytes memory raw) {
                uint256 head;
                for (uint256 i; i < raw.length; i++) head = (head << 8) | uint8(raw[i]);
                if (head <= FORK_LAG) { vm.skip(true); return; }
                blk = head - FORK_LAG;
            } catch {
                vm.skip(true);
                return;
            }
        }
        try vm.createSelectFork(vm.rpcUrl("robinhood_mainnet"), blk) returns (uint256) {}
        catch { vm.skip(true); return; }
        console2.log("mainnet fork pinned at L2 block %s (block.number reports L1 %s)", blk, block.number);
        if (block.chainid != 4663 || USDG.code.length == 0) {
            vm.skip(true);
            return;
        }

        uint8 dec = IERC20(USDG).decimals();
        assertEq(dec, 6, "USDG must be 6 decimals");
        UNIT = 10 ** uint256(dec);

        vault = new DustVault(IERC20(USDG));
        router = new DustRouter(IERC20(USDG), IDustVault(address(vault)), UNIT, IV3Factory(FACTORY));
        sweeper = new DustSweeper(IERC20(USDG), IDustVault(address(vault)), treasury, IV3Factory(FACTORY));
        capture = new DustCapture(
            IERC20(USDG),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(WETH),
            IV3Pool(ETH_POOL),
            IV3Factory(FACTORY)
        );
        for (uint256 i; i < 5; i++) {
            sweeper.listStock(TOKENS[i], POOLS[i]);
        }
        vault.setModules(address(router), address(sweeper), address(capture));
        sweeper.setKeeper(keeper);
        // feeBps stays at the 1% default so cost-basis math is exercised with the fee on
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// Obtain USDG for `to`. deal() finds the balance slot through the Paxos
    /// proxy (verified). Kept behind a helper so the whale path below can be
    /// swapped in if a future USDG upgrade moves the slot.
    function _fundUsdg(address to, uint256 amount) internal {
        deal(USDG, to, amount);
        assertEq(IERC20(USDG).balanceOf(to), amount, "deal did not fund USDG");
    }

    /// Fallback funding: impersonate the deepest USDG/WETH pool and transfer.
    function _fundUsdgFromWhale(address to, uint256 amount) internal {
        uint256 before = IERC20(USDG).balanceOf(to);
        vm.prank(USDG_WETH_POOL_100);
        require(IERC20(USDG).transfer(to, amount), "whale transfer failed");
        assertEq(IERC20(USDG).balanceOf(to) - before, amount, "whale did not fund USDG");
    }

    function _equalBasket(address user) internal returns (uint256 nonce) {
        address[] memory toks = new address[](5);
        uint16[] memory wts = new uint16[](5);
        for (uint256 i; i < 5; i++) {
            toks[i] = TOKENS[i];
            wts[i] = 2_000;
        }
        vm.prank(user);
        sweeper.setBasket(toks, wts);
        nonce = sweeper.basketNonce(user);
    }

    function _singleBasket(address user, address token) internal returns (uint256 nonce) {
        address[] memory toks = new address[](1);
        uint16[] memory wts = new uint16[](1);
        toks[0] = token;
        wts[0] = 10_000;
        vm.prank(user);
        sweeper.setBasket(toks, wts);
        nonce = sweeper.basketNonce(user);
    }

    /// Accrue a round-up for `user` through the router: spend `spend` USDG on
    /// the NVDA pool (deepest) rounding up to the next `granularity` dollars.
    function _accrueViaRouter(address user, uint256 spend, uint256 granularity) internal returns (uint256 roundUp) {
        vm.startPrank(user);
        IERC20(USDG).approve(address(router), type(uint256).max);
        (, roundUp) = router.swapWithRoundUp(P_NVDA, NVDA, spend, 1, granularity, 1);
        vm.stopPrank();
    }

    /// v3 slicing: the investable amount reserves exactly the fee on a full fill.
    function _investable(uint256 amount) internal view returns (uint256) {
        uint16 fb = sweeper.feeBps(); // slicing depends on feeBps alone, never on the treasury
        return fb == 0 ? amount : (amount * 10_000) / (10_000 + fb);
    }

    /// Keeper sweeps `user` with the pinned v3 inputs: live accrued as maxAmount,
    /// poolFor per leg, current basketNonce and feeBps.
    function _sweep(address user, uint256[] memory minOuts) internal {
        DustSweeper.Leg[] memory legs = sweeper.basketOf(user);
        address[] memory pools = new address[](legs.length);
        for (uint256 i; i < legs.length; i++) pools[i] = sweeper.poolFor(legs[i].token);
        uint256 amount = vault.accruedStable(user);
        uint256 nonce = sweeper.basketNonce(user);
        uint16 fb = sweeper.feeBps();
        vm.prank(keeper);
        sweeper.sweep(user, amount, pools, minOuts, nonce, fb);
    }

    /// Per-leg minOuts the way keeper/quote.mjs derives them: TWAP tick over
    /// TWAP_WINDOW via observe(), spot tick fallback if the pool has no oracle
    /// history, then expectedOut * (1 - tolerance). Slices mirror the sweeper's
    /// v3 allocation (fee reserve, last leg takes the remainder).
    function _twapMinOuts(address user, uint256 amount) internal view returns (uint256[] memory minOuts) {
        DustSweeper.Leg[] memory legs = sweeper.basketOf(user);
        uint256 n = legs.length;
        minOuts = new uint256[](n);
        uint256 investable = _investable(amount);
        uint256 allocated;
        for (uint256 i; i < n; i++) {
            uint256 legIn = i == n - 1 ? investable - allocated : (investable * legs[i].weightBps) / 10_000;
            allocated += legIn;
            address pool = sweeper.poolFor(legs[i].token);
            if (legIn == 0 || pool == address(0)) {
                minOuts[i] = 1;
                continue;
            }
            (uint256 m, string memory source) = _quoteMinOut(pool, legIn);
            minOuts[i] = m;
            console2.log("minOut %s (%s): %s", IStockToken(legs[i].token).symbol(), source, m);
        }
    }

    function _quoteMinOut(address pool, uint256 stableIn) internal view returns (uint256 minOut, string memory source) {
        int24 tick;
        uint32[] memory ago = new uint32[](2);
        ago[0] = uint32(TWAP_WINDOW);
        ago[1] = 0;
        try IPoolOracle(pool).observe(ago) returns (int56[] memory tc, uint160[] memory) {
            // JS BigInt division truncates toward zero; mirror that
            tick = int24((tc[1] - tc[0]) / int56(uint56(TWAP_WINDOW)));
            source = "twap";
        } catch {
            (, tick,,,,,) = IPoolOracle(pool).slot0();
            source = "spot-fallback";
        }
        uint160 sqrtP = _getSqrtRatioAtTick(tick);
        require(sqrtP < (1 << 128), "sqrtP too large for this quote path");
        uint256 ratioX96 = (uint256(sqrtP) * uint256(sqrtP)) >> 96; // token1 per token0, Q96
        bool stableIsToken0 = IV3Pool(pool).token0() == USDG;
        uint256 expectedOut = stableIsToken0 ? (stableIn * ratioX96) >> 96 : (stableIn << 96) / ratioX96;
        minOut = (expectedOut * (10_000 - TOLERANCE_BPS)) / 10_000;
        if (minOut == 0) minOut = 1;
    }

    /// Uniswap v3 TickMath.getSqrtRatioAtTick, verbatim (pure). Self-checked in
    /// test_tickMathMatchesLivePools against every launch pool's slot0.
    function _getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= 887272, "T");
            uint256 ratio =
                absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    // ------------------------------------------------------------------
    // tests
    // ------------------------------------------------------------------

    /// The menu lists exactly the five launch Stock Tokens, each paired with
    /// its verified USDG pool, and none is paused or blocked at the fork block.
    function test_menuListsLaunchBasket() public view {
        assertEq(sweeper.menuLength(), 5);
        assertFalse(IRegistry(REGISTRY).paused(), "issuer registry paused at fork block");
        for (uint256 i; i < 5; i++) {
            address token = sweeper.menu(i);
            assertEq(token, TOKENS[i], "menu order");
            address pool = sweeper.poolFor(token);
            assertEq(pool, POOLS[i], "pool for token");
            address t0 = IV3Pool(pool).token0();
            address t1 = IV3Pool(pool).token1();
            assertTrue((t0 == USDG && t1 == token) || (t1 == USDG && t0 == token), "pool pairs USDG with token");
            assertGt(IPoolOracle(pool).liquidity(), 0, "launch pool has no liquidity");
            assertFalse(IStockToken(token).paused(), "token paused");
            assertFalse(IRegistry(REGISTRY).isBlocked(address(vault)), "vault blocked");
            assertFalse(IRegistry(REGISTRY).isBlocked(address(sweeper)), "sweeper blocked");
            console2.log(
                "menu[%s] %s pool fee %s",
                i,
                IStockToken(token).symbol(),
                IPoolOracle(pool).fee()
            );
        }
        assertEq(router.unit(), 1e6, "router unit must be 1e6 for USDG");
        assertEq(address(sweeper.factory()), FACTORY);
        assertEq(address(router.factory()), FACTORY);
        assertEq(address(capture.factory()), FACTORY);
    }

    /// The fifteen-pair v3 default menu (Deploy.s.sol) all pass listStock's
    /// canonical-factory check on live state, and every pool serves the
    /// 10-minute TWAP the sweep floor needs.
    function test_menuExpansionPoolsAreCanonicalAndServeTwap() public {
        DustSweeper fresh = new DustSweeper(IERC20(USDG), IDustVault(address(vault)), treasury, IV3Factory(FACTORY));
        address[15] memory toks = [TSLA, NVDA, AAPL, AMZN, SPY, MSFT, GOOGL, META, NFLX, AMD, PLTR, QQQ, GLD, SPCX, MSTR];
        address[15] memory pools =
            [P_TSLA, P_NVDA, P_AAPL, P_AMZN, P_SPY, P_MSFT, P_GOOGL, P_META, P_NFLX, P_AMD, P_PLTR, P_QQQ, P_GLD, P_SPCX, P_MSTR];
        for (uint256 i; i < 15; i++) {
            fresh.listStock(toks[i], pools[i]);
            assertEq(IV3PoolMeta(pools[i]).factory(), FACTORY);
            uint256 floor = fresh.twapFloor(pools[i], 1 * UNIT);
            assertGt(floor, 0, "TWAP floor must be computable for every menu pool");
            console2.log("%s pool fee %s, floor for 1 USDG: %s", IStockToken(toks[i]).symbol(), IV3PoolMeta(pools[i]).fee(), floor);
        }
        assertEq(fresh.menuLength(), 15);
        // the thin 0.05% TSLA pool is canonical too, but has no oracle history: it can be
        // listed and every leg on it is skipped (see test_M003_thinPoolWithoutOracleHistoryIsSkipped)
        (,,, uint16 thinCard,,,) = IPoolOracle(P_TSLA_THIN).slot0();
        if (thinCard <= 1) {
            vm.expectRevert(bytes("OLD"));
            fresh.twapFloor(P_TSLA_THIN, 1 * UNIT);
        } else {
            assertGt(fresh.twapFloor(P_TSLA_THIN, 1 * UNIT), 0, "thin pool gained oracle history; floor is defined");
        }
    }

    /// Guards the copied TickMath against every live pool's spot: sqrt(tick) <= slot0.sqrtPrice < sqrt(tick + 1).
    function test_tickMathMatchesLivePools() public view {
        for (uint256 i; i < 5; i++) {
            (uint160 sqrtP, int24 tick,,,,,) = IPoolOracle(POOLS[i]).slot0();
            assertLe(_getSqrtRatioAtTick(tick), sqrtP, "tick lower bound");
            assertGt(_getSqrtRatioAtTick(tick + 1), sqrtP, "tick upper bound");
        }
    }

    /// The core product flow on real mainnet state: swap 137.42 USDG, round up
    /// to 140 (2.58 accrued), keeper sweeps into an equal five-stock basket with
    /// TWAP minOuts, vault holds each Stock Token, cost basis equals what was
    /// actually invested, then withdraw one leg in kind.
    function test_endToEnd_roundUpSweepWithdraw() public {
        _fundUsdg(alice, 1_000 * UNIT);
        uint256 nonce = _equalBasket(alice);

        uint256 roundUp = _accrueViaRouter(alice, 137_420_000, 5); // 137.42 -> 140.00
        assertEq(roundUp, 2_580_000, "round-up should be 2.58 USDG");
        assertEq(vault.accruedStable(alice), 2_580_000);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 2_580_000, "round-up not in vault");
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router must hold nothing");
        assertGt(IERC20(NVDA).balanceOf(alice), 0, "user did not receive NVDA from the swap");

        uint256 amount = vault.accruedStable(alice);
        uint256[] memory minOuts = _twapMinOuts(alice, amount);
        uint256 investable = _investable(amount); // 2_554_455
        uint256 expectedFee = (investable * sweeper.feeBps()) / 10_000; // 1% of invested -> 25_544
        assertEq(nonce, sweeper.basketNonce(alice));

        _sweep(alice, minOuts);

        // every leg filled: only a rounding residue re-accrued, fee = 1% of invested, cost basis = invested
        assertLe(vault.accruedStable(alice), 2, "full fill leaves at most a rounding residue");
        assertEq(IERC20(USDG).balanceOf(treasury), expectedFee, "treasury fee");
        assertEq(vault.costBasis(alice), investable, "cost basis must equal stable actually invested");
        assertEq(expectedFee + investable + vault.accruedStable(alice), amount, "conservation");
        assertEq(IERC20(USDG).balanceOf(address(sweeper)), 0, "sweeper must hold nothing");
        assertEq(IERC20(USDG).balanceOf(address(vault)), vault.accruedStable(alice), "vault holds only the residue");
        assertEq(sweeper.basketNonce(alice), nonce + 1, "nonce consumed");
        assertEq(sweeper.lastSweepAt(alice), block.timestamp);

        for (uint256 i; i < 5; i++) {
            uint256 bal = vault.tokenBalanceOf(alice, TOKENS[i]);
            assertGt(bal, 0, "basket leg empty");
            assertGe(bal, minOuts[i], "leg filled below its TWAP floor");
            assertEq(IERC20(TOKENS[i]).balanceOf(address(vault)), bal, "vault balance != ledger");
            console2.log("%s raw credited: %s", IStockToken(TOKENS[i]).symbol(), bal);
        }

        // ERC-8056: AAPL has a non-1 uiMultiplier, so displayed shares != raw balance
        uint256 mult = IStockToken(AAPL).uiMultiplier();
        uint256 rawAapl = vault.tokenBalanceOf(alice, AAPL);
        assertApproxEqRel(IStockToken(AAPL).balanceOfUI(address(vault)), (rawAapl * mult) / 1e18, 1e12, "balanceOfUI");
        console2.log("AAPL uiMultiplier %s, raw %s, UI %s", mult, rawAapl, IStockToken(AAPL).balanceOfUI(address(vault)));

        // withdraw TSLA in kind
        uint256 tsla = vault.tokenBalanceOf(alice, TSLA);
        vm.prank(alice);
        vault.withdrawToken(TSLA, tsla, alice);
        assertEq(IERC20(TSLA).balanceOf(alice), tsla, "in-kind withdrawal");
        assertEq(vault.tokenBalanceOf(alice, TSLA), 0);
        assertEq(IERC20(TSLA).balanceOf(address(vault)), 0);
    }

    /// The sweep's fill equals what canonical QuoterV2 quotes for the same swap
    /// at the same state: the pools really are Uniswap v3 and our direct-pool
    /// path pays nothing extra.
    function test_sweepFillMatchesQuoterV2() public {
        sweeper.setFeeBps(0);
        _fundUsdg(alice, 100 * UNIT);
        uint256 nonce = _singleBasket(alice, TSLA);
        _accrueViaRouter(alice, 90 * UNIT, 100); // 90 -> 100: 10 USDG accrued
        assertEq(vault.accruedStable(alice), 10 * UNIT);

        (uint256 quoted,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: USDG,
                tokenOut: TSLA,
                amountIn: 10 * UNIT,
                fee: IPoolOracle(P_TSLA).fee(),
                sqrtPriceLimitX96: 0
            })
        );
        assertGt(quoted, 0, "quoter returned zero");

        uint256[] memory minOuts = _twapMinOuts(alice, 10 * UNIT);
        uint256 floor = sweeper.twapFloor(P_TSLA, 10 * UNIT);
        assertEq(nonce, sweeper.basketNonce(alice));
        _sweep(alice, minOuts);

        uint256 got = vault.tokenBalanceOf(alice, TSLA);
        console2.log("10 USDG -> TSLA: quoter %s, sweep %s, on-chain TWAP floor %s", quoted, got, floor);
        assertEq(got, quoted, "sweep fill differs from QuoterV2");
        assertGe(got, floor, "fill above the on-chain floor");
        assertEq(vault.costBasis(alice), 10 * UNIT);
    }

    /// Outside-transaction capture on mainnet USDG: user opts in with a weekly
    /// cap + wallet allowance, keeper pulls an observed round-up, it sweeps like
    /// any other.
    function test_captureFlowsIntoBasket() public {
        _fundUsdg(alice, 50 * UNIT);
        uint256 nonce = _singleBasket(alice, SPY);

        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(5 * UNIT));
        IERC20(USDG).approve(address(capture), 5 * UNIT);
        vm.stopPrank();

        vm.prank(keeper);
        capture.captureFor(alice, 600_000); // spent 3.40 outside -> 0.60 round-up
        assertEq(vault.accruedStable(alice), 600_000);
        assertEq(capture.remainingThisWeek(alice), 4_400_000);

        uint256[] memory minOuts = _twapMinOuts(alice, 600_000);
        assertEq(nonce, sweeper.basketNonce(alice));
        _sweep(alice, minOuts);
        assertLe(vault.accruedStable(alice), 2);
        assertGt(vault.tokenBalanceOf(alice, SPY), 0);
        assertEq(vault.costBasis(alice), _investable(600_000)); // 594_059, fee reserved at 1%
        assertEq(IERC20(USDG).balanceOf(treasury), (_investable(600_000) * 100) / 10_000);
    }

    /// A leg routed to an EMPTY pool (initialized, zero liquidity) is skipped
    /// with LegSkipped and its slice returned to the user; the other leg fills.
    /// Deterministic version: stub pool with the real TSLA/USDG pairing and the
    /// real 0.3% pool's oracle, mapped into the canonical factory for its
    /// (TSLA, USDG, 500) slot so listStock accepts it.
    function test_emptyPoolLegIsSkippedNotFatal() public {
        address stub = address(new EmptyPoolStub(TSLA, USDG, P_TSLA, FACTORY));
        vm.mockCall(FACTORY, abi.encodeCall(IV3Factory.getPool, (TSLA, USDG, 500)), abi.encode(stub));
        _runEmptyPoolCase(stub);
        vm.clearMockedCalls();
    }

    /// Audit M003, live variant: the real TSLA/USDG 0.05% pool is canonical and
    /// now has (thin) liquidity, but no oracle history for a 10-minute TWAP.
    /// It can be listed, and every leg routed to it is skipped rather than
    /// swept at an unbounded price; the other leg fills.
    function test_M003_thinPoolWithoutOracleHistoryIsSkipped() public {
        assertGt(IPoolOracle(P_TSLA_THIN).liquidity(), 0, "expected the thin pool to hold liquidity");
        // Live precondition: the pool has never had its oracle buffer grown. Someone
        // extended it in Sept 2026 (cardinality 1 -> 8), so the "OLD" revert is only
        // asserted while the buffer is still at 1; the skip behaviour itself is
        // covered deterministically by the stub case below either way.
        (,,, uint16 card,,,) = IPoolOracle(P_TSLA_THIN).slot0();
        if (card <= 1) {
            vm.expectRevert(bytes("OLD"));
            sweeper.twapFloor(P_TSLA_THIN, 1 * UNIT);
        } else {
            // with history the pool serves a floor and the leg fills; the M003 skip
            // path is exercised by test_emptyPoolLegIsSkippedNotFatal on a stub
            console2.log("thin TSLA pool now has oracle cardinality %s; OLD path not reproducible on live state", card);
            return;
        }
        _runEmptyPoolCase(P_TSLA_THIN);
    }

    function _runEmptyPoolCase(address emptyPool) internal {
        sweeper.setFeeBps(0);
        // re-list TSLA against the dead pool
        sweeper.delistStock(TSLA);
        sweeper.listStock(TSLA, emptyPool);
        assertEq(sweeper.poolFor(TSLA), emptyPool);

        _fundUsdg(alice, 50 * UNIT);
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = TSLA; wts[0] = 5_000;
        toks[1] = NVDA; wts[1] = 5_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);
        uint256 nonce = sweeper.basketNonce(alice);

        _accrueViaRouter(alice, 48 * UNIT, 50); // 48 -> 50: 2 USDG accrued
        assertEq(vault.accruedStable(alice), 2 * UNIT);

        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 1; // any non-zero floor; the leg fails on the pool itself
        (minOuts[1],) = _quoteMinOut(P_NVDA, 1 * UNIT);

        assertEq(nonce, sweeper.basketNonce(alice));
        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegSkipped(alice, TSLA, 1 * UNIT);
        _sweep(alice, minOuts);

        assertEq(vault.tokenBalanceOf(alice, TSLA), 0, "skipped leg must not credit");
        assertGt(vault.tokenBalanceOf(alice, NVDA), 0, "healthy leg must fill");
        assertEq(vault.accruedStable(alice), 1 * UNIT, "skipped slice returned to user");
        assertEq(vault.costBasis(alice), 1 * UNIT);
        assertEq(IERC20(USDG).balanceOf(address(sweeper)), 0, "sweeper must hold nothing");
    }

    /// Issuer kill switch: if the registry reports paused, Stock Token transfers
    /// revert inside the pool swap. Every leg is skipped, no fee is charged, the
    /// whole amount returns to the user, and their USDG stays withdrawable.
    function test_issuerPauseSkipsAllLegsAndReturnsStable() public {
        _fundUsdg(alice, 50 * UNIT);
        uint256 nonce = _equalBasket(alice);
        _accrueViaRouter(alice, 48 * UNIT, 50); // 2 USDG accrued
        uint256[] memory minOuts = _twapMinOuts(alice, 2 * UNIT);

        // issuer pauses everything (paused() is read from the shared registry)
        vm.mockCall(REGISTRY, abi.encodeWithSelector(IRegistry.paused.selector), abi.encode(true));
        assertTrue(IStockToken(TSLA).paused(), "mock did not pause tokens");

        assertEq(nonce, sweeper.basketNonce(alice));
        _sweep(alice, minOuts);

        for (uint256 i; i < 5; i++) {
            assertEq(vault.tokenBalanceOf(alice, TOKENS[i]), 0, "no leg may credit while paused");
        }
        assertEq(vault.accruedStable(alice), 2 * UNIT, "full amount returned");
        assertEq(IERC20(USDG).balanceOf(treasury), 0, "no fee when nothing invested");
        assertEq(vault.costBasis(alice), 0);
        assertEq(IERC20(USDG).balanceOf(address(sweeper)), 0);

        // USDG is not the issuer's token: the user can still take their stable out
        vm.prank(alice);
        vault.withdrawAccrued(2 * UNIT, alice);
        assertEq(vault.accruedStable(alice), 0);
        vm.clearMockedCalls();
    }

    /// Dust's own pause stops NEW sweeps only. Stock Token and stable
    /// withdrawals keep working while paused.
    function test_withdrawalsWorkWhileSweeperPaused() public {
        _fundUsdg(alice, 200 * UNIT);
        uint256 nonce = _equalBasket(alice);
        _accrueViaRouter(alice, 97 * UNIT, 10); // 97 -> 100: 3 USDG accrued
        uint256[] memory minOuts = _twapMinOuts(alice, 3 * UNIT);
        assertEq(nonce, sweeper.basketNonce(alice));
        _sweep(alice, minOuts);
        uint256 amzn = vault.tokenBalanceOf(alice, AMZN);
        assertGt(amzn, 0);
        uint256 residue = vault.accruedStable(alice);
        assertLe(residue, 2);

        // accrue a second round-up that will sit unswept
        _accrueViaRouter(alice, 9_500_000, 1); // 9.50 -> 10: 0.50 USDG
        assertEq(vault.accruedStable(alice), 500_000 + residue);

        sweeper.setPaused(true);
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        uint256 nonce2 = sweeper.basketNonce(alice);

        vm.prank(keeper);
        vm.expectRevert(DustSweeper.Paused.selector);
        sweeper.sweep(alice, 1 * UNIT, new address[](5), minOuts, nonce2, 100);

        vm.startPrank(alice);
        vault.withdrawToken(AMZN, amzn, alice);
        vault.withdrawAccrued(500_000 + residue, alice);
        vm.stopPrank();
        assertEq(IERC20(AMZN).balanceOf(alice), amzn, "in-kind withdrawal while paused");
        assertEq(vault.accruedStable(alice), 0, "stable withdrawal while paused");
        assertEq(vault.tokenBalanceOf(alice, AMZN), 0);
    }

    /// The documented fallback funding path (prank the deepest USDG pool) also
    /// works, so the suite survives a USDG storage-layout change.
    function test_whaleFallbackFundingWorks() public {
        _fundUsdgFromWhale(alice, 25 * UNIT);
        vm.prank(alice);
        IERC20(USDG).approve(address(router), type(uint256).max);
        vm.prank(alice);
        (uint256 out, uint256 roundUp) = router.swapWithRoundUp(P_SPY, SPY, 24_010_000, 1, 1, 1);
        assertGt(out, 0);
        assertEq(roundUp, 990_000);
        assertEq(vault.accruedStable(alice), 990_000);
    }

    // ------------------------------------------------------------------
    // DustCapture v2: round-ups funded from wallet WETH and an ETH float,
    // swapped exact-output on the real WETH/USDG 0.01% pool
    // ------------------------------------------------------------------

    uint256 constant CAPTURE_OUT = 530_000; // 0.53 USDG

    function _optInWeth(address user, uint256 wrap) internal {
        vm.deal(user, wrap + 1 ether);
        vm.startPrank(user);
        IWETH(WETH).deposit{value: wrap}(); // the real WETH, wrapped the normal way
        IWETH(WETH).approve(address(capture), type(uint256).max);
        capture.setWeeklyCap(uint96(5 * UNIT));
        vm.stopPrank();
        assertEq(IERC20(WETH).balanceOf(user), wrap, "WETH deposit did not credit");
    }

    function _quoteWethForUsdg(uint256 usdgOut) internal returns (uint256 quoted) {
        (quoted,,,) = IQuoterV2(QUOTER_V2).quoteExactOutputSingle(
            IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: WETH,
                tokenOut: USDG,
                amount: usdgOut,
                fee: IPoolOracle(ETH_POOL).fee(),
                sqrtPriceLimitX96: 0
            })
        );
        assertGt(quoted, 0, "quoter returned zero");
    }

    /// Decodes the CapturedFrom log out of the recorded logs (source/assetIn are not indexed).
    function _lastCapturedFrom() internal returns (uint8 source, uint256 assetIn, uint256 amountOut) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("CapturedFrom(address,uint8,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(capture) && logs[i].topics[0] == sig) {
                (source, assetIn, amountOut) = abi.decode(logs[i].data, (uint8, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "CapturedFrom not emitted");
    }

    /// The capture module is pinned to the real pool with the expected ordering
    /// and the pool's oracle is deep enough for the 10-minute TWAP.
    function test_captureV2_pinnedToRealPool() public view {
        assertEq(address(capture.weth()), WETH);
        assertEq(address(capture.ethPool()), ETH_POOL);
        assertTrue(capture.wethIsToken0(), "mainnet pool has WETH as token0");
        assertEq(IV3Pool(ETH_POOL).token0(), WETH);
        assertEq(IV3Pool(ETH_POOL).token1(), USDG);
        assertEq(IPoolOracle(ETH_POOL).fee(), 100);
        (,,, uint16 card, uint16 cardNext,,) = IPoolOracle(ETH_POOL).slot0();
        assertGe(cardNext, 64, "oracle buffer too small for the TWAP");
        console2.log("WETH/USDG pool oracle cardinality %s (next %s)", card, cardNext);
    }

    /// The on-chain bound (TWAP + 2%) sits just above what QuoterV2 says the
    /// live exact-output swap costs right now: it covers the swap and stays
    /// within a few percent of it.
    function test_captureV2_maxWethInForTracksQuoterV2() public {
        uint256 limit = capture.maxWethInFor(CAPTURE_OUT);
        uint256 quoted = _quoteWethForUsdg(CAPTURE_OUT);
        console2.log("0.53 USDG exact-out: quoter %s wei, TWAP+2%% bound %s wei", quoted, limit);
        // implied USDG per ETH from the quote, for the log
        console2.log("implied price ~%s USDG per ETH (from quote)", (CAPTURE_OUT * 1e18) / quoted / UNIT);
        assertGe(limit, quoted, "bound must cover the live quote");
        assertLe(limit, (quoted * 10_500) / 10_000, "bound more than 5% above the live quote");
        // linear in amountOut up to rounding
        assertApproxEqRel(capture.maxWethInFor(CAPTURE_OUT * 20), limit * 20, 1e12);
    }

    /// Source 1: WETH pulled from the user's wallet allowance, paid straight to
    /// the pool; exactly amountOut USDG lands in the vault for the user.
    function test_captureV2_fromWalletWeth() public {
        _optInWeth(alice, 1 ether);
        uint256 limit = capture.maxWethInFor(CAPTURE_OUT);
        uint256 quoted = _quoteWethForUsdg(CAPTURE_OUT);
        uint256 wethBefore = IERC20(WETH).balanceOf(alice);
        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        uint256 poolBefore = IERC20(WETH).balanceOf(ETH_POOL);

        vm.recordLogs();
        vm.prank(keeper);
        capture.captureFromWeth(alice, CAPTURE_OUT, limit);

        uint256 spent = wethBefore - IERC20(WETH).balanceOf(alice);
        console2.log("captureFromWeth: spent %s wei (quote %s, bound %s)", spent, quoted, limit);
        assertGt(spent, 0);
        assertLe(spent, limit, "spent more than the TWAP bound");
        assertEq(spent, quoted, "direct pool swap should cost exactly the quoted amount");
        assertEq(vault.accruedStable(alice), CAPTURE_OUT, "accrued must equal amountOut exactly");
        assertEq(IERC20(USDG).balanceOf(address(vault)) - vaultBefore, CAPTURE_OUT, "vault USDG delta");
        assertEq(IERC20(WETH).balanceOf(ETH_POOL) - poolBefore, spent, "pool received exactly what the user paid");
        assertEq(IERC20(WETH).balanceOf(address(capture)), 0, "capture must hold no wallet WETH");
        assertEq(IERC20(USDG).balanceOf(address(capture)), 0, "capture must hold no USDG");
        assertEq(capture.remainingThisWeek(alice), 5 * UNIT - CAPTURE_OUT);

        (uint8 source, uint256 assetIn, uint256 out) = _lastCapturedFrom();
        assertEq(source, 1, "source must be WETH wallet");
        assertEq(assetIn, spent);
        assertEq(out, CAPTURE_OUT);
    }

    /// Source 2: the user parks ETH (held as real WETH), the keeper draws a
    /// round-up from it, the rest comes back out as ETH even at cap 0.
    function test_captureV2_fromEthFloat() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(5 * UNIT));
        capture.depositEth{value: 0.01 ether}();
        vm.stopPrank();
        assertEq(capture.ethBalance(alice), 0.01 ether);
        assertEq(IERC20(WETH).balanceOf(address(capture)), 0.01 ether, "float held as WETH");
        assertEq(address(capture).balance, 0);

        uint256 limit = capture.maxWethInFor(CAPTURE_OUT);
        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vault));
        vm.recordLogs();
        vm.prank(keeper);
        capture.captureFromEth(alice, CAPTURE_OUT, limit);

        uint256 spent = 0.01 ether - capture.ethBalance(alice);
        console2.log("captureFromEth: spent %s wei from the float (bound %s)", spent, limit);
        assertGt(spent, 0);
        assertLe(spent, limit);
        assertEq(vault.accruedStable(alice), CAPTURE_OUT);
        assertEq(IERC20(USDG).balanceOf(address(vault)) - vaultBefore, CAPTURE_OUT);
        assertEq(IERC20(WETH).balanceOf(address(capture)), capture.ethBalance(alice), "float fully backed by WETH");

        (uint8 source, uint256 assetIn, uint256 out) = _lastCapturedFrom();
        assertEq(source, 2, "source must be ETH float");
        assertEq(assetIn, spent);
        assertEq(out, CAPTURE_OUT);

        // opt out, then withdraw the remainder to a fresh address through the real WETH unwrap
        vm.prank(alice);
        capture.setWeeklyCap(0);
        uint256 rest = capture.ethBalance(alice);
        address bob = makeAddr("bob");
        vm.prank(alice);
        capture.withdrawEth(rest, bob);
        assertEq(bob.balance, rest, "ETH did not reach the recipient");
        assertEq(capture.ethBalance(alice), 0);
        assertEq(IERC20(WETH).balanceOf(address(capture)), 0);
        assertEq(address(capture).balance, 0);
    }

    /// Source 0 still works and now also reports CapturedFrom(source 0).
    function test_captureV2_usdgPathUnchanged() public {
        _fundUsdg(alice, 50 * UNIT);
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(5 * UNIT));
        IERC20(USDG).approve(address(capture), 5 * UNIT);
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(keeper);
        capture.captureFor(alice, 600_000);
        assertEq(vault.accruedStable(alice), 600_000);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 600_000);
        (uint8 source, uint256 assetIn, uint256 out) = _lastCapturedFrom();
        assertEq(source, 0);
        assertEq(assetIn, 600_000);
        assertEq(out, 600_000);
    }

    /// The keeper's own bound is honoured: one wei under the live cost reverts
    /// inside the callback, nothing moves, no cap is consumed.
    function test_captureV2_keeperBoundBelowOwedReverts() public {
        _optInWeth(alice, 1 ether);
        uint256 quoted = _quoteWethForUsdg(CAPTURE_OUT);
        vm.prank(keeper);
        vm.expectRevert(DustCapture.OverMaxWethIn.selector);
        capture.captureFromWeth(alice, CAPTURE_OUT, quoted - 1);
        assertEq(vault.accruedStable(alice), 0);
        assertEq(IERC20(WETH).balanceOf(alice), 1 ether);
        assertEq(capture.remainingThisWeek(alice), 5 * UNIT, "a reverted capture consumes no cap");
    }

    /// Cap 0 closes the swap paths too, even with funds sitting in the float.
    function test_captureV2_capZeroBlocksSwapPaths() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        capture.depositEth{value: 0.01 ether}();
        IWETH(WETH).deposit{value: 0.5 ether}();
        IWETH(WETH).approve(address(capture), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromEth(alice, CAPTURE_OUT, type(uint256).max);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromWeth(alice, CAPTURE_OUT, type(uint256).max);
        vm.stopPrank();
        assertEq(capture.ethBalance(alice), 0.01 ether);

        // withdrawEth works with cap 0
        vm.prank(alice);
        capture.withdrawEth(0.01 ether, alice);
        assertEq(capture.ethBalance(alice), 0);
    }

    /// End to end: a WETH-funded round-up sweeps into a Stock Token like any
    /// other accrued USDG.
    function test_captureV2_wethRoundUpSweepsIntoStockToken() public {
        _optInWeth(alice, 1 ether);
        uint256 nonce = _singleBasket(alice, SPY);

        uint256 limit = capture.maxWethInFor(CAPTURE_OUT);
        vm.prank(keeper);
        capture.captureFromWeth(alice, CAPTURE_OUT, limit);
        assertEq(vault.accruedStable(alice), CAPTURE_OUT);

        uint256[] memory minOuts = _twapMinOuts(alice, CAPTURE_OUT);
        assertEq(nonce, sweeper.basketNonce(alice));
        _sweep(alice, minOuts);

        assertLe(vault.accruedStable(alice), 2, "swept up to a rounding residue");
        uint256 spy = vault.tokenBalanceOf(alice, SPY);
        assertGt(spy, 0, "no SPY bought");
        assertGe(spy, minOuts[0]);
        assertGe(spy, sweeper.twapFloor(P_SPY, _investable(CAPTURE_OUT)), "above the on-chain floor");
        assertEq(IERC20(SPY).balanceOf(address(vault)), spy);
        uint256 investable = _investable(CAPTURE_OUT); // 524_752
        assertEq(vault.costBasis(alice), investable, "fee reserved at 1% of invested");
        assertEq(IERC20(USDG).balanceOf(treasury), (investable * 100) / 10_000);
        console2.log("0.53 USDG from wallet WETH -> SPY raw %s", spy);
    }

    // ------------------------------------------------------------------
    // audit reproductions on live state
    // ------------------------------------------------------------------

    /// H001, exactly as the report measured it: 100,000 USDG offered to the
    /// thin, factory-canonical TSLA/USDG 0.05% pool. The pool consumes only a
    /// fraction. v3 refunds the rest in the same call, rounds up on what was
    /// spent, reports the spent amount, and holds nothing afterwards.
    function test_H001_thinPoolPartialFillIsRefunded() public {
        uint256 amountIn = 100_000 * UNIT;
        _fundUsdg(alice, amountIn);
        assertGt(IPoolOracle(P_TSLA_THIN).liquidity(), 0, "thin pool must hold liquidity for this reproduction");
        assertEq(IV3PoolMeta(P_TSLA_THIN).factory(), FACTORY);
        assertEq(IV3Factory(FACTORY).getPool(TSLA, USDG, 500), P_TSLA_THIN, "canonical");

        // what the canonical quoter says this exact-input swap yields (it also stops where liquidity ends)
        (uint256 quoted,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: USDG, tokenOut: TSLA, amountIn: amountIn, fee: 500, sqrtPriceLimitX96: 0
            })
        );

        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), type(uint256).max);
        vm.recordLogs();
        (uint256 out, uint256 roundUp) = router.swapWithRoundUp(P_TSLA_THIN, TSLA, amountIn, 1, 1, 1);
        vm.stopPrank();

        uint256 spent = amountIn - IERC20(USDG).balanceOf(alice) - roundUp;
        console2.log("offered %s, pool consumed %s (%s bps)", amountIn, spent, (spent * 10_000) / amountIn);
        console2.log("TSLA out %s, refund %s, round-up %s", out, amountIn - spent, roundUp);
        assertLt(spent, amountIn, "the thin pool fills only part of the offer");
        assertGt(spent, 0);
        assertEq(IERC20(USDG).balanceOf(address(router)), 0, "router must hold nothing after a partial fill");
        assertEq(IERC20(USDG).balanceOf(alice), amountIn - spent - roundUp, "unspent stable refunded in the same call");
        assertEq(IERC20(TSLA).balanceOf(alice), out, "tokens measured at the user");
        assertEq(out, quoted, "fill matches the canonical quoter for the partial");
        assertEq(roundUp, router.roundUpAmount(spent, 1, 1), "round-up computed on the spent amount");
        assertEq(vault.accruedStable(alice), roundUp);

        // the event reports what was spent, not what was offered
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("SwapWithRoundUp(address,address,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == sig) {
                (uint256 stableIn, uint256 tokensOut, uint256 ru) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(stableIn, spent);
                assertEq(tokensOut, out);
                assertEq(ru, roundUp);
                found = true;
            }
        }
        assertTrue(found, "SwapWithRoundUp not emitted");
    }

    /// H001, the drain half: a pool that pairs TSLA/USDG at fee 500 but is not
    /// the factory's pool is refused; and even if the factory were to vouch for
    /// a hostile pool, the callback cannot pull more than the caller committed.
    function test_H001_hostilePoolRefusedAndCallbackBounded() public {
        MockSwapPool hostile = new MockSwapPool(TSLA, USDG, 0); // right pairing, fee 3000 -> 500 below
        hostile.setFee(500);
        hostile.setFactory(FACTORY);
        _fundUsdg(alice, 10 * UNIT);
        _fundUsdg(address(router), 1_000 * UNIT); // hypothetical stranded pot
        vm.startPrank(alice);
        IERC20(USDG).approve(address(router), type(uint256).max);
        vm.expectRevert(DustRouter.BadPool.selector);
        router.swapWithRoundUp(address(hostile), TSLA, 1 * UNIT, 1, 1, 1);

        // factory compromised (mocked): the hostile pool asks for 501 against a 1 commitment
        vm.mockCall(FACTORY, abi.encodeCall(IV3Factory.getPool, (TSLA, USDG, 500)), abi.encode(address(hostile)));
        hostile.setOvercharge(500 * UNIT);
        hostile.setOutBps(0);
        vm.expectRevert(DustRouter.OverCommitted.selector);
        router.swapWithRoundUp(address(hostile), TSLA, 1 * UNIT, 1, 1, 1);
        vm.stopPrank();
        vm.clearMockedCalls();
        assertEq(IERC20(USDG).balanceOf(address(router)), 1_000 * UNIT, "the pot cannot be pulled through the callback");
        assertEq(IERC20(USDG).balanceOf(alice), 10 * UNIT);
    }

    /// M003 on a live pool: a large buy (2M USDG, enough to walk through the
    /// pool's TSLA liquidity at any recent depth) pushes the TSLA/USDG 0.3% spot
    /// far above its 10-minute TWAP. A keeper sweep with minOut = 1 is bounded
    /// by the on-chain floor: the leg is skipped and the user's stable returned.
    function test_M003_priceMovedBelowTwapFloor_legSkipped() public {
        _fundUsdg(alice, 100 * UNIT);
        uint256 nonce = _singleBasket(alice, TSLA);
        _accrueViaRouter(alice, 90 * UNIT, 100); // 10 USDG accrued
        uint256 legIn = _investable(10 * UNIT);
        uint256 floor = sweeper.twapFloor(P_TSLA, legIn);

        // move the market: buy TSLA with a lot of USDG
        (, int24 tickBefore,,,,,) = IPoolOracle(P_TSLA).slot0();
        PoolSwapper whale = new PoolSwapper();
        uint256 whaleIn = 2_000_000 * UNIT;
        _fundUsdg(address(whale), whaleIn);
        (int256 tslaDelta, int256 usdgDelta) = whale.buy(P_TSLA, USDG, whaleIn);
        (, int24 tickAfter,,,,,) = IPoolOracle(P_TSLA).slot0();
        console2.log("whale: USDG consumed %s of %s, TSLA bought %s", uint256(usdgDelta), whaleIn, uint256(-tslaDelta));
        console2.log("pool tick %s -> %s", vm.toString(int256(tickBefore)), vm.toString(int256(tickAfter)));
        console2.log("pool liquidity now %s", uint256(IPoolOracle(P_TSLA).liquidity()));
        (uint256 quotedNow,,,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: USDG, tokenOut: TSLA, amountIn: legIn, fee: 3000, sqrtPriceLimitX96: 0
            })
        );
        console2.log("after the whale: %s USDG buys %s TSLA, on-chain floor %s", legIn, quotedNow, floor);
        assertLt(quotedNow, floor, "the move must take spot below the TWAP floor for this test to mean anything");

        uint256[] memory minOuts = new uint256[](1);
        minOuts[0] = 1; // a keeper floor of one wei
        assertEq(nonce, sweeper.basketNonce(alice));
        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegSkipped(alice, TSLA, legIn);
        _sweep(alice, minOuts);
        assertEq(vault.tokenBalanceOf(alice, TSLA), 0, "nothing bought below the floor");
        assertEq(vault.accruedStable(alice), 10 * UNIT, "everything returned, no fee");
        assertEq(IERC20(USDG).balanceOf(treasury), 0);
        assertEq(IERC20(USDG).balanceOf(address(sweeper)), 0);
    }

    /// M003 on live state: clearBasket stops the keeper.
    function test_M003_clearBasketStopsKeeper() public {
        _fundUsdg(alice, 100 * UNIT);
        _singleBasket(alice, TSLA);
        _accrueViaRouter(alice, 90 * UNIT, 100);
        vm.prank(alice);
        sweeper.clearBasket();
        assertEq(sweeper.basketLengthOf(alice), 0);
        uint256[] memory minOuts = new uint256[](0);
        uint256 nonce = sweeper.basketNonce(alice);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.NoBasket.selector);
        sweeper.sweep(alice, 10 * UNIT, new address[](0), minOuts, nonce, 100);
        vm.prank(alice);
        vault.withdrawAccrued(10 * UNIT, alice);
        assertEq(IERC20(USDG).balanceOf(alice), 10 * UNIT, "100 funded - 90 spent - 10 round-up + 10 withdrawn");
    }

    /// L001 on real USDG: the issuer freezes the treasury (every transfer to it
    /// reverts). The sweep still settles, the fee is waived for that sweep and
    /// returned to the user.
    function test_L001_frozenTreasuryDoesNotBrickSweep() public {
        _fundUsdg(alice, 100 * UNIT);
        uint256 nonce = _singleBasket(alice, SPY);
        _accrueViaRouter(alice, 90 * UNIT, 100); // 10 USDG
        uint256 investable = _investable(10 * UNIT);
        uint256 fee = (investable * sweeper.feeBps()) / 10_000;
        uint256[] memory minOuts = _twapMinOuts(alice, 10 * UNIT);

        vm.mockCallRevert(USDG, abi.encodeWithSelector(IERC20.transfer.selector, treasury), "frozen");
        assertEq(nonce, sweeper.basketNonce(alice));
        vm.expectEmit(true, false, false, true, address(sweeper));
        emit DustSweeper.FeeSkipped(alice, fee);
        _sweep(alice, minOuts);
        vm.clearMockedCalls();

        assertGt(vault.tokenBalanceOf(alice, SPY), 0, "the buy settled");
        assertEq(IERC20(USDG).balanceOf(treasury), 0);
        assertEq(vault.costBasis(alice), investable);
        assertEq(vault.accruedStable(alice), 10 * UNIT - investable, "the waived fee came back to the user");
        assertEq(IERC20(USDG).balanceOf(address(sweeper)), 0);
    }
}
