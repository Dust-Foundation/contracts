// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IERC20} from "./interfaces/IDust.sol";
import {SafeTransfer} from "./libraries/SafeTransfer.sol";

/// @title DustVault
/// @notice Custody and per-user ledger for Dust. Holds users' accrued stable
///         round-ups and the basket tokens bought with them.
///
/// Invariants this contract is built around:
///  - Accrued-stable withdrawals ALWAYS work: no pause here, no owner power that
///    can touch, freeze, or redirect a user's stable balance. (Stock-token
///    withdrawals depend on the issuer not having paused/blocked that token;
///    that residual risk is the issuer's, not Dust's — see withdrawToken.)
///  - Only the router may accrue; only the sweeper may debit accrued stable,
///    re-accrue unspent stable, and credit bought tokens. Both set exactly once.
///  - Vault balances are per-user accounting entries; no pooled shares, no
///    cross-user math, nothing to manipulate with donations.
///
/// v3 (audit response): logic unchanged; every token movement goes through
/// SafeTransfer (L003) and the compiler is pinned (L005). Known limitation,
/// accepted (L001, issuer-freeze variant): if the stablecoin issuer freezes the
/// immutable sweeper address, debitAccrued reverts and sweeping stops for
/// everyone until a redeploy; withdrawals here keep working throughout.
contract DustVault {
    using SafeTransfer for IERC20;

    IERC20 public immutable stable;
    address public owner;
    address public router;
    address public sweeper;
    address public capture;

    mapping(address => uint256) public accruedStable;
    mapping(address => mapping(address => uint256)) public tokenBalance;
    /// total stable ever swept into the basket per user (cost basis, 6/18-dec stable units)
    mapping(address => uint256) public costBasis;

    event ModulesSet(address router, address sweeper, address capture);
    event Accrued(address indexed user, uint256 amount);
    event AccruedDebited(address indexed user, uint256 amount);
    event TokensCredited(address indexed user, address indexed token, uint256 tokenAmount, uint256 stableSpent);
    event AccruedWithdrawn(address indexed user, address indexed to, uint256 amount);
    event TokensWithdrawn(address indexed user, address indexed token, address indexed to, uint256 amount);

    error NotAuthorized();
    error AlreadySet();
    error ZeroAddress();
    error InsufficientBalance();
    error TransferFailed();

    constructor(IERC20 _stable) {
        stable = _stable;
        owner = msg.sender;
    }

    /// One-shot wiring. After this, the owner has no remaining powers here.
    /// `_capture` is the outside-transaction capture module (may be zero if
    /// deployed without one).
    function setModules(address _router, address _sweeper, address _capture) external {
        if (msg.sender != owner) revert NotAuthorized();
        if (router != address(0) || sweeper != address(0)) revert AlreadySet();
        if (_router == address(0) || _sweeper == address(0)) revert ZeroAddress();
        router = _router;
        sweeper = _sweeper;
        capture = _capture;
        emit ModulesSet(_router, _sweeper, _capture);
    }

    // ---- module surface ----

    /// Router (in-app round-ups) or the capture module (outside-transaction
    /// round-ups) credits a user. Stable must already have been transferred to
    /// this vault in the same transaction (the caller does the pull).
    function accrue(address user, uint256 amount) external {
        if (msg.sender != router && (capture == address(0) || msg.sender != capture)) revert NotAuthorized();
        accruedStable[user] += amount;
        emit Accrued(user, amount);
    }

    /// Sweeper takes a user's accrued stable to buy the basket.
    function debitAccrued(address user, uint256 amount) external {
        if (msg.sender != sweeper) revert NotAuthorized();
        uint256 bal = accruedStable[user];
        if (amount > bal) revert InsufficientBalance();
        accruedStable[user] = bal - amount;
        stable.safeTransfer(sweeper, amount);
        emit AccruedDebited(user, amount);
    }

    /// Sweeper reports tokens bought for a user. Tokens must already have been
    /// transferred to this vault in the same transaction.
    function creditTokens(address user, address token, uint256 tokenAmount, uint256 stableSpent) external {
        if (msg.sender != sweeper) revert NotAuthorized();
        tokenBalance[user][token] += tokenAmount;
        costBasis[user] += stableSpent;
        emit TokensCredited(user, token, tokenAmount, stableSpent);
    }

    /// Sweeper returns stable it debited but could not invest (a skipped/paused
    /// leg, or the unspent remainder of a partial fill). Stable must already
    /// have been transferred back to this vault in the same transaction. This
    /// keeps the "never strand user stable" property: anything not turned into
    /// basket tokens returns to the user's withdrawable accrued balance.
    function reaccrue(address user, uint256 amount) external {
        if (msg.sender != sweeper) revert NotAuthorized();
        accruedStable[user] += amount;
        emit Accrued(user, amount);
    }

    // ---- user surface (always available) ----

    function withdrawAccrued(uint256 amount, address to) external {
        uint256 bal = accruedStable[msg.sender];
        if (amount > bal) revert InsufficientBalance();
        accruedStable[msg.sender] = bal - amount;
        stable.safeTransfer(to, amount);
        emit AccruedWithdrawn(msg.sender, to, amount);
    }

    function withdrawToken(address token, uint256 amount, address to) external {
        uint256 bal = tokenBalance[msg.sender][token];
        if (amount > bal) revert InsufficientBalance();
        tokenBalance[msg.sender][token] = bal - amount;
        IERC20(token).safeTransfer(to, amount);
        emit TokensWithdrawn(msg.sender, token, to, amount);
    }

    // ---- views ----

    function tokenBalanceOf(address user, address token) external view returns (uint256) {
        return tokenBalance[user][token];
    }
}
