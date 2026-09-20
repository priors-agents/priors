// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {ReserveFunder, ICreditPoolReserve} from "../src/ReserveFunder.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";
import {MockPonsFeeEscrow} from "../src/mocks/MockPonsFeeEscrow.sol";
import {TreasurySponsor} from "../src/TreasurySponsor.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Deploys the CreditPool. On dev chains (no USDC / REGISTRY env), deploys mocks first.
///
///   USDC=0x...      existing USDC (6 decimals). Omit to deploy MockUSDC.
///   REGISTRY=0x...  existing ERC-8004 Identity Registry. Omit to deploy MockIdentityRegistry.
///   OWNER=0x...     pool owner. Defaults to the broadcaster.
///   PONS_FEE_ESCROW=0x... and PONS_FACTORY=0x...  also deploy a ReserveFunder (creator-fee recipient for the
///                   project token on Pons) wired to the pool. Omit on chains without Pons.
///
/// Writes deployments/<chainId>.json.
contract Deploy is Script {
    function run() external {
        address usdc = vm.envOr("USDC", address(0));
        bool usdcIsMock = usdc == address(0);
        address registry = vm.envOr("REGISTRY", address(0));
        address owner = vm.envOr("OWNER", address(0));
        address ponsEscrow = vm.envOr("PONS_FEE_ESCROW", address(0));
        address ponsFactory = vm.envOr("PONS_FACTORY", address(0));

        vm.startBroadcast();
        if (owner == address(0)) owner = msg.sender;
        if (usdc == address(0)) {
            usdc = address(new MockUSDC());
            console.log("MockUSDC:", usdc);
        }
        if (registry == address(0)) {
            registry = address(new MockIdentityRegistry());
            console.log("MockIdentityRegistry:", registry);
        }
        CreditPool pool = new CreditPool(IERC20(usdc), IERC8004Identity(registry), owner);
        if (usdcIsMock && ponsEscrow == address(0)) {
            // dev chain: a mock escrow stands in for Pons so the token-fee loop can be exercised
            ponsEscrow = address(new MockPonsFeeEscrow());
            ponsFactory = ponsEscrow;
            console.log("MockPonsFeeEscrow:", ponsEscrow);
        }
        address funder;
        if (ponsEscrow != address(0) && ponsFactory != address(0)) {
            funder = address(
                new ReserveFunder(
                    ICreditPoolReserve(address(pool)),
                    IPonsFeeEscrow(ponsEscrow),
                    IPonsFactoryCreator(ponsFactory),
                    owner
                )
            );
            console.log("ReserveFunder:", funder);
        }
        // the token as a sponsor: creator fees -> reserve + stake, vouching by rule
        TreasurySponsor treasury = new TreasurySponsor(
            pool, IPonsFeeEscrow(ponsEscrow), IPonsFactoryCreator(ponsFactory), owner, vm.envOr("FEE_SINK", owner)
        );
        console.log("TreasurySponsor:", address(treasury));
        uint256 treasuryId;
        if (usdcIsMock && owner == msg.sender) {
            // dev chain: give the treasury an identity right away
            treasuryId = MockIdentityRegistry(registry).register("priors-treasury");
            IERC721(registry).safeTransferFrom(msg.sender, address(treasury), treasuryId);
            treasury.adopt(treasuryId);
            console.log("treasury agentId:", treasuryId);
        } else {
            console.log("register an ERC-8004 identity, transfer it to the TreasurySponsor, then call adopt(id)");
        }
        vm.stopBroadcast();

        console.log("CreditPool:", address(pool));
        console.log("owner:", owner);

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "deployBlock", block.number);
        vm.serializeAddress(json, "usdc", usdc);
        vm.serializeBool(json, "usdcIsMock", usdcIsMock);
        vm.serializeAddress(json, "registry", registry);
        vm.serializeAddress(json, "owner", owner);
        vm.serializeAddress(json, "reserveFunder", funder);
        vm.serializeAddress(json, "treasurySponsor", address(treasury));
        vm.serializeUint(json, "treasuryAgentId", treasuryId);
        string memory out = vm.serializeAddress(json, "creditPool", address(pool));
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(out, path);
        console.log("wrote", path);
    }
}
