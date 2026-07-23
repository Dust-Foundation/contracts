// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustVault} from "../src/DustVault.sol";
import {IERC20, IV3Pool} from "../src/interfaces/IDust.sol";
import {ComposabilityProbe} from "../src/ComposabilityProbe.sol";

/// Live smoke test of the FINAL deployed contracts: set a custom basket, swap
/// with round-up, sweep, check the vault + fee — all real transactions.
contract LiveFlow is Script {
    address constant USDC = 0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F;
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMD  = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant P_TSLA = 0xFfEf1147c3724a19AB7328F4e361C049ba452dA9;
    address constant P_AMD  = 0xae12d50f75ea3f4Cf983Af1272614754e7F5e813;
    ComposabilityProbe constant probe = ComposabilityProbe(0xC6D1b72036195d943d6f14dFbF1fb9Dc3A7a2Ca8);

    DustVault constant vault = DustVault(0xbDf19832A7e76205CaAeB321d190CB80e85f71f2);
    DustRouter constant router = DustRouter(0x5b75b386A86c47861cd174E0967242b7236682f9);
    DustSweeper constant sweeper = DustSweeper(0x7F15B5af91626e295EBFdD6d6BAb0aE281851935);

    function run() external {
        vm.startBroadcast();
        address me = msg.sender;

        // fund with USDC by liquidating any faucet stock tokens via the probe
        address[2] memory toks = [TSLA, AMD];
        address[2] memory pools = [P_TSLA, P_AMD];
        for (uint256 i; i < 2; i++) {
            uint256 bal = IERC20(toks[i]).balanceOf(me);
            if (bal > 1e18) {
                IERC20(toks[i]).transfer(address(probe), bal - 1e18);
                probe.swapExactIn(pools[i], IV3Pool(pools[i]).token0() == toks[i], bal - 1e18);
            }
        }
        probe.push(USDC, me, IERC20(USDC).balanceOf(address(probe)));
        console2.log("USDC:", IERC20(USDC).balanceOf(me));

        // 1. custom basket: 60% TSLA / 40% AMD
        address[] memory bt = new address[](2);
        uint16[] memory bw = new uint16[](2);
        bt[0] = TSLA; bw[0] = 6_000;
        bt[1] = AMD;  bw[1] = 4_000;
        sweeper.setBasket(bt, bw);
        console2.log("basket set, nonce:", sweeper.basketNonce(me));

        // 2. swap 0.4 USDC for TSLA, round up to 1.00 -> 0.60 change
        IERC20(USDC).approve(address(router), type(uint256).max);
        (, uint256 roundUp) = router.swapWithRoundUp(P_TSLA, TSLA, 0.4e18, 1, 1, 1);
        console2.log("round-up banked:", roundUp);
        console2.log("accrued:", vault.accruedStable(me));

        // 3. sweep into the 60/40 basket (fee 1% applies)
        uint256[] memory minOuts = new uint256[](2);
        minOuts[0] = 1; minOuts[1] = 1;
        sweeper.sweep(me, minOuts, sweeper.basketNonce(me));

        console2.log("--- after sweep ---");
        console2.log("TSLA in vault:", vault.tokenBalanceOf(me, TSLA));
        console2.log("AMD in vault:", vault.tokenBalanceOf(me, AMD));
        console2.log("cost basis:", vault.costBasis(me));
        console2.log("treasury USDC:", IERC20(USDC).balanceOf(sweeper.treasury()));

        // 4. withdraw the TSLA leg in kind
        uint256 t = vault.tokenBalanceOf(me, TSLA);
        vault.withdrawToken(TSLA, t, me);
        console2.log("TSLA withdrawn:", t);

        vm.stopBroadcast();
    }
}
