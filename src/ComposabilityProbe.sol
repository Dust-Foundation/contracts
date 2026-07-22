// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @title ComposabilityProbe
/// @notice M0 go/no-go probe: proves whether an arbitrary third-party contract can
///         receive, hold, pull, send, and swap Robinhood Chain Stock Tokens.
///         Throwaway code; never deployed to mainnet.
contract ComposabilityProbe {
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Pull tokens from the caller (requires prior approve). This is the
    ///         sweeper's core motion: transferFrom a user wallet into protocol custody.
    function pull(address token, uint256 amount) external onlyOwner {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull failed");
    }

    /// @notice Send tokens held by this contract to any address.
    function push(address token, address to, uint256 amount) external onlyOwner {
        require(IERC20(token).transfer(to, amount), "push failed");
    }

    /// @notice Exact-input swap directly against a Uniswap v3 pool, no router.
    ///         Proves a third-party contract can be the counterparty on Stock Token pools.
    function swapExactIn(address pool, bool zeroForOne, uint256 amountIn)
        external
        onlyOwner
        returns (int256 amount0, int256 amount1)
    {
        (amount0, amount1) = IUniswapV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(pool)
        );
    }

    /// @dev Pays the pool the owed input token during a swap.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _payPool(amount0Delta, amount1Delta, data);
    }

    /// @dev Same, for Synthra (v3 fork) pools — testnet's deep Stock Token pools use this name.
    function synthraV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        _payPool(amount0Delta, amount1Delta, data);
    }

    function _payPool(int256 amount0Delta, int256 amount1Delta, bytes calldata data) internal {
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "callback not pool");
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(pool).token0()).transfer(pool, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(pool).token1()).transfer(pool, uint256(amount1Delta));
        }
    }
}
