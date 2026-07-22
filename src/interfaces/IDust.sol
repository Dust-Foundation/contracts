// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// Minimal Uniswap-v3-style pool surface (also matches the Synthra fork on
/// Robinhood Chain testnet; only the callback function name differs).
interface IV3Pool {
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

interface IDustVault {
    function accrue(address user, uint256 amount) external;
    function debitAccrued(address user, uint256 amount) external;
    function reaccrue(address user, uint256 amount) external;
    function creditTokens(address user, address token, uint256 tokenAmount, uint256 stableSpent) external;
    function accruedStable(address user) external view returns (uint256);
    function tokenBalanceOf(address user, address token) external view returns (uint256);
}
