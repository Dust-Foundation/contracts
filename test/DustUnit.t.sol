// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {IERC20, IDustVault, IV3Factory} from "../src/interfaces/IDust.sol";
import {MockERC20, MockSwapPool} from "./mocks/SweeperMocks.sol";
import {MockFactory} from "./mocks/CaptureMocks.sol";

contract DustUnitTest is Test {
    MockERC20 stable;
    MockFactory factory;
    DustVault vault;
    DustRouter router;

    uint256 constant UNIT = 1e18;
    int24 constant TICK = 0; // 1:1 price, plenty for config tests
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    function setUp() public {
        stable = new MockERC20("USDG", 18);
        factory = new MockFactory();
        vault = new DustVault(IERC20(address(stable)));
        router = new DustRouter(IERC20(address(stable)), IDustVault(address(vault)), UNIT, IV3Factory(address(factory)));
        // sweeper not needed for unit tests of vault/router surfaces; wire a stub
        vault.setModules(address(router), address(this), address(0));
    }

    // ---- round-up math ----

    function test_roundUp_basicExamples() public view {
        // 137.42 at nearest-1 -> 0.58
        assertEq(router.roundUpAmount(137.42e18, 1, 1), 0.58e18);
        // 137.42 at nearest-5 -> 2.58
        assertEq(router.roundUpAmount(137.42e18, 5, 1), 2.58e18);
        // 2x multiplier doubles the change
        assertEq(router.roundUpAmount(137.42e18, 1, 2), 1.16e18);
        // exact multiple rounds to zero
        assertEq(router.roundUpAmount(140e18, 5, 1), 0);
    }

    function testFuzz_roundUp_boundsAndDivisibility(uint256 amountIn, uint8 gRaw, uint8 mRaw) public view {
        uint256 g = bound(uint256(gRaw), 1, 100);
        uint256 m = bound(uint256(mRaw), 1, 10);
        amountIn = bound(amountIn, 1, 1e30);

        uint256 r = router.roundUpAmount(amountIn, g, m);
        uint256 step = g * UNIT;
        // round-up is strictly less than one full step (times multiplier)
        assertLt(r, step * m);
        // amount + base round-up lands exactly on a step boundary
        if (r > 0) assertEq((amountIn + r / m) % step, 0);
    }

    function testFuzz_roundUp_rejectsBadParams(uint256 g, uint256 m) public {
        vm.assume(g == 0 || g > 100 || m == 0 || m > 10);
        vm.expectRevert(DustRouter.BadParams.selector);
        router.roundUpAmount(1e18, g, m);
    }

    // ---- USDG readiness: the same math at 6 decimals (mainnet stable) ----

    function _router6() internal returns (DustRouter r6) {
        MockERC20 usdg = new MockERC20("USDG", 6);
        DustVault v6 = new DustVault(IERC20(address(usdg)));
        r6 = new DustRouter(IERC20(address(usdg)), IDustVault(address(v6)), 1e6, IV3Factory(address(factory)));
    }

    function test_roundUp_sixDecimalStable() public {
        DustRouter r6 = _router6();
        // 137.42 USDG at 6 decimals
        assertEq(r6.roundUpAmount(137_420_000, 1, 1), 580_000);      // -> 0.58
        assertEq(r6.roundUpAmount(137_420_000, 5, 1), 2_580_000);    // -> 2.58
        assertEq(r6.roundUpAmount(137_420_000, 1, 2), 1_160_000);    // 2x boost
        assertEq(r6.roundUpAmount(140_000_000, 5, 1), 0);            // exact multiple
        // a sub-cent amount still rounds correctly
        assertEq(r6.roundUpAmount(999_999, 1, 1), 1);                // 0.999999 -> 1.000000
    }

    function testFuzz_roundUp_sixDecimals(uint256 amountIn, uint8 gRaw, uint8 mRaw) public {
        DustRouter r6 = _router6();
        uint256 g = bound(uint256(gRaw), 1, 100);
        uint256 m = bound(uint256(mRaw), 1, 10);
        amountIn = bound(amountIn, 1, 1e18); // up to a trillion USDG

        uint256 r = r6.roundUpAmount(amountIn, g, m);
        uint256 step = g * 1e6;
        assertLt(r, step * m);
        if (r > 0) assertEq((amountIn + r / m) % step, 0);
    }

    // ---- vault accounting ----

    function test_vault_onlyModulesCanMutate() public {
        vm.startPrank(alice);
        vm.expectRevert(DustVault.NotAuthorized.selector);
        vault.accrue(alice, 1);
        vm.expectRevert(DustVault.NotAuthorized.selector);
        vault.debitAccrued(alice, 1);
        vm.expectRevert(DustVault.NotAuthorized.selector);
        vault.creditTokens(alice, address(stable), 1, 1);
        vm.stopPrank();
    }

    function test_vault_modulesSetOnce() public {
        vm.expectRevert(DustVault.AlreadySet.selector);
        vault.setModules(address(1), address(2), address(0));
    }

    function testFuzz_vault_accrueWithdraw(uint96 a, uint96 b) public {
        uint256 amtA = bound(uint256(a), 1, 1e30);
        uint256 amtB = bound(uint256(b), 1, 1e30);

        stable.mint(address(vault), amtA + amtB);
        vm.prank(address(router));
        vault.accrue(alice, amtA);
        vm.prank(address(router));
        vault.accrue(bob, amtB);

        assertEq(vault.accruedStable(alice), amtA);
        assertEq(vault.accruedStable(bob), amtB);

        // alice cannot take bob's
        vm.prank(alice);
        vm.expectRevert(DustVault.InsufficientBalance.selector);
        vault.withdrawAccrued(amtA + 1, alice);

        vm.prank(alice);
        vault.withdrawAccrued(amtA, alice);
        assertEq(stable.balanceOf(alice), amtA);
        assertEq(vault.accruedStable(alice), 0);
        // bob untouched
        assertEq(vault.accruedStable(bob), amtB);
    }

    function testFuzz_vault_tokenLedger(uint96 amtRaw) public {
        uint256 amt = bound(uint256(amtRaw), 1, 1e30);
        MockERC20 tsla = new MockERC20("TSLA", 18);
        tsla.mint(address(vault), amt);

        // this test contract is wired as sweeper
        vault.creditTokens(alice, address(tsla), amt, amt / 2);
        assertEq(vault.tokenBalanceOf(alice, address(tsla)), amt);
        assertEq(vault.costBasis(alice), amt / 2);

        vm.prank(alice);
        vault.withdrawToken(address(tsla), amt, alice);
        assertEq(tsla.balanceOf(alice), amt);
        assertEq(vault.tokenBalanceOf(alice, address(tsla)), 0);
    }

    // ---- sweeper config ----

    function _newSweeper() internal returns (DustSweeper) {
        return new DustSweeper(
            IERC20(address(stable)), IDustVault(address(vault)), treasury, IV3Factory(address(factory))
        );
    }

    /// A canonical (factory-registered) pool pairing the stable with a fresh token.
    function _list(DustSweeper s, string memory sym) internal returns (address token) {
        token = address(new MockERC20(sym, 18));
        MockSwapPool p = new MockSwapPool(address(stable), token, TICK);
        factory.register(address(p));
        s.listStock(token, address(p));
    }

    function test_sweeper_constructorRejectsZeroFactory() public {
        vm.expectRevert(DustSweeper.ZeroAddress.selector);
        new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), treasury, IV3Factory(address(0)));
        vm.expectRevert(DustRouter.BadParams.selector);
        new DustRouter(IERC20(address(stable)), IDustVault(address(vault)), UNIT, IV3Factory(address(0)));
    }

    function test_sweeper_menuListing() public {
        DustSweeper s = _newSweeper();
        address tA = _list(s, "A");
        assertEq(s.menuLength(), 1);
        assertTrue(s.poolFor(tA) != address(0));

        // can't list twice
        MockSwapPool p2 = new MockSwapPool(address(stable), tA, TICK);
        factory.register(address(p2));
        vm.expectRevert(DustSweeper.AlreadyListed.selector);
        s.listStock(tA, address(p2));

        // delist stops new buys but leaves menu consistent
        s.delistStock(tA);
        assertEq(s.menuLength(), 0);
        assertEq(s.poolFor(tA), address(0));
    }

    function test_sweeper_rejectsPoolTokenMismatch() public {
        DustSweeper s = _newSweeper();
        address tA = address(new MockERC20("A", 18));
        address wrong = address(new MockERC20("W", 18));
        MockSwapPool p = new MockSwapPool(address(stable), wrong, TICK); // pairs stable/wrong, not tA
        factory.register(address(p));
        vm.expectRevert(DustSweeper.BadListing.selector);
        s.listStock(tA, address(p));
    }

    /// Audit L002: a pool with the right pairing that the factory does not
    /// acknowledge cannot be listed.
    function test_sweeper_rejectsNonCanonicalPool() public {
        DustSweeper s = _newSweeper();
        address tA = address(new MockERC20("A", 18));
        MockSwapPool lookalike = new MockSwapPool(address(stable), tA, TICK); // never registered
        vm.expectRevert(DustSweeper.BadListing.selector);
        s.listStock(tA, address(lookalike));
        // a registered pool for the same pair but a different fee tier is a different pool
        MockSwapPool canonical = new MockSwapPool(address(stable), tA, TICK);
        canonical.setFee(500);
        factory.register(address(canonical));
        lookalike.setFee(500);
        vm.expectRevert(DustSweeper.BadListing.selector);
        s.listStock(tA, address(lookalike));
        s.listStock(tA, address(canonical));
        assertEq(s.poolFor(tA), address(canonical));
    }

    function test_sweeper_onlyOwnerCanListStock() public {
        DustSweeper s = _newSweeper();
        address tA = address(new MockERC20("A", 18));
        MockSwapPool p = new MockSwapPool(address(stable), tA, TICK);
        factory.register(address(p));
        vm.prank(alice);
        vm.expectRevert(DustSweeper.NotAuthorized.selector);
        s.listStock(tA, address(p));
    }

    function test_sweeper_userSetsOwnBasket() public {
        DustSweeper s = _newSweeper();
        address tA = _list(s, "A");
        address tB = _list(s, "B");

        address[] memory toks = new address[](2);
        uint16[] memory wts = new uint16[](2);
        toks[0] = tA; wts[0] = 7_000;
        toks[1] = tB; wts[1] = 3_000;

        vm.prank(alice);
        s.setBasket(toks, wts);
        assertEq(s.basketLengthOf(alice), 2);
        assertEq(s.basketNonce(alice), 1);

        DustSweeper.Leg[] memory legs = s.basketOf(alice);
        assertEq(legs[0].token, tA);
        assertEq(legs[0].weightBps, 7_000);
        assertEq(legs[1].weightBps, 3_000);
    }

    function test_sweeper_basketValidation() public {
        DustSweeper s = _newSweeper();
        address tA = _list(s, "A");
        address tUnlisted = address(new MockERC20("U", 18));

        address[] memory toks = new address[](1);
        uint16[] memory wts = new uint16[](1);

        // weights must sum to 10_000
        toks[0] = tA; wts[0] = 9_999;
        vm.prank(alice);
        vm.expectRevert(DustSweeper.BadBasket.selector);
        s.setBasket(toks, wts);

        // token must be on the menu
        toks[0] = tUnlisted; wts[0] = 10_000;
        vm.prank(alice);
        vm.expectRevert(DustSweeper.NotListed.selector);
        s.setBasket(toks, wts);

        // duplicate tokens rejected
        address[] memory dup = new address[](2);
        uint16[] memory dw = new uint16[](2);
        dup[0] = tA; dup[1] = tA; dw[0] = 5_000; dw[1] = 5_000;
        vm.prank(alice);
        vm.expectRevert(DustSweeper.BadBasket.selector);
        s.setBasket(dup, dw);
    }

    function test_sweeper_sweepWithoutBasketReverts() public {
        DustSweeper s = _newSweeper();
        _list(s, "A");
        uint256[] memory minOuts = new uint256[](0);
        address[] memory pools = new address[](0);
        vm.prank(alice);
        vm.expectRevert(DustSweeper.NoBasket.selector);
        s.sweep(alice, 0, pools, minOuts, 0, 100);
    }

    function test_sweeper_feeConfig() public {
        DustSweeper s = _newSweeper();
        assertEq(s.feeBps(), 100, "1% default");
        assertEq(s.treasury(), treasury);
        assertEq(s.MAX_FEE_BPS(), 500);
        assertEq(s.MAX_SWEEP_SLIPPAGE_BPS(), 300);
        assertEq(s.TWAP_WINDOW(), 600);
        assertEq(s.MIN_SWEEP_INTERVAL(), 300);

        s.setFeeBps(250);
        assertEq(s.feeBps(), 250);
        vm.expectRevert(DustSweeper.FeeTooHigh.selector);
        s.setFeeBps(501);

        vm.prank(alice);
        vm.expectRevert(DustSweeper.NotAuthorized.selector);
        s.setFeeBps(100);
    }

    function test_sweeper_twoStepOwnership() public {
        DustSweeper s = _newSweeper();
        vm.expectRevert(DustSweeper.ZeroAddress.selector);
        s.transferOwnership(address(0));

        s.transferOwnership(bob);
        assertEq(s.owner(), address(this), "owner unchanged until accept");
        vm.prank(alice);
        vm.expectRevert(DustSweeper.NotAuthorized.selector);
        s.acceptOwnership();
        vm.prank(bob);
        s.acceptOwnership();
        assertEq(s.owner(), bob);
    }
}
