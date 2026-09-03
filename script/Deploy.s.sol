// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IDustVault} from "../src/interfaces/IDust.sol";

interface IV3PoolMeta {
    function factory() external view returns (address);
    function fee() external view returns (uint24);
}

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// Deploy-only: the hardened trio + capture module + wiring. Prints addresses
/// for the keeper and the web app to consume.
///
/// Network selection: the path is chosen by `block.chainid` (4663 = Robinhood
/// Chain mainnet, 46630 = testnet). Set DEPLOY_NETWORK=mainnet|testnet to be
/// explicit; the mainnet path additionally hard-requires chain id 4663.
///
/// Dry run (no transactions are sent; forge simulates against the fork):
///   forge script script/Deploy.s.sol --rpc-url robinhood_mainnet -vvvv
///   forge script script/Deploy.s.sol --rpc-url robinhood_testnet -vvvv
///
/// Real deploy adds `--keystores .secrets/<file> --broadcast`. Every address
/// the mainnet path uses is logged before the first transaction; read them.
///
/// Mainnet env (all optional, defaults are the verified values in
/// MAINNET-ADDRESSES.md and the deployer):
///   STABLE       stable token (default USDG 0x5fc5...d168, 6 decimals)
///   TREASURY     fee recipient (default 0 = fee disabled until setTreasury)
///   KEEPER       sweep/capture keeper (default deployer)
///   OWNER        final DustSweeper owner, a multisig (default deployer, with a
///                loud warning; ownership is two-step, OWNER must acceptOwnership)
///   FEE_BPS      sweep fee in bps, <= 500 (default 100 = 1%)
///   MENU_TOKENS  comma-separated Stock Token addresses (default: launch five)
///   MENU_POOLS   comma-separated USDG pools, parallel to MENU_TOKENS
///   WETH         wrapped ETH the capture module wraps/unwraps and swaps
///                (default 0x0Bd7...AD73 on 4663; REQUIRED on any other chain)
///   ETH_POOL     Uniswap v3 WETH/STABLE pool the capture module swaps on and
///                reads its TWAP from (default WETH/USDG 0.01% 0x52e6...71ca
///                on 4663; REQUIRED on any other chain)
///
/// After deploying, the script makes sure ETH_POOL's oracle buffer can serve
/// the capture module's 10-minute TWAP: if slot0().observationCardinalityNext
/// is below 64 it calls increaseObservationCardinalityNext(64) (permissionless,
/// paid by the deployer). On mainnet the pool already sits at 2500, a no-op.
contract Deploy is Script {
    uint256 constant ROBINHOOD_MAINNET = 4663;
    uint256 constant ROBINHOOD_TESTNET = 46630;

    // ---- testnet (46630): 18-dec test USDC + Synthra-fork pools ----
    address constant T_USDC = 0xbf4479C07Dc6fdc6dAa764A0ccA06969e894275F;
    address constant T_TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant T_AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant T_PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;
    address constant T_NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address constant T_AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant TP_TSLA = 0xFfEf1147c3724a19AB7328F4e361C049ba452dA9;
    address constant TP_AMZN = 0x0A837200fB77687ba9b749E5174bd9a09E51286A;
    address constant TP_PLTR = 0x82A81E9EdB32958104A2c9514b8Fc85F972b53Af;
    address constant TP_NFLX = 0xcD8a64d13D5B99Dc546a3D6FFD8e5C7dD0Ecb1a0;
    address constant TP_AMD = 0xae12d50f75ea3f4Cf983Af1272614754e7F5e813;

    // ---- mainnet (4663): verified in MAINNET-ADDRESSES.md, 2026-09-03 ----
    address constant M_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6 decimals
    address constant M_TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant M_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant M_AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant M_AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant M_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant MP_TSLA = 0xf4ACdAEEB7022862A763C9B1B885e11191c889E3; // TSLA/USDG 0.3%
    address constant MP_NVDA = 0xd4EB21209C4D6093f80B5b84f5C45cc093EA14a3; // NVDA/USDG 0.05%
    address constant MP_AAPL = 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D; // AAPL/USDG 0.05%
    address constant MP_AMZN = 0x8AC92DA74AB5F3b1d024Dc1943Ad7e15Dc4179Ef; // AMZN/USDG 0.3%
    address constant MP_SPY = 0xa7Bb1AC63BBaB0C44316E6c8C455213441689167; // SPY/USDG 0.05%
    address constant M_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18 decimals, WETH9 deposit/withdraw
    address constant M_ETH_POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // WETH/USDG 0.01%, token0 = WETH
    address constant M_UNI_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // canonical Uniswap v3 factory on 4663
    uint16 constant MIN_ORACLE_CARDINALITY = 64;

    struct Deployed {
        DustVault vault;
        DustRouter router;
        DustSweeper sweeper;
        DustCapture capture;
    }

    function run() external {
        string memory net = vm.envOr("DEPLOY_NETWORK", string(""));
        bool mainnet;
        if (bytes(net).length == 0) {
            mainnet = block.chainid == ROBINHOOD_MAINNET;
        } else if (_eq(net, "mainnet")) {
            mainnet = true;
        } else if (_eq(net, "testnet")) {
            mainnet = false;
        } else {
            revert("Deploy: DEPLOY_NETWORK must be 'mainnet' or 'testnet'");
        }
        console2.log("chain id: %s", block.chainid);
        console2.log("path:     %s", mainnet ? "MAINNET" : "testnet");
        if (mainnet) _deployMainnet();
        else _deployTestnet();
    }

    // ------------------------------------------------------------------
    // testnet: unchanged behaviour, deployer is treasury/keeper/owner
    // ------------------------------------------------------------------
    function _deployTestnet() internal {
        require(block.chainid == ROBINHOOD_TESTNET, "Deploy: testnet path requires chain id 46630");
        address[] memory tokens = new address[](5);
        address[] memory pools = new address[](5);
        tokens[0] = T_TSLA; pools[0] = TP_TSLA;
        tokens[1] = T_AMZN; pools[1] = TP_AMZN;
        tokens[2] = T_PLTR; pools[2] = TP_PLTR;
        tokens[3] = T_NFLX; pools[3] = TP_NFLX;
        tokens[4] = T_AMD;  pools[4] = TP_AMD;

        uint256 unit = 10 ** uint256(IERC20(T_USDC).decimals()); // 1e18 on testnet
        // no verified WETH/USDC pool is recorded for the testnet: both are required here
        address wethAddr = vm.envAddress("WETH");
        address ethPool = vm.envAddress("ETH_POOL");
        console2.log("WETH:       %s", wethAddr);
        console2.log("ETH_POOL:   %s", ethPool);
        _checkEthPool(T_USDC, wethAddr, ethPool);

        vm.startBroadcast();
        Deployed memory d = _deployCore(T_USDC, unit, msg.sender, tokens, pools, wethAddr, ethPool);
        _ensureOracle(ethPool);
        vm.stopBroadcast();
        _printAddresses(d, T_USDC, unit, wethAddr, ethPool);
    }

    // ------------------------------------------------------------------
    // mainnet: everything from env with verified defaults, logged up front
    // ------------------------------------------------------------------
    function _deployMainnet() internal {
        require(block.chainid == ROBINHOOD_MAINNET, "Deploy: mainnet path requires chain id 4663");

        address deployer = msg.sender;
        address stable = vm.envOr("STABLE", M_USDG);
        address treasury = vm.envOr("TREASURY", address(0));
        address keeper = vm.envOr("KEEPER", deployer);
        address finalOwner = vm.envOr("OWNER", deployer);
        uint256 feeBps = vm.envOr("FEE_BPS", uint256(100));
        address wethAddr = vm.envOr("WETH", M_WETH);
        address ethPool = vm.envOr("ETH_POOL", M_ETH_POOL);
        (address[] memory tokens, address[] memory pools) = _mainnetMenu();

        // ---- log every address before use ----
        console2.log("deployer:   %s", deployer);
        console2.log("STABLE:     %s", stable);
        console2.log("TREASURY:   %s", treasury);
        console2.log("KEEPER:     %s", keeper);
        console2.log("OWNER:      %s", finalOwner);
        console2.log("FEE_BPS:    %s", feeBps);
        console2.log("WETH:       %s", wethAddr);
        console2.log("ETH_POOL:   %s", ethPool);
        for (uint256 i; i < tokens.length; i++) {
            console2.log("menu[%s] token %s pool %s", i, tokens[i], pools[i]);
        }

        // ---- pre-flight (read-only) ----
        require(stable.code.length > 0, "Deploy: STABLE has no code");
        uint8 dec = IERC20(stable).decimals();
        require(dec > 0 && dec <= 18, "Deploy: implausible stable decimals");
        uint256 unit = 10 ** uint256(dec);
        console2.log("stable decimals: %s -> unit %s", dec, unit);
        if (stable == M_USDG) require(dec == 6, "Deploy: USDG must report 6 decimals");
        require(feeBps <= 500, "Deploy: FEE_BPS above the 5% code ceiling");
        require(keeper != address(0), "Deploy: KEEPER is zero");
        require(finalOwner != address(0), "Deploy: OWNER is zero");
        for (uint256 i; i < tokens.length; i++) {
            require(tokens[i].code.length > 0, "Deploy: menu token has no code");
            require(pools[i].code.length > 0, "Deploy: menu pool has no code");
            address t0 = IV3Pool(pools[i]).token0();
            address t1 = IV3Pool(pools[i]).token1();
            bool ok = (t0 == stable && t1 == tokens[i]) || (t1 == stable && t0 == tokens[i]);
            require(ok, "Deploy: pool does not pair STABLE with its menu token");
        }
        _checkEthPool(stable, wethAddr, ethPool);
        // provenance: every pool the modules swap on must be the factory's own
        // pool for its pair and fee tier, not a lookalike passed in by env
        _checkFactoryPool(ethPool, wethAddr, stable);
        for (uint256 i; i < tokens.length; i++) {
            _checkFactoryPool(pools[i], tokens[i], stable);
        }

        if (treasury == address(0)) {
            console2.log("WARNING: TREASURY unset -> sweep fee is DISABLED until owner calls setTreasury");
        }
        if (finalOwner == deployer) {
            console2.log("WARNING: OWNER unset -> the deployer keeps DustSweeper ownership.");
            console2.log("WARNING: transfer it to the multisig (transferOwnership + acceptOwnership) before launch.");
        }

        // ---- deploy ----
        vm.startBroadcast();
        Deployed memory d = _deployCore(stable, unit, treasury, tokens, pools, wethAddr, ethPool);
        _ensureOracle(ethPool);
        if (keeper != deployer) d.sweeper.setKeeper(keeper);
        if (feeBps != 100) d.sweeper.setFeeBps(uint16(feeBps));
        if (finalOwner != deployer) d.sweeper.transferOwnership(finalOwner);
        vm.stopBroadcast();

        _printAddresses(d, stable, unit, wethAddr, ethPool);
        console2.log("DUST_KEEPER=%s", d.sweeper.keeper());
        console2.log("DUST_TREASURY=%s", d.sweeper.treasury());
        console2.log("DUST_FEE_BPS=%s", d.sweeper.feeBps());
        if (finalOwner != deployer) {
            console2.log("ownership transfer STARTED to %s; it must call acceptOwnership() to finish", finalOwner);
        } else {
            console2.log("OWNER IS THE DEPLOYER (%s). Transfer ownership before launch.", deployer);
        }
    }

    /// Launch menu: the five (token, pool) pairs from MAINNET-ADDRESSES.md unless
    /// MENU_TOKENS / MENU_POOLS override them.
    function _mainnetMenu() internal view returns (address[] memory tokens, address[] memory pools) {
        address[] memory defTokens = new address[](5);
        address[] memory defPools = new address[](5);
        defTokens[0] = M_TSLA; defPools[0] = MP_TSLA;
        defTokens[1] = M_NVDA; defPools[1] = MP_NVDA;
        defTokens[2] = M_AAPL; defPools[2] = MP_AAPL;
        defTokens[3] = M_AMZN; defPools[3] = MP_AMZN;
        defTokens[4] = M_SPY;  defPools[4] = MP_SPY;
        tokens = vm.envOr("MENU_TOKENS", ",", defTokens);
        pools = vm.envOr("MENU_POOLS", ",", defPools);
        require(tokens.length > 0, "Deploy: empty menu");
        require(tokens.length == pools.length, "Deploy: MENU_TOKENS/MENU_POOLS length mismatch");
    }

    /// Shared deploy + wiring. Caller wraps in start/stopBroadcast.
    function _deployCore(
        address stable,
        uint256 unit,
        address treasury,
        address[] memory tokens,
        address[] memory pools,
        address wethAddr,
        address ethPool
    ) internal returns (Deployed memory d) {
        d.vault = new DustVault(IERC20(stable));
        d.router = new DustRouter(IERC20(stable), IDustVault(address(d.vault)), unit);
        d.sweeper = new DustSweeper(IERC20(stable), IDustVault(address(d.vault)), treasury);
        // curate the menu of buyable stocks; users compose their own baskets from it
        for (uint256 i; i < tokens.length; i++) {
            d.sweeper.listStock(tokens[i], pools[i]);
        }
        d.capture = new DustCapture(
            IERC20(stable),
            IDustVault(address(d.vault)),
            IKeeperSource(address(d.sweeper)),
            IWETH(wethAddr),
            IV3Pool(ethPool)
        );
        d.vault.setModules(address(d.router), address(d.sweeper), address(d.capture));
    }

    /// Read-only pre-flight for the capture module's swap venue: WETH and the
    /// pool exist, and the pool pairs exactly WETH with STABLE.
    function _checkEthPool(address stable, address wethAddr, address ethPool) internal view {
        require(wethAddr != address(0) && wethAddr.code.length > 0, "Deploy: WETH has no code");
        require(ethPool != address(0) && ethPool.code.length > 0, "Deploy: ETH_POOL has no code");
        require(IERC20(wethAddr).decimals() == 18, "Deploy: WETH must report 18 decimals");
        address t0 = IV3Pool(ethPool).token0();
        address t1 = IV3Pool(ethPool).token1();
        bool ok = (t0 == wethAddr && t1 == stable) || (t0 == stable && t1 == wethAddr);
        require(ok, "Deploy: ETH_POOL does not pair WETH with STABLE");
        (,,, uint16 card, uint16 cardNext,,) = IV3Pool(ethPool).slot0();
        console2.log("ETH_POOL oracle cardinality %s (next %s), WETH is token%s", card, cardNext, t0 == wethAddr ? 0 : 1);
    }

    /// Mainnet only: the pool must report the canonical factory and the factory
    /// must resolve (tokenA, tokenB, fee) back to this very pool.
    function _checkFactoryPool(address pool, address tokenA, address tokenB) internal view {
        require(IV3PoolMeta(pool).factory() == M_UNI_V3_FACTORY, "Deploy: pool not from the canonical Uniswap v3 factory");
        uint24 fee = IV3PoolMeta(pool).fee();
        require(IV3Factory(M_UNI_V3_FACTORY).getPool(tokenA, tokenB, fee) == pool, "Deploy: factory does not know this pool");
    }

    /// Inside the broadcast: grow the pool's oracle buffer if it is too small
    /// for the capture module's TWAP window. Anyone may call this on any pool.
    function _ensureOracle(address ethPool) internal {
        (,,,, uint16 cardNext,,) = IV3Pool(ethPool).slot0();
        if (cardNext < MIN_ORACLE_CARDINALITY) {
            IV3Pool(ethPool).increaseObservationCardinalityNext(MIN_ORACLE_CARDINALITY);
            console2.log("ETH_POOL observationCardinalityNext %s -> %s (increaseObservationCardinalityNext sent)", cardNext, MIN_ORACLE_CARDINALITY);
        } else {
            console2.log("ETH_POOL observationCardinalityNext %s >= %s, no oracle change needed", cardNext, MIN_ORACLE_CARDINALITY);
        }
    }

    function _printAddresses(Deployed memory d, address stable, uint256 unit, address wethAddr, address ethPool)
        internal
        pure
    {
        console2.log("DUST_STABLE=%s", stable);
        console2.log("DUST_STABLE_UNIT=%s", unit);
        console2.log("DUST_WETH=%s", wethAddr);
        console2.log("DUST_ETH_POOL=%s", ethPool);
        console2.log("DUST_VAULT=%s", address(d.vault));
        console2.log("DUST_ROUTER=%s", address(d.router));
        console2.log("DUST_SWEEPER=%s", address(d.sweeper));
        console2.log("DUST_CAPTURE=%s", address(d.capture));
        console2.log("DUST_CAPTURE funds round-ups from USDG (wallet allowance), WETH (wallet allowance) and an ETH float held as WETH");
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
