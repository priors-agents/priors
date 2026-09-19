// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The parts of the Pons V2 fee escrow a creator-fee recipient needs. Fees are credited here after a
///         sweep and withdrawn by the recipient: a native ledger for ETH-paired launches and a per-token ledger
///         for custom-pair launches (the quote asset) and released buyback vests (the launch token).
interface IPonsFeeEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
    function claim() external;
    function claimToken(address token) external;
}

/// @notice The one creator control on the Pons V2 factory: redirect future payouts. Only the current recipient may call.
interface IPonsFactoryCreator {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}
