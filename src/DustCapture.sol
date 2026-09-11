// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20, IWETH, IV3Pool, IV3PoolMeta, IV3Factory, IDustVault} from "./interfaces/IDust.sol";
import {SafeTransfer} from "./libraries/SafeTransfer.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {FullMath} from "./libraries/FullMath.sol";

interface IKeeperSource {
    function keeper() external view returns (address);
}

/// @title DustCapture (v2, multi-asset funding)
/// @notice Outside-transaction round-ups for any wallet, funded from the
///         stable, from WETH in the user's wallet, or from an ETH float the
///         user parks here.
///
/// The user opts in with a weekly cap they set themselves. The keeper then
/// pulls observed round-ups (computed off-chain from the user's outside
/// activity) into the user's own vault position, and can never do more than
/// that:
///
///  - Pulls go ONLY to the vault, credited ONLY to the user they came from.
///    There is no path to any other destination.
///  - In-contract weekly rate limit in stable units, set by the user,
///    changeable/revocable at any time (setWeeklyCap(0) = full opt-out). The
///    cap counts every funding source together.
///  - The user's ERC-20 allowance (stable or WETH) or their ETH float is a
///    second, independent cap they control from any wallet UI.
///  - WETH/ETH captures are exact-output swaps on one immutable pool that the
///    canonical Uniswap v3 factory acknowledges for (WETH, stable, fee). The
///    WETH paid for one capture is bounded on-chain, IN AGGREGATE across every
///    callback the pool makes during that swap, by min(the pool's own
///    10-minute TWAP cost plus MAX_SLIPPAGE_BPS, the keeper's maxWethIn). The
///    bound is decremented in storage as it is consumed, so a pool cannot be
///    paid twice against it. The stable credited to the user is the vault's
///    measured balance delta and must equal amountOut exactly.
///  - No owner, no admin, no pause: nobody can change these rules after
///    deploy. The keeper address is read from the sweeper so key rotation
///    stays in one place. withdrawEth works in every state, cap or no cap.
contract DustCapture {
    using SafeTransfer for IERC20;

    uint64 public constant WEEK = 7 days;
    /// Hard bound on every WETH pull: at most 2% worse than the pool TWAP.
    uint16 public constant MAX_SLIPPAGE_BPS = 200;
    /// TWAP window in seconds.
    uint32 public constant TWAP_WINDOW = 600;

    IERC20 public immutable stable;
    IDustVault public immutable vault;
    IKeeperSource public immutable sweeper;
    IWETH public immutable weth;
    IV3Pool public immutable ethPool;
    IV3Factory public immutable factory;
    bool public immutable wethIsToken0;

    struct Config {
        uint96 weeklyCap;    // user-set max capture per week in stable units (0 = opted out)
        uint96 usedThisWeek; // pulled so far in the current window, all sources
        uint64 weekStart;    // window start timestamp
    }

    mapping(address => Config) public configOf;

    /// User's ETH float, held inside this contract as WETH.
    mapping(address => uint256) public ethBalance;

    /// Swap context set immediately before ethPool.swap and cleared right
    /// after; the callback refuses to pay unless it is set and the caller is
    /// the pool it names.
    struct Pending {
        address pool;      // expected callback caller
        address user;      // who is funding and being credited
        uint8 source;      // 1 = WETH wallet, 2 = ETH float
        uint256 amountOut; // stable the pool must deliver, exactly
        uint256 wethLimit; // min(keeper maxWethIn, maxWethInFor(amountOut)), less what was already paid
    }

    Pending private pending;

    event WeeklyCapSet(address indexed user, uint256 weeklyCap);
    event Captured(address indexed user, uint256 amount, uint256 usedThisWeek);
    /// source 0 = stable from wallet, 1 = WETH from wallet, 2 = ETH float
    event CapturedFrom(address indexed user, uint8 source, uint256 assetIn, uint256 amountOut);
    event EthDeposited(address indexed user, uint256 amount);
    event EthWithdrawn(address indexed user, address indexed to, uint256 amount);

    error NotKeeper();
    error NotOptedIn();
    error OverWeeklyCap();
    error ZeroAmount();
    error ZeroAddress();
    error TransferFailed();
    error BadPool();
    error BadCallback();
    error PartialFill();
    error OverMaxWethIn();
    error InsufficientEthBalance();
    error EthTransferFailed();
    error NotWeth();
    error BadRecipient();

    constructor(
        IERC20 _stable,
        IDustVault _vault,
        IKeeperSource _sweeper,
        IWETH _weth,
        IV3Pool _ethPool,
        IV3Factory _factory
    ) {
        if (
            address(_stable) == address(0) || address(_vault) == address(0) || address(_sweeper) == address(0)
                || address(_weth) == address(0) || address(_ethPool) == address(0) || address(_factory) == address(0)
        ) revert ZeroAddress();
        if (address(_weth) == address(_stable)) revert BadPool();
        address t0 = _ethPool.token0();
        address t1 = _ethPool.token1();
        bool wethFirst = t0 == address(_weth) && t1 == address(_stable);
        bool stableFirst = t0 == address(_stable) && t1 == address(_weth);
        if (!wethFirst && !stableFirst) revert BadPool();
        // provenance travels with the contract, not with one deploy script (audit L004)
        if (_factory.getPool(address(_weth), address(_stable), IV3PoolMeta(address(_ethPool)).fee()) != address(_ethPool)) {
            revert BadPool();
        }

        stable = _stable;
        vault = _vault;
        sweeper = _sweeper;
        weth = _weth;
        ethPool = _ethPool;
        factory = _factory;
        wethIsToken0 = wethFirst;
    }

    // ---- user surface (always available, no pause, no admin) ----

    /// Opt in / change the cap / opt out (cap 0). Always the user's own call.
    function setWeeklyCap(uint96 cap) external {
        Config storage c = configOf[msg.sender];
        c.weeklyCap = cap;
        if (c.weekStart == 0) c.weekStart = uint64(block.timestamp);
        emit WeeklyCapSet(msg.sender, cap);
    }

    /// Park ETH here as a float the keeper may draw round-ups from. Held as
    /// WETH, credited 1:1 to the sender, withdrawable at any time.
    function depositEth() external payable {
        if (msg.value == 0) revert ZeroAmount();
        weth.deposit{value: msg.value}();
        ethBalance[msg.sender] += msg.value;
        emit EthDeposited(msg.sender, msg.value);
    }

    /// Take ETH back out of the float. Works in every state, including cap 0.
    function withdrawEth(uint256 amount, address to) external {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        // ETH sent to WETH would re-wrap into unbacked WETH stuck here; this
        // contract itself refuses plain ETH. Both would strand the user's funds.
        if (to == address(weth) || to == address(this)) revert BadRecipient();
        uint256 bal = ethBalance[msg.sender];
        if (amount > bal) revert InsufficientEthBalance();
        ethBalance[msg.sender] = bal - amount; // debit first
        weth.withdraw(amount);                 // WETH pays ETH to this contract (see receive)
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(msg.sender, to, amount);
    }

    /// Only WETH may send plain ETH here (the unwrap in withdrawEth). Anyone
    /// else gets a revert instead of losing their ETH.
    receive() external payable {
        if (msg.sender != address(weth)) revert NotWeth();
    }

    // ---- keeper surface ----

    /// Source 0: keeper pulls an observed round-up in the stable from the
    /// user's wallet allowance straight into the vault. Unchanged from v1.
    function captureFor(address user, uint256 amount) external {
        if (msg.sender != sweeper.keeper()) revert NotKeeper();
        if (amount == 0) revert ZeroAmount();
        uint256 newUsed = _consumeCap(user, amount);

        // pull straight into the vault, credit the same user. Reverts if the
        // user's wallet allowance or balance is insufficient; the keeper is
        // expected to check first.
        stable.safeTransferFrom(user, address(vault), amount);
        vault.accrue(user, amount);
        emit Captured(user, amount, newUsed);
        emit CapturedFrom(user, 0, amount, amount);
    }

    /// Source 1: buy exactly `amountOut` stable for the user, paying WETH from
    /// the user's wallet allowance directly to the pool (no custody here).
    function captureFromWeth(address user, uint256 amountOut, uint256 maxWethIn) external {
        _captureViaSwap(user, amountOut, maxWethIn, 1);
    }

    /// Source 2: buy exactly `amountOut` stable for the user, paying WETH from
    /// the user's ETH float held here.
    function captureFromEth(address user, uint256 amountOut, uint256 maxWethIn) external {
        _captureViaSwap(user, amountOut, maxWethIn, 2);
    }

    // ---- views ----

    /// How much the keeper could still capture for `user` this week.
    function remainingThisWeek(address user) external view returns (uint256) {
        Config memory c = configOf[user];
        if (c.weeklyCap == 0) return 0;
        if (block.timestamp >= c.weekStart + WEEK) return c.weeklyCap;
        // a cap lowered mid-week below what was already used leaves nothing
        if (c.usedThisWeek >= c.weeklyCap) return 0;
        return c.weeklyCap - c.usedThisWeek;
    }

    /// Most WETH a capture of `amountOut` stable may cost: the pool's
    /// TWAP_WINDOW arithmetic-mean-tick price, times (10000 + MAX_SLIPPAGE_BPS)
    /// / 10000. Reverts if the pool's oracle cannot serve the window (fail
    /// closed), so no capture can happen on a pool without oracle history.
    function maxWethInFor(uint256 amountOut) public view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        (int56[] memory tickCumulatives,) = ethPool.observe(ago);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 window = int56(uint56(TWAP_WINDOW));
        int24 meanTick = int24(delta / window);
        // round toward negative infinity, as Uniswap's OracleLibrary does
        if (delta < 0 && (delta % window != 0)) meanTick--;

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);
        uint256 wethIn;
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP; // token1 per token0, Q192
            wethIn = wethIsToken0
                ? FullMath.mulDivRoundingUp(amountOut, 1 << 192, ratioX192)
                : FullMath.mulDivRoundingUp(amountOut, ratioX192, 1 << 192);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
            wethIn = wethIsToken0
                ? FullMath.mulDivRoundingUp(amountOut, 1 << 128, ratioX128)
                : FullMath.mulDivRoundingUp(amountOut, ratioX128, 1 << 128);
        }
        return FullMath.mulDivRoundingUp(wethIn, 10_000 + MAX_SLIPPAGE_BPS, 10_000);
    }

    // ---- swap callbacks (canonical Uniswap v3 and the testnet Synthra fork) ----

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _paySwap(amount0Delta, amount1Delta);
    }

    function synthraV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        _paySwap(amount0Delta, amount1Delta);
    }

    // ---- internals ----

    /// Weekly window roll + cap check, shared by every source. Reverts if the
    /// user has no cap or this amount would exceed it.
    function _consumeCap(address user, uint256 amount) internal returns (uint256 newUsed) {
        Config storage c = configOf[user];
        if (c.weeklyCap == 0) revert NotOptedIn();
        if (block.timestamp >= c.weekStart + WEEK) {
            c.weekStart = uint64(block.timestamp);
            c.usedThisWeek = 0;
        }
        newUsed = uint256(c.usedThisWeek) + amount;
        if (newUsed > c.weeklyCap) revert OverWeeklyCap();
        c.usedThisWeek = uint96(newUsed);
    }

    function _captureViaSwap(address user, uint256 amountOut, uint256 maxWethIn, uint8 source) internal {
        if (msg.sender != sweeper.keeper()) revert NotKeeper();
        if (amountOut == 0) revert ZeroAmount();
        uint256 newUsed = _consumeCap(user, amountOut); // amountOut <= uint96 cap from here on

        // the on-chain TWAP bound always applies; the keeper's bound can only tighten it
        uint256 limit = maxWethInFor(amountOut);
        if (maxWethIn < limit) limit = maxWethIn;

        uint256 vaultBefore = stable.balanceOf(address(vault));
        pending = Pending({pool: address(ethPool), user: user, source: source, amountOut: amountOut, wethLimit: limit});
        (int256 a0, int256 a1) = ethPool.swap(
            address(vault), // stable lands in the vault directly
            wethIsToken0,   // selling WETH for the stable
            -int256(amountOut),
            wethIsToken0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            ""
        );
        delete pending;

        int256 stableDelta = wethIsToken0 ? a1 : a0;
        int256 wethDelta = wethIsToken0 ? a0 : a1;
        if (stableDelta != -int256(amountOut)) revert PartialFill();
        if (wethDelta <= 0 || uint256(wethDelta) > limit) revert OverMaxWethIn();
        // credit what measurably arrived in the vault, never the pool's report
        if (stable.balanceOf(address(vault)) - vaultBefore != amountOut) revert PartialFill();

        vault.accrue(user, amountOut);
        emit Captured(user, amountOut, newUsed);
        emit CapturedFrom(user, source, uint256(wethDelta), amountOut);
    }

    /// Pays the pool the WETH it is owed for the pending swap, after checking
    /// the fill and the bound. The bound is consumed in storage, so however
    /// many times the pool calls back within one swap, the payments add up to
    /// at most the limit set before the swap. Runs inside ethPool.swap only.
    function _paySwap(int256 a0, int256 a1) internal {
        Pending storage p = pending;
        address pool = p.pool;
        if (pool == address(0) || msg.sender != pool || msg.sender != address(ethPool)) revert BadCallback();

        int256 stableDelta = wethIsToken0 ? a1 : a0;
        int256 wethDelta = wethIsToken0 ? a0 : a1;
        if (stableDelta != -int256(p.amountOut)) revert PartialFill();
        if (wethDelta <= 0) revert BadCallback();
        uint256 owed = uint256(wethDelta);
        uint256 limit = p.wethLimit;
        if (owed > limit) revert OverMaxWethIn();
        p.wethLimit = limit - owed; // aggregate bound per swap (audit L004)

        uint8 source = p.source;
        address user = p.user;
        if (source == 1) {
            // wallet WETH goes straight to the pool; this contract never holds it
            IERC20(address(weth)).safeTransferFrom(user, msg.sender, owed);
        } else if (source == 2) {
            uint256 bal = ethBalance[user];
            if (owed > bal) revert InsufficientEthBalance();
            ethBalance[user] = bal - owed;
            IERC20(address(weth)).safeTransfer(msg.sender, owed);
        } else {
            revert BadCallback();
        }
    }
}
