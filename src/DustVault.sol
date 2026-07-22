// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IDust.sol";

/// @title DustVault
/// @notice Custody and per-user ledger for Dust. Holds users' accrued stable
///         round-ups and the basket tokens bought with them.
///
/// Invariants this contract is built around:
///  - Withdrawals ALWAYS work. There is no pause here and no owner power that
///    can touch, freeze, or redirect a user's balances.
///  - Only the router may accrue; only the sweeper may debit accrued stable
///    and credit bought tokens. Both are set exactly once.
///  - Vault balances are per-user accounting entries; no pooled shares, no
///    cross-user math, nothing to manipulate with donations.
contract DustVault {
    IERC20 public immutable stable;
    address public owner;
    address public router;
    address public sweeper;

    mapping(address => uint256) public accruedStable;
    mapping(address => mapping(address => uint256)) public tokenBalance;
    /// total stable ever swept into the basket per user (cost basis, 6/18-dec stable units)
    mapping(address => uint256) public costBasis;

    event ModulesSet(address router, address sweeper);
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
    function setModules(address _router, address _sweeper) external {
        if (msg.sender != owner) revert NotAuthorized();
        if (router != address(0) || sweeper != address(0)) revert AlreadySet();
        if (_router == address(0) || _sweeper == address(0)) revert ZeroAddress();
        router = _router;
        sweeper = _sweeper;
        emit ModulesSet(_router, _sweeper);
    }

    // ---- module surface ----

    /// Router credits a user's round-up. Stable must already have been
    /// transferred to this vault in the same transaction (router does the pull).
    function accrue(address user, uint256 amount) external {
        if (msg.sender != router) revert NotAuthorized();
        accruedStable[user] += amount;
        emit Accrued(user, amount);
    }

    /// Sweeper takes a user's accrued stable to buy the basket.
    function debitAccrued(address user, uint256 amount) external {
        if (msg.sender != sweeper) revert NotAuthorized();
        uint256 bal = accruedStable[user];
        if (amount > bal) revert InsufficientBalance();
        accruedStable[user] = bal - amount;
        if (!stable.transfer(sweeper, amount)) revert TransferFailed();
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

    // ---- user surface (always available) ----

    function withdrawAccrued(uint256 amount, address to) external {
        uint256 bal = accruedStable[msg.sender];
        if (amount > bal) revert InsufficientBalance();
        accruedStable[msg.sender] = bal - amount;
        if (!stable.transfer(to, amount)) revert TransferFailed();
        emit AccruedWithdrawn(msg.sender, to, amount);
    }

    function withdrawToken(address token, uint256 amount, address to) external {
        uint256 bal = tokenBalance[msg.sender][token];
        if (amount > bal) revert InsufficientBalance();
        tokenBalance[msg.sender][token] = bal - amount;
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        emit TokensWithdrawn(msg.sender, token, to, amount);
    }

    // ---- views ----

    function tokenBalanceOf(address user, address token) external view returns (uint256) {
        return tokenBalance[user][token];
    }
}
