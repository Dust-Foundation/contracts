// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

/// Aerodrome Slipstream factory: pools are keyed by tick spacing, not fee tier.
interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// The one pool read the adapter needs: Slipstream's fee is dynamic (set by a
/// fee module per tick spacing), so it is read live, never cached.
interface ICLPoolFee {
    function fee() external view returns (uint24);
}

/// Makes Aerodrome Slipstream look like a Uniswap v3 factory to the Dust
/// contracts, so the audited DustRouter / DustSweeper / DustCapture bytecode
/// deploys on Base unchanged.
///
/// The Dust contracts verify a pool's provenance with exactly one call:
///     factory.getPool(token0, token1, pool.fee()) == pool
/// Slipstream keys pools by tick spacing and its fee is dynamic, so this
/// adapter answers that question by walking a fixed, deploy-time list of
/// (factory, tickSpacing) slots in order and returning the first canonical
/// pool for the pair whose live fee equals the fee asked for. Only pools
/// created by the allowlisted Slipstream factories can ever be returned, which
/// is the property the Dust contracts rely on (audit H001, L002, L004).
///
/// Ambiguity: two tick spacings can carry the same fee. The slot ORDER decides
/// which pool wins for a given (pair, fee); it is chosen at deploy to put the
/// deep, oracle-backed pools first (see BASE-ADDRESSES.md). The adapter has no
/// owner and no setters: changing the resolution means deploying a new adapter
/// and new Dust contracts, never editing a live one.
contract SlipstreamFactoryAdapter {
    error LengthMismatch();
    error Empty();
    error ZeroAddress();

    /// Parallel arrays: factories[i] is asked for tickSpacings[i].
    address[] public factories;
    int24[] public tickSpacings;

    constructor(address[] memory _factories, int24[] memory _tickSpacings) {
        if (_factories.length != _tickSpacings.length) revert LengthMismatch();
        if (_factories.length == 0) revert Empty();
        for (uint256 i; i < _factories.length; i++) {
            if (_factories[i] == address(0)) revert ZeroAddress();
            factories.push(_factories[i]);
            tickSpacings.push(_tickSpacings[i]);
        }
    }

    function slotCount() external view returns (uint256) {
        return factories.length;
    }

    /// Uniswap-v3-shaped lookup. Symmetric in token order. Returns address(0)
    /// when no allowlisted Slipstream pool for the pair carries `fee` today.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        uint256 n = factories.length;
        for (uint256 i; i < n; i++) {
            address pool = ICLFactory(factories[i]).getPool(tokenA, tokenB, tickSpacings[i]);
            if (pool == address(0)) continue;
            if (ICLPoolFee(pool).fee() == fee) return pool;
        }
        return address(0);
    }
}
