// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Uniswap v4's PoolKey, ABI-identical to v4-core (currencies as addresses; the hook as an address).
struct PoolKeyV4 {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice v4-core's SwapParams: `amountSpecified` negative for an exact input.
struct SwapParamsV4 {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// @notice v4-core's ModifyLiquidityParams: a positive `liquidityDelta` adds.
struct ModifyLiquidityParamsV4 {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

/// @title IPoolManagerV4
/// @notice The slice of Uniswap v4's PoolManager that BuyAndBack (one exact-input swap) and PriorsLiquidity (one
///         liquidity add) use, ABI-identical to v4-core. A `BalanceDelta` is an int256 whose upper 128 bits are
///         currency0's amount and lower 128 bits currency1's, from the caller's side (negative: owed to the pool).
interface IPoolManagerV4 {
    /// @notice Unlock the manager and call back `msg.sender`'s `unlockCallback(data)`; every delta must be zero after.
    function unlock(bytes calldata data) external returns (bytes memory);
    /// @notice A swap; returns the caller's BalanceDelta, the hook's delta included.
    function swap(PoolKeyV4 memory key, SwapParamsV4 memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    /// @notice Add or remove liquidity of the caller's position; `callerDelta` includes `feesAccrued`.
    function modifyLiquidity(PoolKeyV4 memory key, ModifyLiquidityParamsV4 memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    /// @notice Checkpoint `currency`'s balance before a `settle`.
    function sync(address currency) external;
    /// @notice Credit what was transferred in since `sync`.
    function settle() external payable returns (uint256 paid);
    /// @notice Send `amount` of `currency` owed to the caller to `to`.
    function take(address currency, address to, uint256 amount) external;
    /// @notice One word of the manager's storage.
    function extsload(bytes32 slot) external view returns (bytes32);
    /// @notice One word of the manager's transient storage (the open currency deltas).
    function exttload(bytes32 slot) external view returns (bytes32);
}

/// @notice What the PoolManager calls back inside `unlock`.
interface IUnlockCallbackV4 {
    /// @notice Called by the PoolManager on the contract that called `unlock`.
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
