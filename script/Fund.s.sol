// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20, IV3Pool} from "../src/interfaces/IDust.sol";
import {ComposabilityProbe} from "../src/ComposabilityProbe.sol";

/// Liquidate the dev wallet's faucet stock tokens to USDC, then send USDC + gas
/// ETH to a test wallet so it can run the app end to end.
contract Fund is Script {
    address constant USDC = 0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F;
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant P_TSLA = 0xFfEf1147c3724a19AB7328F4e361C049ba452dA9;
    address constant P_AMZN = 0x0A837200fB77687ba9b749E5174bd9a09E51286A;
    address constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant P_AMD = 0xae12d50f75ea3f4Cf983Af1272614754e7F5e813;
    ComposabilityProbe constant probe = ComposabilityProbe(0xC6D1b72036195d943d6f14dFbF1fb9Dc3A7a2Ca8);

    address constant DEST = 0x099950d73746429fC855cFCFe5e33B514d46dcc6;

    function run() external {
        vm.startBroadcast();
        address me = msg.sender;

        address[3] memory toks = [TSLA, AMZN, AMD];
        address[3] memory pools = [P_TSLA, P_AMZN, P_AMD];
        for (uint256 i; i < 3; i++) {
            uint256 bal = IERC20(toks[i]).balanceOf(me);
            if (bal == 0) continue;
            IERC20(toks[i]).transfer(address(probe), bal);
            probe.swapExactIn(pools[i], IV3Pool(pools[i]).token0() == toks[i], bal);
        }
        probe.push(USDC, me, IERC20(USDC).balanceOf(address(probe)));
        uint256 usdc = IERC20(USDC).balanceOf(me);
        console2.log("dev USDC after liquidation:", usdc);

        // send most of the USDC, keep a little dust for the dev wallet
        uint256 sendUsdc = usdc > 0.05e18 ? usdc - 0.05e18 : usdc;
        IERC20(USDC).transfer(DEST, sendUsdc);
        console2.log("sent USDC:", sendUsdc);


        vm.stopBroadcast();
    }
}
