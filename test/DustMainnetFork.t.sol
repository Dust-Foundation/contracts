// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IDustVault} from "../src/interfaces/IDust.sol";

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
/// token pairing as the real pool, and a swap that fills nothing. The real
/// dead TSLA/USDG 0.05% pool ends the same way (LegSkipped) but only after
/// walking ~700 empty tick-bitmap words, which is ~700 uncached storage reads
/// on a fresh fork block and flaky on the public RPC. The real-pool version of
/// the test is kept behind MAINNET_FORK_HEAVY=1.
contract EmptyPoolStub {
    address public immutable token0;
    address public immutable token1;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        return (0, 0);
    }
}

/// End-to-end against REAL Robinhood Chain mainnet state (chain id 4663), in a
/// local fork. Nothing here broadcasts; the fork is a simulation. The Dust
/// contracts are deployed fresh into the fork against real USDG (6 decimals)
/// and the five verified launch pools, then the full loop runs: menu -> basket
/// -> round-up -> keeper sweep with TWAP-derived minOuts -> in-kind withdraw.
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
    /// TSLA/USDG 0.05% pool: initialized but EMPTY (liquidity 0, at MIN_SQRT_RATIO).
    address constant P_TSLA_EMPTY = 0xc4f0172D6ac8DD294Dd1137D047d5E1893760236;

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
        router = new DustRouter(IERC20(USDG), IDustVault(address(vault)), UNIT);
        sweeper = new DustSweeper(IERC20(USDG), IDustVault(address(vault)), treasury);
        capture = new DustCapture(
            IERC20(USDG), IDustVault(address(vault)), IKeeperSource(address(sweeper)), IWETH(WETH), IV3Pool(ETH_POOL)
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

    /// Per-leg minOuts the way keeper/quote.mjs derives them: TWAP tick over
    /// TWAP_WINDOW via observe(), spot tick fallback if the pool has no oracle
    /// history, then expectedOut * (1 - tolerance). Slices mirror the sweeper's
    /// allocation (fee off the top, last leg takes the remainder).
    function _twapMinOuts(address user, uint256 amount) internal view returns (uint256[] memory minOuts) {
        DustSweeper.Leg[] memory legs = sweeper.basketOf(user);
        uint256 n = legs.length;
        minOuts = new uint256[](n);
        uint256 fee = (sweeper.treasury() != address(0) && sweeper.feeBps() > 0)
            ? (amount * sweeper.feeBps()) / 10_000
            : 0;
        uint256 investable = amount - fee;
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
        uint256 expectedFee = (amount * sweeper.feeBps()) / 10_000; // 1% -> 25_800

        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);

        // every leg filled: nothing re-accrued, fee to treasury, cost basis = invested
        assertEq(vault.accruedStable(alice), 0, "full fill should leave nothing accrued");
        assertEq(IERC20(USDG).balanceOf(treasury), expectedFee, "treasury fee");
        assertEq(vault.costBasis(alice), amount - expectedFee, "cost basis must equal stable actually invested");
        assertEq(IERC20(USDG).balanceOf(address(sweeper)), 0, "sweeper must hold nothing");
        assertEq(IERC20(USDG).balanceOf(address(vault)), 0, "vault stable fully swept");

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
        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);

        uint256 got = vault.tokenBalanceOf(alice, TSLA);
        console2.log("10 USDG -> TSLA: quoter %s, sweep %s", quoted, got);
        assertEq(got, quoted, "sweep fill differs from QuoterV2");
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
        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);
        assertEq(vault.accruedStable(alice), 0);
        assertGt(vault.tokenBalanceOf(alice, SPY), 0);
        assertEq(vault.costBasis(alice), 600_000 - 6_000); // 1% fee
    }

    /// A leg routed to an EMPTY pool (initialized, zero liquidity) is skipped
    /// with LegSkipped and its slice returned to the user; the other leg fills.
    /// Deterministic version: stub pool with the real TSLA/USDG pairing.
    function test_emptyPoolLegIsSkippedNotFatal() public {
        address stub = address(new EmptyPoolStub(TSLA, USDG)); // same ordering as the real pools
        _runEmptyPoolCase(stub);
    }

    /// Same case against the REAL dead TSLA/USDG 0.05% pool on mainnet. The
    /// swap walks the whole tick range before ending the leg, so this test is
    /// heavy on the RPC (~700 storage reads). Opt in with MAINNET_FORK_HEAVY=1,
    /// ideally against a paid provider; skipped by default.
    function test_realEmptyPoolLegIsSkipped_heavy() public {
        if (!vm.envOr("MAINNET_FORK_HEAVY", false)) {
            vm.skip(true);
            return;
        }
        assertEq(IPoolOracle(P_TSLA_EMPTY).liquidity(), 0, "expected an empty pool");
        assertEq(IV3Pool(P_TSLA_EMPTY).token0(), TSLA);
        assertEq(IV3Pool(P_TSLA_EMPTY).token1(), USDG);
        _runEmptyPoolCase(P_TSLA_EMPTY);
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

        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegSkipped(alice, TSLA, 1 * UNIT);
        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);

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

        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);

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
        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);
        uint256 amzn = vault.tokenBalanceOf(alice, AMZN);
        assertGt(amzn, 0);

        // accrue a second round-up that will sit unswept
        _accrueViaRouter(alice, 9_500_000, 1); // 9.50 -> 10: 0.50 USDG
        assertEq(vault.accruedStable(alice), 500_000);

        sweeper.setPaused(true);

        vm.prank(keeper);
        vm.expectRevert(DustSweeper.Paused.selector);
        sweeper.sweep(alice, minOuts, nonce);

        vm.startPrank(alice);
        vault.withdrawToken(AMZN, amzn, alice);
        vault.withdrawAccrued(500_000, alice);
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
        vm.prank(keeper);
        sweeper.sweep(alice, minOuts, nonce);

        assertEq(vault.accruedStable(alice), 0, "swept");
        uint256 spy = vault.tokenBalanceOf(alice, SPY);
        assertGt(spy, 0, "no SPY bought");
        assertGe(spy, minOuts[0]);
        assertEq(IERC20(SPY).balanceOf(address(vault)), spy);
        assertEq(vault.costBasis(alice), CAPTURE_OUT - CAPTURE_OUT / 100, "1% fee off the top");
        assertEq(IERC20(USDG).balanceOf(treasury), CAPTURE_OUT / 100);
        console2.log("0.53 USDG from wallet WETH -> SPY raw %s", spy);
    }
}
