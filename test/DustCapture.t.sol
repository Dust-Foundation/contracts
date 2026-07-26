// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IDustVault} from "../src/interfaces/IDust.sol";

contract MockStable {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        require(balanceOf[f] >= amt, "bal");
        uint256 a = allowance[f][msg.sender]; require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt; balanceOf[t] += amt; return true;
    }
}

contract MockSweeper {
    address public keeper;
    constructor(address k) { keeper = k; }
    function setKeeper(address k) external { keeper = k; }
}

contract DustCaptureTest is Test {
    MockStable stable;
    DustVault vault;
    MockSweeper sweeper;
    DustCapture capture;

    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address mallory = makeAddr("mallory");

    function setUp() public {
        stable = new MockStable();
        vault = new DustVault(IERC20(address(stable)));
        sweeper = new MockSweeper(keeper);
        capture = new DustCapture(IERC20(address(stable)), IDustVault(address(vault)), IKeeperSource(address(sweeper)));
        // router slot is a dummy here; capture is the module under test
        vault.setModules(makeAddr("router"), address(sweeper), address(capture));

        stable.mint(alice, 100e18);
        vm.prank(alice);
        stable.approve(address(capture), 50e18); // wallet-side cap
    }

    function test_optInAndCapture() public {
        vm.prank(alice);
        capture.setWeeklyCap(10e18);

        vm.prank(keeper);
        capture.captureFor(alice, 0.6e18);

        assertEq(vault.accruedStable(alice), 0.6e18);
        assertEq(stable.balanceOf(address(vault)), 0.6e18);
        assertEq(capture.remainingThisWeek(alice), 9.4e18);
    }

    function test_onlyKeeper() public {
        vm.prank(alice);
        capture.setWeeklyCap(10e18);
        vm.prank(mallory);
        vm.expectRevert(DustCapture.NotKeeper.selector);
        capture.captureFor(alice, 1e18);
    }

    function test_notOptedInReverts() public {
        vm.prank(keeper);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFor(alice, 1e18);
    }

    function test_weeklyCapEnforced() public {
        vm.prank(alice);
        capture.setWeeklyCap(1e18);

        vm.prank(keeper);
        capture.captureFor(alice, 0.7e18);

        vm.prank(keeper);
        vm.expectRevert(DustCapture.OverWeeklyCap.selector);
        capture.captureFor(alice, 0.4e18); // 0.7 + 0.4 > 1.0

        // window rolls over after a week
        vm.warp(block.timestamp + 7 days);
        assertEq(capture.remainingThisWeek(alice), 1e18);
        vm.prank(keeper);
        capture.captureFor(alice, 0.4e18);
        assertEq(vault.accruedStable(alice), 1.1e18);
    }

    function test_optOutStopsCapture() public {
        vm.prank(alice);
        capture.setWeeklyCap(10e18);
        vm.prank(keeper);
        capture.captureFor(alice, 1e18);

        vm.prank(alice);
        capture.setWeeklyCap(0); // full opt-out

        vm.prank(keeper);
        vm.expectRevert(DustCapture.NotOptedIn.selector);
        capture.captureFor(alice, 1e18);
    }

    function test_walletAllowanceIsSecondCap() public {
        vm.prank(alice);
        capture.setWeeklyCap(100e18); // contract cap generous
        vm.prank(alice);
        stable.approve(address(capture), 0.5e18); // wallet cap tight

        vm.prank(keeper);
        vm.expectRevert(bytes("allow"));
        capture.captureFor(alice, 1e18); // blocked by the wallet allowance
    }

    function test_capturedFundsOnlyReachOwnVaultPosition() public {
        vm.prank(alice);
        capture.setWeeklyCap(10e18);
        vm.prank(keeper);
        capture.captureFor(alice, 2e18);
        // credited to alice, withdrawable by alice only
        assertEq(vault.accruedStable(alice), 2e18);
        vm.prank(alice);
        vault.withdrawAccrued(2e18, alice);
        assertEq(stable.balanceOf(alice), 100e18); // net zero: pulled 2, got 2 back
    }

    function test_keeperRotationViaSweeper() public {
        vm.prank(alice);
        capture.setWeeklyCap(10e18);
        address newKeeper = makeAddr("newKeeper");
        sweeper.setKeeper(newKeeper);

        vm.prank(keeper);
        vm.expectRevert(DustCapture.NotKeeper.selector);
        capture.captureFor(alice, 1e18);

        vm.prank(newKeeper);
        capture.captureFor(alice, 1e18);
        assertEq(vault.accruedStable(alice), 1e18);
    }
}
