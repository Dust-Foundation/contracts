// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {IERC20, IV3Pool, IDustVault} from "../src/interfaces/IDust.sol";
import {ComposabilityProbe} from "../src/ComposabilityProbe.sol";

/// M1 live gate: deploy the trio to Robinhood Chain testnet and run the whole
/// product flow with real transactions. Testnet stock prices are tiny (~0.08
/// USDC), so the demo amounts are scaled down; the mechanics are identical.
/// Run:
///   forge script script/DeployAndFlowLive.s.sol --rpc-url robinhood_testnet \
///     --keystores .secrets/<file> --broadcast -vv
contract DeployAndFlowLive is Script {
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

    ComposabilityProbe constant probe = ComposabilityProbe(0xC6D1b72036195d943d6f14dFbF1fb9Dc3A7a2Ca8);

    function run() external {
        vm.startBroadcast();
        address me = msg.sender;

        // 0. fund: liquidate faucet stock tokens into USDC via the M0 probe
        address[5] memory toks = [TSLA, AMZN, PLTR, NFLX, AMD];
        address[5] memory pools = [P_TSLA, P_AMZN, P_PLTR, P_NFLX, P_AMD];
        for (uint256 i; i < 5; i++) {
            uint256 bal = IERC20(toks[i]).balanceOf(me);
            if (bal == 0) continue;
            IERC20(toks[i]).transfer(address(probe), bal);
            bool stockIsToken0 = IV3Pool(pools[i]).token0() == toks[i];
            probe.swapExactIn(pools[i], stockIsToken0, bal);
        }
        probe.push(USDC, me, IERC20(USDC).balanceOf(address(probe)));
        uint256 usdcBal = IERC20(USDC).balanceOf(me);
        console2.log("USDC funded:", usdcBal);
        require(usdcBal >= 1.05e18, "not enough USDC for the flow");

        // 1. deploy + wire
        DustVault vault = new DustVault(IERC20(USDC));
        DustRouter router = new DustRouter(IERC20(USDC), IDustVault(address(vault)), 1e18);
        DustSweeper.BasketLeg[] memory legs = new DustSweeper.BasketLeg[](5);
        legs[0] = DustSweeper.BasketLeg(TSLA, P_TSLA, 2_000);
        legs[1] = DustSweeper.BasketLeg(AMZN, P_AMZN, 2_000);
        legs[2] = DustSweeper.BasketLeg(PLTR, P_PLTR, 2_000);
        legs[3] = DustSweeper.BasketLeg(NFLX, P_NFLX, 2_000);
        legs[4] = DustSweeper.BasketLeg(AMD, P_AMD, 2_000);
        DustSweeper sweeper = new DustSweeper(IERC20(USDC), IDustVault(address(vault)), 1 days, legs);
        vault.setModules(address(router), address(sweeper));
        console2.log("vault:  ", address(vault));
        console2.log("router: ", address(router));
        console2.log("sweeper:", address(sweeper));

        // 2. the product flow: swap 0.42 USDC, nearest-1 round-up -> 0.58 banked
        IERC20(USDC).approve(address(router), type(uint256).max);
        (uint256 tslaOut, uint256 roundUp) =
            router.swapWithRoundUp(P_TSLA, TSLA, 0.42e18, 1, 1, 1);
        console2.log("swap got TSLA:", tslaOut);
        console2.log("round-up banked:", roundUp);

        // 3. sweep the change into the 5-stock basket (nonzero slippage floors)
        uint256[] memory minOuts = new uint256[](5);
        for (uint256 j; j < 5; j++) minOuts[j] = 1;
        sweeper.sweep(me, minOuts, 0);
        console2.log("--- vault position after sweep ---");
        console2.log("TSLA:", vault.tokenBalanceOf(me, TSLA));
        console2.log("AMZN:", vault.tokenBalanceOf(me, AMZN));
        console2.log("PLTR:", vault.tokenBalanceOf(me, PLTR));
        console2.log("NFLX:", vault.tokenBalanceOf(me, NFLX));
        console2.log("AMD: ", vault.tokenBalanceOf(me, AMD));
        console2.log("cost basis:", vault.costBasis(me));

        // 4. withdraw one leg in kind to prove the exit
        uint256 amzn = vault.tokenBalanceOf(me, AMZN);
        vault.withdrawToken(AMZN, amzn, me);
        console2.log("AMZN withdrawn in kind:", amzn);

        vm.stopBroadcast();
    }
}
