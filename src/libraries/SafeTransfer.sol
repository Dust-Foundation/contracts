// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "../interfaces/IDust.sol";

/// @title SafeTransfer
/// @notice Minimal safe ERC-20 movement helpers (audit L003). A token call is
///         accepted when it does not revert AND either returns nothing (the
///         USDT-style convention) or returns exactly `true`. A token that
///         reverts has its revert data bubbled up unchanged (so an issuer's
///         "frozen" or an allowance error stays visible to the keeper and the
///         app, as with the bare calls before). A `false` return, malformed
///         return data, or a call to an address without code reverts with
///         TransferFailed(), the same selector the Dust contracts already use.
library SafeTransfer {
    error TransferFailed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(IERC20.transfer, (to, amount)), true);
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _call(address(token), abi.encodeCall(IERC20.transferFrom, (from, to, amount)), true);
    }

    /// Non-reverting variant for settlement paths that must not brick on a
    /// recipient the token refuses (audit L001). Returns false instead of
    /// reverting, whatever the failure mode; the caller decides what to do.
    function tryTransfer(IERC20 token, address to, uint256 amount) internal returns (bool) {
        return _call(address(token), abi.encodeCall(IERC20.transfer, (to, amount)), false);
    }

    function _call(address token, bytes memory data, bool bubble) private returns (bool) {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) {
            if (!bubble) return false;
            if (ret.length == 0) revert TransferFailed();
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        bool accepted = ret.length == 0 ? token.code.length > 0 : (ret.length == 32 && abi.decode(ret, (bool)));
        if (!accepted && bubble) revert TransferFailed();
        return accepted;
    }
}
