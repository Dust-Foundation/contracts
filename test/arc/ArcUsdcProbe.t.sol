// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ArcNativeMock, ArcBlocklistMock} from "./ArcNativeMock.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// Does Arc's native-USDC contract behave in a Foundry fork? (USDC on Arc is
/// the gas token: the ERC-20 at 0x36..00 is a view of the native balance.)
contract ArcUsdcProbe is Test {
    IERC20 constant USDC = IERC20(0x3600000000000000000000000000000000000000);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC", string("https://arc.drpc.org")));
        vm.etch(0x1800000000000000000000000000000000000000, address(new ArcNativeMock()).code);
        vm.allowCheatcodes(0x1800000000000000000000000000000000000000);
        vm.etch(0x1800000000000000000000000000000000000001, address(new ArcBlocklistMock()).code);
    }

    function test_dealShowsAsErc20() public {
        vm.deal(alice, 100 ether);
        assertEq(USDC.decimals(), 6);
        assertEq(USDC.balanceOf(alice), 100e6, "erc20 view of native balance");
    }

    function test_transferMovesNative() public {
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        bool ok = USDC.transfer(bob, 25e6);
        assertTrue(ok);
        assertEq(USDC.balanceOf(bob), 25e6);
        assertEq(bob.balance, 25 ether, "native moved");
        assertEq(USDC.balanceOf(alice), 75e6);
    }

    function test_transferFromViaAllowance() public {
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        USDC.approve(carol, 10e6);
        vm.prank(carol);
        USDC.transferFrom(alice, bob, 7e6);
        assertEq(USDC.balanceOf(bob), 7e6);
        assertEq(USDC.balanceOf(alice), 93e6);
    }
}
