// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {IERC20, IDustVault} from "../src/interfaces/IDust.sol";

contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _sym, uint8 _dec) {
        symbol = _sym;
        decimals = _dec;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockPool {
    address public token0;
    address public token1;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }
}

contract DustUnitTest is Test {
    MockERC20 stable;
    DustVault vault;
    DustRouter router;

    uint256 constant UNIT = 1e18;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    function setUp() public {
        stable = new MockERC20("USDG", 18);
        vault = new DustVault(IERC20(address(stable)));
        router = new DustRouter(IERC20(address(stable)), IDustVault(address(vault)), UNIT);
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
        return new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), treasury);
    }

    function _list(DustSweeper s, string memory sym) internal returns (address token) {
        token = address(new MockERC20(sym, 18));
        MockPool p = new MockPool(address(stable), token); // pool pairs stable<->token
        s.listStock(token, address(p));
    }

    function test_sweeper_menuListing() public {
        DustSweeper s = _newSweeper();
        address tA = _list(s, "A");
        assertEq(s.menuLength(), 1);
        assertTrue(s.poolFor(tA) != address(0));

        // can't list twice
        MockPool p2 = new MockPool(address(stable), tA);
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
        MockPool p = new MockPool(address(stable), wrong); // pairs stable/wrong, not tA
        vm.expectRevert(DustSweeper.BadListing.selector);
        s.listStock(tA, address(p));
    }

    function test_sweeper_onlyOwnerCanListStock() public {
        DustSweeper s = _newSweeper();
        address tA = address(new MockERC20("A", 18));
        MockPool p = new MockPool(address(stable), tA);
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
        vm.prank(alice);
        vm.expectRevert(DustSweeper.NoBasket.selector);
        s.sweep(alice, minOuts, 0);
    }

    function test_sweeper_feeConfig() public {
        DustSweeper s = _newSweeper();
        assertEq(s.feeBps(), 100, "1% default");
        assertEq(s.treasury(), treasury);
        assertEq(s.MAX_FEE_BPS(), 500);

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
