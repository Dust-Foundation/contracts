// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20, IV3Pool, IDustVault} from "./interfaces/IDust.sol";

/// @title DustSweeper
/// @notice Converts each user's accrued stable round-ups into THEIR OWN basket.
///
/// Trust model (stronger than a single global basket):
///  - The owner curates a MENU of buyable stocks (token -> pool paired with the
///    stable). That is the only basket-related power the owner has.
///  - Each user composes their own basket by choosing stocks from the menu and
///    setting their own weights. The owner cannot change what a user's money
///    buys — only the user can. There is no discretion over user allocations.
///  - Deterministic execution: same accrued amount + same user basket -> same
///    buys, every time. Price is bounded by a caller-supplied nonzero minOut.
///  - Leg isolation: each leg buys in its own isolated call; a failing leg
///    (paused/blocked/delisted token, thin pool) is skipped and its stable
///    returned to the user, never bricking the sweep.
///  - Partial fills credit only the stable actually spent; the rest is returned.
///  - Pausing stops NEW sweeps only. It cannot touch the vault or withdrawals.
contract DustSweeper {
    struct Leg {
        address token;    // stock token (pool looked up from the menu at sweep time)
        uint16 weightBps; // out of 10_000
    }

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IERC20 public immutable stable;
    IDustVault public immutable vault;

    address public owner;
    address public pendingOwner;
    address public keeper;
    bool public paused;
    uint256 public minSweepAmount;

    // owner-curated menu of buyable stocks: token -> pool (paired with stable)
    mapping(address => address) public poolFor;
    address[] public menu;
    mapping(address => uint256) private menuIndex; // 1-based, 0 = not listed

    // per-user basket + a nonce that bumps whenever the user changes it
    mapping(address => Leg[]) private _basket;
    mapping(address => uint256) public basketNonce;

    // transient callback guard (plain storage; reset within the same tx)
    address private expectedPool;

    event StockListed(address indexed token, address indexed pool);
    event StockDelisted(address indexed token);
    event BasketSet(address indexed user, uint256 nonce, uint256 legs);
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
    error BadListing();
    error AlreadyListed();
    error NotListed();
    error BadBasket();
    error NoBasket();
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

    constructor(IERC20 _stable, IDustVault _vault) {
        stable = _stable;
        vault = _vault;
        owner = msg.sender;
        keeper = msg.sender;
    }

    // ---- menu curation (owner) ----

    /// Add a stock to the buyable menu. Validates the pool actually pairs the
    /// stable with this token (mirrors the router's pairing check).
    function listStock(address token, address pool) external onlyOwner {
        if (token == address(0) || pool == address(0)) revert BadListing();
        if (menuIndex[token] != 0) revert AlreadyListed();
        address t0 = IV3Pool(pool).token0();
        address t1 = IV3Pool(pool).token1();
        bool ok = (t0 == address(stable) && t1 == token) || (t1 == address(stable) && t0 == token);
        if (!ok) revert BadListing();
        poolFor[token] = pool;
        menu.push(token);
        menuIndex[token] = menu.length; // 1-based
        emit StockListed(token, pool);
    }

    /// Remove a stock from the menu. Does NOT touch anyone's vault holdings —
    /// users keep and can withdraw tokens they already own; this only stops new
    /// buys. A user basket still referencing it will simply skip that leg.
    function delistStock(address token) external onlyOwner {
        uint256 idx = menuIndex[token];
        if (idx == 0) revert NotListed();
        uint256 last = menu.length;
        if (idx != last) {
            address moved = menu[last - 1];
            menu[idx - 1] = moved;
            menuIndex[moved] = idx;
        }
        menu.pop();
        menuIndex[token] = 0;
        poolFor[token] = address(0);
        emit StockDelisted(token);
    }

    function menuLength() external view returns (uint256) {
        return menu.length;
    }

    // ---- per-user basket ----

    /// Compose your basket from the menu. Weights are out of 10_000 and must sum
    /// to exactly 10_000. Every token must be on the menu. This is the only way
    /// a user's allocation is ever set — by the user.
    function setBasket(address[] calldata tokens, uint16[] calldata weights) external {
        uint256 n = tokens.length;
        if (n == 0 || n > 20 || weights.length != n) revert BadBasket();
        delete _basket[msg.sender];
        uint256 total;
        for (uint256 i; i < n; i++) {
            address token = tokens[i];
            if (poolFor[token] == address(0)) revert NotListed();
            // reject duplicate tokens within the basket
            for (uint256 j; j < i; j++) {
                if (tokens[j] == token) revert BadBasket();
            }
            total += weights[i];
            _basket[msg.sender].push(Leg(token, weights[i]));
        }
        if (total != 10_000) revert BadBasket();
        unchecked { basketNonce[msg.sender]++; }
        emit BasketSet(msg.sender, basketNonce[msg.sender], n);
    }

    function basketOf(address user) external view returns (Leg[] memory) {
        return _basket[user];
    }

    function basketLengthOf(address user) external view returns (uint256) {
        return _basket[user].length;
    }

    // ---- admin (enumerated powers) ----

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

    /// @param user            whose accrued stable to sweep into their basket
    /// @param minOuts         per-leg minimum token out; MUST be non-zero for
    ///                        every leg with a non-zero stable slice
    /// @param expectedNonce   user's basketNonce the minOuts were quoted against
    function sweep(address user, uint256[] calldata minOuts, uint256 expectedNonce) external {
        if (paused) revert Paused();
        if (msg.sender != user && msg.sender != keeper) revert NotAuthorized();

        Leg[] storage legs = _basket[user];
        uint256 n = legs.length;
        if (n == 0) revert NoBasket();
        if (expectedNonce != basketNonce[user]) revert StaleBasket();
        if (minOuts.length != n) revert LengthMismatch();

        uint256 amount = vault.accruedStable(user);
        if (amount == 0 || amount < minSweepAmount) revert BelowMinimum();
        vault.debitAccrued(user, amount); // sweeper now holds `amount` stable

        uint256 invested;
        uint256 allocated;
        for (uint256 i; i < n; i++) {
            Leg memory leg = legs[i];
            uint256 legIn = i == n - 1 ? amount - allocated : (amount * leg.weightBps) / 10_000;
            allocated += legIn;
            if (legIn == 0) continue;
            if (minOuts[i] == 0) revert ZeroMinOut();

            address pool = poolFor[leg.token];
            if (pool == address(0)) {
                // token delisted since the user set their basket -> skip cleanly
                emit LegSkipped(user, leg.token, legIn);
                continue;
            }

            try this.buyLeg(user, leg.token, pool, legIn, minOuts[i]) returns (uint256 spent) {
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
    /// contain its reverts. Returns the stable actually spent (< legIn on a
    /// partial fill).
    function buyLeg(address user, address token, address pool, uint256 legIn, uint256 minOut)
        external
        returns (uint256 spent)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        uint256 stableBefore = stable.balanceOf(address(this));

        uint256 got = _buy(pool, token, legIn);
        if (got == 0) revert ZeroOutput();
        if (got < minOut) revert SlippageExceeded();

        spent = stableBefore - stable.balanceOf(address(this));

        if (!IERC20(token).transfer(address(vault), got)) revert BadCallback();
        vault.creditTokens(user, token, got, spent);
        emit LegBought(user, token, spent, got);
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
}
