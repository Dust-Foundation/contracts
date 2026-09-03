// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

/// WETH9 surface: the ERC-20 plus wrap/unwrap. Robinhood Chain's WETH is an
/// upgradeable L2 WETH behind a proxy, but it exposes the standard
/// deposit()/withdraw(uint256) pair and pays unwrapped ETH back to msg.sender.
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
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

    /// Oracle: cumulative tick / seconds-per-liquidity at each `secondsAgos`.
    /// Reverts ("OLD") when the pool's observation buffer does not reach back
    /// that far; callers that depend on it must fail closed.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    /// Permissionless: grows the oracle buffer. Anyone may pay for it.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

interface IDustVault {
    function accrue(address user, uint256 amount) external;
    function debitAccrued(address user, uint256 amount) external;
    function reaccrue(address user, uint256 amount) external;
    function creditTokens(address user, address token, uint256 tokenAmount, uint256 stableSpent) external;
    function accruedStable(address user) external view returns (uint256);
    function tokenBalanceOf(address user, address token) external view returns (uint256);
}
