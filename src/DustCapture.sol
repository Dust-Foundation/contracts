// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20, IDustVault} from "./interfaces/IDust.sol";

interface IKeeperSource {
    function keeper() external view returns (address);
}

/// @title DustCapture
/// @notice Outside-transaction round-ups for any wallet, today.
///
/// The user opts in with a weekly cap they set themselves and a standard,
/// capped ERC-20 allowance to this contract. The keeper then pulls observed
/// round-ups (computed off-chain from the user's outside activity) into the
/// user's own vault position — and can never do more than that:
///
///  - Pulls go ONLY to the vault, credited ONLY to the user they came from.
///    There is no path to any other destination.
///  - In-contract weekly rate limit, set by the user, changeable/revocable by
///    the user at any time (setWeeklyCap(0) = full opt-out).
///  - The ERC-20 allowance is a second, independent cap in the user's wallet;
///    approve(0) revokes from any wallet UI without touching Dust.
///  - No owner, no admin, no pause: nobody can change these rules after
///    deploy. The keeper address is read from the sweeper so key rotation
///    stays in one place.
///
/// This is the same shape as wallet-native periodic permissions (ERC-7715),
/// with the guarantees enforced by this immutable contract instead of the
/// wallet — the bridge until wallets ship the standard on this chain.
contract DustCapture {
    uint64 public constant WEEK = 7 days;

    IERC20 public immutable stable;
    IDustVault public immutable vault;
    IKeeperSource public immutable sweeper;

    struct Config {
        uint96 weeklyCap;    // user-set max capture per week (0 = opted out)
        uint96 usedThisWeek; // pulled so far in the current window
        uint64 weekStart;    // window start timestamp
    }

    mapping(address => Config) public configOf;

    event WeeklyCapSet(address indexed user, uint256 weeklyCap);
    event Captured(address indexed user, uint256 amount, uint256 usedThisWeek);

    error NotKeeper();
    error NotOptedIn();
    error OverWeeklyCap();
    error ZeroAmount();
    error TransferFailed();

    constructor(IERC20 _stable, IDustVault _vault, IKeeperSource _sweeper) {
        stable = _stable;
        vault = _vault;
        sweeper = _sweeper;
    }

    /// Opt in / change the cap / opt out (cap 0). Always the user's own call.
    function setWeeklyCap(uint96 cap) external {
        Config storage c = configOf[msg.sender];
        c.weeklyCap = cap;
        if (c.weekStart == 0) c.weekStart = uint64(block.timestamp);
        emit WeeklyCapSet(msg.sender, cap);
    }

    /// Keeper pulls an observed round-up into the user's vault position.
    function captureFor(address user, uint256 amount) external {
        if (msg.sender != sweeper.keeper()) revert NotKeeper();
        if (amount == 0) revert ZeroAmount();

        Config storage c = configOf[user];
        if (c.weeklyCap == 0) revert NotOptedIn();

        // roll the weekly window forward if it has elapsed
        if (block.timestamp >= c.weekStart + WEEK) {
            c.weekStart = uint64(block.timestamp);
            c.usedThisWeek = 0;
        }
        uint256 newUsed = uint256(c.usedThisWeek) + amount;
        if (newUsed > c.weeklyCap) revert OverWeeklyCap();
        c.usedThisWeek = uint96(newUsed);

        // pull straight into the vault, credit the same user. Reverts if the
        // user's wallet allowance or balance is insufficient — the keeper is
        // expected to check first.
        if (!stable.transferFrom(user, address(vault), amount)) revert TransferFailed();
        vault.accrue(user, amount);
        emit Captured(user, amount, newUsed);
    }

    /// How much the keeper could still capture for `user` this week.
    function remainingThisWeek(address user) external view returns (uint256) {
        Config memory c = configOf[user];
        if (c.weeklyCap == 0) return 0;
        if (block.timestamp >= c.weekStart + WEEK) return c.weeklyCap;
        return c.weeklyCap - c.usedThisWeek;
    }
}
