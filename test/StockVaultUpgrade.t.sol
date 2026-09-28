// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StockVault.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {StockVaultProxy} from "../src/StockVaultProxy.sol";

/// A later implementation, as an upgrade would bring one: the same storage plus one appended slot, and an owner-only way
/// to move what the vault holds (why the vault is upgradable: to fix it, or to move its funds).
contract StockVaultV2Mock is StockVault {
    uint256 public moved; // appended after every StockVault slot

    constructor(CreditPoolV2 pool_) StockVault(pool_) {}

    function move(IERC20 token, address to, uint256 amount) external onlyOwner {
        moved += amount;
        token.transfer(to, amount);
    }
}

/// The vault is a Transparent proxy (StockVaultProxy) to a StockVault implementation: initialized once with the
/// defaults, its implementation never usable itself, upgraded only by its ProxyAdmin's owner, and an upgrade keeps
/// every position, the stake, the settings and the tokens.
contract StockVaultUpgradeTest is StockVaultBase {
    function _admin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(address(vault), ERC1967Utils.ADMIN_SLOT)))));
    }

    function _settings() internal view returns (bytes memory) {
        (address feed, uint64 maxAge, uint8 td, uint8 fd, bool enabled, uint16 ltv, uint128 cap) =
            vault.assets(address(spy));
        return abi.encode(
            vault.owner(),
            vault.seizeTo(),
            vault.feeSink(),
            vault.agentId(),
            vault.assetList(),
            abi.encode(feed, maxAge, td, fd, enabled, ltv, cap)
        );
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    function test_proxy_isInitializedOnce_withTheDefaults() public {
        assertEq(vault.owner(), owner);
        assertEq(vault.seizeTo(), treasury);
        assertEq(vault.feeSink(), sink);
        (uint256 ltv, uint256 maxLine, uint256 epochCap, uint64 epochLength) = vault.params();
        assertEq(abi.encode(ltv, maxLine, epochCap, epochLength), abi.encode(_params()));
        assertEq(vault.sessionMaxAge(), 26 hours);
        assertEq(vault.idleAfter(), 30 days);
        assertEq(vault.idleUndrawnAfter(), 7 days);
        assertEq(vault.maxJumpBps(), 2500);
        assertEq(vault.jumpWindow(), 14 days);
        assertEq(vault.multiplierCooldown(), 1 days);
        assertEq(vault.epochStart(), 1_790_000_000);
        assertEq(usdc.allowance(address(vault), address(pool)), type(uint256).max);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(anyone, anyone, anyone, _params());
    }

    function test_proxy_refusesNoOwner() public {
        StockVault impl = new StockVault(pool);
        bytes memory init = abi.encodeCall(StockVault.initialize, (address(0), treasury, sink, _params()));
        vm.expectRevert(StockVault.InvalidParams.selector);
        new StockVaultProxy(address(impl), owner, init);
    }

    function test_implementation_cannotBeInitialized_andHoldsNothing() public {
        StockVault impl = StockVault(_impl());
        assertTrue(address(impl) != address(0) && address(impl) != address(vault));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(anyone, anyone, anyone, _params());
        assertEq(impl.owner(), address(0xdead));
        assertEq(address(impl.pool()), address(pool));
        assertEq(impl.agentId(), 0);
    }

    function test_onlyTheProxyAdminsOwner_upgrades() public {
        ProxyAdmin admin = _admin();
        assertEq(admin.owner(), owner);
        address before = _impl();
        StockVaultV2Mock v2 = new StockVaultV2Mock(pool);

        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), address(v2), "");
        // the proxy's own upgrade entry answers its admin only: anyone else, the vault's owner included, reaches the
        // implementation, which has no such function
        vm.prank(anyone);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(vault)).upgradeToAndCall(address(v2), "");
        vm.prank(owner);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(vault)).upgradeToAndCall(address(v2), "");
        assertEq(_impl(), before);

        vm.prank(owner);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), address(v2), "");
        assertEq(_impl(), address(v2));
    }

    function test_upgrade_keepsPositions_stake_settings_andTokens_andCanMoveThem() public {
        assertEq(_open(AGENT_PK, AGENT, SHARE / 2), 150 * USDC);
        assertEq(_open(AGENT2_PK, AGENT2, SHARE / 4), 75 * USDC);
        uint256 loanId = _borrow(agentOp, AGENT, 50 * USDC);

        bytes memory positions = abi.encode(vault.getPosition(AGENT), vault.getPosition(AGENT2));
        bytes memory settings = _settings();
        bytes memory books = abi.encode(
            vault.held(address(spy)), vault.openLines(), vault.openLinesOf(address(spy)), vault.linedThisEpoch()
        );
        uint256 room = vault.borrowRoom(AGENT);
        uint256 backing = pool.freeBacking(VAULT_ID);
        uint256 tokens = spy.balanceOf(address(vault));

        StockVaultV2Mock v2 = new StockVaultV2Mock(pool);
        vm.prank(owner);
        _admin().upgradeAndCall(ITransparentUpgradeableProxy(address(vault)), address(v2), "");

        assertEq(abi.encode(vault.getPosition(AGENT), vault.getPosition(AGENT2)), positions);
        assertEq(_settings(), settings);
        assertEq(
            abi.encode(
                vault.held(address(spy)), vault.openLines(), vault.openLinesOf(address(spy)), vault.linedThisEpoch()
            ),
            books
        );
        assertEq(vault.borrowRoom(AGENT), room);
        assertEq(pool.freeBacking(VAULT_ID), backing);
        assertEq(pool.hook(VAULT_ID), address(vault));
        assertEq(spy.balanceOf(address(vault)), tokens);

        // the upgraded vault still runs the lines: the loan is repaid and the line closes, the tokens go back
        vm.prank(agentOp);
        pool.repay(loanId, AGENT, type(uint256).max);
        vm.prank(agentOp);
        vault.close(AGENT);
        assertEq(spy.balanceOf(agentOp), 10 * SHARE);

        // and its owner can move what it holds with the new code (the second position's tokens, here)
        StockVaultV2Mock up = StockVaultV2Mock(address(vault));
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        up.move(IERC20(address(spy)), anyone, SHARE / 4);
        vm.prank(owner);
        up.move(IERC20(address(spy)), treasury, SHARE / 4);
        assertEq(spy.balanceOf(treasury), SHARE / 4);
        assertEq(up.moved(), SHARE / 4);
    }
}
