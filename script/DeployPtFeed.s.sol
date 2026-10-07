// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PtLinearDiscountFeed} from "../src/PtLinearDiscountFeed.sol";
import {StockVault} from "../src/StockVault.sol";
import {IPPrincipalToken, IStandardizedYield, IPMarket} from "../src/interfaces/IPendle.sol";

/// @notice Deploys the PT-USDG price feed (src/PtLinearDiscountFeed.sol) from deployments/pt-usdg.<chainId>.json, after
///         reading every Pendle address, the expiry and the PT's decimals back from the chain; and checks a deployed
///         feed against the build (docs/PT-USDG.md, step 1).
///
///   dry run (simulates on the chain's state, sends nothing):
///     forge script script/DeployPtFeed.s.sol --rpc-url robinhood
///   deploy (any funded key: the deployer gets no power over the feed):
///     forge script script/DeployPtFeed.s.sol --rpc-url robinhood --broadcast --account <keystore> --sender <address>
///   check a deployed feed's code and settings against this build (reads `feed` from the config):
///     forge script script/DeployPtFeed.s.sol --rpc-url robinhood --sig "verify()"
///
///   PT_CONFIG=path   another config (default deployments/pt-usdg.<chainId>.json)
///
/// A broadcast writes the feed's address and block into the config (`feed`, `feedBlock`).
contract DeployPtFeed is Script {
    struct Config {
        address market;
        address pt;
        address sy;
        address yt;
        address safe;
        address stockVault;
        uint256 expiry;
        uint256 ptDecimals;
        uint256 rateBps;
        uint256 maxAge;
        uint256 ltvBps;
        uint256 lineCap;
    }

    function _path() internal view returns (string memory) {
        return vm.envOr("PT_CONFIG", string.concat("deployments/pt-usdg.", vm.toString(block.chainid), ".json"));
    }

    function _load(string memory json) internal pure returns (Config memory c) {
        c.market = vm.parseJsonAddress(json, ".market");
        c.pt = vm.parseJsonAddress(json, ".pt");
        c.sy = vm.parseJsonAddress(json, ".sy");
        c.yt = vm.parseJsonAddress(json, ".yt");
        c.safe = vm.parseJsonAddress(json, ".safe");
        c.stockVault = vm.parseJsonAddress(json, ".stockVault");
        c.expiry = vm.parseJsonUint(json, ".expiry");
        c.ptDecimals = vm.parseJsonUint(json, ".ptDecimals");
        c.rateBps = vm.parseJsonUint(json, ".rateBps");
        c.maxAge = vm.parseJsonUint(json, ".setAsset.maxAge");
        c.ltvBps = vm.parseJsonUint(json, ".setAsset.ltvBps");
        c.lineCap = vm.parseJsonUint(json, ".setAsset.lineCap");
    }

    /// Every address and number of the config, read back from the chain: a mismatch stops the script.
    function _checkChain(Config memory c) internal view {
        (address sy, address pt, address yt) = IPMarket(c.market).readTokens();
        require(sy == c.sy && pt == c.pt && yt == c.yt, "market.readTokens() differs from the config");
        require(IPPrincipalToken(c.pt).SY() == c.sy && IPPrincipalToken(c.pt).YT() == c.yt, "PT's SY/YT differ");
        require(IPPrincipalToken(c.pt).expiry() == c.expiry, "PT expiry differs from the config");
        require(IPMarket(c.market).expiry() == c.expiry, "market expiry differs from the config");
        require(IPPrincipalToken(c.pt).decimals() == c.ptDecimals, "PT decimals differ from the config");
        require(!IStandardizedYield(c.sy).paused(), "the SY is paused");
        require(StockVault(c.stockVault).owner() == c.safe, "the stock vault's owner is not the config's safe");
        require(c.rateBps == 600, "the owner's rate is 600 bps (6% a year)");
        require(c.ltvBps == 5000 && c.lineCap == 250e6 && c.maxAge == 26 hours, "not the owner's launch settings");
    }

    function _log(Config memory c, PtLinearDiscountFeed feed) internal view {
        console.log("feed:", address(feed));
        console.log("pt / sy / yt:", c.pt, c.sy, c.yt);
        console.log("expiry:", c.expiry);
        console.log("rateBps:", c.rateBps);
        console.log("safe (off switch):", c.safe);
        console.log("price now (1e18 = par):", feed.price());
        console.log("Safe call, once 14 days of rounds exist: StockVault", c.stockVault);
        console.logBytes(
            abi.encodeCall(
                StockVault.setAsset, (c.pt, address(feed), uint64(c.maxAge), true, uint16(c.ltvBps), uint128(c.lineCap))
            )
        );
    }

    function run() external returns (PtLinearDiscountFeed feed) {
        string memory path = _path();
        Config memory c = _load(vm.readFile(path));
        require(block.chainid == vm.parseJsonUint(vm.readFile(path), ".chainId"), "wrong chain");
        _checkChain(c);

        vm.startBroadcast();
        feed = new PtLinearDiscountFeed(IPPrincipalToken(c.pt), c.rateBps, c.safe);
        vm.stopBroadcast();

        _checkFeed(c, feed);
        _log(c, feed);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.writeJson(string.concat("\"", vm.toString(address(feed)), "\""), path, ".feed");
            vm.writeJson(vm.toString(block.number), path, ".feedBlock");
            console.log("wrote feed and feedBlock to", path);
        } else {
            console.log("dry run: nothing sent (add --broadcast to deploy)");
        }
    }

    /// The deployed feed's runtime code equals this build's, constructed with the config's arguments (the immutables
    /// included), and its settings read back as configured.
    function verify() external {
        string memory path = _path();
        Config memory c = _load(vm.readFile(path));
        PtLinearDiscountFeed feed = PtLinearDiscountFeed(vm.parseJsonAddress(vm.readFile(path), ".feed"));
        require(address(feed).code.length != 0, "no code at the config's feed");
        PtLinearDiscountFeed fresh = new PtLinearDiscountFeed(IPPrincipalToken(c.pt), c.rateBps, c.safe); // local only
        require(
            keccak256(address(feed).code) == keccak256(address(fresh).code), "deployed bytecode differs from the build"
        );
        _checkFeed(c, feed);
        console.log("bytecode matches the build, codehash:");
        console.logBytes32(address(feed).codehash);
        console.log("rounds stored:", feed.latestRound());
        console.log("off:", feed.off());
        _log(c, feed);
    }

    function _checkFeed(Config memory c, PtLinearDiscountFeed feed) internal view {
        require(address(feed.pt()) == c.pt && address(feed.sy()) == c.sy && address(feed.yt()) == c.yt, "feed tokens");
        require(feed.expiry() == c.expiry && feed.rateBps() == c.rateBps && feed.safe() == c.safe, "feed settings");
        require(feed.decimals() == 18, "feed decimals");
        uint256 p = feed.price();
        require(p > 0.9e18 && p <= 1e18, "price out of range");
    }
}
