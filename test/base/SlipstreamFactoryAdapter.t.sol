// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {SlipstreamFactoryAdapter} from "../../src/SlipstreamFactoryAdapter.sol";

contract MockCLPool {
    uint24 public fee;
    constructor(uint24 f) { fee = f; }
    function setFee(uint24 f) external { fee = f; }
}

contract MockCLFactory {
    mapping(bytes32 => address) pools;
    function set(address a, address b, int24 ts, address pool) external {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pools[keccak256(abi.encode(t0, t1, ts))] = pool;
    }
    function getPool(address a, address b, int24 ts) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return pools[keccak256(abi.encode(t0, t1, ts))];
    }
}

contract SlipstreamFactoryAdapterTest is Test {
    MockCLFactory fNew = new MockCLFactory();
    MockCLFactory fOld = new MockCLFactory();
    address usdc = address(0xA);
    address nvda = address(0xB);
    address aero = address(0xC);

    function _adapter() internal returns (SlipstreamFactoryAdapter) {
        address[] memory fs = new address[](4);
        int24[] memory ts = new int24[](4);
        fs[0] = address(fNew); ts[0] = 100;
        fs[1] = address(fNew); ts[1] = 200;
        fs[2] = address(fOld); ts[2] = 100;
        fs[3] = address(fOld); ts[3] = 200;
        return new SlipstreamFactoryAdapter(fs, ts);
    }

    function test_resolvesByLiveFeeAndIsSymmetric() public {
        MockCLPool p = new MockCLPool(500);
        fNew.set(usdc, nvda, 100, address(p));
        SlipstreamFactoryAdapter a = _adapter();
        assertEq(a.getPool(usdc, nvda, 500), address(p));
        assertEq(a.getPool(nvda, usdc, 500), address(p), "symmetric");
        assertEq(a.getPool(usdc, nvda, 3000), address(0), "wrong fee -> none");
        assertEq(a.getPool(usdc, aero, 500), address(0), "unknown pair -> none");
    }

    function test_dynamicFeeIsReadLive() public {
        MockCLPool p = new MockCLPool(500);
        fNew.set(usdc, nvda, 100, address(p));
        SlipstreamFactoryAdapter a = _adapter();
        assertEq(a.getPool(usdc, nvda, 500), address(p));
        p.setFee(400); // the fee module moved the pool's fee
        assertEq(a.getPool(usdc, nvda, 500), address(0), "old fee no longer resolves");
        assertEq(a.getPool(usdc, nvda, 400), address(p), "new fee does");
    }

    function test_slotOrderBreaksTies() public {
        MockCLPool deep = new MockCLPool(500);
        MockCLPool thin = new MockCLPool(500); // same fee, different tick spacing
        fNew.set(usdc, nvda, 100, address(deep));
        fNew.set(usdc, nvda, 200, address(thin));
        SlipstreamFactoryAdapter a = _adapter();
        assertEq(a.getPool(usdc, nvda, 500), address(deep), "first slot wins");
    }

    function test_legacyFactoryConsultedAfterCurrent() public {
        MockCLPool old = new MockCLPool(500);
        fOld.set(usdc, aero, 100, address(old));
        SlipstreamFactoryAdapter a = _adapter();
        assertEq(a.getPool(usdc, aero, 500), address(old));
    }

    function test_constructorGuards() public {
        address[] memory fs = new address[](1);
        int24[] memory ts = new int24[](2);
        vm.expectRevert(SlipstreamFactoryAdapter.LengthMismatch.selector);
        new SlipstreamFactoryAdapter(fs, ts);
        vm.expectRevert(SlipstreamFactoryAdapter.Empty.selector);
        new SlipstreamFactoryAdapter(new address[](0), new int24[](0));
        int24[] memory ts1 = new int24[](1);
        vm.expectRevert(SlipstreamFactoryAdapter.ZeroAddress.selector);
        new SlipstreamFactoryAdapter(fs, ts1);
    }

    /// A non-canonical pool that merely claims a fee is never returned: the
    /// adapter only ever hands back what an allowlisted factory resolves.
    function test_lookalikePoolNeverResolves() public {
        MockCLPool fake = new MockCLPool(500);
        SlipstreamFactoryAdapter a = _adapter();
        assertEq(a.getPool(usdc, nvda, 500), address(0));
        assertTrue(address(fake) != a.getPool(usdc, nvda, 500));
    }
}
