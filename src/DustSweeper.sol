// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20, IV3Pool, IDustVault} from "./interfaces/IDust.sol";

/// @title DustSweeper
/// @notice Converts users' accrued stable round-ups into the basket.
///
/// Rules of the road:
///  - The basket is a fixed, published list of (token, pool, weight). Changing
///    it goes through propose -> timelock delay -> execute, all onchain.
///  - Deterministic execution: same accrued amount, same weights, every time.
///    Nobody at Dust chooses what a sweep buys.
///  - Pausing stops NEW sweeps only. It cannot touch the vault or withdrawals.
///  - A sweep can be triggered by the user themself, or by the keeper (batch).
contract DustSweeper {
    struct BasketLeg {
        address token;   // stock token
        address pool;    // v3-style pool paired with `stable`
        uint16 weightBps; // out of 10_000
    }

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IERC20 public immutable stable;
    IDustVault public immutable vault;
    uint256 public immutable timelockDelay;

    address public owner;
    address public keeper;
    bool public paused;
    uint256 public minSweepAmount;

    BasketLeg[] public basket;

    BasketLeg[] public pendingBasket;
    uint256 public pendingEta;

    // transient callback guard
    address private expectedPool;

    event BasketProposed(uint256 eta);
    event BasketExecuted();
    event Swept(address indexed user, uint256 stableIn);
    event LegBought(address indexed user, address indexed token, uint256 stableIn, uint256 tokensOut);
    event PausedSet(bool paused);
    event KeeperSet(address keeper);
    event MinSweepSet(uint256 amount);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotAuthorized();
    error Paused();
    error BadBasket();
    error TimelockNotReady();
    error NothingPending();
    error BelowMinimum();
    error SlippageExceeded();
    error BadCallback();
    error LengthMismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(IERC20 _stable, IDustVault _vault, uint256 _timelockDelay, BasketLeg[] memory initialBasket) {
        stable = _stable;
        vault = _vault;
        timelockDelay = _timelockDelay;
        owner = msg.sender;
        keeper = msg.sender;
        _validate(initialBasket);
        for (uint256 i; i < initialBasket.length; i++) basket.push(initialBasket[i]);
    }

    // ---- admin (enumerated powers, nothing else) ----

    function proposeBasket(BasketLeg[] calldata newBasket) external onlyOwner {
        _validate(newBasket);
        delete pendingBasket;
        for (uint256 i; i < newBasket.length; i++) pendingBasket.push(newBasket[i]);
        pendingEta = block.timestamp + timelockDelay;
        emit BasketProposed(pendingEta);
    }

    /// Anyone may execute once the delay has passed — the change was public.
    function executeBasket() external {
        if (pendingEta == 0) revert NothingPending();
        if (block.timestamp < pendingEta) revert TimelockNotReady();
        delete basket;
        for (uint256 i; i < pendingBasket.length; i++) basket.push(pendingBasket[i]);
        delete pendingBasket;
        pendingEta = 0;
        emit BasketExecuted();
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setKeeper(address k) external onlyOwner {
        keeper = k;
        emit KeeperSet(k);
    }

    function setMinSweepAmount(uint256 a) external onlyOwner {
        minSweepAmount = a;
        emit MinSweepSet(a);
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    // ---- sweeping ----

    /// @param user      whose accrued stable to sweep
    /// @param minOuts   per-leg minimum token out (slippage bound), same order as basket
    function sweep(address user, uint256[] calldata minOuts) external {
        if (paused) revert Paused();
        if (msg.sender != user && msg.sender != keeper) revert NotAuthorized();
        uint256 legs = basket.length;
        if (minOuts.length != legs) revert LengthMismatch();

        uint256 amount = vault.accruedStable(user);
        if (amount == 0 || amount < minSweepAmount) revert BelowMinimum();
        vault.debitAccrued(user, amount);

        uint256 spent;
        for (uint256 i; i < legs; i++) {
            BasketLeg memory leg = basket[i];
            // last leg gets the remainder so rounding never strands stable here
            uint256 legIn = i == legs - 1 ? amount - spent : (amount * leg.weightBps) / 10_000;
            spent += legIn;
            if (legIn == 0) continue;

            uint256 got = _buy(leg.pool, leg.token, legIn);
            if (got < minOuts[i]) revert SlippageExceeded();

            if (!IERC20(leg.token).transfer(address(vault), got)) revert BadCallback();
            vault.creditTokens(user, leg.token, got, legIn);
            emit LegBought(user, leg.token, legIn, got);
        }
        emit Swept(user, amount);
    }

    function basketLength() external view returns (uint256) {
        return basket.length;
    }

    // ---- internals ----

    function _buy(address pool, address token, uint256 stableIn) internal returns (uint256 out) {
        bool zeroForOne = IV3Pool(pool).token0() == address(stable);
        expectedPool = pool;
        (int256 a0, int256 a1) = IV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(stableIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(pool)
        );
        expectedPool = address(0);
        int256 tokenDelta = zeroForOne ? a1 : a0;
        // pool pays us the token: delta is negative from the pool's view
        out = uint256(-tokenDelta);
        // sanity: we must actually hold what the pool reported
        if (IERC20(token).balanceOf(address(this)) < out) revert BadCallback();
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

    /// Robinhood Chain testnet pools are a Synthra v3 fork with a renamed callback.
    function synthraV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _payPool(a0, a1, data);
    }

    function _validate(BasketLeg[] memory b) internal pure {
        if (b.length == 0 || b.length > 20) revert BadBasket();
        uint256 total;
        for (uint256 i; i < b.length; i++) {
            if (b[i].token == address(0) || b[i].pool == address(0)) revert BadBasket();
            total += b[i].weightBps;
        }
        if (total != 10_000) revert BadBasket();
    }
}
