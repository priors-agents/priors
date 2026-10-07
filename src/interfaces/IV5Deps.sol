// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The live SeatSizerV4 (0x97C4…8777, src/SeatSizer.sol) as V5 reads it.
interface ISeatSizerV4 {
    function medianSqrtPrice() external view returns (uint160);
    function observation(uint256 i) external view returns (uint160);
    function obsCount() external view returns (uint256);
    function lastObsAt() external view returns (uint64);
}

/// @notice Uniswap v4's PoolKey (ABI-identical to v4-core and to src/tools/V4SwapOnce.sol).
struct V5PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice src/tools/V4SwapOnce.sol: stateless, ownerless, pays from msg.sender's allowance.
interface IV4SwapOnce {
    error Expired();
    error TooLittleOut(uint256 out, uint256 minOut);

    function swapExactIn(
        V5PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint256 minOut,
        uint160 sqrtPriceLimitX96,
        address to,
        uint256 deadline
    ) external returns (uint256 paid, uint256 out);
}

/// @notice The PoolManager's raw storage read (the SeatSizer reads slot0 the same way).
interface IExtsloadV5 {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @notice Uniswap's Permit2 (AllowanceTransfer), the parts V5 uses.
interface IPermit2V5 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @notice USDG's EIP-2612 permit and its issuer's freeze view.
interface IUsdgV5 {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function isFrozen(address who) external view returns (bool);
}

/// @notice $PRIORS: no permit, but `burn`.
interface IPriorsBurn {
    function burn(uint256 amount) external;
}
