// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @dev Deploys CreditPoolV2 from its build artifact, linking PoolV2Lib by hand: the protocol tests never compile the
///      pool's source (test/protocol/forge.sh copies both artifacts, built by the pool's via-IR profile).
library PoolArtifact {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string internal constant POOL = "out/CreditPoolV2.sol/CreditPoolV2.json";
    string internal constant LIB = "out/PoolV2Lib.sol/PoolV2Lib.pool-v2.json";
    // keccak256("src/libraries/PoolV2Lib.sol:PoolV2Lib"), first 34 hex chars, as solc writes the placeholder
    string internal constant PLACEHOLDER = "__$b9258e0997a81c306fe124a7ffefa61ba6$__";

    function deploy(bytes memory args) internal returns (address pool) {
        bytes memory libCode = vm.parseBytes(vm.parseJsonString(vm.readFile(LIB), ".bytecode.object"));
        address lib;
        assembly ("memory-safe") {
            lib := create(0, add(libCode, 32), mload(libCode))
        }
        require(lib != address(0), "lib deploy");
        string memory hexCode = vm.parseJsonString(vm.readFile(POOL), ".bytecode.object");
        string memory addr = vm.replace(vm.toString(lib), "0x", "");
        hexCode = vm.replace(hexCode, PLACEHOLDER, vm.toLowercase(addr));
        bytes memory code = abi.encodePacked(vm.parseBytes(hexCode), args);
        assembly ("memory-safe") {
            pool := create(0, add(code, 32), mload(code))
        }
        require(pool != address(0), "pool deploy");
    }
}
