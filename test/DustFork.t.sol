// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {IERC20, IDustVault} from "../src/interfaces/IDust.sol";

/// End-to-end against live Robinhood Chain testnet state.
/// Run: forge test --fork-url robinhood_testnet --match-contract DustForkTest -vv
contract DustForkTest is Test {
    // testnet addresses (discovered onchain, see M0-FINDINGS.md)
    address constant USDC = 0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F; // 18-dec testnet stable
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;
    address constant NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address constant AMD  = 0x71178BAc73cBeb415514eB542a8995b82669778d;

    address constant P_TSLA = 0xFfEf1147c3724a19AB7328F4e361C049ba452dA9;
    address constant P_AMZN = 0x0A837200fB77687ba9b749E5174bd9a09E51286A;
    address constant P_PLTR = 0x82A81E9EdB32958104A2c9514b8Fc85F972b53Af;
    address constant P_NFLX = 0xcD8a64d13D5B99Dc546a3D6FFD8e5C7dD0Ecb1a0;
    address constant P_AMD  = 0xae12d50f75ea3f4Cf983Af1272614754e7F5e813;

    uint256 constant UNIT = 1e18;

    DustVault vault;
    DustRouter router;
    DustSweeper sweeper;
    address alice = makeAddr("alice");

    function setUp() public {
        vault = new DustVault(IERC20(USDC));
        router = new DustRouter(IERC20(USDC), IDustVault(address(vault)), UNIT);
        sweeper = new DustSweeper(IERC20(USDC), IDustVault(address(vault)));

        // owner curates the menu of buyable stocks
        sweeper.listStock(TSLA, P_TSLA);
        sweeper.listStock(AMZN, P_AMZN);
        sweeper.listStock(PLTR, P_PLTR);
        sweeper.listStock(NFLX, P_NFLX);
        sweeper.listStock(AMD, P_AMD);

        vault.setModules(address(router), address(sweeper));
        deal(USDC, alice, 1_000e18);
    }

    /// Give alice an equal-weight 5-stock basket (the old default), returns minOuts.
    function _equalBasket() internal returns (uint256[] memory m) {
        address[] memory toks = new address[](5);
        uint16[] memory wts = new uint16[](5);
        toks[0] = TSLA; toks[1] = AMZN; toks[2] = PLTR; toks[3] = NFLX; toks[4] = AMD;
        for (uint256 i; i < 5; i++) wts[i] = 2_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);
        m = new uint256[](5);
        for (uint256 i; i < 5; i++) m[i] = 1;
    }

    /// The core product flow: swap 137.42, round up to 140, sweep into alice's
    /// own basket, hold it, withdraw a leg.
    function test_endToEnd_swapRoundUpSweepWithdraw() public {
        uint256[] memory minOuts = _equalBasket();

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        (uint256 tslaOut, uint256 roundUp) =
            router.swapWithRoundUp(P_TSLA, TSLA, 137.42e18, 1, 5, 1);
        vm.stopPrank();

        assertGt(tslaOut, 0, "no TSLA from swap");
        assertEq(IERC20(TSLA).balanceOf(alice), tslaOut);
        assertEq(roundUp, 2.58e18, "wrong round-up");
        assertEq(vault.accruedStable(alice), 2.58e18);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 2.58e18, "round-up not in vault");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router must hold nothing");

        vm.prank(alice);
        sweeper.sweep(alice, minOuts, 1); // basketNonce is 1 after setBasket

        assertEq(vault.accruedStable(alice), 0, "full fill should leave nothing accrued");
        assertEq(vault.costBasis(alice), 2.58e18);
        address[5] memory toks = [TSLA, AMZN, PLTR, NFLX, AMD];
        for (uint256 i; i < 5; i++) {
            uint256 bal = vault.tokenBalanceOf(alice, toks[i]);
            assertGt(bal, 0, "basket leg empty");
            assertGe(IERC20(toks[i]).balanceOf(address(vault)), bal, "vault underfunded");
        }
        assertEq(IERC20(USDC).balanceOf(address(sweeper)), 0, "sweeper must hold nothing");

        uint256 amzn = vault.tokenBalanceOf(alice, AMZN);
        vm.prank(alice);
        vault.withdrawToken(AMZN, amzn, alice);
        assertEq(IERC20(AMZN).balanceOf(alice), amzn);
    }

    /// The headline of the redesign: the user's OWN weights decide what gets
    /// bought. Alice picks a 2-stock 60/40 basket; only those two fill, in ratio.
    function test_customBasketDrivesTheBuy() public {
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = TSLA; wts[0] = 6_000;
        toks[1] = AMD;  wts[1] = 4_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 85e18, 1, 10, 1); // 85 -> round up to 90 -> 5.00 change
        vm.stopPrank();
        assertEq(vault.accruedStable(alice), 5e18);

        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 1; minOuts[1] = 1;
        vm.prank(alice);
        sweeper.sweep(alice, minOuts, 1);

        // only TSLA and AMD bought; the other three menu stocks untouched
        assertGt(vault.tokenBalanceOf(alice, TSLA), 0);
        assertGt(vault.tokenBalanceOf(alice, AMD), 0);
        assertEq(vault.tokenBalanceOf(alice, AMZN), 0, "AMZN not in her basket");
        assertEq(vault.tokenBalanceOf(alice, PLTR), 0);
        assertEq(vault.tokenBalanceOf(alice, NFLX), 0);
        // she spent her full 5 across the two legs (3 + 2)
        assertEq(vault.costBasis(alice), 5e18);
        assertEq(vault.accruedStable(alice), 0);
    }

    /// Two users, two different baskets, from the same shared menu.
    function test_twoUsersDifferentBaskets() public {
        // alice: 100% TSLA
        address[] memory aT = new address[](1);
        uint16[] memory aW = new uint16[](1);
        aT[0] = TSLA; aW[0] = 10_000;
        vm.prank(alice);
        sweeper.setBasket(aT, aW);

        // bob: 100% NFLX
        address bob2 = makeAddr("bob2");
        deal(USDC, bob2, 1_000e18);
        address[] memory bT = new address[](1);
        uint16[] memory bW = new uint16[](1);
        bT[0] = NFLX; bW[0] = 10_000;
        vm.prank(bob2);
        sweeper.setBasket(bT, bW);

        // both trade + sweep
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 9.5e18, 1, 1, 1);
        sweeper.sweep(alice, one, 1);
        vm.stopPrank();
        vm.startPrank(bob2);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_NFLX, NFLX, 9.5e18, 1, 1, 1);
        sweeper.sweep(bob2, one, 1);
        vm.stopPrank();

        assertGt(vault.tokenBalanceOf(alice, TSLA), 0);
        assertEq(vault.tokenBalanceOf(alice, NFLX), 0);
        assertGt(vault.tokenBalanceOf(bob2, NFLX), 0);
        assertEq(vault.tokenBalanceOf(bob2, TSLA), 0);
    }

    function test_pauseBlocksSweepNotWithdrawals() public {
        uint256[] memory minOuts = _equalBasket();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1); // 0.50 round-up
        vm.stopPrank();

        sweeper.setPaused(true);

        vm.prank(alice);
        vm.expectRevert(DustSweeper.Paused.selector);
        sweeper.sweep(alice, minOuts, 1);

        // withdrawal of accrued stable still works while paused
        vm.prank(alice);
        vault.withdrawAccrued(0.5e18, alice);
        assertEq(IERC20(USDC).balanceOf(alice), 1_000e18 - 99.5e18 - 0.5e18 + 0.5e18);
    }

    function test_strangerCannotSweepForUser() public {
        uint256[] memory minOuts = _equalBasket();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1);
        vm.stopPrank();

        address mallory = makeAddr("mallory");
        vm.prank(mallory);
        vm.expectRevert(DustSweeper.NotAuthorized.selector);
        sweeper.sweep(alice, minOuts, 1);
    }

    /// A leg whose slippage bound can't be met is SKIPPED (isolated), not fatal:
    /// its stable slice returns to the user's accrued balance, the rest buys.
    function test_tightLegIsSkippedAndReaccrued() public {
        uint256[] memory minOuts = _equalBasket();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1); // 0.50 round-up
        vm.stopPrank();

        minOuts[0] = type(uint256).max; // TSLA leg impossible to fill

        vm.prank(alice);
        sweeper.sweep(alice, minOuts, 1);

        // TSLA leg skipped -> no TSLA credited, its 20% slice re-accrued
        assertEq(vault.tokenBalanceOf(alice, TSLA), 0, "skipped leg must not credit");
        assertApproxEqAbs(vault.accruedStable(alice), 0.5e18 / 5, 2, "skipped slice returned");
        // the other four legs still bought
        assertGt(vault.tokenBalanceOf(alice, AMZN), 0);
        assertGt(vault.tokenBalanceOf(alice, AMD), 0);
        assertEq(IERC20(USDC).balanceOf(address(sweeper)), 0, "sweeper holds nothing");
    }

    function test_zeroMinOutRejected() public {
        uint256[] memory minOuts = _equalBasket();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1);
        minOuts[2] = 0; // one zero floor on a funded leg
        vm.expectRevert(DustSweeper.ZeroMinOut.selector);
        sweeper.sweep(alice, minOuts, 1);
        vm.stopPrank();
    }

    function test_staleBasketRejected() public {
        uint256[] memory minOuts = _equalBasket();
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1);
        vm.expectRevert(DustSweeper.StaleBasket.selector);
        sweeper.sweep(alice, minOuts, 99); // wrong nonce
        vm.stopPrank();
    }

    function test_exactAmountNoRoundUp() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        (, uint256 roundUp) = router.swapWithRoundUp(P_TSLA, TSLA, 100e18, 1, 1, 1);
        vm.stopPrank();
        assertEq(roundUp, 0);
        assertEq(vault.accruedStable(alice), 0);
    }
}
