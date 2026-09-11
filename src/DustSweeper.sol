// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20, IV3Pool, IV3PoolMeta, IV3Factory, IDustVault} from "./interfaces/IDust.sol";
import {SafeTransfer} from "./libraries/SafeTransfer.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {FullMath} from "./libraries/FullMath.sol";

/// @title DustSweeper (v3)
/// @notice Converts each user's accrued stable round-ups into THEIR OWN basket.
///
/// Trust model (stronger than a single global basket):
///  - The owner curates a MENU of buyable stocks (token -> pool paired with the
///    stable). Only pools the canonical Uniswap v3 factory acknowledges can be
///    listed. That is the only basket-related power the owner has.
///  - Each user composes their own basket by choosing stocks from the menu and
///    setting their own weights, and can clear it at any time (clearBasket),
///    which stops all sweeps for them. The owner cannot change what a user's
///    money buys; only the user can. There is no discretion over user
///    allocations.
///  - Every sweep executes a quote the caller pins: the accrued amount it was
///    priced against (maxAmount), the pool per leg, the fee rate and the
///    user's basket nonce. If any of them moved, the sweep reverts instead of
///    executing different economics. The nonce is consumed by every sweep, so
///    a quote can never be replayed.
///  - On-chain price floor: each leg must deliver at least the pool's own
///    10-minute TWAP output less MAX_SWEEP_SLIPPAGE_BPS, whatever minOut the
///    caller passed. minOut can only tighten that floor. A pool without
///    oracle history cannot be swept into (the leg is skipped).
///  - Per-user rate limit: a user is swept at most once per MIN_SWEEP_INTERVAL.
///  - Leg isolation: each leg buys in its own isolated call; a failing leg
///    (paused/blocked/delisted token, thin pool, no oracle, price below the
///    floor) is skipped and its stable returned to the user, never bricking
///    the sweep. A leg can never spend more than its own slice.
///  - Partial fills credit only the stable actually spent and the tokens the
///    vault actually received; the rest is returned.
///  - Fee: feeBps of the stable actually INVESTED, charged after the legs ran.
///    Stable that comes back to the user carries no fee and is never re-taxed,
///    so the lifetime fee on any unit of round-up is at most feeBps. Leg sizes
///    depend on feeBps alone (pinned by the quote), never on the treasury. If
///    there is no treasury, or it cannot receive the fee, the fee for that
///    sweep is waived and returned to the user rather than bricking settlement.
///  - Known limitation (accepted): when a leg is persistently skipped, its
///    slice returns to the user's accrued balance and is re-split across the
///    whole basket on the next sweep, so the realized allocation drifts toward
///    the buyable legs. The user can withdraw accrued stable at any time.
///  - Pausing stops NEW sweeps only. It cannot touch the vault or withdrawals.
contract DustSweeper {
    using SafeTransfer for IERC20;

    struct Leg {
        address token;    // stock token (pool looked up from the menu at sweep time)
        uint16 weightBps; // out of 10_000
    }

    /// Fee is a percentage of each round-up actually invested, skimmed at sweep
    /// time to the treasury. Hard-capped in code so no owner can ever set a
    /// predatory rate.
    uint16 public constant MAX_FEE_BPS = 500; // 5% ceiling, immutable
    /// Hard floor on every leg: at least the pool TWAP output less 3%.
    uint16 public constant MAX_SWEEP_SLIPPAGE_BPS = 300;
    /// TWAP window in seconds.
    uint32 public constant TWAP_WINDOW = 600;
    /// A user is swept at most once per this many seconds.
    uint32 public constant MIN_SWEEP_INTERVAL = 300;

    IERC20 public immutable stable;
    IDustVault public immutable vault;
    /// Canonical Uniswap v3 factory; listStock accepts only its pools.
    IV3Factory public immutable factory;

    address public owner;
    address public pendingOwner;
    address public keeper;
    address public treasury;
    uint16 public feeBps = 100; // 1% at launch
    bool public paused;
    uint256 public minSweepAmount;

    // owner-curated menu of buyable stocks: token -> pool (paired with stable)
    mapping(address => address) public poolFor;
    address[] public menu;
    mapping(address => uint256) private menuIndex; // 1-based, 0 = not listed

    // per-user basket + a nonce that bumps whenever the basket changes or is swept
    mapping(address => Leg[]) private _basket;
    mapping(address => uint256) public basketNonce;
    /// timestamp of the user's last sweep (rate limit)
    mapping(address => uint256) public lastSweepAt;

    // transient callback guard (plain storage; reset within the same tx)
    address private expectedPool;
    /// stable the in-flight leg may still pay its pool (its own slice, at most)
    uint256 private remaining;

    event StockListed(address indexed token, address indexed pool);
    event StockDelisted(address indexed token);
    event BasketSet(address indexed user, uint256 nonce, uint256 legs);
    event BasketCleared(address indexed user, uint256 nonce);
    /// `returned` is the stable re-accrued to the user (excludes the fee).
    event Swept(address indexed user, uint256 stableIn, uint256 invested, uint256 fee, uint256 returned);
    event LegBought(address indexed user, address indexed token, uint256 stableIn, uint256 tokensOut);
    event LegSkipped(address indexed user, address indexed token, uint256 stableSlice);
    event PausedSet(bool paused);
    event KeeperSet(address keeper);
    event MinSweepSet(uint256 amount);
    event TreasurySet(address treasury);
    event FeeSet(uint16 feeBps);
    event FeeCharged(address indexed user, uint256 amount);
    /// The treasury refused the fee transfer; the amount went back to the user.
    event FeeSkipped(address indexed user, uint256 amount);
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
    error AmountAboveQuote();
    error PoolMismatch();
    error FeeChanged();
    error TooSoon();
    error SlippageExceeded();
    error ZeroOutput();
    error ZeroMinOut();
    error OverCommitted();
    error BadCallback();
    error LengthMismatch();
    error StaleBasket();
    error ZeroAddress();
    error OnlySelf();
    error FeeTooHigh();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(IERC20 _stable, IDustVault _vault, address _treasury, IV3Factory _factory) {
        if (address(_stable) == address(0) || address(_vault) == address(0) || address(_factory) == address(0)) {
            revert ZeroAddress();
        }
        stable = _stable;
        vault = _vault;
        factory = _factory;
        owner = msg.sender;
        keeper = msg.sender;
        treasury = _treasury; // may be zero at deploy; the fee is waived back to users until set
    }

    // ---- menu curation (owner) ----

    /// Add a stock to the buyable menu. The pool must pair the stable with this
    /// token AND be the canonical factory's pool for that pair and fee tier, so
    /// a lookalike pool can never be listed (audit L002).
    function listStock(address token, address pool) external onlyOwner {
        if (token == address(0) || pool == address(0)) revert BadListing();
        if (menuIndex[token] != 0) revert AlreadyListed();
        address t0 = IV3Pool(pool).token0();
        address t1 = IV3Pool(pool).token1();
        bool ok = (t0 == address(stable) && t1 == token) || (t1 == address(stable) && t0 == token);
        if (!ok) revert BadListing();
        if (factory.getPool(t0, t1, IV3PoolMeta(pool).fee()) != pool) revert BadListing();
        poolFor[token] = pool;
        menu.push(token);
        menuIndex[token] = menu.length; // 1-based
        emit StockListed(token, pool);
    }

    /// Remove a stock from the menu. Does NOT touch anyone's vault holdings:
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
    /// a user's allocation is ever set: by the user.
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

    /// Revoke the sweeper's standing authority over your accrued stable: with
    /// no basket, sweep reverts NoBasket for you until you set one again. Your
    /// vault balances are untouched and stay withdrawable (audit M003).
    function clearBasket() external {
        delete _basket[msg.sender];
        unchecked { basketNonce[msg.sender]++; }
        emit BasketCleared(msg.sender, basketNonce[msg.sender]);
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

    function setTreasury(address t) external onlyOwner {
        treasury = t;
        emit TreasurySet(t);
    }

    function setFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = bps;
        emit FeeSet(bps);
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

    /// Execute a pinned quote for `user`. Reverts if anything the quote depended
    /// on has moved (audit M004): the accrued amount grew past `maxAmount`
    /// (AmountAboveQuote), a listed leg's pool differs from `pools[i]`
    /// (PoolMismatch), the fee rate differs from `expectedFeeBps` (FeeChanged),
    /// the basket changed or was already swept against this nonce
    /// (StaleBasket), or the user was swept less than MIN_SWEEP_INTERVAL ago
    /// (TooSoon). A delisted leg (poolFor == 0) is skipped regardless of
    /// pools[i] and minOuts[i].
    ///
    /// Slicing: the investable amount is amount * 10000 / (10000 + feeBps),
    /// split by weight (last leg takes the remainder), so the fee on a full
    /// fill fits exactly. It depends on feeBps only, which the quote pins, so
    /// no owner action (including setTreasury) can resize a leg between quote
    /// and execution. Settlement: fee = invested * feeBps / 10000 is sent to
    /// the treasury; amount - invested - fee is re-accrued to the user. With
    /// no treasury, or one that refuses the transfer, fee is 0 for that sweep.
    ///
    /// @param user            whose accrued stable to sweep into their basket
    /// @param maxAmount       the accrued amount the quote was priced against;
    ///                        reverts if the live balance is above it
    /// @param pools           expected pool per leg (poolFor at quote time)
    /// @param minOuts         per-leg minimum token out; MUST be non-zero for
    ///                        every listed leg with a non-zero stable slice.
    ///                        The on-chain TWAP floor applies on top.
    /// @param expectedNonce   user's basketNonce the quote was built against
    /// @param expectedFeeBps  feeBps the quote was built against
    function sweep(
        address user,
        uint256 maxAmount,
        address[] calldata pools,
        uint256[] calldata minOuts,
        uint256 expectedNonce,
        uint16 expectedFeeBps
    ) external {
        if (paused) revert Paused();
        if (msg.sender != user && msg.sender != keeper) revert NotAuthorized();

        Leg[] storage legs = _basket[user];
        uint256 n = legs.length;
        if (n == 0) revert NoBasket();
        if (expectedNonce != basketNonce[user]) revert StaleBasket();
        if (minOuts.length != n || pools.length != n) revert LengthMismatch();
        if (expectedFeeBps != feeBps) revert FeeChanged();
        uint256 last = lastSweepAt[user];
        if (last != 0 && block.timestamp < last + MIN_SWEEP_INTERVAL) revert TooSoon();

        uint256 amount = vault.accruedStable(user);
        if (amount == 0 || amount < minSweepAmount) revert BelowMinimum();
        if (amount > maxAmount) revert AmountAboveQuote();

        // consume the quote: a nonce is good for exactly one sweep
        unchecked { basketNonce[user]++; }
        lastSweepAt[user] = block.timestamp;

        vault.debitAccrued(user, amount); // sweeper now holds `amount` stable

        // reserve room for the fee on what gets invested; nothing is charged yet.
        // expectedFeeBps == feeBps was checked above, so the slicing is exactly
        // what the quote priced (audit M004); the treasury plays no part here.
        uint16 fb = expectedFeeBps;
        uint256 investable = fb == 0 ? amount : (amount * 10_000) / (10_000 + fb);

        uint256 invested;
        uint256 allocated;
        for (uint256 i; i < n; i++) {
            Leg memory leg = legs[i];
            uint256 legIn = i == n - 1 ? investable - allocated : (investable * leg.weightBps) / 10_000;
            allocated += legIn;
            if (legIn == 0) continue;

            address pool = poolFor[leg.token];
            if (pool == address(0)) {
                // token delisted since the user set their basket -> skip cleanly
                emit LegSkipped(user, leg.token, legIn);
                continue;
            }
            if (pools[i] != pool) revert PoolMismatch();
            if (minOuts[i] == 0) revert ZeroMinOut();

            try this.buyLeg(user, leg.token, pool, legIn, minOuts[i]) returns (uint256 spent) {
                invested += spent;
            } catch {
                emit LegSkipped(user, leg.token, legIn);
            }
        }

        // settle: fee on what was invested, everything else back to the user.
        // The sweeper keeps nothing: amount = invested + fee + returned.
        uint256 fee = (fb == 0 || invested == 0) ? 0 : (invested * fb) / 10_000;
        if (fee > 0) {
            address to = treasury;
            if (to == address(0)) {
                fee = 0; // no treasury yet: the reserve goes back to the user
            } else if (stable.tryTransfer(to, fee)) {
                emit FeeCharged(user, fee);
            } else {
                // a treasury that cannot receive must not brick settlement (audit L001)
                emit FeeSkipped(user, fee);
                fee = 0;
            }
        }
        uint256 leftover = amount - invested - fee;
        if (leftover > 0) {
            stable.safeTransfer(address(vault), leftover);
            vault.reaccrue(user, leftover);
        }
        emit Swept(user, amount, invested, fee, leftover);
    }

    /// One basket leg, isolated behind an external self-call so try/catch can
    /// contain its reverts. Returns the stable actually spent (< legIn on a
    /// partial fill). Reverts (and is therefore skipped by sweep) if the pool
    /// has no oracle history, the output is below max(minOut, TWAP floor), or
    /// the pool tried to take more than the leg's slice.
    function buyLeg(address user, address token, address pool, uint256 legIn, uint256 minOut)
        external
        returns (uint256 spent)
    {
        if (msg.sender != address(this)) revert OnlySelf();

        // the user-authorised floor applies whatever the caller passed (audit M003)
        uint256 floor = twapFloor(pool, legIn);
        if (floor > minOut) minOut = floor;

        uint256 stableBefore = stable.balanceOf(address(this));
        uint256 got = _buy(pool, token, legIn);
        if (got == 0) revert ZeroOutput();
        if (got < minOut) revert SlippageExceeded();

        spent = stableBefore - stable.balanceOf(address(this));
        if (spent > legIn) revert SlippageExceeded(); // audit L002

        // credit what the vault actually received, not what the pool reported (audit M002)
        uint256 vaultBefore = IERC20(token).balanceOf(address(vault));
        IERC20(token).safeTransfer(address(vault), got);
        uint256 credited = IERC20(token).balanceOf(address(vault)) - vaultBefore;
        if (credited == 0) revert ZeroOutput();
        vault.creditTokens(user, token, credited, spent);
        emit LegBought(user, token, spent, credited);
    }

    // ---- views ----

    /// Token output `stableIn` would buy at the pool's TWAP_WINDOW arithmetic-
    /// mean-tick price (no pool fee, no price impact). Reverts if the pool's
    /// oracle cannot serve the window (fail closed).
    function expectedOutAtTwap(address pool, uint256 stableIn) public view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        (int56[] memory tickCumulatives,) = IV3Pool(pool).observe(ago);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 window = int56(uint56(TWAP_WINDOW));
        int24 meanTick = int24(delta / window);
        // round toward negative infinity, as Uniswap's OracleLibrary does
        if (delta < 0 && (delta % window != 0)) meanTick--;

        uint160 sqrtP = TickMath.getSqrtRatioAtTick(meanTick);
        bool stableIsToken0 = IV3Pool(pool).token0() == address(stable);
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtP) * sqrtP; // token1 per token0, Q192
            return stableIsToken0
                ? FullMath.mulDiv(stableIn, ratioX192, 1 << 192)
                : FullMath.mulDiv(stableIn, 1 << 192, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 64);
        return stableIsToken0
            ? FullMath.mulDiv(stableIn, ratioX128, 1 << 128)
            : FullMath.mulDiv(stableIn, 1 << 128, ratioX128);
    }

    /// The least a leg of `stableIn` on `pool` may deliver: TWAP output less
    /// MAX_SWEEP_SLIPPAGE_BPS.
    function twapFloor(address pool, uint256 stableIn) public view returns (uint256) {
        return FullMath.mulDiv(expectedOutAtTwap(pool, stableIn), 10_000 - MAX_SWEEP_SLIPPAGE_BPS, 10_000);
    }

    // ---- internals ----

    /// Exact-input swap of `stableIn` on `pool`; returns the tokens that
    /// actually arrived here (measured, not the pool's report).
    function _buy(address pool, address token, uint256 stableIn) internal returns (uint256 out) {
        bool zeroForOne = IV3Pool(pool).token0() == address(stable);
        uint256 tokBefore = IERC20(token).balanceOf(address(this));
        expectedPool = pool;
        remaining = stableIn;
        IV3Pool(pool).swap(
            address(this),
            zeroForOne,
            int256(stableIn),
            zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(pool)
        );
        expectedPool = address(0);
        remaining = 0;
        out = IERC20(token).balanceOf(address(this)) - tokBefore;
    }

    /// Pays the in-flight pool what it reports as owed, bounded in aggregate by
    /// the leg's own slice.
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

    /// Robinhood Chain testnet pools are a Synthra v3 fork with a renamed callback.
    function synthraV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _payPool(a0, a1, data);
    }
}
