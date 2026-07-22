// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ComposabilityProbe, IERC20, IUniswapV3Pool} from "../src/ComposabilityProbe.sol";

/// Live M0 probe on Robinhood Chain testnet. Requires a faucet-funded wallet
/// (0.01 ETH + 5 of each Stock Token).
///
/// Run:
///   forge script script/ProbeLive.s.sol --rpc-url $RPC_TESTNET \
///     --keystores .secrets/<file> --broadcast -vv
contract ProbeLive is Script {
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant WETH = 0x33e4191705c386532ba27cBF171Db86919200B94;
    address constant POOL_TSLA_WETH_3000 = 0x593e2e0EF3869616Ec3Fbe989dCFf2699D52b69B;

    function run() external {
        vm.startBroadcast();
        address me = msg.sender;

        // 1. Deploy: proves permissionless deployment on the live chain.
        ComposabilityProbe probe = new ComposabilityProbe();
        console2.log("probe deployed:", address(probe));

        // 2. Hold: send 1 TSLA into the probe contract.
        IERC20(TSLA).transfer(address(probe), 1e18);
        console2.log("probe TSLA after transfer in:", IERC20(TSLA).balanceOf(address(probe)));

        // 3. Pull: approve + transferFrom (the sweeper motion).
        IERC20(TSLA).approve(address(probe), 1e18);
        probe.pull(TSLA, 1e18);
        console2.log("probe TSLA after pull:", IERC20(TSLA).balanceOf(address(probe)));

        // 4. Push one back out to the EOA.
        probe.push(TSLA, me, 1e18);

        // 5. Swap: wrap a sliver of ETH, give it to the probe, buy TSLA on the pool.
        (bool ok,) = WETH.call{value: 0.002 ether}("");
        require(ok, "wrap failed");
        IERC20(WETH).transfer(address(probe), 0.002 ether);
        bool zeroForOne = IUniswapV3Pool(POOL_TSLA_WETH_3000).token0() == WETH;
        probe.swapExactIn(POOL_TSLA_WETH_3000, zeroForOne, 0.002 ether);
        console2.log("probe TSLA after live swap:", IERC20(TSLA).balanceOf(address(probe)));

        // 6. Sweep everything home.
        probe.push(TSLA, me, IERC20(TSLA).balanceOf(address(probe)));
        console2.log("final EOA TSLA:", IERC20(TSLA).balanceOf(me));

        vm.stopBroadcast();
    }
}
