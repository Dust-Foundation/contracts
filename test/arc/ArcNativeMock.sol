// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Vm.sol";

/// Test-only stand-in for Arc's native-balance system contract at
/// 0x1800...0000. On Arc, the USDC ERC-20 (0x3600...0000) delegates transfers
/// to this address, which moves the *native* USDC balance (18 decimals) with
/// an opcode Foundry does not know. In a fork we etch this contract there and
/// move native balances with cheatcodes, so the real USDC contract, the real
/// pools and the real factory all keep working.
contract ArcNativeMock {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function transfer(address from, address to, uint256 amount) external returns (bool) {
        require(from.balance >= amount, "ArcNativeMock: insufficient");
        vm.deal(from, from.balance - amount);
        vm.deal(to, to.balance + amount);
        return true;
    }
}

/// Stand-in for Arc's protocol blocklist at 0x1800...0001: nobody is blocked.
contract ArcBlocklistMock {
    function isBlocklisted(address) external pure returns (bool) {
        return false;
    }
}
