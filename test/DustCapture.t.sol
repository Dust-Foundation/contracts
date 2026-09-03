// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IDustVault} from "../src/interfaces/IDust.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {MockStable, MockWETH, MockSweeper, MockV3Pool} from "./mocks/CaptureMocks.sol";

/// A recipient that refuses plain ETH, to exercise withdrawEth's failure path.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract DustCaptureTest is Test {
    MockStable stable;
    MockWETH weth;
    MockV3Pool pool;
    DustVault vault;
    MockSweeper sweeper;
    DustCapture capture;

    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant UNIT = 1e6; // 6-decimal stable, as USDG on mainnet
    /// price token1/token0 at this tick is about 2.5e-9 raw = ~2500 USDG per WETH
    int24 constant TICK = -198080;

    function setUp() public {
        stable = new MockStable();
        weth = new MockWETH();
        pool = new MockV3Pool(address(weth), address(stable), TICK); // token0 = WETH, as on mainnet
        vault = new DustVault(IERC20(address(stable)));
        sweeper = new MockSweeper(keeper);
        capture = new DustCapture(
            IERC20(address(stable)),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(address(weth)),
            IV3Pool(address(pool))
        );
        // router slot is a dummy here; capture is the module under test
        vault.setModules(makeAddr("router"), address(sweeper), address(capture));

        // pool "liquidity": stable to pay out
        stable.mint(address(pool), 1_000_000 * UNIT);

        // alice: stable + wallet WETH, both with capped allowances
        stable.mint(alice, 100 * UNIT);
        vm.deal(alice, 10 ether);
        vm.startPrank(alice);
        stable.approve(address(capture), 50 * UNIT);
        weth.deposit{value: 5 ether}();
        weth.approve(address(capture), 5 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _optIn(uint96 cap) internal {
        vm.prank(alice);
        capture.setWeeklyCap(cap);
    }

    function _float(uint256 amount) internal {
        vm.prank(alice);
        capture.depositEth{value: amount}();
    }

    // ------------------------------------------------------------------
    // constructor
    // ------------------------------------------------------------------

    function test_constructorPinsPoolOrdering() public view {
        assertTrue(capture.wethIsToken0());
        assertEq(address(capture.weth()), address(weth));
        assertEq(address(capture.ethPool()), address(pool));
        assertEq(capture.MAX_SLIPPAGE_BPS(), 200);
        assertEq(capture.TWAP_WINDOW(), 600);
    }

    function test_constructorRejectsMismatchedPool() public {
        MockStable other = new MockStable();
        MockV3Pool bad = new MockV3Pool(address(weth), address(other), TICK);
        vm.expectRevert(DustCapture.BadPool.selector);
        new DustCapture(
            IERC20(address(stable)),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(address(weth)),
            IV3Pool(address(bad))
        );
    }

    // ------------------------------------------------------------------
    // source 0: stable from wallet (v1 behaviour)
    // ------------------------------------------------------------------

    function test_usdgPathUnchanged() public {
        _optIn(uint96(10 * UNIT));

        vm.expectEmit(true, false, false, true, address(capture));
        emit DustCapture.Captured(alice, 600_000, 600_000);
        vm.expectEmit(true, false, false, true, address(capture));
        emit DustCapture.CapturedFrom(alice, 0, 600_000, 600_000);
        vm.prank(keeper);
        capture.captureFor(alice, 600_000);

        assertEq(vault.accruedStable(alice), 600_000);
        assertEq(stable.balanceOf(address(vault)), 600_000);
        assertEq(capture.remainingThisWeek(alice), 9_400_000);
    }

    function test_walletAllowanceIsSecondCap() public {
        _optIn(uint96(100 * UNIT));
        vm.prank(alice);
        stable.approve(address(capture), 500_000);
        vm.prank(keeper);
        vm.expectRevert(bytes("allow"));
        capture.captureFor(alice, 1 * UNIT);
    }

    // ------------------------------------------------------------------
    // keeper gate / opt-in gate across every path
    // ------------------------------------------------------------------

    function test_nonKeeperRevertsOnEveryPath() public {
        _optIn(uint96(10 * UNIT));
        _float(1 ether);
        vm.startPrank(mallory);
        vm.expectRevert(DustCapture.NotKeeper.selector);
        capture.captureFor(alice, 1 * UNIT);
        vm.expectRevert(DustCapture.NotKeeper.selector);
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        vm.expectRevert(DustCapture.NotKeeper.selector);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        vm.stopPrank();
    }

    function test_capZeroBlocksEveryPath() public {
        _float(1 ether); // funds are there, but no cap was ever set
        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFor(alice, 1 * UNIT);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        vm.stopPrank();

        // opt in, use it once, opt out again: every path is closed again
        _optIn(uint96(10 * UNIT));
        vm.prank(keeper);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        _optIn(0);
        assertEq(capture.remainingThisWeek(alice), 0);
        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFor(alice, 1 * UNIT);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        vm.stopPrank();
    }

    function test_zeroAmountReverts() public {
        _optIn(uint96(10 * UNIT));
        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.ZeroAmount.selector);
        capture.captureFor(alice, 0);
        vm.expectRevert(DustCapture.ZeroAmount.selector);
        capture.captureFromWeth(alice, 0, type(uint256).max);
        vm.expectRevert(DustCapture.ZeroAmount.selector);
        capture.captureFromEth(alice, 0, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // weekly cap counts every source together
    // ------------------------------------------------------------------

    function test_capAccountingAcrossSources() public {
        _optIn(uint96(2 * UNIT));
        _float(1 ether);

        vm.startPrank(keeper);
        capture.captureFor(alice, 600_000);                            // 0.60 stable
        capture.captureFromWeth(alice, 700_000, type(uint256).max);    // 0.70 via wallet WETH
        capture.captureFromEth(alice, 500_000, type(uint256).max);     // 0.50 via float
        assertEq(vault.accruedStable(alice), 1_800_000);
        assertEq(capture.remainingThisWeek(alice), 200_000);

        // 0.30 more would breach the cap on any path
        vm.expectRevert(DustCapture.OverWeeklyCap.selector);
        capture.captureFor(alice, 300_000);
        vm.expectRevert(DustCapture.OverWeeklyCap.selector);
        capture.captureFromWeth(alice, 300_000, type(uint256).max);
        vm.expectRevert(DustCapture.OverWeeklyCap.selector);
        capture.captureFromEth(alice, 300_000, type(uint256).max);

        // exactly the remainder is fine
        capture.captureFromEth(alice, 200_000, type(uint256).max);
        assertEq(capture.remainingThisWeek(alice), 0);

        // window rolls after a week
        vm.warp(block.timestamp + 7 days);
        assertEq(capture.remainingThisWeek(alice), 2 * UNIT);
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        vm.stopPrank();
        assertEq(vault.accruedStable(alice), 3 * UNIT);
        (, uint96 used,) = capture.configOf(alice);
        assertEq(used, 1 * UNIT);
    }

    // ------------------------------------------------------------------
    // source 1: WETH from the wallet allowance
    // ------------------------------------------------------------------

    function test_captureFromWeth_pullsFromWalletToPool() public {
        _optIn(uint96(10 * UNIT));
        uint256 amountOut = 530_000; // 0.53 stable
        uint256 expectedIn = pool.quoteExactOutput(true, amountOut);
        uint256 limit = capture.maxWethInFor(amountOut);
        assertLe(expectedIn, limit, "pool price within the TWAP bound");
        // TWAP == pool price here, so the bound is exactly the 2% headroom (rounded up)
        assertApproxEqRel(limit, (expectedIn * 10_200) / 10_000, 1e12);

        uint256 wethBefore = weth.balanceOf(alice);
        uint256 poolBefore = weth.balanceOf(address(pool));

        vm.expectEmit(true, false, false, true, address(capture));
        emit DustCapture.Captured(alice, amountOut, amountOut);
        vm.expectEmit(true, false, false, true, address(capture));
        emit DustCapture.CapturedFrom(alice, 1, expectedIn, amountOut);
        vm.prank(keeper);
        capture.captureFromWeth(alice, amountOut, limit);

        assertEq(wethBefore - weth.balanceOf(alice), expectedIn, "wallet debited exactly what the pool charged");
        assertEq(weth.balanceOf(address(pool)) - poolBefore, expectedIn, "pool paid directly");
        assertEq(weth.balanceOf(address(capture)), 0, "no custody of wallet WETH");
        assertEq(vault.accruedStable(alice), amountOut);
        assertEq(stable.balanceOf(address(vault)), amountOut);
        assertEq(capture.ethBalance(alice), 0, "float untouched");
        // about 2500 stable per WETH: 0.53 stable is about 2.12e14 wei
        assertApproxEqRel(expectedIn, 212e12, 0.01e18);
    }

    function test_captureFromWeth_walletAllowanceIsSecondCap() public {
        _optIn(uint96(100 * UNIT));
        vm.prank(alice);
        weth.approve(address(capture), 1); // 1 wei
        vm.prank(keeper);
        vm.expectRevert(bytes("allow"));
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
    }

    function test_captureFromWeth_keeperBoundBelowOwedReverts() public {
        _optIn(uint96(10 * UNIT));
        uint256 owed = pool.quoteExactOutput(true, 530_000);
        vm.prank(keeper);
        vm.expectRevert(DustCapture.OverMaxWethIn.selector);
        capture.captureFromWeth(alice, 530_000, owed - 1);
        assertEq(vault.accruedStable(alice), 0);
        assertEq(weth.balanceOf(alice), 5 ether);
        (, uint96 used,) = capture.configOf(alice);
        assertEq(used, 0, "reverted capture must not consume the cap");
    }

    function test_twapBoundStopsOverpayingEvenWithLaxKeeper() public {
        _optIn(uint96(10 * UNIT));
        _float(1 ether);
        pool.setExtraBps(201); // pool wants 2.01% more than TWAP: just over the hard bound
        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.OverMaxWethIn.selector);
        capture.captureFromWeth(alice, 530_000, type(uint256).max);
        vm.expectRevert(DustCapture.OverMaxWethIn.selector);
        capture.captureFromEth(alice, 530_000, type(uint256).max);
        vm.stopPrank();

        pool.setExtraBps(199); // just inside the bound: fills
        vm.prank(keeper);
        capture.captureFromWeth(alice, 530_000, type(uint256).max);
        assertEq(vault.accruedStable(alice), 530_000);
    }

    function test_partialFillReverts() public {
        _optIn(uint96(10 * UNIT));
        _float(1 ether);
        pool.setPartialFill(true);
        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.PartialFill.selector);
        capture.captureFromWeth(alice, 530_000, type(uint256).max);
        vm.expectRevert(DustCapture.PartialFill.selector);
        capture.captureFromEth(alice, 530_000, type(uint256).max);
        vm.stopPrank();
        assertEq(vault.accruedStable(alice), 0);
        assertEq(capture.ethBalance(alice), 1 ether);
    }

    function test_synthraCallbackNameAlsoWorks() public {
        _optIn(uint96(10 * UNIT));
        pool.setSynthraCallback(true);
        vm.prank(keeper);
        capture.captureFromWeth(alice, 530_000, type(uint256).max);
        assertEq(vault.accruedStable(alice), 530_000);
    }

    // ------------------------------------------------------------------
    // source 2: the ETH float
    // ------------------------------------------------------------------

    function test_captureFromEth_debitsFloat() public {
        _optIn(uint96(10 * UNIT));
        _float(0.01 ether);
        uint256 amountOut = 530_000;
        uint256 expectedIn = pool.quoteExactOutput(true, amountOut);
        uint256 walletBefore = weth.balanceOf(alice);

        uint256 limit = capture.maxWethInFor(amountOut);
        vm.expectEmit(true, false, false, true, address(capture));
        emit DustCapture.CapturedFrom(alice, 2, expectedIn, amountOut);
        vm.prank(keeper);
        capture.captureFromEth(alice, amountOut, limit);

        assertEq(capture.ethBalance(alice), 0.01 ether - expectedIn);
        assertEq(weth.balanceOf(address(capture)), 0.01 ether - expectedIn, "float stays fully backed");
        assertEq(weth.balanceOf(alice), walletBefore, "wallet WETH untouched");
        assertEq(vault.accruedStable(alice), amountOut);
    }

    function test_captureFromEth_insufficientFloatReverts() public {
        _optIn(uint96(10 * UNIT));
        _float(1_000); // 1000 wei: far below 0.53 stable worth
        vm.prank(keeper);
        vm.expectRevert(DustCapture.InsufficientEthBalance.selector);
        capture.captureFromEth(alice, 530_000, type(uint256).max);
        assertEq(capture.ethBalance(alice), 1_000);
    }

    function test_captureFromEth_cannotSpendAnotherUsersFloat() public {
        // bob parks a float; alice opts in with no float of her own
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        capture.depositEth{value: 1 ether}();
        _optIn(uint96(10 * UNIT));
        vm.prank(keeper);
        vm.expectRevert(DustCapture.InsufficientEthBalance.selector);
        capture.captureFromEth(alice, 530_000, type(uint256).max);
        assertEq(capture.ethBalance(bob), 1 ether);
    }

    // ------------------------------------------------------------------
    // depositEth / withdrawEth / receive
    // ------------------------------------------------------------------

    function test_depositWithdrawRoundTrip() public {
        uint256 before = alice.balance;
        vm.expectEmit(true, false, false, true, address(capture));
        emit DustCapture.EthDeposited(alice, 1 ether);
        _float(1 ether);
        assertEq(capture.ethBalance(alice), 1 ether);
        assertEq(weth.balanceOf(address(capture)), 1 ether);
        assertEq(address(capture).balance, 0, "no loose ETH held");

        vm.expectEmit(true, true, false, true, address(capture));
        emit DustCapture.EthWithdrawn(alice, bob, 0.4 ether);
        vm.prank(alice);
        capture.withdrawEth(0.4 ether, bob);
        assertEq(bob.balance, 0.4 ether);
        assertEq(capture.ethBalance(alice), 0.6 ether);

        vm.prank(alice);
        capture.withdrawEth(0.6 ether, alice);
        assertEq(capture.ethBalance(alice), 0);
        assertEq(weth.balanceOf(address(capture)), 0);
        assertEq(address(capture).balance, 0);
        assertEq(alice.balance, before - 0.4 ether);
    }

    function test_withdrawEthWorksWithCapZero() public {
        // never opted in
        _float(1 ether);
        vm.prank(alice);
        capture.withdrawEth(0.5 ether, alice);
        assertEq(capture.ethBalance(alice), 0.5 ether);

        // opted in, then fully opted out: still works
        _optIn(uint96(10 * UNIT));
        _optIn(0);
        vm.prank(alice);
        capture.withdrawEth(0.5 ether, alice);
        assertEq(capture.ethBalance(alice), 0);
    }

    function test_withdrawEthGuards() public {
        _float(1 ether);
        vm.startPrank(alice);
        vm.expectRevert(DustCapture.InsufficientEthBalance.selector);
        capture.withdrawEth(1 ether + 1, alice);
        vm.expectRevert(DustCapture.ZeroAmount.selector);
        capture.withdrawEth(0, alice);
        vm.expectRevert(DustCapture.ZeroAddress.selector);
        capture.withdrawEth(1, address(0));
        vm.stopPrank();

        // mallory cannot withdraw alice's float
        vm.prank(mallory);
        vm.expectRevert(DustCapture.InsufficientEthBalance.selector);
        capture.withdrawEth(1, mallory);

        // a recipient that rejects ETH: the whole call reverts, balance intact
        address rejecter = address(new RejectsEth());
        vm.prank(alice);
        vm.expectRevert(DustCapture.EthTransferFailed.selector);
        capture.withdrawEth(1 ether, rejecter);
        assertEq(capture.ethBalance(alice), 1 ether);
        assertEq(weth.balanceOf(address(capture)), 1 ether);
    }

    function test_depositZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(DustCapture.ZeroAmount.selector);
        capture.depositEth{value: 0}();
    }

    function test_receiveRejectsNonWethSenders() public {
        vm.deal(mallory, 1 ether);
        vm.prank(mallory);
        (bool ok,) = address(capture).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH from a non-WETH sender must be refused");
        assertEq(address(capture).balance, 0);
        assertEq(mallory.balance, 1 ether);

        // and the WETH contract itself may send (the unwrap path)
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (ok,) = address(capture).call{value: 1 wei}("");
        assertTrue(ok);
    }

    // ------------------------------------------------------------------
    // callback guard
    // ------------------------------------------------------------------

    function test_callbackFromNonPoolReverts() public {
        vm.prank(mallory);
        vm.expectRevert(DustCapture.BadCallback.selector);
        capture.uniswapV3SwapCallback(1, -1, "");
        vm.prank(mallory);
        vm.expectRevert(DustCapture.BadCallback.selector);
        capture.synthraV3SwapCallback(1, -1, "");

        // even the real pool cannot trigger a payment outside a swap it was asked for
        _float(1 ether);
        vm.prank(address(pool));
        vm.expectRevert(DustCapture.BadCallback.selector);
        capture.uniswapV3SwapCallback(1, -1, "");
        assertEq(capture.ethBalance(alice), 1 ether);
    }

    // ------------------------------------------------------------------
    // maxWethInFor
    // ------------------------------------------------------------------

    function test_maxWethInForFailsClosedWithoutOracle() public {
        _optIn(uint96(10 * UNIT));
        _float(1 ether);
        pool.setObserveReverts(true);
        vm.expectRevert(bytes("OLD"));
        capture.maxWethInFor(1 * UNIT);
        vm.startPrank(keeper);
        vm.expectRevert(bytes("OLD"));
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        vm.expectRevert(bytes("OLD"));
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        vm.stopPrank();
    }

    function test_maxWethInForMagnitude() public view {
        // ~2500 stable per WETH -> 1 stable costs ~4e14 wei, plus 2%
        uint256 m = capture.maxWethInFor(1 * UNIT);
        assertApproxEqRel(m, 4e14 * 102 / 100, 0.01e18);
        // linear in amountOut (up to rounding)
        assertApproxEqRel(capture.maxWethInFor(10 * UNIT), m * 10, 1e12);
    }

    function test_maxWethInForRoundsMeanTickDown() public {
        // a TWAP delta that does not divide evenly must floor (toward -inf),
        // which for a negative tick gives a LOWER price = MORE weth needed:
        // the conservative direction for a maximum.
        uint256 atTick = capture.maxWethInFor(1 * UNIT);
        pool.setMeanTick(TICK - 1);
        uint256 atLower = capture.maxWethInFor(1 * UNIT);
        assertGt(atLower, atTick);
    }

    // ------------------------------------------------------------------
    // reversed token ordering (stable = token0, WETH = token1)
    // ------------------------------------------------------------------

    function test_reversedPoolOrdering() public {
        // price token1/token0 = WETH per stable = 4e8 raw -> tick about +198080
        MockV3Pool rpool = new MockV3Pool(address(stable), address(weth), -TICK);
        DustCapture rcap = new DustCapture(
            IERC20(address(stable)),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(address(weth)),
            IV3Pool(address(rpool))
        );
        assertFalse(rcap.wethIsToken0());
        DustVault rvault = new DustVault(IERC20(address(stable)));
        // fresh vault wired to this capture
        rcap = new DustCapture(
            IERC20(address(stable)),
            IDustVault(address(rvault)),
            IKeeperSource(address(sweeper)),
            IWETH(address(weth)),
            IV3Pool(address(rpool))
        );
        rvault.setModules(makeAddr("router"), address(sweeper), address(rcap));
        stable.mint(address(rpool), 1_000 * UNIT);

        vm.startPrank(alice);
        rcap.setWeeklyCap(uint96(10 * UNIT));
        weth.approve(address(rcap), 5 ether);
        vm.stopPrank();

        uint256 expectedIn = rpool.quoteExactOutput(false, 530_000);
        uint256 limit = rcap.maxWethInFor(530_000);
        assertApproxEqRel(limit, (expectedIn * 10_200) / 10_000, 1e12);
        assertApproxEqRel(expectedIn, 212e12, 0.01e18); // same economic price as the forward pool

        uint256 before = weth.balanceOf(alice);
        vm.prank(keeper);
        rcap.captureFromWeth(alice, 530_000, limit);
        assertEq(before - weth.balanceOf(alice), expectedIn);
        assertEq(rvault.accruedStable(alice), 530_000);
        assertEq(stable.balanceOf(address(rvault)), 530_000);
    }

    // ------------------------------------------------------------------
    // keeper rotation (via the sweeper)
    // ------------------------------------------------------------------

    function test_keeperRotationViaSweeper() public {
        _optIn(uint96(10 * UNIT));
        address newKeeper = makeAddr("newKeeper");
        sweeper.setKeeper(newKeeper);
        vm.prank(keeper);
        vm.expectRevert(DustCapture.NotKeeper.selector);
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        vm.prank(newKeeper);
        capture.captureFromWeth(alice, 1 * UNIT, type(uint256).max);
        assertEq(vault.accruedStable(alice), 1 * UNIT);
    }

    // ------------------------------------------------------------------
    // vendored libraries
    // ------------------------------------------------------------------

    function testFuzz_tickMathRoundTrip(int24 t) public pure {
        t = int24(bound(int256(t), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK) - 1));
        uint160 sp = TickMath.getSqrtRatioAtTick(t);
        assertEq(TickMath.getTickAtSqrtRatio(sp), t);
        assertGt(TickMath.getSqrtRatioAtTick(t + 1), sp);
    }

    function test_tickMathExtremes() public pure {
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK), TickMath.MIN_SQRT_RATIO);
        assertEq(TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK), TickMath.MAX_SQRT_RATIO);
        assertEq(TickMath.getSqrtRatioAtTick(0), 1 << 96);
    }

    function testFuzz_fullMathMatchesNativeWhenNoOverflow(uint128 a, uint128 b, uint128 d) public pure {
        vm.assume(d > 0);
        uint256 p = uint256(a) * uint256(b);
        assertEq(FullMath.mulDiv(a, b, d), p / d);
        uint256 up = p / d + (p % d == 0 ? 0 : 1);
        assertEq(FullMath.mulDivRoundingUp(a, b, d), up);
    }

    function test_fullMathPhantomOverflow() public pure {
        assertEq(FullMath.mulDiv(1 << 200, 1 << 100, 1 << 100), 1 << 200);
        assertEq(FullMath.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
        assertEq(FullMath.mulDivRoundingUp(1 << 255, 3, 1 << 254), 6);
    }
}
