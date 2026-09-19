// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "./interfaces/IPonsFeeEscrow.sol";

interface ICreditPoolReserve {
    function fundReserve(uint256 amount) external;
    function usdc() external view returns (IERC20);
}

/// @title ReserveFunder
/// @notice Set this contract as the creator-fee recipient of the project token on Pons. Every creator fee the
///         token earns (paid in the pool's own asset when the launch is paired against it) can then be swept,
///         by anyone, into the CreditPool's first-loss reserve. Trading the coin funds the unbacked credit
///         agents earn, and the receipt for it is on-chain.
///
///         Anything that lands here in another asset (ETH from a native-paired launch, vested launch tokens)
///         is held for the owner to withdraw and convert by hand; nothing is swapped on-chain.
contract ReserveFunder is Ownable2Step {
    using SafeERC20 for IERC20;

    ICreditPoolReserve public immutable pool;
    IERC20 public immutable asset;
    IPonsFeeEscrow public immutable escrow;
    IPonsFactoryCreator public immutable factory;

    uint256 public totalSwept;

    event Swept(address indexed caller, uint256 claimed, uint256 funded);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    constructor(ICreditPoolReserve pool_, IPonsFeeEscrow escrow_, IPonsFactoryCreator factory_, address owner_)
        Ownable(owner_)
    {
        pool = pool_;
        asset = pool_.usdc();
        escrow = escrow_;
        factory = factory_;
        asset.approve(address(pool_), type(uint256).max);
    }

    /// @notice Claim whatever the escrow owes this contract in the pool asset and fund the reserve with it,
    ///         plus anything already sitting here. Permissionless: the reserve can only go up.
    function sweep() external returns (uint256 funded) {
        uint256 claimed = escrow.balanceOfToken(address(this), address(asset));
        if (claimed > 0) escrow.claimToken(address(asset));
        funded = asset.balanceOf(address(this));
        if (funded > 0) {
            pool.fundReserve(funded);
            totalSwept += funded;
        }
        emit Swept(msg.sender, claimed, funded);
    }

    /// @notice How much a sweep would fund right now: escrow balance plus what is already here.
    function sweepable() external view returns (uint256) {
        return escrow.balanceOfToken(address(this), address(asset)) + asset.balanceOf(address(this));
    }

    /// @notice Redirect the launch token's future creator fees elsewhere (e.g. a new funder). Claim first.
    function transferCreatorFeeRecipient(address launchToken, address newRecipient) external onlyOwner {
        factory.transferCreatorFeeRecipient(launchToken, newRecipient);
    }

    /// @notice Claim and withdraw any other asset the escrow credited to this contract (ETH, vested launch tokens).
    function rescue(address token, address to) external onlyOwner {
        if (token == address(0)) {
            if (escrow.balanceOf(address(this)) > 0) escrow.claim();
            uint256 bal = address(this).balance;
            (bool ok,) = to.call{value: bal}("");
            require(ok, "eth transfer failed");
            emit Rescued(address(0), to, bal);
        } else {
            require(token != address(asset), "use sweep");
            if (escrow.balanceOfToken(address(this), token) > 0) escrow.claimToken(token);
            uint256 bal = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, bal);
            emit Rescued(token, to, bal);
        }
    }

    receive() external payable {}
}
