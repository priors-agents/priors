// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IncomeRouter, IncomeBox, IIncomeRouterPool} from "../src/IncomeRouter.sol";

/// @notice Deploys the IncomeRouter (src/IncomeRouter.sol; docs/proposals/2026-11-01-income-repay-and-inference-on-
///         credit.md, section 2) against pool v2 and the Safe named in deployments/<chainId>.v2.json, and checks a
///         deployed one against this build. Not audited.
///
///   dry run (simulates on the chain's state, sends nothing, writes nothing):
///     forge script script/DeployIncomeRouter.s.sol --rpc-url robinhood
///   (or, from the scratch project that never compiles the pool's source:
///     bash test/income/forge.sh script script/DeployIncomeRouter.s.sol --rpc-url http://127.0.0.1:8545)
///   deploy (any funded key: the deployer gets no power over the router; the Safe's only power is the 14-day pause):
///     REAL_DEPLOY=1 forge script script/DeployIncomeRouter.s.sol --rpc-url robinhood --broadcast \
///       --account <keystore> --sender <address>
///   check a deployed router's code and settings against this build (reads `incomeRouter` from the config, or
///   INCOME_ROUTER_ADDRESS):
///     forge script script/DeployIncomeRouter.s.sol --rpc-url robinhood --sig "verify()"
///
///   INCOME_CONFIG=path    another config (default deployments/<chainId>.v2.json)
///   INCOME_WINDOW=secs    the repayment window (default 21600, 6 h: AutoRepayV2's, the owner's answer 4 of 2026-11-01)
///   REAL_DEPLOY=1         write `incomeRouter` and `incomeRouterBlock` into the config after a broadcast
///
/// Only a broadcast with REAL_DEPLOY=1 writes the config's `incomeRouter` and `incomeRouterBlock` (a fork rehearsal's
/// broadcast leaves the record as it is).
contract DeployIncomeRouter is Script {
    uint64 constant DEFAULT_WINDOW = 6 hours;

    struct Config {
        address pool;
        address usdg;
        address registry;
        address safe;
        uint64 window;
    }

    function _path() internal view returns (string memory) {
        return vm.envOr("INCOME_CONFIG", string.concat("deployments/", vm.toString(block.chainid), ".v2.json"));
    }

    function _load(string memory json) internal view returns (Config memory c) {
        c.pool = vm.parseJsonAddress(json, ".pool");
        c.usdg = vm.parseJsonAddress(json, ".usdg");
        c.registry = vm.parseJsonAddress(json, ".registry");
        c.safe = vm.parseJsonAddress(json, ".safe");
        c.window = uint64(vm.envOr("INCOME_WINDOW", uint256(DEFAULT_WINDOW)));
    }

    /// The config read back from the chain: the pool's own token and registry, and a Safe with code.
    function _checkChain(Config memory c) internal view {
        require(c.pool.code.length != 0, "no code at the config's pool");
        require(address(IIncomeRouterPool(c.pool).usdg()) == c.usdg, "pool.usdg() differs from the config");
        require(IIncomeRouterPool(c.pool).registry() == c.registry, "pool.registry() differs from the config");
        require(c.safe.code.length != 0, "no code at the config's safe");
    }

    function _deploy(Config memory c) internal returns (IncomeRouter r) {
        r = new IncomeRouter(IIncomeRouterPool(c.pool), c.safe, c.window);
    }

    function _checkDeployed(Config memory c, IncomeRouter r) internal view {
        require(r.VERSION() == 1, "not IncomeRouter v1");
        require(address(r.pool()) == c.pool && address(r.usdg()) == c.usdg, "pool / usdg");
        require(address(r.registry()) == c.registry, "registry");
        require(r.PAUSER() == c.safe && r.WINDOW() == c.window, "pauser / window");
        require(r.BOX_CODE_HASH() == keccak256(type(IncomeBox).creationCode), "box code");
        require(r.pausedUntil() == 0, "paused at deploy");
    }

    function _log(Config memory c, IncomeRouter r) internal view {
        console.log("incomeRouter:", address(r));
        console.log("pool / usdg:", c.pool, c.usdg);
        console.log("registry:", c.registry);
        console.log("pauser (the Safe, sweep and repay only, 14 days at most):", c.safe);
        console.log("window (s):", c.window);
        console.log("box code hash:");
        console.logBytes32(r.BOX_CODE_HASH());
        console.log("version:", r.VERSION());
    }

    function run() external returns (IncomeRouter r) {
        string memory path = _path();
        string memory json = vm.readFile(path);
        require(block.chainid == vm.parseJsonUint(json, ".chainId"), "wrong chain");
        Config memory c = _load(json);
        _checkChain(c);

        vm.startBroadcast();
        r = _deploy(c);
        vm.stopBroadcast();

        _checkDeployed(c, r);
        _log(c, r);
        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        if (broadcast && vm.envOr("REAL_DEPLOY", false)) {
            vm.writeJson(string.concat("\"", vm.toString(address(r)), "\""), path, ".incomeRouter");
            vm.writeJson(vm.toString(block.number), path, ".incomeRouterBlock");
            console.log("REAL_DEPLOY: wrote incomeRouter and incomeRouterBlock to", path);
        } else if (broadcast) {
            console.log("broadcast without REAL_DEPLOY=1: the record is left as it is");
        } else {
            console.log("dry run: nothing sent, nothing written (REAL_DEPLOY=1 and --broadcast to deploy)");
        }
    }

    /// The deployed router's runtime code equals this build's with the config's arguments (immutables included).
    function verify() external {
        string memory path = _path();
        string memory json = vm.readFile(path);
        Config memory c = _load(json);
        address at = vm.envOr("INCOME_ROUTER_ADDRESS", address(0));
        if (at == address(0)) at = vm.parseJsonAddress(json, ".incomeRouter");
        IncomeRouter r = IncomeRouter(at);
        require(address(r).code.length != 0, "no code at the config's incomeRouter");
        IncomeRouter fresh = _deploy(c); // local only
        require(
            keccak256(address(r).code) == keccak256(address(fresh).code), "deployed bytecode differs from the build"
        );
        _checkDeployed(c, r);
        console.log("bytecode matches the build, codehash:");
        console.logBytes32(address(r).codehash);
        _log(c, r);
    }
}
