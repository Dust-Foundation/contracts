// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20, IV3Pool, IDustVault} from "./interfaces/IDust.sol";

/// @title DustSweeper
/// @notice Converts users' accrued stable round-ups into the basket.
///
/// Rules of the road:
///  - The basket is a fixed, published list of (token, pool, weight). Changing
///    it goes through propose -> timelock delay -> execute, all onchain, and
///    bumps basketVersion so in-flight sweeps can't be mispriced by a swap.
///  - Deterministic execution: same accrued amount, same weights, every time.
///    Nobody at Dust chooses what a sweep buys. Price is bounded by a caller-
///    supplied minOut that must be non-zero (no "buy at any price").
///  - Leg isolation: each basket leg is bought in its own isolated call. If a
///    leg reverts (issuer paused/blocked the token, thin pool, etc.) its stable
///    is returned to the user's accrued balance instead of bricking the sweep.
///  - Partial fills credit only the stable actually spent; the remainder is
///    returned to the user. The sweeper never keeps user stable between txs.
///  - Pausing stops NEW sweeps only. It cannot touch the vault or withdrawals.
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
    address public pendingOwner;
    address public keeper;
    bool public paused;
    uint256 public minSweepAmount;
    uint256 public basketVersion;

    BasketLeg[] public basket;

    BasketLeg[] public pendingBasket;
    uint256 public pendingEta;

    // transient callback guard (plain storage; reset within the same tx)
    address private expectedPool;

    event BasketProposed(uint256 eta);
    event BasketExecuted(uint256 newVersion);
    event Swept(address indexed user, uint256 stableIn, uint256 invested, uint256 returned);
    event LegBought(address indexed user, address indexed token, uint256 stableIn, uint256 tokensOut);
    event LegSkipped(address indexed user, address indexed token, uint256 stableSlice);
    event PausedSet(bool paused);
    event KeeperSet(address keeper);
    event MinSweepSet(uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    error NotAuthorized();
    error Paused();
    error BadBasket();
    error TimelockNotReady();
    error NothingPending();
    error BelowMinimum();
    error SlippageExceeded();
    error ZeroOutput();
    error ZeroMinOut();
    error BadCallback();
    error LengthMismatch();
    error StaleBasket();
    error ZeroAddress();
    error OnlySelf();

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
        unchecked { basketVersion++; }
        emit BasketExecuted(basketVersion);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setKeeper(address k) external onlyOwner {
        if (k == address(0)) revert ZeroAddress();
        keeper = k;
        emit KeeperSet(k);
    }

    function setMinSweepAmount(uint256 a) external onlyOwner {
        minSweepAmount = a;
        emit MinSweepSet(a);
    }

    /// Two-step ownership transfer: prevents bricking governance on a typo or
    /// a transfer to a wrong/zero address.
    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotAuthorized();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ---- sweeping ----

    /// @param user            whose accrued stable to sweep
    /// @param minOuts         per-leg minimum token out; MUST be non-zero for
    ///                        every leg with a non-zero stable slice. The
    ///                        caller (user or keeper) is responsible for
    ///                        quoting these against a fair price.
    /// @param expectedVersion basketVersion the minOuts were quoted against;
    ///                        reverts if the basket changed underneath.
    function sweep(address user, uint256[] calldata minOuts, uint256 expectedVersion) external {
        if (paused) revert Paused();
        if (msg.sender != user && msg.sender != keeper) revert NotAuthorized();
        if (expectedVersion != basketVersion) revert StaleBasket();
        uint256 legs = basket.length;
        if (minOuts.length != legs) revert LengthMismatch();

        uint256 amount = vault.accruedStable(user);
        if (amount == 0 || amount < minSweepAmount) revert BelowMinimum();
        vault.debitAccrued(user, amount); // sweeper now holds `amount` stable

        uint256 invested;
        uint256 allocated;
        for (uint256 i; i < legs; i++) {
            BasketLeg memory leg = basket[i];
            uint256 legIn = i == legs - 1 ? amount - allocated : (amount * leg.weightBps) / 10_000;
            allocated += legIn;
            if (legIn == 0) continue;
            if (minOuts[i] == 0) revert ZeroMinOut();

            // isolated: a reverting leg (paused/blocked token, thin pool) is
            // skipped, not fatal. Returns the stable actually consumed.
            try this.buyLeg(user, leg, legIn, minOuts[i]) returns (uint256 spent) {
                invested += spent;
            } catch {
                emit LegSkipped(user, leg.token, legIn);
            }
        }

        // return everything not invested (skipped legs + partial-fill dust) to
        // the user's withdrawable accrued balance. Sweeper keeps nothing.
        uint256 leftover = amount - invested;
        if (leftover > 0) {
            if (!stable.transfer(address(vault), leftover)) revert BadCallback();
            vault.reaccrue(user, leftover);
        }
        emit Swept(user, amount, invested, leftover);
    }

    /// One basket leg, isolated behind an external self-call so try/catch can
    /// contain its reverts. Credits the user's vault position and returns the
    /// stable actually spent (may be < legIn on a partial fill).
    function buyLeg(address user, BasketLeg calldata leg, uint256 legIn, uint256 minOut)
        external
        returns (uint256 spent)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 stableBefore = stable.balanceOf(address(this));

        uint256 got = _buy(leg.pool, leg.token, legIn);
        if (got == 0) revert ZeroOutput();
        if (got < minOut) revert SlippageExceeded();

        // measure what the swap actually consumed (exact-input may partial-fill)
        spent = stableBefore - stable.balanceOf(address(this));

        if (!IERC20(leg.token).transfer(address(vault), got)) revert BadCallback();
        vault.creditTokens(user, leg.token, got, spent);
        emit LegBought(user, leg.token, spent, got);
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
        out = uint256(-tokenDelta);
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

    /// Validate a basket: non-zero entries, count 1..20, weights sum to 10_000,
    /// and every pool actually pairs `stable` with that leg's token.
    function _validate(BasketLeg[] memory b) internal view {
        uint256 n = b.length;
        if (n == 0 || n > 20) revert BadBasket();
        uint256 total;
        for (uint256 i; i < n; i++) {
            BasketLeg memory leg = b[i];
            if (leg.token == address(0) || leg.pool == address(0)) revert BadBasket();
            total += leg.weightBps;
            address t0 = IV3Pool(leg.pool).token0();
            address t1 = IV3Pool(leg.pool).token1();
            // exactly one side is the stable, the other is the leg's token
            bool ok = (t0 == address(stable) && t1 == leg.token)
                || (t1 == address(stable) && t0 == leg.token);
            if (!ok) revert BadBasket();
        }
        if (total != 10_000) revert BadBasket();
    }
}
