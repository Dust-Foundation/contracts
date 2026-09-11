// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustCapture} from "../src/DustCapture.sol";
import {SafeTransfer} from "../src/libraries/SafeTransfer.sol";
import {IERC20, IDustVault, IV3Factory} from "../src/interfaces/IDust.sol";
import {MockERC20, MockSwapPool, NoReturnERC20, FalseReturnERC20} from "./mocks/SweeperMocks.sol";
import {MockFactory} from "./mocks/CaptureMocks.sol";

/// One test (or a few) per finding of the September 2026 external audit,
/// reproducing the auditor's scenario against mocks and proving the v3 fix.
/// The mainnet-state counterparts live in test/DustMainnetFork.t.sol.
contract DustAuditV3Test is Test {
    MockERC20 stable; // 6 decimals, as USDG
    MockFactory factory;

    // sweeper fixture: this test accrues directly (wired as router)
    DustVault vault;
    DustSweeper sweeper;

    // router fixture: this test is wired as the sweeper (unused)
    DustVault rvault;
    DustRouter router;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address mallory = makeAddr("mallory");

    uint256 constant UNIT = 1e6;
    /// token1 per token0 ~ 1e10 raw: about $100 per 18-decimal share against a 6-decimal stable
    int24 constant TICK = 230_270;
    uint16 constant FEE = 100;

    function setUp() public {
        stable = new MockERC20("USDG", 6);
        factory = new MockFactory();

        vault = new DustVault(IERC20(address(stable)));
        sweeper = new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), treasury, IV3Factory(address(factory)));
        vault.setModules(address(this), address(sweeper), address(0));
        sweeper.setKeeper(keeper);

        rvault = new DustVault(IERC20(address(stable)));
        router = new DustRouter(IERC20(address(stable)), IDustVault(address(rvault)), UNIT, IV3Factory(address(factory)));
        rvault.setModules(address(router), address(this), address(0));
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _pool(address token) internal returns (MockSwapPool p) {
        p = new MockSwapPool(address(stable), token, TICK);
        factory.register(address(p));
    }

    function _list(string memory sym) internal returns (MockERC20 tok, MockSwapPool p) {
        tok = new MockERC20(sym, 18);
        p = _pool(address(tok));
        tok.mint(address(p), 1e36);
        sweeper.listStock(address(tok), address(p));
    }

    function _single(address user, address tok) internal {
        address[] memory t = new address[](1);
        uint16[] memory w = new uint16[](1);
        t[0] = tok;
        w[0] = 10_000;
        vm.prank(user);
        sweeper.setBasket(t, w);
    }

    function _accrue(address user, uint256 amt) internal {
        stable.mint(address(vault), amt);
        vault.accrue(user, amt);
    }

    function _pools(address user) internal view returns (address[] memory pools) {
        DustSweeper.Leg[] memory legs = sweeper.basketOf(user);
        pools = new address[](legs.length);
        for (uint256 i; i < legs.length; i++) pools[i] = sweeper.poolFor(legs[i].token);
    }

    function _ones(uint256 n) internal pure returns (uint256[] memory m) {
        m = new uint256[](n);
        for (uint256 i; i < n; i++) m[i] = 1;
    }

    /// Keeper sweeps `user` against the live quote inputs (read before the
    /// prank so no argument call consumes it).
    function _sweep(address user, uint256[] memory minOuts) internal {
        uint256 amount = vault.accruedStable(user);
        address[] memory pools = _pools(user);
        uint256 nonce = sweeper.basketNonce(user);
        uint16 fb = sweeper.feeBps();
        vm.prank(keeper);
        sweeper.sweep(user, amount, pools, minOuts, nonce, fb);
    }

    function _investable(uint256 amount) internal view returns (uint256) {
        uint16 fb = sweeper.feeBps(); // slicing depends on feeBps alone, never on the treasury
        return fb == 0 ? amount : (amount * 10_000) / (10_000 + fb);
    }

    // ------------------------------------------------------------------
    // H001: router partial fill + permissionless drain
    // ------------------------------------------------------------------

    /// The audited scenario: a thin pool consumes 13.87% of a 100,000.50 offer.
    /// v3 refunds the rest in the same call, rounds up on what was spent, and
    /// holds nothing afterwards.
    function test_H001_partialFillIsRefundedAndRouterHoldsNothing() public {
        MockERC20 tok = new MockERC20("TSLA", 18);
        MockSwapPool p = _pool(address(tok));
        tok.mint(address(p), 1e36);
        p.setFillBps(1387);

        uint256 amountIn = 100_000_500_000; // 100,000.50 USDG
        stable.mint(alice, amountIn + 10 * UNIT);
        uint256 expectedSpent = (amountIn * 1387) / 10_000; // 13,870.06935
        uint256 expectedOut = p.quoteAtTwap(true, expectedSpent);
        uint256 expectedRoundUp = router.roundUpAmount(expectedSpent, 1, 1); // 0.93065

        vm.startPrank(alice);
        stable.approve(address(router), type(uint256).max);
        vm.expectEmit(true, true, false, true, address(router));
        emit DustRouter.SwapWithRoundUp(alice, address(tok), expectedSpent, expectedOut, expectedRoundUp);
        (uint256 out, uint256 roundUp) = router.swapWithRoundUp(address(p), address(tok), amountIn, 1, 1, 1);
        vm.stopPrank();

        assertEq(p.lastConsumed(), expectedSpent, "pool consumed 13.87%");
        assertLt(expectedSpent, amountIn, "partial fill");
        assertEq(stable.balanceOf(address(router)), 0, "router must hold nothing");
        assertEq(stable.balanceOf(address(p)), expectedSpent, "pool was paid exactly what it consumed");
        assertEq(
            stable.balanceOf(alice), amountIn + 10 * UNIT - expectedSpent - expectedRoundUp, "unspent 86.13% refunded"
        );
        assertEq(out, expectedOut);
        assertEq(tok.balanceOf(alice), out, "tokens measured at the user");
        assertEq(roundUp, expectedRoundUp, "round-up on the spent amount, not the offer");
        assertGt(roundUp, 0);
        assertEq(rvault.accruedStable(alice), roundUp);
        assertEq(stable.balanceOf(address(rvault)), roundUp);
    }

    /// The drain half of the finding: a pool that pairs the right tokens but
    /// is not the factory's pool is refused before any transfer happens.
    function test_H001_hostilePoolRejectedByProvenanceCheck() public {
        MockERC20 tok = new MockERC20("T", 18);
        MockSwapPool hostile = new MockSwapPool(address(stable), address(tok), TICK); // never registered
        tok.mint(address(hostile), 1e30);
        stable.mint(address(router), 1_000 * UNIT); // a hypothetical stranded pot
        stable.mint(mallory, 1 * UNIT);

        vm.startPrank(mallory);
        stable.approve(address(router), type(uint256).max);
        vm.expectRevert(DustRouter.BadPool.selector);
        router.swapWithRoundUp(address(hostile), address(tok), 1 * UNIT, 1, 1, 1);
        // a pool the factory knows under a different fee tier is still not this pool
        MockSwapPool canonical = _pool(address(tok));
        canonical.setFee(500);
        factory.register(address(canonical));
        hostile.setFee(500);
        vm.expectRevert(DustRouter.BadPool.selector);
        router.swapWithRoundUp(address(hostile), address(tok), 1 * UNIT, 1, 1, 1);
        vm.stopPrank();
        assertEq(stable.balanceOf(address(router)), 1_000 * UNIT, "nothing left the router");
        assertEq(stable.balanceOf(mallory), 1 * UNIT);
    }

    /// Even a pool the factory acknowledges cannot be paid more than the
    /// caller committed, in aggregate across callbacks.
    function test_H001_callbackCannotExceedCommittedAmount() public {
        MockERC20 tok = new MockERC20("T", 18);
        MockSwapPool p = _pool(address(tok)); // "canonical", but misbehaving
        tok.mint(address(p), 1e36);
        stable.mint(address(router), 1_000 * UNIT); // stranded pot to tempt
        stable.mint(mallory, 10 * UNIT);
        vm.startPrank(mallory);
        stable.approve(address(router), type(uint256).max);

        p.setOvercharge(500 * UNIT); // asks for 501 against a 1 commitment
        vm.expectRevert(DustRouter.OverCommitted.selector);
        router.swapWithRoundUp(address(p), address(tok), 1 * UNIT, 1, 1, 1);

        p.setOvercharge(0);
        p.setDoubleCallback(true); // asks for the full amount twice
        vm.expectRevert(DustRouter.OverCommitted.selector);
        router.swapWithRoundUp(address(p), address(tok), 1 * UNIT, 1, 1, 1);

        p.setDoubleCallback(false);
        p.setOvercharge(1); // one wei over
        vm.expectRevert(DustRouter.OverCommitted.selector);
        router.swapWithRoundUp(address(p), address(tok), 1 * UNIT, 1, 1, 1);
        vm.stopPrank();

        assertEq(stable.balanceOf(address(router)), 1_000 * UNIT, "the pot is untouchable through the callback");
        assertEq(stable.balanceOf(mallory), 10 * UNIT);
        assertEq(stable.balanceOf(address(p)), 0);
    }

    function test_H001_zeroGuardsAndPairingChecks() public {
        MockERC20 tok = new MockERC20("T", 18);
        MockSwapPool p = _pool(address(tok));
        tok.mint(address(p), 1e36);
        stable.mint(alice, 100 * UNIT);
        vm.startPrank(alice);
        stable.approve(address(router), type(uint256).max);

        vm.expectRevert(DustRouter.ZeroMinOut.selector);
        router.swapWithRoundUp(address(p), address(tok), 10 * UNIT, 0, 1, 1);

        p.setOutBps(0); // pool takes the stable and delivers nothing
        vm.expectRevert(DustRouter.ZeroOutput.selector);
        router.swapWithRoundUp(address(p), address(tok), 10 * UNIT, 1, 1, 1);
        p.setOutBps(10_000);

        p.setFillBps(0); // pool consumes nothing
        vm.expectRevert(DustRouter.NothingSpent.selector);
        router.swapWithRoundUp(address(p), address(tok), 10 * UNIT, 1, 1, 1);
        p.setFillBps(10_000);

        // honest price but the caller's floor is tighter: whole call reverts, nothing moves
        uint256 fair = p.quoteAtTwap(true, 10 * UNIT);
        vm.expectRevert(DustRouter.SlippageExceeded.selector);
        router.swapWithRoundUp(address(p), address(tok), 10 * UNIT, fair + 1, 1, 1);

        // wrong tokenOut for this pool
        vm.expectRevert(DustRouter.BadParams.selector);
        router.swapWithRoundUp(address(p), address(stable), 10 * UNIT, 1, 1, 1);
        // a pool that does not contain the stable at all
        MockERC20 other = new MockERC20("O", 18);
        MockSwapPool noStable = new MockSwapPool(address(other), address(tok), TICK);
        factory.register(address(noStable));
        vm.expectRevert(DustRouter.BadParams.selector);
        router.swapWithRoundUp(address(noStable), address(tok), 10 * UNIT, 1, 1, 1);
        vm.stopPrank();

        assertEq(stable.balanceOf(alice), 100 * UNIT, "every rejected call left the balance intact");
        assertEq(stable.balanceOf(address(router)), 0);
    }

    // ------------------------------------------------------------------
    // M001: fee on gross + re-charge on recycled leftover
    // ------------------------------------------------------------------

    /// The audited numbers: 20 USDG, 20 equal legs, one fills. v2 charged
    /// 0.20 on 0.99 invested (2,020 bps). v3 charges 1% of 0.99.
    function test_M001_oneOfTwentyLegsFills_feeOnlyOnInvested() public {
        address[] memory toks = new address[](20);
        uint16[] memory wts = new uint16[](20);
        for (uint256 i; i < 20; i++) {
            (MockERC20 tok,) = _list(string(abi.encodePacked("S", vm.toString(i))));
            toks[i] = address(tok);
            wts[i] = 500;
        }
        vm.prank(alice);
        sweeper.setBasket(toks, wts);

        uint256 amount = 20 * UNIT;
        _accrue(alice, amount);
        uint256[] memory minOuts = _ones(20);
        for (uint256 i = 1; i < 20; i++) minOuts[i] = type(uint256).max; // 19 legs cannot fill

        uint256 investable = _investable(amount);
        uint256 legIn = (investable * 500) / 10_000;
        _sweep(alice, minOuts);

        uint256 invested = vault.costBasis(alice);
        uint256 fee = stable.balanceOf(treasury);
        assertEq(invested, legIn, "exactly one leg invested");
        assertEq(fee, (invested * FEE) / 10_000, "fee is feeBps of invested, nothing else");
        assertEq(vault.accruedStable(alice), amount - invested - fee, "everything else back to the user");
        assertEq(stable.balanceOf(address(sweeper)), 0);
        // effective rate against stable actually swept: 100 bps, not 2,020
        assertLe(fee * 10_000, invested * FEE);
    }

    /// The compounding half: a 90%-weight leg is permanently unbuyable and the
    /// leftover is recycled through ten sweeps. Each sweep charges exactly
    /// feeBps of what it invested and the lifetime fee stays within feeBps of
    /// the original round-up (v2 reached 9.17% at these parameters).
    function test_M001_recycledLeftoverIsNeverRetaxed() public {
        (MockERC20 tA,) = _list("A");
        (MockERC20 tB,) = _list("B");
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = address(tA); wts[0] = 9_000;
        toks[1] = address(tB); wts[1] = 1_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);

        uint256 original = 1_000 * UNIT;
        _accrue(alice, original);
        uint256[] memory minOuts = _ones(2);
        minOuts[0] = type(uint256).max; // leg A never fills

        uint256 feeSoFar;
        uint256 investedSoFar;
        for (uint256 round; round < 10; round++) {
            _sweep(alice, minOuts);
            uint256 invested = vault.costBasis(alice) - investedSoFar;
            uint256 fee = stable.balanceOf(treasury) - feeSoFar;
            assertGt(invested, 0, "leg B fills every round");
            assertEq(fee, (invested * FEE) / 10_000, "each round: feeBps of that round's investment");
            investedSoFar += invested;
            feeSoFar += fee;
            vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        }
        assertEq(stable.balanceOf(treasury) + vault.costBasis(alice) + vault.accruedStable(alice), original, "conservation");
        assertLe(stable.balanceOf(treasury) * 10_000, original * FEE, "lifetime fee within feeBps of the original");
        assertEq(stable.balanceOf(address(sweeper)), 0);
    }

    /// A full fill leaves at most two raw units (rounding) re-accrued, and the
    /// fee is exactly feeBps of what was invested.
    function test_M001_fullFillFeeExactUpToRounding() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        uint256 amount = 2_580_000; // 2.58 USDG, the doc example
        _accrue(alice, amount);
        _sweep(alice, _ones(1));
        uint256 investable = _investable(amount);
        assertEq(vault.costBasis(alice), investable);
        assertEq(stable.balanceOf(treasury), (investable * FEE) / 10_000);
        assertLe(vault.accruedStable(alice), 2, "rounding residue only");
        assertEq(stable.balanceOf(treasury) + vault.costBasis(alice) + vault.accruedStable(alice), amount);
    }

    // ------------------------------------------------------------------
    // M002: buyLeg credited the pool-reported output
    // ------------------------------------------------------------------

    /// A token that taxes the sweeper -> vault hop (but not the pool's payout)
    /// gets credited for what the vault actually received.
    function test_M002_creditEqualsVaultBalanceDelta() public {
        (MockERC20 tok, MockSwapPool p) = _list("R");
        tok.setExempt(address(p), true);
        tok.setHaircut(1_000); // 10% off every non-exempt transfer
        _single(alice, address(tok));
        uint256 amount = 10 * UNIT;
        _accrue(alice, amount);

        uint256 got = p.quoteAtTwap(true, _investable(amount)); // what the pool delivers to the sweeper
        uint256 expectedCredit = got - (got * 1_000) / 10_000;
        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegBought(alice, address(tok), _investable(amount), expectedCredit);
        _sweep(alice, _ones(1));

        uint256 credited = vault.tokenBalanceOf(alice, address(tok));
        assertEq(credited, expectedCredit, "credited the measured delta");
        assertLt(credited, got, "not the pool-reported amount");
        assertEq(credited, tok.balanceOf(address(vault)), "ledger equals custody");
        // the last withdrawer can always be paid
        vm.prank(alice);
        vault.withdrawToken(address(tok), credited, alice);
        assertEq(vault.tokenBalanceOf(alice, address(tok)), 0);
        assertEq(tok.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------
    // M003: no revocation, keeper-set price bound, replayable quotes, no rate limit
    // ------------------------------------------------------------------

    function test_M003_clearBasketRevokesSweepAuthority() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 5 * UNIT);
        uint256 n0 = sweeper.basketNonce(alice);

        vm.expectEmit(true, false, false, true, address(sweeper));
        emit DustSweeper.BasketCleared(alice, n0 + 1);
        vm.prank(alice);
        sweeper.clearBasket();
        assertEq(sweeper.basketLengthOf(alice), 0);
        assertEq(sweeper.basketNonce(alice), n0 + 1, "nonce bumped so no old quote survives");

        vm.prank(keeper);
        vm.expectRevert(DustSweeper.NoBasket.selector);
        sweeper.sweep(alice, 5 * UNIT, new address[](0), new uint256[](0), n0 + 1, FEE);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.NoBasket.selector);
        sweeper.sweep(alice, 5 * UNIT, new address[](0), new uint256[](0), n0, FEE);

        // funds untouched and withdrawable; and the user may opt back in later
        assertEq(vault.accruedStable(alice), 5 * UNIT);
        vm.prank(alice);
        vault.withdrawAccrued(5 * UNIT, alice);
        assertEq(stable.balanceOf(alice), 5 * UNIT);
        _single(alice, address(tok));
        assertEq(sweeper.basketLengthOf(alice), 1);
    }

    /// The keeper's minOut of one wei no longer sets the price: the pool's own
    /// TWAP less 3% does. 4% below TWAP is skipped; 2.5% below fills.
    function test_M003_twapFloorBoundsTheKeeper() public {
        (MockERC20 tok, MockSwapPool p) = _list("A");
        _single(alice, address(tok));
        uint256 amount = 10 * UNIT;
        _accrue(alice, amount);
        uint256 investable = _investable(amount);

        assertEq(sweeper.expectedOutAtTwap(address(p), 1 * UNIT), p.quoteAtTwap(true, 1 * UNIT), "TWAP quote");
        assertEq(sweeper.twapFloor(address(p), 1 * UNIT), (p.quoteAtTwap(true, 1 * UNIT) * 9_700) / 10_000);

        p.setOutBps(9_600); // pool fills 4% below its own TWAP
        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegSkipped(alice, address(tok), investable);
        _sweep(alice, _ones(1)); // keeper passes minOut = 1
        assertEq(vault.tokenBalanceOf(alice, address(tok)), 0, "nothing bought below the floor");
        assertEq(vault.accruedStable(alice), amount, "everything returned, no fee");
        assertEq(stable.balanceOf(treasury), 0);
        assertEq(stable.balanceOf(address(sweeper)), 0);

        p.setOutBps(9_750); // 2.5% below TWAP: inside the user-authorised band
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        _sweep(alice, _ones(1));
        assertGt(vault.tokenBalanceOf(alice, address(tok)), 0);
        assertGe(vault.tokenBalanceOf(alice, address(tok)), sweeper.twapFloor(address(p), investable));
    }

    function test_M003_poolWithoutOracleHistoryIsSkippedNotFatal() public {
        (MockERC20 tA, MockSwapPool pA) = _list("A");
        (MockERC20 tB,) = _list("B");
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = address(tA); wts[0] = 5_000;
        toks[1] = address(tB); wts[1] = 5_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);
        _accrue(alice, 10 * UNIT);
        pA.setObserveReverts(true);
        vm.expectRevert(bytes("OLD"));
        sweeper.twapFloor(address(pA), 1 * UNIT);

        _sweep(alice, _ones(2));
        assertEq(vault.tokenBalanceOf(alice, address(tA)), 0, "no oracle, no buy");
        assertGt(vault.tokenBalanceOf(alice, address(tB)), 0, "the other leg fills");
        assertEq(stable.balanceOf(address(sweeper)), 0);
    }

    function test_M003_nonceConsumedPerSweep_replayRejected() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 5 * UNIT);
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory pools = _pools(alice);
        uint256[] memory minOuts = _ones(1);

        vm.prank(keeper);
        sweeper.sweep(alice, 5 * UNIT, pools, minOuts, nonce, FEE);
        assertEq(sweeper.basketNonce(alice), nonce + 1, "sweep consumed the nonce");

        _accrue(alice, 5 * UNIT);
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.StaleBasket.selector);
        sweeper.sweep(alice, 5 * UNIT, pools, minOuts, nonce, FEE); // the old quote again
        vm.prank(keeper);
        sweeper.sweep(alice, 6 * UNIT, pools, minOuts, nonce + 1, FEE); // a fresh quote (with headroom for the residue)
        assertEq(sweeper.basketNonce(alice), nonce + 2);
    }

    function test_M003_minSweepInterval() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 5 * UNIT);
        _sweep(alice, _ones(1));
        assertEq(sweeper.lastSweepAt(alice), block.timestamp);

        _accrue(alice, 5 * UNIT);
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory pools = _pools(alice);
        uint256[] memory ones = _ones(1);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.TooSoon.selector);
        sweeper.sweep(alice, 5 * UNIT, pools, ones, nonce, FEE);
        vm.warp(block.timestamp + 299);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.TooSoon.selector);
        sweeper.sweep(alice, 5 * UNIT, pools, ones, nonce, FEE);
        // the user is rate-limited the same way
        vm.prank(alice);
        vm.expectRevert(DustSweeper.TooSoon.selector);
        sweeper.sweep(alice, 5 * UNIT, pools, ones, nonce, FEE);
        vm.warp(block.timestamp + 1);
        _sweep(alice, _ones(1));
        assertLe(vault.accruedStable(alice), 2);
    }

    // ------------------------------------------------------------------
    // M004: unpinned execution parameters
    // ------------------------------------------------------------------

    function test_M004_maxAmountPinsTheAccruedBalance() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 5 * UNIT);
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory pools = _pools(alice);
        uint256[] memory ones = _ones(1);
        // the balance grew after the quote (a router round-up landed)
        _accrue(alice, 1 * UNIT);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.AmountAboveQuote.selector);
        sweeper.sweep(alice, 5 * UNIT, pools, ones, nonce, FEE);
        // a quote that allows headroom executes
        vm.prank(keeper);
        sweeper.sweep(alice, 6 * UNIT, pools, ones, nonce, FEE);
        assertEq(vault.costBasis(alice), _investable(6 * UNIT));
    }

    function test_M004_poolsPinTheVenue() public {
        (MockERC20 tA, MockSwapPool pA) = _list("A");
        (MockERC20 tB,) = _list("B");
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = address(tA); wts[0] = 5_000;
        toks[1] = address(tB); wts[1] = 5_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);
        _accrue(alice, 10 * UNIT);
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory quotedPools = _pools(alice);

        // owner re-points A at another (canonical) pool between quote and execution
        MockSwapPool pA2 = _pool(address(tA));
        pA2.setFee(500);
        factory.register(address(pA2));
        tA.mint(address(pA2), 1e36);
        sweeper.delistStock(address(tA));
        sweeper.listStock(address(tA), address(pA2));
        assertEq(sweeper.poolFor(address(tA)), address(pA2));

        vm.prank(keeper);
        vm.expectRevert(DustSweeper.PoolMismatch.selector);
        sweeper.sweep(alice, 10 * UNIT, quotedPools, _ones(2), nonce, FEE);

        // wrong array length
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.LengthMismatch.selector);
        sweeper.sweep(alice, 10 * UNIT, new address[](1), _ones(2), nonce, FEE);

        // a quote built against the new venue executes
        address[] memory freshPools = _pools(alice);
        vm.prank(keeper);
        sweeper.sweep(alice, 10 * UNIT, freshPools, _ones(2), nonce, FEE);
        assertGt(vault.tokenBalanceOf(alice, address(tA)), 0);
        assertEq(stable.balanceOf(address(pA)), 0, "the old venue saw nothing");
    }

    function test_M004_feeBpsPinned() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 10 * UNIT);
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory pools = _pools(alice);
        sweeper.setFeeBps(50); // owner moves the fee after the quote
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.FeeChanged.selector);
        sweeper.sweep(alice, 10 * UNIT, pools, _ones(1), nonce, FEE);
        vm.prank(keeper);
        sweeper.sweep(alice, 10 * UNIT, pools, _ones(1), nonce, 50);
        assertEq(stable.balanceOf(treasury), (vault.costBasis(alice) * 50) / 10_000);
    }

    // ------------------------------------------------------------------
    // L001: settlement DoS through a frozen treasury
    // ------------------------------------------------------------------

    function test_L001_frozenTreasuryDoesNotBrickSweep() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        uint256 amount = 10 * UNIT;
        _accrue(alice, amount);
        stable.setFrozen(treasury, true); // issuer freeze on the fee recipient
        uint256 investable = _investable(amount);

        vm.expectEmit(true, false, false, true, address(sweeper));
        emit DustSweeper.FeeSkipped(alice, (investable * FEE) / 10_000);
        vm.expectEmit(true, false, false, true, address(sweeper));
        emit DustSweeper.Swept(alice, amount, investable, 0, amount - investable);
        _sweep(alice, _ones(1));

        assertEq(stable.balanceOf(treasury), 0, "treasury got nothing");
        assertEq(vault.costBasis(alice), investable, "the buy went through");
        assertEq(vault.accruedStable(alice), amount - investable, "the waived fee came back to the user");
        assertEq(stable.balanceOf(address(sweeper)), 0);

        // once the treasury can receive again the fee is charged normally
        stable.setFrozen(treasury, false);
        _accrue(alice, amount);
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        uint256 investable2 = _investable(vault.accruedStable(alice)); // includes the returned fee
        _sweep(alice, _ones(1));
        assertEq(stable.balanceOf(treasury), (investable2 * FEE) / 10_000);
    }

    // ------------------------------------------------------------------
    // L002: a listed pool spending beyond its own slice
    // ------------------------------------------------------------------

    /// The auditor's scenario with the provenance check assumed defeated (the
    /// hostile pool is registered in the factory): it asks for 950 of a 1,000
    /// sweep against its 500 slice. v3 refuses inside the callback, the leg is
    /// skipped and the other leg still fills; the user loses nothing.
    function test_L002_hostileListedPoolCannotSpendBeyondItsSlice() public {
        (MockERC20 tA, MockSwapPool pA) = _list("A");
        (MockERC20 tB,) = _list("B");
        pA.setOvercharge(450 * UNIT); // slice ~495 + 450 = 945 demanded
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = address(tA); wts[0] = 5_000;
        toks[1] = address(tB); wts[1] = 5_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);
        uint256 amount = 1_000 * UNIT;
        _accrue(alice, amount);
        uint256 investable = _investable(amount);
        uint256 legA = (investable * 5_000) / 10_000;
        uint256 legB = investable - legA;

        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegSkipped(alice, address(tA), legA);
        _sweep(alice, _ones(2));

        assertEq(vault.tokenBalanceOf(alice, address(tA)), 0);
        assertEq(stable.balanceOf(address(pA)), 0, "hostile pool got nothing");
        assertGt(vault.tokenBalanceOf(alice, address(tB)), 0);
        assertEq(vault.costBasis(alice), legB);
        uint256 fee = (legB * FEE) / 10_000;
        assertEq(vault.accruedStable(alice), amount - legB - fee, "A's slice fully returned");
        assertEq(stable.balanceOf(address(sweeper)), 0);
    }

    /// One wei over the slice is enough to skip the leg.
    function test_L002_oneWeiOverSliceIsRefused() public {
        (MockERC20 tok, MockSwapPool p) = _list("A");
        p.setOvercharge(1);
        _single(alice, address(tok));
        _accrue(alice, 10 * UNIT);
        _sweep(alice, _ones(1));
        assertEq(vault.tokenBalanceOf(alice, address(tok)), 0);
        assertEq(vault.accruedStable(alice), 10 * UNIT);
        p.setOvercharge(0);
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        _sweep(alice, _ones(1));
        assertGt(vault.tokenBalanceOf(alice, address(tok)), 0);
    }

    // ------------------------------------------------------------------
    // L003: bare transfer / transferFrom
    // ------------------------------------------------------------------

    function test_L003_noReturnTokenWorksAsStockAndAsStable() public {
        // as a Stock Token through a sweep and an in-kind withdrawal
        NoReturnERC20 tok = new NoReturnERC20();
        MockSwapPool p = _pool(address(tok));
        tok.mint(address(p), 1e36);
        sweeper.listStock(address(tok), address(p));
        _single(alice, address(tok));
        _accrue(alice, 10 * UNIT);
        _sweep(alice, _ones(1));
        uint256 credited = vault.tokenBalanceOf(alice, address(tok));
        assertGt(credited, 0, "no-return token swept");
        vm.prank(alice);
        vault.withdrawToken(address(tok), credited, alice);
        assertEq(tok.balanceOf(alice), credited);

        // as the stable through the router and the vault
        NoReturnERC20 usdt = new NoReturnERC20();
        DustVault v = new DustVault(IERC20(address(usdt)));
        DustRouter r = new DustRouter(IERC20(address(usdt)), IDustVault(address(v)), 1e18, IV3Factory(address(factory)));
        v.setModules(address(r), address(this), address(0));
        MockERC20 t2 = new MockERC20("T2", 18);
        MockSwapPool p2 = new MockSwapPool(address(usdt), address(t2), 0);
        factory.register(address(p2));
        t2.mint(address(p2), 1e36);
        usdt.mint(alice, 200e18);
        vm.startPrank(alice);
        usdt.approve(address(r), type(uint256).max);
        (, uint256 roundUp) = r.swapWithRoundUp(address(p2), address(t2), 137.42e18, 1, 1, 1);
        vm.stopPrank();
        assertEq(roundUp, 0.58e18);
        assertEq(v.accruedStable(alice), 0.58e18);
        assertEq(usdt.balanceOf(address(v)), 0.58e18);
        assertEq(usdt.balanceOf(address(r)), 0);
        vm.prank(alice);
        v.withdrawAccrued(0.58e18, alice);
        assertEq(v.accruedStable(alice), 0);
    }

    function test_L003_falseReturningTokenIsCaughtAndSelectorsMatch() public {
        // the library reverts with the same selector the contracts declare
        assertEq(SafeTransfer.TransferFailed.selector, DustVault.TransferFailed.selector);
        assertEq(SafeTransfer.TransferFailed.selector, DustRouter.TransferFailed.selector);
        assertEq(SafeTransfer.TransferFailed.selector, DustSweeper.TransferFailed.selector);
        assertEq(SafeTransfer.TransferFailed.selector, DustCapture.TransferFailed.selector);

        // vault: a false return is a revert, state intact
        FalseReturnERC20 f = new FalseReturnERC20();
        f.mint(address(rvault), 5e18);
        rvault.creditTokens(alice, address(f), 5e18, 0); // this test is rvault's sweeper
        f.setFailAll(true);
        vm.prank(alice);
        vm.expectRevert(DustVault.TransferFailed.selector);
        rvault.withdrawToken(address(f), 5e18, alice);
        assertEq(rvault.tokenBalanceOf(alice, address(f)), 5e18);
        f.setFailAll(false);
        vm.prank(alice);
        rvault.withdrawToken(address(f), 5e18, alice);
        assertEq(f.balanceOf(alice), 5e18);

        // an address without code is not a token
        rvault.creditTokens(alice, address(0xdead), 1, 0);
        vm.prank(alice);
        vm.expectRevert(DustVault.TransferFailed.selector);
        rvault.withdrawToken(address(0xdead), 1, alice);

        // sweeper: a false-returning Stock Token skips its leg and returns the slice
        FalseReturnERC20 g = new FalseReturnERC20();
        MockSwapPool pg = _pool(address(g));
        g.mint(address(pg), 1e36);
        sweeper.listStock(address(g), address(pg));
        _single(alice, address(g));
        _accrue(alice, 10 * UNIT);
        g.setFailAll(true);
        _sweep(alice, _ones(1));
        assertEq(vault.tokenBalanceOf(alice, address(g)), 0);
        assertEq(vault.accruedStable(alice), 10 * UNIT);

        // router: a false-returning stable fails closed
        FalseReturnERC20 fs = new FalseReturnERC20();
        DustVault v = new DustVault(IERC20(address(fs)));
        DustRouter r = new DustRouter(IERC20(address(fs)), IDustVault(address(v)), 1e18, IV3Factory(address(factory)));
        MockERC20 t = new MockERC20("T", 18);
        MockSwapPool pr = new MockSwapPool(address(fs), address(t), 0);
        factory.register(address(pr));
        fs.mint(alice, 10e18);
        fs.setFailAll(true);
        vm.startPrank(alice);
        fs.approve(address(r), type(uint256).max);
        vm.expectRevert(DustRouter.TransferFailed.selector);
        r.swapWithRoundUp(address(pr), address(t), 1e18, 1, 1, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // I002: minOut == 0 rejected before the delisted skip
    // ------------------------------------------------------------------

    function test_I002_delistedLegWithZeroMinOutIsSkipped() public {
        (MockERC20 tA,) = _list("A");
        (MockERC20 tB,) = _list("B");
        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = address(tA); wts[0] = 5_000;
        toks[1] = address(tB); wts[1] = 5_000;
        vm.prank(alice);
        sweeper.setBasket(toks, wts);
        _accrue(alice, 10 * UNIT);
        sweeper.delistStock(address(tA));

        uint256[] memory minOuts = _ones(2);
        minOuts[0] = 0; // placeholder for the delisted leg
        address[] memory pools = _pools(alice); // pools[0] is address(0)
        pools[0] = address(0xbeef); // and it does not matter what the caller put there
        uint256 legA = (_investable(10 * UNIT) * 5_000) / 10_000;
        uint256 nonce = sweeper.basketNonce(alice);
        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegSkipped(alice, address(tA), legA);
        vm.prank(keeper);
        sweeper.sweep(alice, 10 * UNIT, pools, minOuts, nonce, FEE);
        assertGt(vault.tokenBalanceOf(alice, address(tB)), 0);

        // a zero floor on a LISTED, funded leg still reverts
        _accrue(alice, 10 * UNIT);
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        minOuts[1] = 0;
        nonce = sweeper.basketNonce(alice);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.ZeroMinOut.selector);
        sweeper.sweep(alice, 20 * UNIT, pools, minOuts, nonce, FEE);
    }

    // ------------------------------------------------------------------
    // Retest (CredShields-style break attempts beyond the reported scenarios)
    // ------------------------------------------------------------------

    /// H001 (retest): for ANY fill fraction, price, size and round-up setting,
    /// one call leaves the router's stable balance exactly where it was (a
    /// pre-existing pot included), the caller pays exactly spent + roundUp and
    /// the pool receives exactly what it consumed. Nothing can accumulate.
    function testFuzz_H001_routerNeverAccumulates(uint16 fillBps, uint16 outBps, uint64 amountIn, uint8 gran, uint8 mult)
        public
    {
        fillBps = uint16(bound(fillBps, 0, 10_000));
        outBps = uint16(bound(outBps, 0, 20_000));
        amountIn = uint64(bound(amountIn, 1, 1_000_000 * UNIT));
        gran = uint8(bound(gran, 1, 100));
        mult = uint8(bound(mult, 1, 10));

        MockERC20 tok = new MockERC20("T", 18);
        MockSwapPool p = _pool(address(tok));
        tok.mint(address(p), 1e40);
        p.setFillBps(fillBps);
        p.setOutBps(outBps);

        uint256 pot = 777 * UNIT; // a hypothetical stranded pot (v2 legacy) must be untouchable
        stable.mint(address(router), pot);
        uint256 funding = uint256(amountIn) + uint256(gran) * UNIT * mult;
        stable.mint(alice, funding);

        uint256 expectedSpent = (uint256(amountIn) * fillBps) / 10_000;
        uint256 expectedOut = (p.quoteAtTwap(true, expectedSpent) * outBps) / 10_000;

        vm.startPrank(alice);
        stable.approve(address(router), type(uint256).max);
        if (expectedSpent == 0) {
            vm.expectRevert(DustRouter.NothingSpent.selector);
            router.swapWithRoundUp(address(p), address(tok), amountIn, 1, gran, mult);
        } else if (expectedOut == 0) {
            vm.expectRevert(DustRouter.ZeroOutput.selector);
            router.swapWithRoundUp(address(p), address(tok), amountIn, 1, gran, mult);
        } else {
            (uint256 out, uint256 roundUp) = router.swapWithRoundUp(address(p), address(tok), amountIn, 1, gran, mult);
            assertEq(out, expectedOut, "tokens measured at the user");
            assertEq(roundUp, router.roundUpAmount(expectedSpent, gran, mult), "round-up on spent");
            assertEq(stable.balanceOf(alice), funding - expectedSpent - roundUp, "caller pays spent + roundUp only");
            assertEq(stable.balanceOf(address(p)), expectedSpent, "pool paid exactly what it consumed");
            assertEq(rvault.accruedStable(alice), roundUp);
            assertEq(stable.balanceOf(address(rvault)), roundUp);
        }
        vm.stopPrank();
        assertEq(stable.balanceOf(address(router)), pot, "router balance must never change");
    }

    /// H001 (retest): a pool whose fee() lies about its tier is refused by the
    /// router and by listStock, both when the factory has no pool at the claimed
    /// tier and when it has a different one.
    function test_H001_poolLyingAboutFeeIsRefused() public {
        MockERC20 tok = new MockERC20("T", 18);
        MockSwapPool p = _pool(address(tok)); // registered at its real tier (3000)
        tok.mint(address(p), 1e36);
        stable.mint(alice, 10 * UNIT);
        vm.startPrank(alice);
        stable.approve(address(router), type(uint256).max);
        router.swapWithRoundUp(address(p), address(tok), 1 * UNIT, 1, 1, 1); // honest tier: fine

        p.setFee(500); // claims a tier the factory has no pool for
        vm.expectRevert(DustRouter.BadPool.selector);
        router.swapWithRoundUp(address(p), address(tok), 1 * UNIT, 1, 1, 1);

        MockSwapPool other = new MockSwapPool(address(stable), address(tok), TICK);
        other.setFee(500);
        factory.register(address(other)); // now the factory knows a different pool at 500
        vm.expectRevert(DustRouter.BadPool.selector);
        router.swapWithRoundUp(address(p), address(tok), 1 * UNIT, 1, 1, 1);
        vm.stopPrank();

        vm.expectRevert(DustSweeper.BadListing.selector);
        sweeper.listStock(address(tok), address(p));
        sweeper.listStock(address(tok), address(other)); // the pool the factory vouches for lists fine
        assertEq(sweeper.poolFor(address(tok)), address(other));
    }

    /// M003 (retest): a keeper that fills at the worst price the floor allows,
    /// sweep after sweep, and that forces skips to recycle stable in between,
    /// can cost a unit of round-up at most MAX_SWEEP_SLIPPAGE_BPS once (plus the
    /// fee once). Stable that came back was never sold and is never re-taxed.
    function test_M003_repeatedWorstCaseSweepsAreBounded() public {
        (MockERC20 tok, MockSwapPool p) = _list("A");
        _single(alice, address(tok));
        uint256 accruedTotal;
        uint256[] memory skipAll = new uint256[](1);
        skipAll[0] = type(uint256).max;

        for (uint256 r; r < 8; r++) {
            _accrue(alice, 7 * UNIT);
            accruedTotal += 7 * UNIT;

            // keeper forces a skip: everything returns, no fee, nothing sold
            uint256 before = vault.accruedStable(alice);
            uint256 feeBefore = stable.balanceOf(treasury);
            _sweep(alice, skipAll);
            assertEq(vault.accruedStable(alice), before, "forced skip returns everything");
            assertEq(stable.balanceOf(treasury), feeBefore, "forced skip charges nothing");
            vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());

            // keeper fills exactly at the floor with minOut = 1
            p.setOutBps(10_000 - sweeper.MAX_SWEEP_SLIPPAGE_BPS());
            _sweep(alice, _ones(1));
            assertEq(stable.balanceOf(address(sweeper)), 0);
            vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        }

        uint256 invested = vault.costBasis(alice);
        uint256 fee = stable.balanceOf(treasury);
        assertEq(invested + fee + vault.accruedStable(alice), accruedTotal, "conservation across every sweep");
        // tokens received >= (1 - 3%) of the TWAP value of everything invested (price is linear in the mock)
        // each of the 8 fills floors twice (quote, then the 97% scaling), so allow 2 raw units per fill
        uint256 fairTokens = p.quoteAtTwap(true, invested);
        assertGe(
            vault.tokenBalanceOf(alice, address(tok)) * 10_000 + 8 * 2 * 10_000,
            fairTokens * (10_000 - sweeper.MAX_SWEEP_SLIPPAGE_BPS()),
            "lifetime price loss bounded by the floor"
        );
        // lifetime fee within feeBps of what was ever accrued
        assertLe(fee * 10_000, accruedTotal * FEE);
        assertLe(vault.accruedStable(alice), 8 * 2, "only rounding residues remain");
    }

    /// M003 (retest): the on-chain floor is right for both token orderings
    /// (the mainnet menu has USDG as token0 in some pools and token1 in others).
    function test_M003_twapFloorHoldsWithStableAsToken1() public {
        MockERC20 tok = new MockERC20("B", 18);
        MockSwapPool p = new MockSwapPool(address(tok), address(stable), -TICK); // stable is token1
        factory.register(address(p));
        tok.mint(address(p), 1e36);
        sweeper.listStock(address(tok), address(p));
        assertEq(sweeper.expectedOutAtTwap(address(p), 3 * UNIT), p.quoteAtTwap(false, 3 * UNIT), "token1 ordering");
        assertGt(sweeper.expectedOutAtTwap(address(p), 3 * UNIT), 0);

        _single(alice, address(tok));
        uint256 amount = 10 * UNIT;
        _accrue(alice, amount);
        uint256 investable = _investable(amount);

        p.setOutBps(9_650); // 3.5% below TWAP: skipped
        _sweep(alice, _ones(1));
        assertEq(vault.tokenBalanceOf(alice, address(tok)), 0, "below the floor: nothing bought");
        assertEq(vault.accruedStable(alice), amount);

        p.setOutBps(9_750); // 2.5% below: fills
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        _sweep(alice, _ones(1));
        uint256 got = vault.tokenBalanceOf(alice, address(tok));
        assertGt(got, 0);
        assertGe(got, sweeper.twapFloor(address(p), investable), "fill at or above the floor");
        assertEq(stable.balanceOf(address(p)), investable, "pool received the whole slice");
    }

    /// M004 (retest): the treasury is not a quote input. Clearing or setting it
    /// between quote and execution changes neither the leg sizes nor the amount
    /// invested; it only decides whether the fee reserve goes to the treasury
    /// or back to the user.
    function test_M004_treasuryChangeCannotResizeLegs() public {
        (MockERC20 tok, MockSwapPool p) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 10 * UNIT);
        uint256 investable = _investable(10 * UNIT); // quoted while the treasury is set
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory pools = _pools(alice);

        sweeper.setTreasury(address(0)); // owner clears the treasury after the quote
        vm.expectEmit(true, true, false, true, address(sweeper));
        emit DustSweeper.LegBought(alice, address(tok), investable, p.quoteAtTwap(true, investable));
        vm.expectEmit(true, false, false, true, address(sweeper));
        emit DustSweeper.Swept(alice, 10 * UNIT, investable, 0, 10 * UNIT - investable);
        vm.prank(keeper);
        sweeper.sweep(alice, 10 * UNIT, pools, _ones(1), nonce, FEE);
        assertEq(vault.costBasis(alice), investable, "leg exactly as quoted");
        assertEq(stable.balanceOf(treasury), 0);
        assertEq(vault.accruedStable(alice), 10 * UNIT - investable, "the fee reserve came back to the user");

        // reverse: quoted with no treasury, owner sets one before execution
        _accrue(alice, 10 * UNIT);
        vm.warp(block.timestamp + sweeper.MIN_SWEEP_INTERVAL());
        uint256 amount = vault.accruedStable(alice);
        uint256 investable2 = _investable(amount);
        nonce = sweeper.basketNonce(alice);
        sweeper.setTreasury(treasury);
        vm.prank(keeper);
        sweeper.sweep(alice, amount, pools, _ones(1), nonce, FEE);
        assertEq(vault.costBasis(alice) - investable, investable2, "leg exactly as quoted again");
        assertEq(stable.balanceOf(treasury), (investable2 * FEE) / 10_000);
        assertEq(stable.balanceOf(address(sweeper)), 0);
    }

    /// M004 (retest): the one owner input a quote does not carry, minSweepAmount,
    /// can only make the sweep revert; nothing moves and the quote stays valid.
    function test_M004_minSweepAmountChangeOnlyReverts() public {
        (MockERC20 tok,) = _list("A");
        _single(alice, address(tok));
        _accrue(alice, 5 * UNIT);
        uint256 nonce = sweeper.basketNonce(alice);
        address[] memory pools = _pools(alice);
        sweeper.setMinSweepAmount(6 * UNIT);
        vm.prank(keeper);
        vm.expectRevert(DustSweeper.BelowMinimum.selector);
        sweeper.sweep(alice, 5 * UNIT, pools, _ones(1), nonce, FEE);
        assertEq(vault.accruedStable(alice), 5 * UNIT);
        assertEq(sweeper.basketNonce(alice), nonce, "a reverted sweep consumes nothing");
        sweeper.setMinSweepAmount(0);
        vm.prank(keeper);
        sweeper.sweep(alice, 5 * UNIT, pools, _ones(1), nonce, FEE);
        assertGt(vault.tokenBalanceOf(alice, address(tok)), 0);
    }
}
