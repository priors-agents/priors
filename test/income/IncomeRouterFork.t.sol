// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolV2} from "./IPoolV2.sol";
import {IncomeRouter, IncomeBox, IIncomeRouterPool} from "../../src/IncomeRouter.sol";

/// @dev The live ERC-8004 identity registry, the parts this rehearsal uses.
interface ILiveRegistry {
    function register(string calldata uri) external returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;
    function getAgentWallet(uint256 agentId) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @dev USDG's EIP-3009 transfer, as x402 facilitators settle a payment.
interface IUsdg3009 {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

/// @title IncomeRouter rehearsal against LIVE Robinhood Chain state (proposal section 5, fork).
/// @notice Runs only when FORK_RPC is set (skipped otherwise), best against a local anvil fork of the chain:
///           anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8545 &
///           FORK_RPC=http://127.0.0.1:8545 bash test/income/forge.sh test --match-contract Fork -vv
///         It deploys the IncomeRouter on the fork against the live pool v2, USDG and the ERC-8004 registry, with the
///         live Safe as its pauser, opens real 14-day loans on Start-shaped agents, has x402 payments (EIP-3009,
///         signed by an outside payer, submitted by a facilitator) land in an agent's box before the box exists,
///         sweeps them, and repays the loan in its window. Nothing is broadcast.
contract IncomeRouterForkTest is Test {
    IPoolV2 constant POOL = IPoolV2(0x281210097f0de7A8FB6F87310AF0f089c9C8DE21);
    ILiveRegistry constant REG = ILiveRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant SAFE = 0x20c6816B2419616238772591965E6E9AbE493fD5;

    bytes32 constant AGENT_WALLET_TYPEHASH =
        keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)");
    bytes32 constant TRANSFER_AUTH_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 constant U = 1e6;
    uint64 constant TERM = 14 days;
    uint256 constant CAP = 51 * U; // a $50 loan plus its fee, rounded up
    uint256 constant ALL = 10_000;

    bool forked;
    uint256 payments;
    IncomeRouter router;
    uint256 ROOT;

    // keys of our own (short well-known test keys have code on the live chain)
    uint256 constant ROOT_PK = uint256(keccak256("priors.income.fork.root"));
    uint256 constant OWNER_PK = uint256(keccak256("priors.income.fork.owner")); // the Go mode account's signer
    uint256 constant KEY_PK = uint256(keccak256("priors.income.fork.key")); // the agent's own key, made by Start
    uint256 constant PAYER_PK = uint256(keccak256("priors.income.fork.payer")); // an x402 client outside the cluster
    address rootOwner = vm.addr(ROOT_PK);
    address owner = vm.addr(OWNER_PK);
    address key = vm.addr(KEY_PK);
    address payer = vm.addr(PAYER_PK);
    address keeper = makeAddr("keeper");
    address facilitator = makeAddr("facilitator");
    address shop = makeAddr("shop");
    address buyer = makeAddr("buyer");

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        forked = true;
        assertEq(block.chainid, 4663, "Robinhood Chain");
        assertEq(address(POOL.usdg()), address(USDG));
        assertEq(address(POOL.registry()), address(REG));

        router = new IncomeRouter(IIncomeRouterPool(address(POOL)), SAFE, 6 hours);

        // a backer of our own on the live pool (anyone can be one with the minimum stake)
        _deal(rootOwner, 300 * U);
        vm.startPrank(rootOwner);
        ROOT = REG.register("ipfs://income-fork-root");
        USDG.approve(address(POOL), type(uint256).max);
        POOL.enrollRoot(ROOT, 300 * U);
        vm.stopPrank();
        console2.log("fork block", block.number, "timestamp", block.timestamp);
    }

    function _deal(address to, uint256 amount) internal {
        uint256 b = USDG.balanceOf(to);
        deal(address(USDG), to, b + amount);
        assertEq(USDG.balanceOf(to), b + amount, "deal() on USDG");
    }

    /// A Start-shaped agent: registered by its owner's account, a line from our root with the owner's consent, the
    /// agent's own key named its pool delegate and declared its ERC-8004 wallet (signed by the key, as Start does).
    function _startAgent(address o, uint256 oPk, address k, uint256 kPk) internal returns (uint256 id) {
        vm.prank(o);
        id = REG.register("ipfs://income-fork-agent");
        IPoolV2.Consent memory c = IPoolV2.Consent({
            agentId: id,
            sponsorId: ROOT,
            owner: o,
            maxPremiumBps: 0,
            nonce: POOL.nonces(id),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oPk, POOL.consentDigest(c));
        vm.prank(rootOwner);
        POOL.vouchWithConsent(ROOT, id, 100 * U, 0, c, abi.encodePacked(r, s, v));

        uint256 deadline = block.timestamp + 240;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ERC8004IdentityRegistry"),
                keccak256("1"),
                block.chainid,
                address(REG)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(AGENT_WALLET_TYPEHASH, id, k, o, deadline)))
        );
        (v, r, s) = vm.sign(kPk, digest);
        vm.startPrank(o);
        REG.setAgentWallet(id, k, deadline, abi.encodePacked(r, s, v));
        POOL.setDelegate(id, k);
        vm.stopPrank();
        assertEq(REG.getAgentWallet(id), k, "the key is the agent's declared wallet");
    }

    /// An x402-style payment: the outside payer signs an EIP-3009 authorization to `to`, a facilitator submits it.
    function _x402(address to, uint256 value, uint256 now_) internal {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Global Dollar"),
                keccak256("1"),
                block.chainid,
                address(USDG)
            )
        );
        bytes32 nonce = keccak256(abi.encode(to, value, ++payments));
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domain,
                keccak256(abi.encode(TRANSFER_AUTH_TYPEHASH, payer, to, value, 0, now_ + 1 hours, nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, digest);
        vm.prank(facilitator);
        IUsdg3009(address(USDG)).transferWithAuthorization(payer, to, value, 0, now_ + 1 hours, nonce, v, r, s);
    }

    function _list(uint256 a) internal pure returns (uint256[] memory l) {
        l = new uint256[](1);
        l[0] = a;
    }

    /// Income arrives at a box that does not exist yet; the first sweep deploys it, sets the loan's due aside and
    /// forwards the rest to the agent's key; the loan is repaid from the box in its window. The pool records the
    /// router as the payer; the router's IncomeRepaid names the agent and its owner.
    function test_fork_x402ToUndeployedBox_sweep_repaidInWindow() public onFork {
        uint256 id = _startAgent(owner, OWNER_PK, key, KEY_PK);
        address box = router.incomeAddressOf(id);
        assertEq(box.code.length, 0, "the box is not deployed");
        assertEq(USDG.balanceOf(box), 0);

        vm.prank(owner); // Go mode's default: everything until the loans are covered, the rest to the agent's key
        router.enroll(id, ALL, key, CAP, false);

        vm.prank(key);
        uint256 loanId = POOL.borrow(id, 50 * U, TERM, key, type(uint256).max);
        IPoolV2.Loan memory l = POOL.getLoan(loanId);
        uint256 due = l.principal + l.fee;
        assertEq(l.owner, owner, "a loan the agent's key took is under the owner");
        vm.prank(key);
        assertTrue(USDG.transfer(shop, 50 * U)); // the agent spends what it borrowed

        // x402 income to the box's address, before the box exists
        _deal(payer, 60 * U);
        uint256 t = l.issuedAt;
        for (uint256 i = 0; i < 3; i++) {
            t += 2 days;
            vm.warp(t);
            _x402(box, 20 * U, t);
        }
        assertEq(USDG.balanceOf(box), 60 * U, "x402 income at the income address");
        assertEq(box.code.length, 0, "still no code there");

        vm.recordLogs();
        vm.prank(keeper);
        (uint256 arrived, uint256 put, uint256 fwd, uint256 rel) = router.sweep(id, _list(loanId));
        assertGt(box.code.length, 0, "the first sweep deployed the box");
        assertEq(IncomeBox(box).router(), address(router));
        assertEq(arrived, 60 * U);
        assertEq(put, due, "the loan's due set aside");
        assertEq(fwd, 60 * U - due, "the rest to the payout");
        assertEq(rel, 0);
        assertEq(USDG.balanceOf(key), 60 * U - due, "the agent's key received the rest");
        assertEq(USDG.balanceOf(box), due);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool deployed;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IncomeRouter.BoxDeployed.selector) {
                deployed = true;
            }
        }
        assertTrue(deployed, "BoxDeployed");
        _repayInWindowChecked(id, loanId);
    }

    /// The repayment at the window's opening, by a keeper that pays nothing, with the score's facts checked.
    function _repayInWindowChecked(uint256 id, uint256 loanId) internal {
        IPoolV2.Loan memory l = POOL.getLoan(loanId);
        uint256 due = l.principal + l.fee;
        address box = router.incomeAddressOf(id);
        uint64 opens = router.opensAt(l.issuedAt, l.dueAt);
        assertEq(opens, l.dueAt - 6 hours, "a 14-day loan's window is its last 6 h");
        vm.warp(opens - 1);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.TooEarly.selector, loanId, opens));
        router.repay(loanId, _list(loanId));
        vm.warp(opens);
        assertEq(uint8(router.checkLoan(loanId).status), uint8(IncomeRouter.Status.Ready));
        uint256 qualifiedBefore = POOL.getAgent(id).qualifiedRepaid;
        vm.recordLogs();
        vm.prank(keeper);
        assertEq(router.repay(loanId, _list(loanId)), due);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool repaid;
        bool income;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(POOL) && logs[i].topics[0] == IPoolV2.Repaid.selector) {
                (,, address p) = abi.decode(logs[i].data, (uint256, uint256, address));
                assertEq(p, address(router), "the pool's Repaid.payer is the router: the score pins it");
                repaid = true;
            }
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IncomeRouter.IncomeRepaid.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[3]))), owner);
                income = true;
            }
        }
        assertTrue(repaid && income, "Repaid and IncomeRepaid");
        IPoolV2.Loan memory after_ = POOL.getLoan(loanId);
        assertEq(uint8(after_.status), uint8(IPoolV2.LoanStatus.Repaid));
        assertLe(after_.closedAt, after_.dueAt, "repaid on time");
        assertGe(after_.closedAt - after_.issuedAt, 7 days, "held a week: week-long credit");
        assertEq(POOL.getAgent(id).qualifiedRepaid, qualifiedBefore + 1, "the pool counts the week-long loan");
        assertEq(USDG.balanceOf(box), 0);
        assertEq(router.setAsideTotal(id), 0);
        assertEq(USDG.balanceOf(address(router)), 0, "the router holds nothing");
        assertEq(USDG.allowance(address(router), address(POOL)), 0);
        assertEq(USDG.balanceOf(keeper), 0, "the keeper paid nothing and got nothing");
        console2.log("loan", loanId, "repaid from the box's x402 income, due", due);
    }

    /// A change of hands on the live registry: the sale is a new epoch at once, the buyer's income waits for its own
    /// plan, and the earlier owner's set-aside still repays the earlier owner's loan in its window. The Safe's pause
    /// stops repay and lifts.
    function test_fork_sale_earlierOwnersSetAsideRepaysItsLoan_pauseLifts() public onFork {
        uint256 id = _startAgent(owner, OWNER_PK, key, KEY_PK);
        address box = router.incomeAddressOf(id);
        vm.prank(owner);
        router.enroll(id, ALL, owner, CAP, false);
        vm.prank(key);
        uint256 loanId = POOL.borrow(id, 50 * U, TERM, key, type(uint256).max);
        IPoolV2.Loan memory l = POOL.getLoan(loanId);
        uint256 due = l.principal + l.fee;
        _deal(payer, 80 * U);
        _x402(box, 55 * U, block.timestamp);
        vm.prank(keeper);
        router.sweep(id, _list(loanId));
        assertEq(router.setAsideOf(id, owner), due);

        vm.prank(owner);
        REG.transferFrom(owner, buyer, id);
        assertEq(REG.getAgentWallet(id), address(0), "the registry clears the wallet at a transfer");
        IncomeRouter.Summary memory v = router.check(id);
        assertEq(v.owner, buyer);
        assertFalse(v.planOn, "the sale is a new epoch: the old plan counts for nothing");
        _x402(box, 25 * U, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.NoPlan.selector, id, buyer));
        router.sweep(id, _list(loanId));
        assertEq(router.check(id).unswept, 25 * U, "the buyer's income waits for the buyer's plan");

        vm.warp(router.opensAt(l.issuedAt, l.dueAt));
        vm.prank(SAFE);
        router.pause(uint64(block.timestamp + 14 days));
        vm.expectRevert(abi.encodeWithSelector(IncomeRouter.IsPaused.selector, uint64(block.timestamp + 14 days)));
        router.repay(loanId, _list(loanId));
        vm.prank(SAFE);
        router.pause(0);
        vm.prank(keeper);
        router.repay(loanId, _list(loanId)); // the earlier owner's loan, from the earlier owner's set-aside, after the sale
        assertEq(uint8(POOL.getLoan(loanId).status), uint8(IPoolV2.LoanStatus.Repaid));
        assertEq(router.setAsideOf(id, owner), 0);
        assertEq(USDG.balanceOf(box), 25 * U, "the buyer's 25 untouched");
        assertEq(USDG.balanceOf(address(router)), 0);
    }
}
