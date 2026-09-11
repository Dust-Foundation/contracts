// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {ComposabilityProbe, IERC20, IUniswapV3Pool} from "../src/ComposabilityProbe.sol";

/// Fork tests against the live Robinhood Chain testnet (46630).
/// Run: forge test --match-contract ComposabilityProbeForkTest -vv
/// The suite forks the `robinhood_testnet` endpoint from foundry.toml itself.
/// If the RPC is unreachable or the testnet contracts are gone, it is skipped
/// with a reason rather than failed, so the default `forge test` stays green.
/// These exercise the REAL deployed Stock Token + pool bytecode, so a pass here
/// is strong evidence of composability; the same script re-runs live after funding.
contract ComposabilityProbeForkTest is Test {
    // Robinhood Chain testnet (46630) addresses, discovered onchain 2026-07-22
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant USDC = 0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F; // 18-dec testnet USDC
    address constant WETH = 0x33e4191705c386532ba27cBF171Db86919200B94;
    address constant POOL_TSLA_USDC_3000 = 0xFfEf1147c3724a19AB7328F4e361C049ba452dA9;
    address constant POOL_TSLA_WETH_3000 = 0x593e2e0EF3869616Ec3Fbe989dCFf2699D52b69B;

    ComposabilityProbe probe;
    address user = makeAddr("user");

    function setUp() public {
        // fork live testnet; skip cleanly if the RPC is down or the state is gone
        try vm.createSelectFork(vm.rpcUrl("robinhood_testnet")) returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        if (block.chainid != 46630 || TSLA.code.length == 0 || POOL_TSLA_USDC_3000.code.length == 0) {
            vm.skip(true);
            return;
        }
        probe = new ComposabilityProbe();
    }

    /// Can the probe contract simply hold Stock Tokens sent to it?
    function test_receiveAndHoldStockToken() public {
        deal(TSLA, address(this), 1e18);
        assertTrue(IERC20(TSLA).transfer(address(probe), 1e18), "transfer in failed");
        assertEq(IERC20(TSLA).balanceOf(address(probe)), 1e18, "probe does not hold TSLA");
    }

    /// The sweeper motion: approve + transferFrom into the contract, then send onward.
    function test_pullAndPushStockToken() public {
        deal(TSLA, address(this), 2e18);
        IERC20(TSLA).approve(address(probe), 2e18);
        probe.pull(TSLA, 2e18);
        assertEq(IERC20(TSLA).balanceOf(address(probe)), 2e18);

        probe.push(TSLA, user, 1e18);
        assertEq(IERC20(TSLA).balanceOf(user), 1e18, "arbitrary recipient did not receive");
        assertEq(IERC20(TSLA).balanceOf(address(probe)), 1e18);
    }

    /// Buy TSLA with USDC directly on the pool, contract as counterparty and recipient.
    function test_swapUsdcForTslaOnPool() public {
        deal(USDC, address(probe), 1000e18);
        bool zeroForOne = IUniswapV3Pool(POOL_TSLA_USDC_3000).token0() == USDC;

        uint256 tslaBefore = IERC20(TSLA).balanceOf(address(probe));
        probe.swapExactIn(POOL_TSLA_USDC_3000, zeroForOne, 1000e18);
        uint256 tslaAfter = IERC20(TSLA).balanceOf(address(probe));

        console2.log("TSLA received for 1000 USDC:", tslaAfter - tslaBefore);
        assertGt(tslaAfter, tslaBefore, "swap yielded no TSLA");
    }

    /// Same, via the WETH pool (the path faucet-funded wallets will use live).
    function test_swapWethForTslaOnPool() public {
        deal(WETH, address(probe), 0.005e18);
        bool zeroForOne = IUniswapV3Pool(POOL_TSLA_WETH_3000).token0() == WETH;

        uint256 tslaBefore = IERC20(TSLA).balanceOf(address(probe));
        probe.swapExactIn(POOL_TSLA_WETH_3000, zeroForOne, 0.005e18);
        uint256 tslaAfter = IERC20(TSLA).balanceOf(address(probe));

        console2.log("TSLA received for 0.005 WETH:", tslaAfter - tslaBefore);
        assertGt(tslaAfter, tslaBefore, "swap yielded no TSLA");
    }

    /// Round trip: buy TSLA then sell it back. Proves both directions clear.
    function test_swapRoundTrip() public {
        deal(USDC, address(probe), 500e18);
        bool usdcIsToken0 = IUniswapV3Pool(POOL_TSLA_USDC_3000).token0() == USDC;

        probe.swapExactIn(POOL_TSLA_USDC_3000, usdcIsToken0, 500e18);
        uint256 tsla = IERC20(TSLA).balanceOf(address(probe));
        assertGt(tsla, 0);

        probe.swapExactIn(POOL_TSLA_USDC_3000, !usdcIsToken0, tsla);
        assertEq(IERC20(TSLA).balanceOf(address(probe)), 0);
        assertGt(IERC20(USDC).balanceOf(address(probe)), 0, "no USDC back");
    }
}
