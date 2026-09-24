// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Stand-in for $PRIORS: 18 decimals, 1e9 supply, a public burn like the live token.
contract MockPriors is ERC20 {
    constructor() ERC20("Priors Agents", "PRIORS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @dev A token without burn(): the vault must fall back to the dead address.
contract MockNoBurn is ERC20 {
    constructor() ERC20("No Burn", "NB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Takes 1% of every transfer: a seat must be exact, so the vault refuses it.
contract MockTaxToken is ERC20 {
    constructor() ERC20("Tax", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0xbeef), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

