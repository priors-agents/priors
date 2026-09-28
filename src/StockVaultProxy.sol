// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title StockVaultProxy
/// @notice The stock vault's address: an ERC-1967 Transparent proxy to a StockVault implementation. Its constructor
///         deploys the ProxyAdmin, owned by `admin` (the Safe), which alone can move the proxy to a new implementation
///         (ProxyAdmin.upgradeAndCall), and runs `StockVault.initialize` once through `initData`. The upgrade code lives
///         here and in the ProxyAdmin, not in the vault (which is at the 24 KB contract limit).
contract StockVaultProxy is TransparentUpgradeableProxy {
    constructor(address implementation, address admin, bytes memory initData)
        TransparentUpgradeableProxy(implementation, admin, initData)
    {}
}
