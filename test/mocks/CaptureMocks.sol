// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {TickMath} from "../../src/libraries/TickMath.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";

/// Test doubles for DustCapture. Shared by the unit tests and the testnet
/// fork test (which only needs a WETH + pool pair that passes the constructor).

interface IMockERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IUniCallback {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
}

interface ISynthraCallback {
    function synthraV3SwapCallback(int256, int256, bytes calldata) external;
}

/// Minimal Uniswap-v3-factory double: the tests register the pools they want
/// the modules to accept; everything else resolves to address(0).
contract MockFactory {
    mapping(bytes32 => address) private pools;

    function register(address pool) external {
        address t0 = IMockPoolMeta(pool).token0();
        address t1 = IMockPoolMeta(pool).token1();
        uint24 fee = IMockPoolMeta(pool).fee();
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
        pools[keccak256(abi.encode(t1, t0, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a, b, fee))];
    }
}

interface IMockPoolMeta {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

contract MockStable {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true;
    }
    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        require(balanceOf[f] >= amt, "bal");
        uint256 a = allowance[f][msg.sender]; require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt; balanceOf[t] += amt; return true;
    }
}

/// WETH9 semantics, including the 2300-gas `transfer` on withdraw so the
/// receive() under test is exercised with the tightest stipend.
contract MockWETH {
    string public constant name = "Wrapped Ether";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    receive() external payable { deposit(); }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "bal");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() external view returns (uint256) { return address(this).balance; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { return transferFrom(msg.sender, to, amt); }
    function transferFrom(address f, address t, uint256 amt) public returns (bool) {
        require(balanceOf[f] >= amt, "bal");
        if (f != msg.sender && allowance[f][msg.sender] != type(uint256).max) {
            require(allowance[f][msg.sender] >= amt, "allow");
            allowance[f][msg.sender] -= amt;
        }
        balanceOf[f] -= amt; balanceOf[t] += amt; return true;
    }
}

contract MockSweeper {
    address public keeper;
    constructor(address k) { keeper = k; }
    function setKeeper(address k) external { keeper = k; }
}

/// A Uniswap-v3-shaped pool at a fixed price: observe() serves `meanTick` as
/// the TWAP, swap() fills exact-output orders at exactly that tick (plus an
/// optional surcharge to simulate slippage/fees) and calls the configured
/// callback name. It must be funded with the output token by the test.
/// Adversarial knobs (audit L004): `doubleCallback` invokes the callback twice
/// for one swap with identical deltas; `underDeliverBps` pays out less than the
/// deltas it reports.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public fee = 100;
    address public factory;

    int24 public meanTick;
    uint256 public extraBps;         // charge this much more input than the TWAP implies
    bool public partialFill;         // deliver one unit less than asked (and report it)
    bool public useSynthraCallback;  // call synthraV3SwapCallback instead of uniswapV3SwapCallback
    bool public observeReverts;      // simulate "OLD": no oracle history
    bool public doubleCallback;      // invoke the callback twice within one swap
    uint256 public underDeliverBps;  // report the full output but deliver this many bps less
    uint16 public cardinalityNext = 1;

    constructor(address t0, address t1, int24 tick) {
        token0 = t0;
        token1 = t1;
        meanTick = tick;
        factory = msg.sender;
    }

    function setMeanTick(int24 t) external { meanTick = t; }
    function setExtraBps(uint256 b) external { extraBps = b; }
    function setPartialFill(bool p) external { partialFill = p; }
    function setSynthraCallback(bool s) external { useSynthraCallback = s; }
    function setObserveReverts(bool r) external { observeReverts = r; }
    function setDoubleCallback(bool d) external { doubleCallback = d; }
    function setUnderDeliverBps(uint256 b) external { underDeliverBps = b; }
    function setFee(uint24 f) external { fee = f; }
    function setFactory(address f) external { factory = f; }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        require(!observeReverts, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; i++) {
            // constant tick: cumulative = tick * elapsed
            tickCumulatives[i] = int56(meanTick) * int56(int256(1_000_000 - uint256(secondsAgos[i])));
        }
    }

    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)
    {
        return (TickMath.getSqrtRatioAtTick(meanTick), meanTick, 0, cardinalityNext, cardinalityNext, 0, true);
    }

    function increaseObservationCardinalityNext(uint16 n) external {
        if (n > cardinalityNext) cardinalityNext = n;
    }

    /// What this pool will charge for an exact-output order (test oracle).
    function quoteExactOutput(bool zeroForOne, uint256 amountOut) public view returns (uint256 amountIn) {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        amountIn = zeroForOne
            ? FullMath.mulDivRoundingUp(amountOut, 1 << 192, ratioX192)
            : FullMath.mulDivRoundingUp(amountOut, ratioX192, 1 << 192);
        amountIn = (amountIn * (10_000 + extraBps)) / 10_000;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified < 0, "mock: exact output only");
        uint256 amountOut = uint256(-amountSpecified);
        address tokenOut = zeroForOne ? token1 : token0;
        address tokenIn = zeroForOne ? token0 : token1;

        uint256 amountIn = quoteExactOutput(zeroForOne, amountOut);
        uint256 reported = partialFill ? amountOut - 1 : amountOut;
        uint256 delivered = reported - (reported * underDeliverBps) / 10_000;

        require(IMockERC20(tokenOut).transfer(recipient, delivered), "mock: pay out");
        uint256 before = IMockERC20(tokenIn).balanceOf(address(this));

        if (zeroForOne) {
            amount0 = int256(amountIn);
            amount1 = -int256(reported);
        } else {
            amount1 = int256(amountIn);
            amount0 = -int256(reported);
        }

        _callback(amount0, amount1, data);
        if (doubleCallback) _callback(amount0, amount1, data);

        require(IMockERC20(tokenIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }

    function _callback(int256 a0, int256 a1, bytes calldata data) internal {
        if (useSynthraCallback) ISynthraCallback(msg.sender).synthraV3SwapCallback(a0, a1, data);
        else IUniCallback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
    }
}
