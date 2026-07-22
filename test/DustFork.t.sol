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

        DustSweeper.BasketLeg[] memory legs = new DustSweeper.BasketLeg[](5);
        legs[0] = DustSweeper.BasketLeg(TSLA, P_TSLA, 2_000);
        legs[1] = DustSweeper.BasketLeg(AMZN, P_AMZN, 2_000);
        legs[2] = DustSweeper.BasketLeg(PLTR, P_PLTR, 2_000);
        legs[3] = DustSweeper.BasketLeg(NFLX, P_NFLX, 2_000);
        legs[4] = DustSweeper.BasketLeg(AMD, P_AMD, 2_000);
        sweeper = new DustSweeper(IERC20(USDC), IDustVault(address(vault)), 1 days, legs);

        vault.setModules(address(router), address(sweeper));
        deal(USDC, alice, 1_000e18);
    }

    /// The core product flow: swap 137.42, round up to 140, sweep, hold basket.
    function test_endToEnd_swapRoundUpSweepWithdraw() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);

        (uint256 tslaOut, uint256 roundUp) =
            router.swapWithRoundUp(P_TSLA, TSLA, 137.42e18, 1, 5, 1);
        vm.stopPrank();

        // she got her TSLA and her change was banked
        assertGt(tslaOut, 0, "no TSLA from swap");
        assertEq(IERC20(TSLA).balanceOf(alice), tslaOut);
        assertEq(roundUp, 2.58e18, "wrong round-up");
        assertEq(vault.accruedStable(alice), 2.58e18);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 2.58e18, "round-up not in vault");
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router must hold nothing");

        // sweep her 2.58 into the 5-stock basket (self-sweep)
        uint256[] memory minOuts = new uint256[](5);
        vm.prank(alice);
        sweeper.sweep(alice, minOuts);

        assertEq(vault.accruedStable(alice), 0);
        assertEq(vault.costBasis(alice), 2.58e18);
        address[5] memory toks = [TSLA, AMZN, PLTR, NFLX, AMD];
        for (uint256 i; i < 5; i++) {
            uint256 bal = vault.tokenBalanceOf(alice, toks[i]);
            assertGt(bal, 0, "basket leg empty");
            // vault actually holds what it credits
            assertGe(IERC20(toks[i]).balanceOf(address(vault)), bal, "vault underfunded");
        }
        assertEq(IERC20(USDC).balanceOf(address(sweeper)), 0, "sweeper must hold nothing");

        // withdraw one leg in kind
        uint256 amzn = vault.tokenBalanceOf(alice, AMZN);
        vm.prank(alice);
        vault.withdrawToken(AMZN, amzn, alice);
        assertEq(IERC20(AMZN).balanceOf(alice), amzn);
    }

    function test_pauseBlocksSweepNotWithdrawals() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1); // 0.50 round-up
        vm.stopPrank();

        sweeper.setPaused(true);

        uint256[] memory minOuts = new uint256[](5);
        vm.prank(alice);
        vm.expectRevert(DustSweeper.Paused.selector);
        sweeper.sweep(alice, minOuts);

        // withdrawal of accrued stable still works while paused
        vm.prank(alice);
        vault.withdrawAccrued(0.5e18, alice);
        assertEq(IERC20(USDC).balanceOf(alice), 1_000e18 - 99.5e18 - 0.5e18 + 0.5e18);
    }

    function test_strangerCannotSweepForUser() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1);
        vm.stopPrank();

        address mallory = makeAddr("mallory");
        uint256[] memory minOuts = new uint256[](5);
        vm.prank(mallory);
        vm.expectRevert(DustSweeper.NotAuthorized.selector);
        sweeper.sweep(alice, minOuts);
    }

    function test_slippageBoundReverts() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        router.swapWithRoundUp(P_TSLA, TSLA, 99.5e18, 1, 1, 1);

        uint256[] memory minOuts = new uint256[](5);
        minOuts[0] = type(uint256).max; // impossible bound
        vm.expectRevert(DustSweeper.SlippageExceeded.selector);
        sweeper.sweep(alice, minOuts);
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
