// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test double for the Pons V2 fee escrow: credit balances, pull them out. Also stands in for the factory's
///         creator control so the ReserveFunder can be tested end to end.
contract MockPonsFeeEscrow {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public balanceOfToken;
    mapping(address => address) public feeRecipientOf; // launch token => recipient

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function creditToken(address recipient, address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balanceOfToken[recipient][token] += amount;
    }

    function claim() external {
        uint256 v = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: v}("");
        require(ok);
    }

    function claimToken(address token) external {
        uint256 v = balanceOfToken[msg.sender][token];
        balanceOfToken[msg.sender][token] = 0;
        IERC20(token).transfer(msg.sender, v);
    }

    function setFeeRecipient(address launchToken, address recipient) external {
        feeRecipientOf[launchToken] = recipient;
    }

    function transferCreatorFeeRecipient(address launchToken, address newRecipient) external {
        require(feeRecipientOf[launchToken] == msg.sender, "NotCreatorFeeRecipient");
        feeRecipientOf[launchToken] = newRecipient;
    }
}
