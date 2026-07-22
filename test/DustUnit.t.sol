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

    function setUp() public {
        stable = new MockERC20("USDG", 18);
        vault = new DustVault(IERC20(address(stable)));
        router = new DustRouter(IERC20(address(stable)), IDustVault(address(vault)), UNIT);
        // sweeper not needed for unit tests of vault/router surfaces; wire a stub
        vault.setModules(address(router), address(this));
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
        vault.setModules(address(1), address(2));
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

    function _leg(address token, uint16 bps) internal returns (DustSweeper.BasketLeg memory) {
        // pool must pair `stable` with `token` to pass _validate
        MockPool p = new MockPool(address(stable), token);
        return DustSweeper.BasketLeg(token, address(p), bps);
    }

    function test_sweeper_basketTimelockAndVersion() public {
        address tA = address(new MockERC20("A", 18));
        address tB = address(new MockERC20("B", 18));
        DustSweeper.BasketLeg[] memory legs = new DustSweeper.BasketLeg[](1);
        legs[0] = _leg(tA, 10_000);
        DustSweeper sweeper =
            new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), 1 days, legs);
        assertEq(sweeper.basketVersion(), 0);

        DustSweeper.BasketLeg[] memory next = new DustSweeper.BasketLeg[](2);
        next[0] = _leg(tA, 6_000);
        next[1] = _leg(tB, 4_000);
        sweeper.proposeBasket(next);

        vm.expectRevert(DustSweeper.TimelockNotReady.selector);
        sweeper.executeBasket();

        vm.warp(block.timestamp + 1 days);
        sweeper.executeBasket();
        assertEq(sweeper.basketLength(), 2);
        assertEq(sweeper.basketVersion(), 1, "version must bump");
    }

    function test_sweeper_rejectsBadWeights() public {
        DustSweeper.BasketLeg[] memory legs = new DustSweeper.BasketLeg[](1);
        legs[0] = _leg(address(new MockERC20("A", 18)), 9_999);
        vm.expectRevert(DustSweeper.BadBasket.selector);
        new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), 1 days, legs);
    }

    function test_sweeper_rejectsPoolTokenMismatch() public {
        address tA = address(new MockERC20("A", 18));
        address wrong = address(new MockERC20("W", 18));
        // pool pairs stable/wrong but leg claims token tA -> must reject
        MockPool p = new MockPool(address(stable), wrong);
        DustSweeper.BasketLeg[] memory legs = new DustSweeper.BasketLeg[](1);
        legs[0] = DustSweeper.BasketLeg(tA, address(p), 10_000);
        vm.expectRevert(DustSweeper.BadBasket.selector);
        new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), 1 days, legs);
    }

    function test_sweeper_twoStepOwnership() public {
        DustSweeper.BasketLeg[] memory legs = new DustSweeper.BasketLeg[](1);
        legs[0] = _leg(address(new MockERC20("A", 18)), 10_000);
        DustSweeper sweeper =
            new DustSweeper(IERC20(address(stable)), IDustVault(address(vault)), 1 days, legs);

        vm.expectRevert(DustSweeper.ZeroAddress.selector);
        sweeper.transferOwnership(address(0));

        sweeper.transferOwnership(bob);
        assertEq(sweeper.owner(), address(this), "owner unchanged until accept");
        vm.prank(alice);
        vm.expectRevert(DustSweeper.NotAuthorized.selector);
        sweeper.acceptOwnership();
        vm.prank(bob);
        sweeper.acceptOwnership();
        assertEq(sweeper.owner(), bob);
    }
}
