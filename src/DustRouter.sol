// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20, IV3Pool, IV3PoolMeta, IV3Factory, IDustVault} from "./interfaces/IDust.sol";
import {SafeTransfer} from "./libraries/SafeTransfer.sol";

/// @title DustRouter (v3)
/// @notice The front door: executes a user's stable -> token swap and captures
///         the round-up in the same transaction. Holds no funds between txs
///         and has no admin functions at all.
///
/// Round-up rule (deterministic): round the stable amount actually SPENT up to
/// the next multiple of `granularity` whole stable units; the difference, times
/// the user's chosen multiplier, is accrued to their vault position. An exact
/// multiple rounds to zero (nothing owed).
///
/// v3 settlement (audit H001):
///  - Only pools the canonical factory acknowledges for (stable, tokenOut, fee)
///    are accepted, so a caller cannot route through a contract of their own.
///  - The stable consumed is MEASURED as this contract's balance delta across
///    the swap, and the tokens received are measured at the caller. A thin pool
///    that fills only part of `amountIn` leaves the rest here for exactly one
///    step: it is refunded to the caller before the round-up is computed.
///  - The swap callback may pay the pool at most `amountIn` in aggregate,
///    however many times it is invoked.
///  - minOut and the measured output must both be non-zero.
contract DustRouter {
    using SafeTransfer for IERC20;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IERC20 public immutable stable;
    IDustVault public immutable vault;
    /// 1 whole stable unit (1e6 for USDG mainnet, 1e18 for the testnet USDC)
    uint256 public immutable unit;
    /// Canonical Uniswap v3 factory; the only source of accepted pools.
    IV3Factory public immutable factory;

    address private expectedPool;
    /// Stable the in-flight swap may still pay its pool (set to amountIn
    /// before the swap, decremented per callback, cleared after).
    uint256 private remaining;
    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert BadCallback();
        locked = 2;
        _;
        locked = 1;
    }

    /// `stableIn` is the stable actually consumed by the pool (measured), not
    /// the amount the caller offered.
    event SwapWithRoundUp(
        address indexed user,
        address indexed tokenOut,
        uint256 stableIn,
        uint256 tokensOut,
        uint256 roundUp
    );

    error BadParams();
    error BadPool();
    error ZeroMinOut();
    error ZeroOutput();
    error NothingSpent();
    error SlippageExceeded();
    error OverCommitted();
    error BadCallback();
    error TransferFailed();

    constructor(IERC20 _stable, IDustVault _vault, uint256 _unit, IV3Factory _factory) {
        if (address(_stable) == address(0) || address(_vault) == address(0) || address(_factory) == address(0)) {
            revert BadParams();
        }
        stable = _stable;
        vault = _vault;
        unit = _unit;
        factory = _factory;
    }

    /// Pure round-up math, exposed for testing and UIs.
    /// @param granularity whole stable units to round up to (1..100)
    /// @param multiplier  boost factor (1..10)
    function roundUpAmount(uint256 amountIn, uint256 granularity, uint256 multiplier)
        public
        view
        returns (uint256)
    {
        if (granularity == 0 || granularity > 100 || multiplier == 0 || multiplier > 10) revert BadParams();
        uint256 step = granularity * unit;
        uint256 rem = amountIn % step;
        if (rem == 0) return 0;
        return (step - rem) * multiplier;
    }

    /// Swap up to `amountIn` stable for `tokenOut` on `pool`, sending tokens
    /// straight to the caller, refunding any stable the pool did not consume,
    /// and accruing the round-up on the amount actually spent to the caller's
    /// vault position. The caller's approval must cover amountIn plus the
    /// round-up on the spent amount (at most granularity * unit * multiplier).
    function swapWithRoundUp(
        address pool,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 granularity,
        uint256 multiplier
    ) external nonReentrant returns (uint256 tokensOut, uint256 roundUp) {
        if (amountIn == 0 || amountIn > uint256(type(int256).max)) revert BadParams();
        if (granularity == 0 || granularity > 100 || multiplier == 0 || multiplier > 10) revert BadParams();
        if (minOut == 0) revert ZeroMinOut();

        // the pool must pair the stable with exactly the token the user asked for
        address t0 = IV3Pool(pool).token0();
        address t1 = IV3Pool(pool).token1();
        bool zeroForOne = t0 == address(stable);
        if (!((zeroForOne && t1 == tokenOut) || (t1 == address(stable) && t0 == tokenOut))) revert BadParams();
        if (tokenOut == address(stable)) revert BadParams();
        // provenance: the canonical factory must resolve this pair + fee to this very pool
        if (factory.getPool(t0, t1, IV3PoolMeta(pool).fee()) != pool) revert BadPool();

        // pull the offered amount here; the callback pays the pool out of it
        stable.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 stableBefore = stable.balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(msg.sender);

        expectedPool = pool;
        remaining = amountIn;
        IV3Pool(pool).swap(
            msg.sender, // tokens go straight to the user
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(pool)
        );
        expectedPool = address(0);
        remaining = 0;

        // measure, never trust the pool's report
        uint256 spent = stableBefore - stable.balanceOf(address(this));
        if (spent == 0) revert NothingSpent();
        tokensOut = IERC20(tokenOut).balanceOf(msg.sender) - outBefore;
        if (tokensOut == 0) revert ZeroOutput();
        if (tokensOut < minOut) revert SlippageExceeded();

        // a partial fill leaves the unspent stable here: hand it straight back
        uint256 refund = amountIn - spent;
        if (refund > 0) stable.safeTransfer(msg.sender, refund);

        // round up what was actually spent, pull it straight into the vault
        roundUp = roundUpAmount(spent, granularity, multiplier);
        if (roundUp > 0) {
            stable.safeTransferFrom(msg.sender, address(vault), roundUp);
            vault.accrue(msg.sender, roundUp);
        }

        emit SwapWithRoundUp(msg.sender, tokenOut, spent, tokensOut, roundUp);
    }

    /// Pays the in-flight pool what it reports as owed, bounded in aggregate by
    /// the amount the caller committed to this swap.
    function _payPool(int256 a0, int256 a1, bytes calldata data) internal {
        address pool = abi.decode(data, (address));
        if (msg.sender != pool || pool != expectedPool) revert BadCallback();
        int256 owed = IV3Pool(pool).token0() == address(stable) ? a0 : a1;
        if (owed > 0) {
            uint256 due = uint256(owed);
            if (due > remaining) revert OverCommitted();
            remaining -= due;
            stable.safeTransfer(pool, due);
        }
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _payPool(a0, a1, data);
    }

    function synthraV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _payPool(a0, a1, data);
    }
}
