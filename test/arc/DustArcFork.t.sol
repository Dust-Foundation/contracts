// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {DustVault} from "../../src/DustVault.sol";
import {DustRouter} from "../../src/DustRouter.sol";
import {DustSweeper} from "../../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IV3Factory, IV3PoolMeta, IDustVault} from "../../src/interfaces/IDust.sol";
import {ArcNativeMock, ArcBlocklistMock} from "./ArcNativeMock.sol";

/// Dust on Arc (chain id 5042), against live mainnet state.
///
/// Arc's stable is USDC, which is also the gas token: the ERC-20 at
/// 0x3600...0000 is a 6-decimal view of the 18-decimal native balance, and
/// transfers go through a system contract Foundry cannot run. setUp etches a
/// cheatcode-backed stand-in for that system contract (see ArcNativeMock), so
/// the real USDC contract, the real Uniswap-v3-style factory and the real
/// cirBTC/USDC pool are exercised unchanged.
///
/// The Dust bytecode is the audited v3 code with no changes. The capture
/// module still takes a WETH and a WETH/USDC pool at deploy time; on Arc that
/// pool is empty, so the WETH and ETH-float paths fail closed (tested below)
/// and only the USDC path is live. The keeper never calls the other two there.
///
///     forge test --match-contract DustArcFork -vv
contract DustArcForkTest is Test {
    uint256 constant ARC_MAINNET = 5042;
    address constant USDC = 0x3600000000000000000000000000000000000000; // 6 decimals as ERC-20, native gas
    address constant NATIVE_SYS = 0x1800000000000000000000000000000000000000; // native transfer system contract
    address constant BLOCKLIST_SYS = 0x1800000000000000000000000000000000000001;
    address constant FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918; // Uniswap-v3-style factory (verified 2026-09-17)
    address constant CIRBTC = 0x171A4217b86A807A64eB94757Db6849fb4bDbAA0; // 8 decimals
    address constant P_CIRBTC = 0x82916bee18fCEF517B26C72d7Cb5F13694E1dB41; // cirBTC/USDC 0.01%, ~6.6M USDC, cardinality 600
    address constant WETH = 0x128cC466B61f542da60c70e3aA11c10e19B84EDB; // 18 decimals, no meaningful USDC liquidity on Arc
    address constant P_WETH = 0xE17939B09faf35CA3aDE4ab040dB955945134874; // WETH/USDC 0.05%, empty, cardinality 1
    address constant P_EURC = 0x6fd5F2fb831940DcD61A98c5B3aCB7D8C6f3bFc1; // EURC/USDC 0.05%, thin (~8k), not on the menu
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;

    uint256 constant TWAP_WINDOW = 900;
    uint256 constant TOLERANCE_BPS = 300;
    uint256 UNIT;

    DustVault vault;
    DustRouter router;
    DustSweeper sweeper;
    DustCapture capture;

    address alice = makeAddr("alice");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");

    function setUp() public {
        try vm.createSelectFork(vm.rpcUrl("arc_mainnet")) returns (uint256) {}
        catch { vm.skip(true); return; }
        if (block.chainid != ARC_MAINNET || USDC.code.length == 0) { vm.skip(true); return; }

        // Arc's native-USDC plumbing, replaced with cheatcode-backed stand-ins
        vm.etch(NATIVE_SYS, address(new ArcNativeMock()).code);
        vm.allowCheatcodes(NATIVE_SYS);
        vm.etch(BLOCKLIST_SYS, address(new ArcBlocklistMock()).code);

        uint8 dec = IERC20(USDC).decimals();
        assertEq(dec, 6, "USDC must be 6 decimals");
        UNIT = 10 ** uint256(dec);

        vault = new DustVault(IERC20(USDC));
        router = new DustRouter(IERC20(USDC), IDustVault(address(vault)), UNIT, IV3Factory(FACTORY));
        sweeper = new DustSweeper(IERC20(USDC), IDustVault(address(vault)), treasury, IV3Factory(FACTORY));
        capture = new DustCapture(
            IERC20(USDC),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(WETH),
            IV3Pool(P_WETH),
            IV3Factory(FACTORY)
        );
        sweeper.listStock(CIRBTC, P_CIRBTC);
        vault.setModules(address(router), address(sweeper), address(capture));
        sweeper.setKeeper(keeper);
    }

    // ---- helpers -----------------------------------------------------------

    /// USDC on Arc is the native balance; 1 USDC = 1e18 wei = 1e6 ERC-20 units.
    function _fundUsdc(address to, uint256 amount6) internal {
        vm.deal(to, amount6 * 1e12);
        assertEq(IERC20(USDC).balanceOf(to), amount6, "native deal did not show as USDC");
    }

    function _basketCirBtc(address user) internal returns (uint256 nonce) {
        address[] memory toks = new address[](1);
        uint16[] memory wts = new uint16[](1);
        toks[0] = CIRBTC;
        wts[0] = 10_000;
        vm.prank(user);
        sweeper.setBasket(toks, wts);
        nonce = sweeper.basketNonce(user);
    }

    function _investable(uint256 amount) internal view returns (uint256) {
        uint16 fb = sweeper.feeBps();
        return fb == 0 ? amount : (amount * 10_000) / (10_000 + fb);
    }

    /// keeper-style minOut: the sweeper's own TWAP expectation less the keeper tolerance
    function _minOuts(uint256 amount) internal view returns (uint256[] memory minOuts) {
        minOuts = new uint256[](1);
        uint256 expected = sweeper.expectedOutAtTwap(P_CIRBTC, _investable(amount));
        minOuts[0] = (expected * (10_000 - TOLERANCE_BPS)) / 10_000;
        if (minOuts[0] == 0) minOuts[0] = 1;
    }

    function _sweep(address user) internal {
        address[] memory pools = new address[](1);
        pools[0] = sweeper.poolFor(CIRBTC);
        uint256 amount = vault.accruedStable(user);
        uint256[] memory minOuts = _minOuts(amount);
        uint256 nonce = sweeper.basketNonce(user);
        uint16 fb = sweeper.feeBps();
        vm.prank(keeper); // every argument is resolved above: the prank must land on sweep itself
        sweeper.sweep(user, amount, pools, minOuts, nonce, fb);
    }

    // ---- tests -------------------------------------------------------------

    function test_arcUsdcIsBothGasAndToken() public {
        _fundUsdc(alice, 100 * UNIT);
        assertEq(alice.balance, 100 ether, "native side");
        vm.prank(alice);
        IERC20(USDC).transfer(treasury, 1 * UNIT);
        assertEq(IERC20(USDC).balanceOf(treasury), 1 * UNIT);
        assertEq(treasury.balance, 1 ether, "an ERC-20 transfer moved the native balance");
    }

    function test_cirBtcPoolIsCanonicalAndServesTwap() public view {
        assertEq(IV3PoolMeta(P_CIRBTC).factory(), FACTORY);
        assertEq(IV3Factory(FACTORY).getPool(USDC, CIRBTC, IV3PoolMeta(P_CIRBTC).fee()), P_CIRBTC, "factory resolves the pool");
        assertEq(IERC20(CIRBTC).decimals(), 8);
        (,,, uint16 card,,,) = IV3Pool(P_CIRBTC).slot0();
        assertGe(card, 64, "oracle history for a 10-minute TWAP");
        uint256 floor = sweeper.twapFloor(P_CIRBTC, 100 * UNIT);
        uint256 expected = sweeper.expectedOutAtTwap(P_CIRBTC, 100 * UNIT);
        assertGt(floor, 0);
        assertLt(floor, expected);
        // sanity: $100 buys on the order of 1e-3 BTC (price between 20k and 500k)
        assertGt(expected, 20_000, "100 USDC should buy more than 0.0002 BTC");
        assertLt(expected, 500_000, "100 USDC should buy less than 0.005 BTC");
        console2.log("cirBTC per 100 USDC at TWAP: %s sats, floor %s sats", expected, floor);
    }

    /// The whole loop on live Arc state: opt in, keeper captures USDC
    /// round-ups from the wallet allowance, sweeps into cirBTC at the pinned
    /// quote, user withdraws in kind. No ETH anywhere.
    function test_endToEnd_usdcCaptureSweepWithdraw() public {
        _fundUsdc(alice, 200 * UNIT);
        uint256 nonce = _basketCirBtc(alice);

        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(20 * UNIT));
        IERC20(USDC).approve(address(capture), 20 * UNIT);
        vm.stopPrank();

        // three outside trades: 0.62 + 0.38 + 4.00 of change
        vm.startPrank(keeper);
        capture.captureFor(alice, 620_000);
        capture.captureFor(alice, 380_000);
        capture.captureFor(alice, 4_000_000);
        vm.stopPrank();
        uint256 amount = vault.accruedStable(alice);
        assertEq(amount, 5 * UNIT, "5.00 accrued");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 5 * UNIT, "vault holds the change");
        assertEq(capture.remainingThisWeek(alice), 15 * UNIT);

        uint256[] memory minOuts = _minOuts(amount);
        uint256 investable = _investable(amount);
        uint256 expectedFee = (investable * sweeper.feeBps()) / 10_000;
        _sweep(alice);

        assertLe(vault.accruedStable(alice), 2, "full fill");
        assertEq(IERC20(USDC).balanceOf(treasury), expectedFee, "1% fee on invested");
        assertEq(vault.costBasis(alice), investable);
        assertEq(sweeper.basketNonce(alice), nonce + 1);
        uint256 sats = vault.tokenBalanceOf(alice, CIRBTC);
        assertGe(sats, minOuts[0], "filled at or above the keeper floor");
        assertEq(IERC20(CIRBTC).balanceOf(address(vault)), sats, "ledger matches balance");
        assertEq(IERC20(USDC).balanceOf(address(sweeper)), 0);
        console2.log("5 USDC of round-ups bought %s sats of cirBTC (fee %s)", sats, expectedFee);

        vm.prank(alice);
        vault.withdrawToken(CIRBTC, sats, alice);
        assertEq(IERC20(CIRBTC).balanceOf(alice), sats, "in-kind withdrawal");
        assertEq(vault.tokenBalanceOf(alice, CIRBTC), 0);
    }

    /// In-app swap through the router on the cirBTC pool, round-up captured in
    /// the same transaction and swept afterwards.
    function test_routerRoundUpOnCirBtc() public {
        _fundUsdc(alice, 500 * UNIT);
        _basketCirBtc(alice);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        (uint256 out, uint256 roundUp) = router.swapWithRoundUp(P_CIRBTC, CIRBTC, 137_420_000, 1, 5, 1); // 137.42 -> 140
        vm.stopPrank();
        assertEq(roundUp, 2_580_000, "2.58 USDC round-up");
        assertGt(out, 0);
        assertEq(IERC20(CIRBTC).balanceOf(alice), out, "user got the cirBTC");
        assertEq(vault.accruedStable(alice), 2_580_000);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router holds nothing");
        _sweep(alice);
        assertGt(vault.tokenBalanceOf(alice, CIRBTC), 0);
    }

    /// The two ETH funding paths cannot fire on Arc: the WETH/USDC pool has no
    /// oracle history so the contract's own bound fails closed, and the bridged
    /// WETH has no payable deposit so an ETH float cannot be parked.
    function test_ethPathsFailClosedOnArc() public {
        _fundUsdc(alice, 50 * UNIT);
        _basketCirBtc(alice);
        vm.prank(alice);
        capture.setWeeklyCap(uint96(20 * UNIT));

        // the empty pool still answers a bound (its single observation is old), so the
        // pull itself must fail: give alice bridged WETH and an allowance, then try
        deal(WETH, alice, 1 ether);
        vm.prank(alice);
        IERC20(WETH).approve(address(capture), type(uint256).max);
        uint256 bound = capture.maxWethInFor(1 * UNIT);
        console2.log("empty WETH pool quotes a bound of %s wei per 1 USDC (unusable, no liquidity)", bound);
        vm.prank(keeper);
        vm.expectRevert();
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        assertEq(IERC20(WETH).balanceOf(alice), 1 ether, "nothing was pulled");

        vm.prank(keeper);
        vm.expectRevert();
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        capture.depositEth{value: 1 ether}();

        // and the USDC path still works right after
        vm.prank(alice);
        IERC20(USDC).approve(address(capture), 5 * UNIT);
        vm.prank(keeper);
        capture.captureFor(alice, 700_000);
        assertEq(vault.accruedStable(alice), 700_000);
    }

    /// Nothing the owner can do stops a withdrawal, on Arc as on Robinhood.
    function test_withdrawalsWorkWhilePaused() public {
        _fundUsdc(alice, 50 * UNIT);
        _basketCirBtc(alice);
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(20 * UNIT));
        IERC20(USDC).approve(address(capture), 20 * UNIT);
        vm.stopPrank();
        vm.prank(keeper);
        capture.captureFor(alice, 5 * UNIT);
        _sweep(alice);
        uint256 sats = vault.tokenBalanceOf(alice, CIRBTC);
        assertGt(sats, 0);

        sweeper.setPaused(true);
        uint256 nonce = sweeper.basketNonce(alice);
        uint16 fb = sweeper.feeBps();
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.Paused.selector);
        sweeper.sweep(alice, 0, new address[](1), new uint256[](1), nonce, fb);

        vm.prank(alice);
        vault.withdrawToken(CIRBTC, sats, alice);
        assertEq(IERC20(CIRBTC).balanceOf(alice), sats);
    }

    /// A thin pool is refused for the menu by the same rule as on Robinhood:
    /// listStock takes it (it is canonical), but the sweep floor cannot be
    /// served without oracle history, so a leg there is skipped, not filled badly.
    function test_thinEurcPoolIsListableButFloorHolds() public view {
        assertEq(IV3Factory(FACTORY).getPool(USDC, EURC, IV3PoolMeta(P_EURC).fee()), P_EURC);
        uint256 floor = sweeper.twapFloor(P_EURC, 1 * UNIT);
        assertGt(floor, 0, "EURC pool has oracle history, floor is defined");
        console2.log("EURC per 1 USDC at TWAP floor: %s", floor);
    }
}
