// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {StockVault, IPriceFeed} from "../src/StockVault.sol";

interface IRegistryMintLive {
    function register(string calldata agentURI) external returns (uint256 agentId);
}

/// Calls a hook the way the pool does (PoolV2Lib.canBorrow): the address's code is read first, then a staticcall
/// with exactly `cap` gas. `used` is what the staticcall consumed.
contract HookGasProbe {
    function call(address h, bytes calldata data, uint256 cap)
        external
        view
        returns (bool ok, uint256 word, uint256 used)
    {
        require(h.code.length != 0, "no code");
        bytes memory d = data;
        assembly {
            let g := gas()
            ok := staticcall(cap, h, add(d, 0x20), mload(d), 0, 0)
            used := sub(g, gas())
            if and(ok, gt(returndatasize(), 31)) {
                returndatacopy(0, 0, 32)
                word := mload(0)
            }
        }
    }
}

/// The LIVE stock vault (its proxy, whatever implementation it points to) on live Robinhood Chain state: for every
/// accepted token that takes new loans, a real position is opened through the vault, its borrow hook is measured from
/// cold storage, and a real pool.borrow goes through the pool's HOOK_GAS. Isolation makes every top-level call its own
/// transaction (cold accounts and slots, as on chain); without it the price-history walk's feed reads look warm.
/// Nothing is sent to mainnet.
///   FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/StockVaultLiveHookGasFork.t.sol -vv
/// Without FORK_RPC the test is skipped.
contract StockVaultLiveHookGasForkTest is Test {
    CreditPoolV2 constant POOL = CreditPoolV2(0x281210097f0de7A8FB6F87310AF0f089c9C8DE21);
    StockVault constant VAULT = StockVault(0xbEcd07EC689988e16b870C121756C4c2C8cb02B6);
    uint256 constant ROOT = 6424;
    /// What a borrow hook must leave unused under HOOK_GAS: a feed upgrade or denser rounds must not take a live
    /// token to the edge unnoticed (on 2026-10-02 the worst token used about 213k, the longest walk about 243k).
    uint256 constant MARGIN = 50_000;

    HookGasProbe probe;
    IRegistryMintLive reg;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        probe = new HookGasProbe();
        reg = IRegistryMintLive(address(POOL.registry()));
    }

    function _open(address token, uint256 i, uint256 usd) internal returns (address owner, uint256 agent) {
        (address feed,,,,,,) = VAULT.assets(token);
        uint256 pk = 0xA11CE000 + i;
        owner = vm.addr(pk);
        vm.prank(owner);
        agent = reg.register("https://example.invalid/hook-gas.json");
        (, int256 answer,,,) = IPriceFeed(feed).latestRoundData();
        uint256 scale = uint256(IERC20Metadata(token).decimals()) + IPriceFeed(feed).decimals();
        uint256 amount = usd * 10 ** (scale - 6) / uint256(answer);
        deal(token, owner, amount);
        vm.prank(owner);
        IERC20(token).approve(address(VAULT), amount);
        CreditPoolV2.Consent memory c = CreditPoolV2.Consent({
            agentId: agent,
            sponsorId: ROOT,
            owner: owner,
            maxPremiumBps: 0,
            nonce: POOL.nonces(agent),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, POOL.consentDigest(c));
        vm.prank(owner);
        VAULT.open(agent, token, amount, c, abi.encodePacked(r, s, v));
    }

    /// GHSA-35hh (not a vulnerability): its figures came from measuring each feed read as its own transaction. In a
    /// borrow they share one, and every live token fits with room to spare.
    /// forge-config: default.isolate = true
    function test_fork_everyLiveToken_borrowHookFitsTheHookGas_andABorrowGoesThrough() public {
        if (!forked) vm.skip(true);
        address[] memory list = VAULT.assetList();
        uint256 minLoan = POOL.getParams().minLoan;
        uint256 cage = POOL.HOOK_GAS();
        uint256 worst;
        uint256 measured;
        for (uint256 i; i < list.length; i++) {
            (,,,, bool enabled,,) = VAULT.assets(list[i]);
            if (!enabled || VAULT.lendStatus(list[i]) != 0) continue; // on hold: takes no new loans whatever the gas
            uint256 snap = vm.snapshotState();
            (address owner, uint256 agent) = _open(list[i], i, 40e6);
            bytes memory data =
                abi.encodeCall(StockVault.canBorrow, (ROOT, agent, minLoan, 7 days, 0, owner, owner, owner));
            (bool ok, uint256 word, uint256 used) = probe.call(address(VAULT), data, cage);
            string memory sym = IERC20Metadata(list[i]).symbol();
            assertTrue(ok && word == 1, string.concat(sym, ": the hook allows the loan within HOOK_GAS"));
            emit log_named_uint(string.concat(sym, " cold hook gas"), used);
            if (used > worst) worst = used;
            vm.prank(owner);
            POOL.borrow(agent, minLoan, 7 days, owner, type(uint256).max); // reverts the test if the pool refuses
            measured++;
            vm.revertToState(snap);
        }
        emit log_named_uint("tokens measured", measured);
        emit log_named_uint("worst cold hook gas", worst);
        assertGt(measured, 0, "at least one token takes new loans");
        assertLt(worst + MARGIN, cage, "every live token's hook keeps the margin under HOOK_GAS");
    }
}
