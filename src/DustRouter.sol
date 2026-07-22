// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20, IV3Pool, IDustVault} from "./interfaces/IDust.sol";

/// @title DustRouter
/// @notice The front door: executes a user's stable -> token swap and captures
///         the round-up in the same transaction. Holds no funds between txs
///         and has no admin functions at all.
///
/// Round-up rule (deterministic): round the stable amount spent UP to the next
/// multiple of `granularity` whole stable units; the difference, times the
/// user's chosen multiplier, is accrued to their vault position. An exact
/// multiple rounds to zero (nothing owed).
contract DustRouter {
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IERC20 public immutable stable;
    IDustVault public immutable vault;
    /// 1 whole stable unit (1e6 for USDG mainnet, 1e18 for the testnet USDC)
    uint256 public immutable unit;

    address private expectedPool;

    event SwapWithRoundUp(
        address indexed user,
        address indexed tokenOut,
        uint256 stableIn,
        uint256 tokensOut,
        uint256 roundUp
    );

    error BadParams();
    error SlippageExceeded();
    error BadCallback();
    error TransferFailed();

    constructor(IERC20 _stable, IDustVault _vault, uint256 _unit) {
        stable = _stable;
        vault = _vault;
        unit = _unit;
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

    /// Swap `amountIn` stable for `tokenOut` on `pool`, sending tokens straight
    /// to the caller, and accrue the round-up to their vault position.
    function swapWithRoundUp(
        address pool,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 granularity,
        uint256 multiplier
    ) external returns (uint256 tokensOut, uint256 roundUp) {
        if (amountIn == 0) revert BadParams();
        roundUp = roundUpAmount(amountIn, granularity, multiplier);

        // pull swap amount to router (paid to pool in the callback)
        if (!stable.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        // pull round-up straight into the vault, then record it
        if (roundUp > 0) {
            if (!stable.transferFrom(msg.sender, address(vault), roundUp)) revert TransferFailed();
            vault.accrue(msg.sender, roundUp);
        }

        bool zeroForOne = IV3Pool(pool).token0() == address(stable);
        // the paired token must actually be what the user asked for
        address pairedToken = zeroForOne ? IV3Pool(pool).token1() : IV3Pool(pool).token0();
        if (pairedToken != tokenOut) revert BadParams();

        expectedPool = pool;
        (int256 a0, int256 a1) = IV3Pool(pool).swap(
            msg.sender, // tokens go straight to the user
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(pool)
        );
        expectedPool = address(0);

        tokensOut = uint256(-(zeroForOne ? a1 : a0));
        if (tokensOut < minOut) revert SlippageExceeded();

        emit SwapWithRoundUp(msg.sender, tokenOut, amountIn, tokensOut, roundUp);
    }

    function _payPool(int256 a0, int256 a1, bytes calldata data) internal {
        address pool = abi.decode(data, (address));
        if (msg.sender != pool || pool != expectedPool) revert BadCallback();
        int256 owed = IV3Pool(pool).token0() == address(stable) ? a0 : a1;
        if (owed > 0) {
            if (!stable.transfer(pool, uint256(owed))) revert BadCallback();
        }
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _payPool(a0, a1, data);
    }

    function synthraV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _payPool(a0, a1, data);
    }
}
