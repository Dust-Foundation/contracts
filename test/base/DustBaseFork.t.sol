// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {DustVault} from "../../src/DustVault.sol";
import {DustRouter} from "../../src/DustRouter.sol";
import {DustSweeper} from "../../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../../src/DustCapture.sol";
import {SlipstreamFactoryAdapter} from "../../src/SlipstreamFactoryAdapter.sol";
import {IERC20, IWETH, IV3Pool, IV3Factory, IV3PoolMeta, IDustVault} from "../../src/interfaces/IDust.sol";

/// Stand-in for a Coinbase tokenized stock (B20). On Base these tokens are
/// node precompiles (code 0xef), which Foundry cannot execute, so the fork
/// etches this plain 8-decimal ERC-20 at the token's address and seeds the
/// pool's balance. Transfers, allowances and the Slipstream swap path are
/// then exercised for real; only the token's own bookkeeping is simulated.
contract B20Stub {
    string public name;
    string public symbol;
    uint8 public constant decimals = 8;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function init(string memory n, string memory s) external { name = n; symbol = s; }
    function mint(address to, uint256 v) external { balanceOf[to] += v; totalSupply += v; emit Transfer(address(0), to, v); }
    /// B20 share multiplier (WAD): 1.0 for the stub
    function multiplier() external pure returns (uint256) { return 1e18; }
    function transfer(address to, uint256 v) external returns (bool) { _move(msg.sender, to, v); return true; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; emit Approval(msg.sender, s, v); return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) { require(a >= v, "allowance"); allowance[f][msg.sender] = a - v; }
        _move(f, to, v); return true;
    }
    function _move(address f, address to, uint256 v) internal { require(balanceOf[f] >= v, "balance"); balanceOf[f] -= v; balanceOf[to] += v; emit Transfer(f, to, v); }
}

/// Dust on Base: the audited contracts behind a SlipstreamFactoryAdapter,
/// buying Coinbase tokenized stocks and AERO through live Aerodrome pools.
///
///     forge test --match-contract DustBaseFork -vv
contract DustBaseForkTest is Test {
    uint256 constant BASE = 8453;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant P_WETH = 0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59; // legacy factory, ts 100
    address constant CL_CURRENT = 0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef;
    address constant CL_LEGACY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant CL_MID = 0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a;
    address constant NVDA = 0xb20000000000000000000078ee7ce2fE4908108C;
    address constant AAPL = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    address constant META = 0xb2000000000000000000008bC8786B856E61707C;
    address constant GOOGL = 0xb2000000000000000000002D0BA3164cc74f58B7;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant P_NVDA = 0x853F5f1B92b16714Fe6CDA67CAad0856B83C7ab9;
    address constant P_AAPL = 0xA3b1E3f9747065e2073722Ff4c9027d3eA4994F0;
    address constant P_META = 0xEAF57753BC382E0324a1D43F72E7027705a2273E;
    address constant P_GOOGL = 0xB1987CAD1682841b4b641d50E520777eC5Ab5542;
    address constant P_AERO = 0xa4FDd479eda160671636e2eCF8f993Cbf86258a8;

    uint256 constant TOLERANCE_BPS = 300;
    uint256 UNIT;

    SlipstreamFactoryAdapter adapter;
    DustVault vault;
    DustRouter router;
    DustSweeper sweeper;
    DustCapture capture;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");

    address[5] TOKENS = [NVDA, AAPL, META, GOOGL, AERO];
    address[5] POOLS = [P_NVDA, P_AAPL, P_META, P_GOOGL, P_AERO];
    string[4] STUB_SYMBOLS = ["NVDAc", "AAPLc", "METAc", "GOOGLc"];

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("base_mainnet")) returns (uint256) {}
        catch { vm.skip(true); return; }
        if (block.chainid != BASE || USDC.code.length == 0) { vm.skip(true); return; }

        // cbStocks are precompiles Foundry cannot run: stand them in and give
        // each pool a generous stock balance so swaps can pay out
        B20Stub impl = new B20Stub();
        for (uint256 i; i < 4; i++) {
            vm.etch(TOKENS[i], address(impl).code);
            B20Stub(TOKENS[i]).init(STUB_SYMBOLS[i], STUB_SYMBOLS[i]);
            B20Stub(TOKENS[i]).mint(POOLS[i], 1_000_000 * 1e8);
        }

        UNIT = 10 ** uint256(IERC20(USDC).decimals());
        assertEq(UNIT, 1e6);

        address[] memory fs = new address[](13);
        int24[] memory ts = new int24[](13);
        fs[0] = CL_LEGACY; ts[0] = 100;
        fs[1] = CL_CURRENT; ts[1] = 10;
        fs[2] = CL_CURRENT; ts[2] = 50;
        fs[3] = CL_LEGACY; ts[3] = 2000;
        fs[4] = CL_CURRENT; ts[4] = 1;
        fs[5] = CL_CURRENT; ts[5] = 100;
        fs[6] = CL_CURRENT; ts[6] = 200;
        fs[7] = CL_CURRENT; ts[7] = 2000;
        fs[8] = CL_LEGACY; ts[8] = 1;
        fs[9] = CL_LEGACY; ts[9] = 50;
        fs[10] = CL_LEGACY; ts[10] = 200;
        fs[11] = CL_MID; ts[11] = 100;
        fs[12] = CL_MID; ts[12] = 200;
        adapter = new SlipstreamFactoryAdapter(fs, ts);

        vault = new DustVault(IERC20(USDC));
        router = new DustRouter(IERC20(USDC), IDustVault(address(vault)), UNIT, IV3Factory(address(adapter)));
        sweeper = new DustSweeper(IERC20(USDC), IDustVault(address(vault)), treasury, IV3Factory(address(adapter)));
        capture = new DustCapture(
            IERC20(USDC), IDustVault(address(vault)), IKeeperSource(address(sweeper)), IWETH(WETH), IV3Pool(P_WETH), IV3Factory(address(adapter))
        );
        for (uint256 i; i < 5; i++) sweeper.listStock(TOKENS[i], POOLS[i]);
        vault.setModules(address(router), address(sweeper), address(capture));
        sweeper.setKeeper(keeper);
    }

    // ---- helpers ----------------------------------------------------------

    function _fundUsdc(address to, uint256 amount) internal {
        deal(USDC, to, amount);
        assertEq(IERC20(USDC).balanceOf(to), amount, "deal did not fund USDC");
    }

    function _equalBasket(address user) internal returns (uint256 nonce) {
        address[] memory toks = new address[](5);
        uint16[] memory wts = new uint16[](5);
        for (uint256 i; i < 5; i++) { toks[i] = TOKENS[i]; wts[i] = 2_000; }
        vm.prank(user);
        sweeper.setBasket(toks, wts);
        nonce = sweeper.basketNonce(user);
    }

    function _investable(uint256 amount) internal view returns (uint256) {
        uint16 fb = sweeper.feeBps();
        return fb == 0 ? amount : (amount * 10_000) / (10_000 + fb);
    }

    /// keeper-style minOuts from the sweeper's own TWAP expectation, per leg slice
    function _minOuts(address user, uint256 amount) internal view returns (uint256[] memory minOuts) {
        DustSweeper.Leg[] memory legs = sweeper.basketOf(user);
        uint256 n = legs.length;
        minOuts = new uint256[](n);
        uint256 investable = _investable(amount);
        uint256 allocated;
        for (uint256 i; i < n; i++) {
            uint256 legIn = i == n - 1 ? investable - allocated : (investable * legs[i].weightBps) / 10_000;
            allocated += legIn;
            uint256 expected = sweeper.expectedOutAtTwap(sweeper.poolFor(legs[i].token), legIn);
            minOuts[i] = (expected * (10_000 - TOLERANCE_BPS)) / 10_000;
            if (minOuts[i] == 0) minOuts[i] = 1;
        }
    }

    function _sweep(address user) internal {
        DustSweeper.Leg[] memory legs = sweeper.basketOf(user);
        address[] memory pools = new address[](legs.length);
        for (uint256 i; i < legs.length; i++) pools[i] = sweeper.poolFor(legs[i].token);
        uint256 amount = vault.accruedStable(user);
        uint256[] memory minOuts = _minOuts(user, amount);
        uint256 nonce = sweeper.basketNonce(user);
        uint16 fb = sweeper.feeBps();
        vm.prank(keeper);
        sweeper.sweep(user, amount, pools, minOuts, nonce, fb);
    }

    // ---- tests -----------------------------------------------------------

    /// The adapter resolves every live pool the way the Dust contracts ask,
    /// and the sweeper accepted all five listings through it.
    function test_adapterResolvesLivePools() public view {
        for (uint256 i; i < 5; i++) {
            address p = POOLS[i];
            uint24 fee = IV3PoolMeta(p).fee();
            assertEq(adapter.getPool(USDC, TOKENS[i], fee), p, "adapter resolves the pool by live fee");
            assertEq(adapter.getPool(TOKENS[i], USDC, fee), p, "symmetric");
            assertEq(sweeper.poolFor(TOKENS[i]), p, "listed");
        }
        assertEq(adapter.getPool(WETH, USDC, IV3PoolMeta(P_WETH).fee()), P_WETH, "WETH pool via the legacy factory");
        assertEq(sweeper.menuLength(), 5);
    }

    /// Every menu pool serves the 10-minute TWAP the sweeper floors on.
    function test_menuPoolsServeTwap() public view {
        for (uint256 i; i < 5; i++) {
            uint256 floor = sweeper.twapFloor(POOLS[i], 10 * UNIT);
            uint256 expected = sweeper.expectedOutAtTwap(POOLS[i], 10 * UNIT);
            assertGt(floor, 0);
            assertLt(floor, expected);
        }
        // sanity: $10 of NVDAc at ~$220 is about 0.045 tokens = 4.5e6 raw
        uint256 nv = sweeper.expectedOutAtTwap(P_NVDA, 10 * UNIT);
        assertGt(nv, 1_000_000); assertLt(nv, 50_000_000);
        console2.log("10 USDC -> NVDAc raw at TWAP: %s", nv);
    }

    /// Full loop through Aerodrome: USDC round-up captured, swept into four
    /// tokenized stocks and AERO at the pinned quote, one leg withdrawn.
    function test_endToEnd_captureSweepWithdraw() public {
        _fundUsdc(alice, 100 * UNIT);
        uint256 nonce = _equalBasket(alice);
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(20 * UNIT));
        IERC20(USDC).approve(address(capture), 20 * UNIT);
        vm.stopPrank();
        vm.startPrank(keeper);
        capture.captureFor(alice, 4_200_000);
        capture.captureFor(alice, 800_000);
        vm.stopPrank();
        uint256 amount = vault.accruedStable(alice);
        assertEq(amount, 5 * UNIT);

        uint256[] memory minOuts = _minOuts(alice, amount);
        uint256 investable = _investable(amount);
        uint256 expectedFee = (investable * sweeper.feeBps()) / 10_000;
        _sweep(alice);

        assertLe(vault.accruedStable(alice), 4, "full fill leaves at most rounding residue");
        assertEq(IERC20(USDC).balanceOf(treasury), expectedFee, "1% fee on invested");
        assertEq(vault.costBasis(alice), investable);
        assertEq(sweeper.basketNonce(alice), nonce + 1);
        for (uint256 i; i < 5; i++) {
            uint256 bal = vault.tokenBalanceOf(alice, TOKENS[i]);
            assertGt(bal, 0, "leg empty");
            assertGe(bal, minOuts[i], "filled below the floor");
            assertEq(IERC20(TOKENS[i]).balanceOf(address(vault)), bal, "ledger matches balance");
            console2.log("leg %s credited raw %s", i, bal);
        }
        uint256 aero = vault.tokenBalanceOf(alice, AERO);
        vm.prank(alice);
        vault.withdrawToken(AERO, aero, alice);
        assertEq(IERC20(AERO).balanceOf(alice), aero, "real AERO withdrawn in kind");
    }

    /// In-app swap through the router on a Slipstream pool, round-up in the same tx.
    function test_routerRoundUpOnSlipstream() public {
        _fundUsdc(alice, 500 * UNIT);
        _equalBasket(alice);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        (uint256 out, uint256 roundUp) = router.swapWithRoundUp(P_AERO, AERO, 137_420_000, 1, 5, 1);
        vm.stopPrank();
        assertEq(roundUp, 2_580_000);
        assertGt(out, 0);
        assertEq(IERC20(AERO).balanceOf(alice), out, "real AERO received");
        assertEq(vault.accruedStable(alice), 2_580_000);
    }

    /// The router refuses a pool the adapter does not resolve (lookalike or
    /// non-canonical), exactly as it refuses non-Uniswap pools on Robinhood.
    function test_routerRefusesUnresolvedPool() public {
        _fundUsdc(alice, 50 * UNIT);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.expectRevert(DustRouter.BadPool.selector);
        router.swapWithRoundUp(address(this), AERO, 10 * UNIT, 1, 1, 1);
        vm.stopPrank();
    }

    /// WETH funding path is real on Base: the capture contract sizes the pull
    /// against the deep legacy WETH/USDC pool's TWAP and swaps for exactly the
    /// round-up.
    function test_captureFromWethOnSlipstream() public {
        _equalBasket(alice);
        deal(WETH, alice, 1 ether);
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(20 * UNIT));
        IERC20(WETH).approve(address(capture), type(uint256).max);
        vm.stopPrank();
        uint256 bound = capture.maxWethInFor(3 * UNIT);
        assertGt(bound, 0);
        vm.prank(keeper);
        capture.captureFromWeth(alice, 3 * UNIT, bound);
        assertEq(vault.accruedStable(alice), 3 * UNIT, "exact round-up landed in the vault");
        assertLt(1 ether - IERC20(WETH).balanceOf(alice), bound, "paid no more than the bound");
    }

    /// Withdrawals cannot be gated by the owner: pause sweeps, withdraw anyway.
    function test_withdrawalsWorkWhilePaused() public {
        _fundUsdc(alice, 50 * UNIT);
        _equalBasket(alice);
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(20 * UNIT));
        IERC20(USDC).approve(address(capture), 20 * UNIT);
        vm.stopPrank();
        vm.prank(keeper);
        capture.captureFor(alice, 5 * UNIT);
        _sweep(alice);
        uint256 nv = vault.tokenBalanceOf(alice, NVDA);
        assertGt(nv, 0);
        sweeper.setPaused(true);
        vm.prank(alice);
        vault.withdrawToken(NVDA, nv, alice);
        assertEq(IERC20(NVDA).balanceOf(alice), nv);
    }

    // the router calls this on the fake "pool" in test_routerRefusesUnresolvedPool
    function token0() external pure returns (address) { return USDC; }
    function token1() external pure returns (address) { return AERO; }
    function fee() external pure returns (uint24) { return 500; }
}
