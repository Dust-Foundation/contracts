// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IDustVault} from "../src/interfaces/IDust.sol";

/// Deploy-only: the hardened trio + wiring, no demo flow. Prints addresses for
/// the web app to consume.
/// Run:
///   forge script script/Deploy.s.sol --rpc-url robinhood_testnet \
///     --keystores .secrets/<file> --broadcast -vv
contract Deploy is Script {
    address constant USDC = 0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F;
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;
    address constant NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address constant AMD  = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant P_TSLA = 0xFfEf1147c3724a19AB7328F4e361C049ba452dA9;
    address constant P_AMZN = 0x0A837200fB77687ba9b749E5174bd9a09E51286A;
    address constant P_PLTR = 0x82A81E9EdB32958104A2c9514b8Fc85F972b53Af;
    address constant P_NFLX = 0xcD8a64d13D5B99Dc546a3D6FFD8e5C7dD0Ecb1a0;
    address constant P_AMD  = 0xae12d50f75ea3f4Cf983Af1272614754e7F5e813;

    function run() external {
        vm.startBroadcast();
        DustVault vault = new DustVault(IERC20(USDC));
        DustRouter router = new DustRouter(IERC20(USDC), IDustVault(address(vault)), 1e18);
        // treasury = deployer for testnet; on mainnet this is the fee multisig
        DustSweeper sweeper = new DustSweeper(IERC20(USDC), IDustVault(address(vault)), msg.sender);
        // curate the menu of buyable stocks; users compose their own baskets from it
        sweeper.listStock(TSLA, P_TSLA);
        sweeper.listStock(AMZN, P_AMZN);
        sweeper.listStock(PLTR, P_PLTR);
        sweeper.listStock(NFLX, P_NFLX);
        sweeper.listStock(AMD, P_AMD);
        DustCapture capture =
            new DustCapture(IERC20(USDC), IDustVault(address(vault)), IKeeperSource(address(sweeper)));
        vault.setModules(address(router), address(sweeper), address(capture));

        console2.log("DUST_VAULT=%s", address(vault));
        console2.log("DUST_ROUTER=%s", address(router));
        console2.log("DUST_SWEEPER=%s", address(sweeper));
        console2.log("DUST_CAPTURE=%s", address(capture));
        vm.stopBroadcast();
    }
}
