// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";
import {DustVault} from "../src/DustVault.sol";
import {DustRouter} from "../src/DustRouter.sol";
import {DustSweeper} from "../src/DustSweeper.sol";
import {DustCapture, IKeeperSource} from "../src/DustCapture.sol";
import {IERC20, IWETH, IV3Pool, IV3PoolMeta, IV3Factory, IDustVault} from "../src/interfaces/IDust.sol";

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
///   FACTORY      canonical Uniswap v3 factory the three swap modules accept
///                pools from (default 0x1f7d...2efa on 4663; REQUIRED on any
///                other chain, e.g. the Synthra factory on the testnet)
///
/// v3 menu: the mainnet default lists all fifteen verified (token, pool) pairs
/// from MAINNET-ADDRESSES.md (the launch five plus the 2026-09-09 expansion).
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
    // ---- menu expansion (2026-09-09), verified against the canonical factory ----
    address constant M_MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant M_GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant M_META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant M_NFLX = 0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8;
    address constant M_AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
    address constant M_PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address constant M_QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant M_GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant M_SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant M_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address constant MP_MSFT = 0xeb60bCD1D920ad6E102690CCFC6fB488899E1510; // MSFT/USDG 0.3%
    address constant MP_GOOGL = 0x34D0dC122CF9A8Eb296fC5e0D3A233625D7d19b7; // GOOGL/USDG 0.05%
    address constant MP_META = 0x107a7Cb40d8665360ba10E59471Af06150A50922; // META/USDG 0.3%
    address constant MP_NFLX = 0x59895C0302F41aEaa129D2fa2442CEc01E7eF45E; // NFLX/USDG 0.3%
    address constant MP_AMD = 0x48D284A2A4d3DC1b3Da08231Fe44317e7e7Aa51f; // AMD/USDG 0.3%
    address constant MP_PLTR = 0x851680416A4f4E1c463d45171d61ACDdBc8554c0; // PLTR/USDG 0.3%
    address constant MP_QQQ = 0xD60A5d14dB690B7Afad71F76B108071D7175597d; // QQQ/USDG 0.05%
    address constant MP_GLD = 0x7A6A053eCCf1446A2633E05aA6D40D09381997ec; // GLD/USDG 0.3%
    address constant MP_SPCX = 0xc61284332117c3FB23A2A56cceFFD07F7aF60029; // SPCX/USDG 0.05%
    address constant MP_MSTR = 0x17578C0e0D15da44f31677263114F71aE76653EA; // MSTR/USDG 1%
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
        address factory = vm.envAddress("FACTORY");
        console2.log("WETH:       %s", wethAddr);
        console2.log("ETH_POOL:   %s", ethPool);
        console2.log("FACTORY:    %s", factory);
        _checkEthPool(T_USDC, wethAddr, ethPool);
        _checkFactoryPool(factory, ethPool, wethAddr, T_USDC);
        for (uint256 i; i < tokens.length; i++) {
            _checkFactoryPool(factory, pools[i], tokens[i], T_USDC);
        }

        vm.startBroadcast();
        Deployed memory d = _deployCore(T_USDC, unit, msg.sender, tokens, pools, wethAddr, ethPool, factory);
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
        address factory = vm.envOr("FACTORY", M_UNI_V3_FACTORY);
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
        console2.log("FACTORY:    %s", factory);
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
        require(factory.code.length > 0, "Deploy: FACTORY has no code");
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
        _checkFactoryPool(factory, ethPool, wethAddr, stable);
        for (uint256 i; i < tokens.length; i++) {
            _checkFactoryPool(factory, pools[i], tokens[i], stable);
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
        Deployed memory d = _deployCore(stable, unit, treasury, tokens, pools, wethAddr, ethPool, factory);
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

    /// v3 menu: the fifteen verified (token, pool) pairs from
    /// MAINNET-ADDRESSES.md unless MENU_TOKENS / MENU_POOLS override them.
    function _mainnetMenu() internal view returns (address[] memory tokens, address[] memory pools) {
        address[] memory defTokens = new address[](15);
        address[] memory defPools = new address[](15);
        defTokens[0] = M_TSLA;   defPools[0] = MP_TSLA;
        defTokens[1] = M_NVDA;   defPools[1] = MP_NVDA;
        defTokens[2] = M_AAPL;   defPools[2] = MP_AAPL;
        defTokens[3] = M_AMZN;   defPools[3] = MP_AMZN;
        defTokens[4] = M_SPY;    defPools[4] = MP_SPY;
        defTokens[5] = M_MSFT;   defPools[5] = MP_MSFT;
        defTokens[6] = M_GOOGL;  defPools[6] = MP_GOOGL;
        defTokens[7] = M_META;   defPools[7] = MP_META;
        defTokens[8] = M_NFLX;   defPools[8] = MP_NFLX;
        defTokens[9] = M_AMD;    defPools[9] = MP_AMD;
        defTokens[10] = M_PLTR;  defPools[10] = MP_PLTR;
        defTokens[11] = M_QQQ;   defPools[11] = MP_QQQ;
        defTokens[12] = M_GLD;   defPools[12] = MP_GLD;
        defTokens[13] = M_SPCX;  defPools[13] = MP_SPCX;
        defTokens[14] = M_MSTR;  defPools[14] = MP_MSTR;
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
        address ethPool,
        address factory
    ) internal returns (Deployed memory d) {
        d.vault = new DustVault(IERC20(stable));
        d.router = new DustRouter(IERC20(stable), IDustVault(address(d.vault)), unit, IV3Factory(factory));
        d.sweeper = new DustSweeper(IERC20(stable), IDustVault(address(d.vault)), treasury, IV3Factory(factory));
        // curate the menu of buyable stocks; users compose their own baskets from it
        for (uint256 i; i < tokens.length; i++) {
            d.sweeper.listStock(tokens[i], pools[i]);
        }
        d.capture = new DustCapture(
            IERC20(stable),
            IDustVault(address(d.vault)),
            IKeeperSource(address(d.sweeper)),
            IWETH(wethAddr),
            IV3Pool(ethPool),
            IV3Factory(factory)
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

    /// The pool must report `factory` and the factory must resolve
    /// (tokenA, tokenB, fee) back to this very pool. The same check runs again
    /// inside every module (constructor / listStock), so a pool that fails
    /// here would also fail on-chain.
    function _checkFactoryPool(address factory, address pool, address tokenA, address tokenB) internal view {
        require(IV3PoolMeta(pool).factory() == factory, "Deploy: pool not from the configured factory");
        uint24 fee = IV3PoolMeta(pool).fee();
        require(IV3Factory(factory).getPool(tokenA, tokenB, fee) == pool, "Deploy: factory does not know this pool");
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
        view
    {
        console2.log("DUST_STABLE=%s", stable);
        console2.log("DUST_STABLE_UNIT=%s", unit);
        console2.log("DUST_WETH=%s", wethAddr);
        console2.log("DUST_ETH_POOL=%s", ethPool);
        console2.log("DUST_FACTORY=%s", address(d.sweeper.factory()));
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
