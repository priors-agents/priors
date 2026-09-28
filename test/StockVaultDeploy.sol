// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {StockVault} from "../src/StockVault.sol";
import {StockVaultProxy} from "../src/StockVaultProxy.sol";

/// The vault as it deploys on chain: an implementation for `pool`, behind a StockVaultProxy whose
/// ProxyAdmin `admin` owns, initialized in the proxy's constructor.
function deployStockVault(
    CreditPoolV2 pool,
    address owner,
    address seizeTo,
    address feeSink,
    StockVault.Params memory p,
    address admin
) returns (StockVault) {
    StockVault impl = new StockVault(pool);
    bytes memory init = abi.encodeCall(StockVault.initialize, (owner, seizeTo, feeSink, p));
    return StockVault(address(new StockVaultProxy(address(impl), admin, init)));
}
