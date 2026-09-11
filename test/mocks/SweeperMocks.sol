// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {TickMath} from "../../src/libraries/TickMath.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";

/// Test doubles for DustRouter and DustSweeper (exact-input swaps).

interface IUniCallbackX {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
}

interface IMockToken {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// Plain ERC-20 with the adversarial knobs the audit findings need:
///  - `frozen[addr]`: transfers to or from a frozen address revert (USDG-style
///    issuer freeze, audit L001)
///  - `haircutBps` + `exemptSender`: a transfer that is not from an exempt
///    sender delivers `haircutBps` less than requested (fee-on-transfer that
///    exempts pools but taxes the sweeper -> vault hop, audit M002)
contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public frozen;
    mapping(address => bool) public exemptSender;
    uint16 public haircutBps;

    constructor(string memory _sym, uint8 _dec) {
        symbol = _sym;
        decimals = _dec;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function setFrozen(address a, bool f) external {
        frozen[a] = f;
    }

    function setHaircut(uint16 bps) external {
        haircutBps = bps;
    }

    function setExempt(address a, bool e) external {
        exemptSender[a] = e;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function _move(address from, address to, uint256 amt) internal {
        require(!frozen[from] && !frozen[to], "frozen");
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        uint256 received = exemptSender[from] ? amt : amt - (amt * haircutBps) / 10_000;
        balanceOf[to] += received;
    }
}

/// USDT-style token: transfer/transferFrom return nothing (audit L003).
contract NoReturnERC20 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }

    function transfer(address to, uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// Token that returns false instead of reverting on failure (audit L003).
contract FalseReturnERC20 {
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public failAll;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function setFailAll(bool f) external { failAll = f; }
    function approve(address s, uint256 amt) external returns (bool) { allowance[msg.sender][s] = amt; return true; }

    function transfer(address to, uint256 amt) external returns (bool) {
        if (failAll || balanceOf[msg.sender] < amt) return false;
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (failAll || a < amt || balanceOf[from] < amt) return false;
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// Uniswap-v3-shaped exact-input pool at a fixed price. observe() serves
/// `meanTick` as the TWAP; swap() fills exact-input orders at that tick, scaled
/// by `outBps` (price worse or better than TWAP), consuming `fillBps` of the
/// input (partial fill on thin liquidity). Adversarial knobs:
///  - `overcharge`: extra input demanded in the callback beyond what the swap
///    consumed (a pool that tries to pull more than the committed amount)
///  - `doubleCallback`: invoke the callback twice for one swap
///  - `underDeliverBps`: deliver less output than reported
/// Must be funded with the output token by the test.
contract MockSwapPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public fee = 3000;
    address public factory;

    int24 public meanTick;
    uint256 public outBps = 10_000;
    uint256 public fillBps = 10_000;
    uint256 public overcharge;
    bool public doubleCallback;
    uint256 public underDeliverBps;
    bool public observeReverts;
    uint256 public lastConsumed;

    constructor(address t0, address t1, int24 tick) {
        token0 = t0;
        token1 = t1;
        meanTick = tick;
        factory = msg.sender;
    }

    function setMeanTick(int24 t) external { meanTick = t; }
    function setOutBps(uint256 b) external { outBps = b; }
    function setFillBps(uint256 b) external { fillBps = b; }
    function setOvercharge(uint256 o) external { overcharge = o; }
    function setDoubleCallback(bool d) external { doubleCallback = d; }
    function setUnderDeliverBps(uint256 b) external { underDeliverBps = b; }
    function setObserveReverts(bool r) external { observeReverts = r; }
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
            tickCumulatives[i] = int56(meanTick) * int56(int256(1_000_000 - uint256(secondsAgos[i])));
        }
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtRatioAtTick(meanTick), meanTick, 0, 1, 1, 0, true);
    }

    /// Output at exactly the TWAP price (no fee, no impact) for `amountIn`.
    function quoteAtTwap(bool zeroForOne, uint256 amountIn) public view returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);
        uint256 ratioX192 = uint256(sqrtP) * sqrtP;
        return zeroForOne
            ? FullMath.mulDiv(amountIn, ratioX192, 1 << 192)
            : FullMath.mulDiv(amountIn, 1 << 192, ratioX192);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "mock: exact input only");
        uint256 consumed = (uint256(amountSpecified) * fillBps) / 10_000;
        lastConsumed = consumed;
        address tokenOut = zeroForOne ? token1 : token0;
        address tokenIn = zeroForOne ? token0 : token1;

        uint256 reported = (quoteAtTwap(zeroForOne, consumed) * outBps) / 10_000;
        uint256 delivered = reported - (reported * underDeliverBps) / 10_000;
        // low-level so a no-return (USDT-style) output token works too
        (bool paid,) = tokenOut.call(abi.encodeCall(IMockToken.transfer, (recipient, delivered)));
        require(paid, "mock: pay out");

        uint256 demanded = consumed + overcharge;
        uint256 before = IMockToken(tokenIn).balanceOf(address(this));
        if (zeroForOne) {
            amount0 = int256(demanded);
            amount1 = -int256(reported);
        } else {
            amount1 = int256(demanded);
            amount0 = -int256(reported);
        }
        IUniCallbackX(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        if (doubleCallback) IUniCallbackX(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(IMockToken(tokenIn).balanceOf(address(this)) >= before + demanded, "IIA");
    }
}
