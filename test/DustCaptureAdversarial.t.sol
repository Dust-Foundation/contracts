// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IDustVault} from "../src/interfaces/IDust.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {FullMath} from "../src/libraries/FullMath.sol";
import {MockStable, MockWETH, MockSweeper, MockV3Pool} from "./mocks/CaptureMocks.sol";

/// A float owner that re-enters the capture module from its receive() hook
/// while its own withdrawal is mid-flight.
contract ReentrantRecipient {
    DustCapture immutable capture;
    uint8 public mode; // 1 = withdrawEth again, 2 = depositEth, 3 = spoof the swap callback
    uint256 public reentries;
    bool public innerOk;

    constructor(DustCapture c) {
        capture = c;
    }

    function setMode(uint8 m) external {
        mode = m;
        reentries = 0;
    }

    function deposit() external payable {
        capture.depositEth{value: msg.value}();
    }

    function withdraw(uint256 amt) external {
        capture.withdrawEth(amt, address(this));
    }

    receive() external payable {
        if (reentries > 0) return;
        reentries++;
        if (mode == 1) {
            (innerOk,) = address(capture).call(abi.encodeCall(capture.withdrawEth, (msg.value, address(this))));
        } else if (mode == 2) {
            (innerOk,) = address(capture).call{value: msg.value}(abi.encodeCall(capture.depositEth, ()));
        } else if (mode == 3) {
            (innerOk,) = address(capture).call(abi.encodeCall(capture.uniswapV3SwapCallback, (int256(1), -int256(1), "")));
        }
    }
}

/// A recipient that burns all forwarded gas.
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// Oracle-only pool double: token pair + arbitrary tick cumulatives, so the
/// mean-tick rounding in maxWethInFor can be driven to non-divisible deltas.
contract ObservePool {
    address public immutable token0;
    address public immutable token1;
    int56 c0;
    int56 c1;

    constructor(address a, address b) {
        token0 = a;
        token1 = b;
    }

    function set(int56 a, int56 b) external {
        c0 = a;
        c1 = b;
    }

    function observe(uint32[] calldata) external view returns (int56[] memory t, uint160[] memory l) {
        t = new int56[](2);
        l = new uint160[](2);
        t[0] = c0;
        t[1] = c1;
    }
}

contract DustCaptureAdversarialTest is Test {
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

    uint256 constant UNIT = 1e6;
    int24 constant TICK = -198080;

    function setUp() public {
        stable = new MockStable();
        weth = new MockWETH();
        pool = new MockV3Pool(address(weth), address(stable), TICK);
        vault = new DustVault(IERC20(address(stable)));
        sweeper = new MockSweeper(keeper);
        capture = new DustCapture(
            IERC20(address(stable)),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(address(weth)),
            IV3Pool(address(pool))
        );
        vault.setModules(makeAddr("router"), address(sweeper), address(capture));
        stable.mint(address(pool), 1_000_000 * UNIT);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _floatSum() internal view returns (uint256) {
        return capture.ethBalance(alice) + capture.ethBalance(bob) + capture.ethBalance(mallory);
    }

    // ------------------------------------------------------------------
    // reentrancy through withdrawEth's ETH forward
    // ------------------------------------------------------------------

    function test_reenterWithdrawCannotDoubleSpend() public {
        ReentrantRecipient r = new ReentrantRecipient(capture);
        r.deposit{value: 1 ether}(); // funded by this test contract
        assertEq(capture.ethBalance(address(r)), 1 ether);
        uint256 before = address(r).balance;

        r.setMode(1);
        r.withdraw(1 ether);
        assertEq(r.reentries(), 1, "hook ran");
        assertFalse(r.innerOk(), "second withdrawal of the same balance must fail");
        assertEq(capture.ethBalance(address(r)), 0);
        assertEq(weth.balanceOf(address(capture)), 0, "float fully drained, no phantom WETH");
        assertEq(address(r).balance - before, 1 ether, "got back exactly what was parked, once");
        assertEq(address(capture).balance, 0);
    }

    function test_reenterWithdrawWithSpareBalanceIsJustTwoWithdrawals() public {
        ReentrantRecipient r = new ReentrantRecipient(capture);
        r.deposit{value: 2 ether}();
        uint256 before = address(r).balance;
        r.setMode(1);
        r.withdraw(1 ether); // hook withdraws the other 1 ether
        assertTrue(r.innerOk());
        assertEq(capture.ethBalance(address(r)), 0);
        assertEq(weth.balanceOf(address(capture)), 0);
        assertEq(address(r).balance - before, 2 ether, "exactly the parked total, nothing more");
    }

    function test_reenterDepositDuringWithdrawKeepsBacking() public {
        ReentrantRecipient r = new ReentrantRecipient(capture);
        vm.deal(address(r), 1 ether);
        r.deposit{value: 1 ether}();
        r.setMode(2);
        r.withdraw(1 ether); // hook re-deposits the ETH it just received
        assertTrue(r.innerOk());
        assertEq(capture.ethBalance(address(r)), 1 ether);
        assertEq(weth.balanceOf(address(capture)), 1 ether, "float is backed 1:1 after the re-deposit");
        assertEq(address(capture).balance, 0);
    }

    function test_reenterCallbackDuringWithdrawIsRejected() public {
        ReentrantRecipient r = new ReentrantRecipient(capture);
        vm.deal(address(r), 1 ether);
        r.deposit{value: 1 ether}();
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        r.setMode(3);
        r.withdraw(1 ether);
        assertFalse(r.innerOk(), "callback outside a swap must revert");
        assertEq(capture.ethBalance(alice), 1 ether);
        assertEq(weth.balanceOf(address(capture)), 1 ether);
    }

    function test_gasBurningRecipientOnlyHurtsTheCaller() public {
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        address burner = address(new GasBurner());
        vm.prank(alice);
        (bool ok,) = address(capture).call{gas: 300_000}(abi.encodeCall(capture.withdrawEth, (1 ether, burner)));
        assertFalse(ok);
        assertEq(capture.ethBalance(alice), 1 ether, "state intact after the failed forward");
        assertEq(weth.balanceOf(address(capture)), 1 ether);
    }

    // ------------------------------------------------------------------
    // callback: stale context, spoofing, replay
    // ------------------------------------------------------------------

    function test_callbackAfterCompletedSwapIsStale() public {
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(10 * UNIT));
        capture.depositEth{value: 1 ether}();
        vm.stopPrank();
        vm.prank(keeper);
        capture.captureFromEth(alice, 530_000, type(uint256).max);
        uint256 after_ = capture.ethBalance(alice);

        // the real pool replays the exact deltas it just used: context is gone
        vm.prank(address(pool));
        vm.expectRevert(DustCapture.BadCallback.selector);
        capture.uniswapV3SwapCallback(int256(1), -int256(530_000), "");
        vm.prank(address(pool));
        vm.expectRevert(DustCapture.BadCallback.selector);
        capture.synthraV3SwapCallback(int256(1), -int256(530_000), "");
        assertEq(capture.ethBalance(alice), after_);
    }

    function test_callbackFromLookalikePoolReverts() public {
        // a second pool with the same pair is not the pinned pool
        MockV3Pool other = new MockV3Pool(address(weth), address(stable), TICK);
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        vm.prank(address(other));
        vm.expectRevert(DustCapture.BadCallback.selector);
        capture.uniswapV3SwapCallback(1, -1, "");
    }

    function test_keeperBoundZeroBlocksSwapPaths() public {
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(10 * UNIT));
        capture.depositEth{value: 1 ether}();
        weth.deposit{value: 1 ether}();
        weth.approve(address(capture), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(keeper);
        vm.expectRevert(DustCapture.OverMaxWethIn.selector);
        capture.captureFromWeth(alice, 530_000, 0);
        vm.expectRevert(DustCapture.OverMaxWethIn.selector);
        capture.captureFromEth(alice, 530_000, 0);
        vm.stopPrank();
        (, uint96 used,) = capture.configOf(alice);
        assertEq(used, 0);
    }

    // ------------------------------------------------------------------
    // weekly cap edge cases
    // ------------------------------------------------------------------

    function test_remainingThisWeekAfterLoweringCapBelowUsed() public {
        vm.prank(alice);
        capture.setWeeklyCap(uint96(10 * UNIT));
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        vm.prank(keeper);
        capture.captureFromEth(alice, 5 * UNIT, type(uint256).max);

        // user tightens the cap below what was already used this week
        vm.prank(alice);
        capture.setWeeklyCap(uint96(2 * UNIT));
        assertEq(capture.remainingThisWeek(alice), 0, "must report 0, not revert");
        vm.prank(keeper);
        vm.expectRevert(DustCapture.OverWeeklyCap.selector);
        capture.captureFromEth(alice, 1, type(uint256).max);

        // next window: the new, lower cap applies
        vm.warp(block.timestamp + 7 days);
        assertEq(capture.remainingThisWeek(alice), 2 * UNIT);
    }

    function test_windowRollBoundaryIsExactlyOneWeek() public {
        vm.prank(alice);
        capture.setWeeklyCap(uint96(1 * UNIT));
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        (,, uint64 start) = capture.configOf(alice);
        vm.prank(keeper);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);

        vm.warp(uint256(start) + 7 days - 1);
        assertEq(capture.remainingThisWeek(alice), 0);
        vm.prank(keeper);
        vm.expectRevert(DustCapture.OverWeeklyCap.selector);
        capture.captureFromEth(alice, 1, type(uint256).max);

        vm.warp(uint256(start) + 7 days);
        assertEq(capture.remainingThisWeek(alice), 1 * UNIT);
        vm.prank(keeper);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        (,, uint64 newStart) = capture.configOf(alice);
        assertEq(newStart, start + 7 days);
    }

    function test_raisingCapMidWeekDoesNotResetUsage() public {
        vm.prank(alice);
        capture.setWeeklyCap(uint96(1 * UNIT));
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        vm.prank(keeper);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        vm.prank(alice);
        capture.setWeeklyCap(uint96(3 * UNIT));
        assertEq(capture.remainingThisWeek(alice), 2 * UNIT);
    }

    // ------------------------------------------------------------------
    // ETH float backing invariant under random op sequences
    // ------------------------------------------------------------------

    function testFuzz_floatAlwaysBackedByWeth(uint256 seed) public {
        address[2] memory users = [alice, bob];
        for (uint256 i; i < 2; i++) {
            vm.prank(users[i]);
            capture.setWeeklyCap(uint96(1_000 * UNIT));
        }
        for (uint256 step; step < 24; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address u = users[r % 2];
            uint256 op = (r >> 8) % 4;
            uint256 amt = ((r >> 16) % 1e18) + 1;
            if (op == 0) {
                vm.prank(u);
                capture.depositEth{value: amt}();
            } else if (op == 1) {
                uint256 bal = capture.ethBalance(u);
                if (bal == 0) continue;
                vm.prank(u);
                capture.withdrawEth((amt % bal) + 1, u);
            } else if (op == 2) {
                uint256 out = ((r >> 96) % (2 * UNIT)) + 1;
                vm.prank(keeper);
                (bool ok,) = address(capture).call(abi.encodeCall(capture.captureFromEth, (u, out, type(uint256).max)));
                ok; // may legitimately fail on an empty float; the invariant must hold either way
            } else {
                pool.setMeanTick(TICK + int24(int256((r >> 128) % 2000)) - 1000);
            }
            assertEq(_floatSum(), weth.balanceOf(address(capture)), "float must equal WETH held");
            assertEq(address(capture).balance, 0, "no loose ETH");
        }
    }

    // ------------------------------------------------------------------
    // withdrawEth recipient footguns
    // ------------------------------------------------------------------

    function test_withdrawToWethAddressIsRefused() public {
        vm.prank(alice);
        capture.depositEth{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert(DustCapture.BadRecipient.selector);
        capture.withdrawEth(1 ether, address(weth));
        vm.prank(alice);
        vm.expectRevert(DustCapture.BadRecipient.selector);
        capture.withdrawEth(1 ether, address(capture));
        assertEq(capture.ethBalance(alice), 1 ether);
    }

    // ------------------------------------------------------------------
    // TWAP mean-tick rounding: floor toward negative infinity
    // ------------------------------------------------------------------

    function _ref(int24 tick, uint256 amountOut, bool wethIsToken0) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(tick);
        uint256 wethIn;
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP;
            wethIn = wethIsToken0
                ? FullMath.mulDivRoundingUp(amountOut, 1 << 192, ratioX192)
                : FullMath.mulDivRoundingUp(amountOut, ratioX192, 1 << 192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
            wethIn = wethIsToken0
                ? FullMath.mulDivRoundingUp(amountOut, 1 << 128, ratioX128)
                : FullMath.mulDivRoundingUp(amountOut, ratioX128, 1 << 128);
        }
        return FullMath.mulDivRoundingUp(wethIn, 10_200, 10_000);
    }

    function _oracleCapture(bool wethFirst) internal returns (DustCapture c, ObservePool op) {
        op = wethFirst ? new ObservePool(address(weth), address(stable)) : new ObservePool(address(stable), address(weth));
        c = new DustCapture(
            IERC20(address(stable)),
            IDustVault(address(vault)),
            IKeeperSource(address(sweeper)),
            IWETH(address(weth)),
            IV3Pool(address(op))
        );
    }

    function test_meanTickFloorsNegativeNonDivisibleDelta() public {
        (DustCapture c, ObservePool op) = _oracleCapture(true);
        int56 base = int56(TICK) * 600;

        op.set(0, base); // exact
        assertEq(c.maxWethInFor(UNIT), _ref(TICK, UNIT, true));

        op.set(0, base - 1); // -198080.0017 -> floor -198081 (truncation would say -198080)
        assertEq(c.maxWethInFor(UNIT), _ref(TICK - 1, UNIT, true), "floor, not truncation");

        op.set(0, base + 1); // -198079.998 -> floor -198080 (truncation would say -198079)
        assertEq(c.maxWethInFor(UNIT), _ref(TICK, UNIT, true), "floor, not truncation");

        op.set(0, base + 599); // still floors to TICK
        assertEq(c.maxWethInFor(UNIT), _ref(TICK, UNIT, true));
        op.set(0, base + 600);
        assertEq(c.maxWethInFor(UNIT), _ref(TICK + 1, UNIT, true));

        // cumulative offsets do not matter, only the delta
        op.set(type(int56).max - 1000, type(int56).max - 1000 + base - 1);
        assertEq(c.maxWethInFor(UNIT), _ref(TICK - 1, UNIT, true));
    }

    function test_meanTickPositiveDeltaTruncatesToFloor() public {
        (DustCapture c, ObservePool op) = _oracleCapture(false); // stable = token0, positive ticks
        int56 base = int56(-TICK) * 600;
        op.set(0, base + 1);
        assertEq(c.maxWethInFor(UNIT), _ref(-TICK, UNIT, false));
        op.set(0, base + 599);
        assertEq(c.maxWethInFor(UNIT), _ref(-TICK, UNIT, false));
        op.set(0, base - 1);
        assertEq(c.maxWethInFor(UNIT), _ref(-TICK - 1, UNIT, false));
    }

    function testFuzz_meanTickMatchesOracleLibraryFloor(int256 tickSeed, uint16 frac, uint96 amountOut) public {
        int24 tick = int24(bound(tickSeed, -400_000, 400_000));
        frac = uint16(bound(frac, 0, 599));
        amountOut = uint96(bound(amountOut, 1, 1_000_000 * UNIT));
        (DustCapture c, ObservePool op) = _oracleCapture(true);
        // delta = tick*600 + frac, so floor(delta/600) == tick for every frac in [0,599]
        op.set(int56(12345), int56(12345) + int56(tick) * 600 + int56(uint56(frac)));
        assertEq(c.maxWethInFor(amountOut), _ref(tick, amountOut, true));
    }

    function test_meanTickBothOrderingsAgreeOnPrice() public {
        // same economic price expressed in both orderings must give the same WETH bound
        (DustCapture a, ObservePool oa) = _oracleCapture(true);
        (DustCapture b, ObservePool ob) = _oracleCapture(false);
        oa.set(0, int56(TICK) * 600);
        ob.set(0, int56(-TICK) * 600);
        assertApproxEqRel(a.maxWethInFor(UNIT), b.maxWethInFor(UNIT), 1e9);
        // 6-dec stable vs 18-dec WETH at ~2500: about 4.08e14 wei per stable unit incl. 2%
        assertApproxEqRel(a.maxWethInFor(UNIT), 408e12, 0.01e18);
    }

    function test_maxWethInForExtremeTicksFailClosedOrStayBounded() public {
        (DustCapture c, ObservePool op) = _oracleCapture(true);
        // TWAP at MIN_TICK: WETH nearly worthless in stable terms -> astronomically large bound
        op.set(0, int56(TickMath.MIN_TICK) * 600);
        (bool ok,) = address(c).staticcall(abi.encodeCall(c.maxWethInFor, (UNIT)));
        // either reverts (overflow, fail closed) or returns; neither may wrap silently
        if (ok) assertGt(c.maxWethInFor(UNIT), 1e30);
        // TWAP at MAX_TICK: WETH astronomically expensive -> tiny bound; two
        // round-ups (the quote, then the +2%) give at most 2 wei, never 0
        op.set(0, int56(TickMath.MAX_TICK) * 600);
        uint256 tiny = c.maxWethInFor(UNIT);
        assertGe(tiny, 1);
        assertLe(tiny, 2);
    }

    // ------------------------------------------------------------------
    // no admin surface: a compromised keeper still cannot move funds anywhere
    // but the user's own vault position
    // ------------------------------------------------------------------

    function test_keeperCannotRedirectProceedsOrPayFromOthers() public {
        vm.startPrank(alice);
        capture.setWeeklyCap(uint96(10 * UNIT));
        capture.depositEth{value: 1 ether}();
        vm.stopPrank();
        vm.prank(bob);
        capture.depositEth{value: 1 ether}();

        // keeper captures for bob (cap 0): cannot use alice's float either
        vm.prank(keeper);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFromEth(bob, 1 * UNIT, type(uint256).max);

        // capture for alice: only alice's float moves, only alice is credited
        vm.prank(keeper);
        capture.captureFromEth(alice, 1 * UNIT, type(uint256).max);
        assertEq(capture.ethBalance(bob), 1 ether);
        assertLt(capture.ethBalance(alice), 1 ether);
        assertEq(vault.accruedStable(alice), 1 * UNIT);
        assertEq(vault.accruedStable(bob), 0);
        assertEq(stable.balanceOf(address(vault)), 1 * UNIT);
        assertEq(stable.balanceOf(keeper), 0);
        assertEq(weth.balanceOf(keeper), 0);
    }
}
