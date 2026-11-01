// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolV2} from "./IPoolV2.sol";
import {PoolArtifact} from "../protocol/PoolArtifact.sol";
import {MockIdentityRegistry} from "../../src/mocks/MockIdentityRegistry.sol";
import {IncomeRouter, IncomeBox, IIncomeRouterPool} from "../../src/IncomeRouter.sol";

/// @dev USDG stand-in: 6 decimals, and an issuer that can freeze any address, pause every transfer, and seize from any
///      address (docs/AUTOPAY-SPEC.md:491; the token's own code is not in the repo, so this is the strictest reading:
///      a frozen sender or receiver, or a pause, reverts the transfer).
contract IssuerUSDG is ERC20 {
    mapping(address => bool) public frozen;
    bool public paused;

    constructor() ERC20("Global Dollar (mock)", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function freeze(address who, bool f) external {
        frozen[who] = f;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    /// The issuer takes `a` from `from`, with no approval and whatever the freezes.
    function seize(address from, uint256 a) external {
        bool f = frozen[from];
        frozen[from] = false;
        _update(from, address(0xdead), a);
        frozen[from] = f;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!paused, "paused");
        require(!frozen[from] && !frozen[to], "frozen");
        super._update(from, to, v);
    }
}

/// @dev The ERC-8004 registry's rules the suite needs: a new agent declares its minter as its wallet, the owner can
///      declare another (on chain the wallet signs; here the owner sets it), a transfer clears it, and `ownerOf` can be
///      made to fail (test/autopay2's MockAgentRegistry).
contract MockAgentRegistry is MockIdentityRegistry {
    mapping(uint256 => address) internal _wallet;
    bool public ownerBroken;

    function setAgentWallet(uint256 id, address w) external {
        require(ownerOf(id) == msg.sender, "not owner");
        _wallet[id] = w;
    }

    function getAgentWallet(uint256 id) external view returns (address) {
        return _wallet[id];
    }

    function ownerOf(uint256 id) public view override returns (address) {
        require(!ownerBroken, "registry down");
        return super.ownerOf(id);
    }

    function setOwnerBroken(bool b) external {
        ownerBroken = b;
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        from = super._update(to, id, auth);
        _wallet[id] = from == address(0) ? to : address(0);
    }
}

/// @dev Just enough of a savings vault for AutoRepayV2's constructor (its asset); every other read fails, so its plans
///      pay from USDG only.
contract AssetOnly {
    address public immutable asset;

    constructor(address a) {
        asset = a;
    }
}

/// @dev A backer hook that, once armed, calls back into the router from inside the pool's notifications (a release
///      during `pool.repay`, CreditPoolV2.sol:866-867, :959-962), and records how each call ended. It never reverts
///      itself, so the pool's call goes on and the record survives.
contract ReenteringHook {
    IncomeRouter public router;
    bool public armed;
    uint256 public agentId;
    uint256 public otherLoan;
    uint256 public attempts;
    uint256 public succeeded;
    bytes4 public lastError;

    function arm(IncomeRouter r, uint256 agentId_, uint256 otherLoan_) external {
        router = r;
        agentId = agentId_;
        otherLoan = otherLoan_;
        armed = true;
    }

    function canBorrow(uint256, uint256, uint256, uint64, uint256, address, address, address)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function onBorrow(uint256, uint256, uint256) external {}

    function onDefault(uint256, uint256, uint256, uint256, bool) external {
        _reenter();
    }

    function onRelease(uint256, uint256, uint256, uint8) external {
        _reenter();
    }

    function _reenter() internal {
        if (!armed) return;
        uint256[] memory none = new uint256[](0);
        _try(abi.encodeCall(IncomeRouter.sweep, (agentId, none)));
        _try(abi.encodeCall(IncomeRouter.repay, (otherLoan, none)));
        _try(abi.encodeCall(IncomeRouter.release, (agentId, address(this), none)));
        _try(abi.encodeCall(IncomeRouter.leave, (agentId)));
    }

    function _try(bytes memory data) internal {
        attempts++;
        (bool ok, bytes memory r) = address(router).call(data);
        if (ok) {
            succeeded++;
        } else if (r.length >= 4) {
            lastError = bytes4(r);
        }
    }
}

/// @dev A token whose transfer calls back into the router (the `rescue` path), recording how the call ended.
contract ReenteringToken is ERC20 {
    IncomeRouter public router;
    uint256 public agentId;
    bool public reentered;
    bytes4 public lastError;

    constructor() ERC20("Reenter", "RE") {}

    function setTarget(IncomeRouter r, uint256 id) external {
        router = r;
        agentId = id;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 v) internal override {
        if (address(router) != address(0) && from != address(0) && !reentered) {
            reentered = true;
            (bool ok, bytes memory r) = address(router).call(abi.encodeCall(IncomeRouter.rescue, (agentId, this)));
            if (!ok && r.length >= 4) lastError = bytes4(r);
        }
        super._update(from, to, v);
    }
}

contract IncomeBase is Test {
    uint256 constant U = 1e6;
    uint64 constant WIN = 6 hours;

    IssuerUSDG usdg;
    MockAgentRegistry reg;
    IPoolV2 pool;
    IncomeRouter router;

    address safe = makeAddr("safe");
    address timelock = makeAddr("timelock");
    address guardian = makeAddr("guardian");
    address lender = makeAddr("lender");
    address anyone = makeAddr("anyone");
    address keeper = makeAddr("keeper");
    address key = makeAddr("agentKey"); // the agent's own key: its declared wallet and pool delegate
    address payout = makeAddr("payout"); // where the owner's rest goes
    address payout2 = makeAddr("payout2");
    address payer = makeAddr("x402payer");

    uint256 constant ROOT_PK = 0xB0B;
    uint256 constant OWNER_PK = 0xA1;
    uint256 constant BUYER_PK = 0xA2;
    address rootOwner = vm.addr(ROOT_PK);
    address owner = vm.addr(OWNER_PK);
    address buyer = vm.addr(BUYER_PK);

    uint256 ROOT;
    uint256 AGENT;

    function _params() internal pure returns (IPoolV2.Params memory) {
        return IPoolV2.Params({
            minLoan: 5e6,
            maxLoan: 500e6,
            minTerm: 1 days,
            maxTerm: 30 days,
            grace: 3 days,
            minScoreTerm: 7 days,
            feeBps: 100,
            sponsorFeeBps: 2500,
            protocolFeeBps: 1500,
            minStake: 10e6,
            maxUtilizationBps: 9000,
            keeperBounty: 0
        });
    }

    function setUp() public virtual {
        vm.warp(1_790_000_000);
        usdg = new IssuerUSDG();
        reg = new MockAgentRegistry();
        // deployed from its artifact: usdg, registry, no v1, the timelock as owner, the guardian
        pool = IPoolV2(
            PoolArtifact.deploy(abi.encode(address(usdg), address(reg), address(0), timelock, guardian, _params()))
        );
        usdg.mint(address(this), 1 * U);
        usdg.approve(address(pool), 1 * U);
        pool.seed();

        usdg.mint(lender, 100_000 * U);
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        pool.deposit(50_000 * U, lender, 0);
        vm.stopPrank();

        ROOT = _newRoot(rootOwner, 10_000 * U);
        AGENT = _newAgent(owner, OWNER_PK, key, ROOT);
        router = new IncomeRouter(IIncomeRouterPool(address(pool)), safe, WIN);
    }

    function _newRoot(address o, uint256 stake) internal returns (uint256 id) {
        usdg.mint(o, stake);
        vm.startPrank(o);
        id = reg.register("root");
        usdg.approve(address(pool), type(uint256).max);
        pool.enrollRoot(id, stake);
        vm.stopPrank();
    }

    /// A Start-shaped agent: registered by `o` (its Go mode account), backed with a 500 USDG line by `root`, with `k`
    /// as its pool delegate and declared ERC-8004 wallet (none when `k` is zero).
    function _newAgent(address o, uint256 pk, address k, uint256 root) internal returns (uint256 id) {
        vm.prank(o);
        id = reg.register("agent");
        _sponsor(id, o, pk, root, 500 * U);
        if (k != address(0)) {
            vm.startPrank(o);
            reg.setAgentWallet(id, k);
            pool.setDelegate(id, k);
            vm.stopPrank();
        }
    }

    function _sponsor(uint256 id, address o, uint256 pk, uint256 root, uint256 amount) internal {
        IPoolV2.Consent memory c = IPoolV2.Consent({
            agentId: id,
            sponsorId: root,
            owner: o,
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: block.timestamp + 1 days
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, pool.consentDigest(c));
        vm.prank(reg.ownerOf(root));
        pool.vouchWithConsent(root, id, amount, 0, c, abi.encodePacked(r, s, v));
    }

    /// A loan of `amount` for `term`, borrowed by the agent's controller `by` and paid to it.
    function _borrowAs(address by, uint256 id, uint256 amount, uint64 term) internal returns (uint256 loanId) {
        vm.prank(by);
        loanId = pool.borrow(id, amount, term, by, type(uint256).max);
    }

    function _borrow(uint64 term) internal returns (uint256) {
        return _borrowAs(key, AGENT, 50 * U, term);
    }

    /// x402-style income: USDG arrives at the agent's income address, with no call to it (EIP-3009 runs no code at
    /// `payTo`).
    function _pay(uint256 id, uint256 amount) internal {
        address box = router.incomeAddressOf(id);
        usdg.mint(payer, amount);
        vm.prank(payer);
        require(usdg.transfer(box, amount), "pay");
    }

    function _enroll(address o, uint256 id, uint256 shareBps, address to, uint256 cap, bool early) internal {
        vm.prank(o);
        router.enroll(id, shareBps, to, cap, early);
    }

    /// The agent's open loans, ids rising, read from the pool (what the keeper passes).
    function _open(uint256 id) internal view returns (uint256[] memory list) {
        uint256[] memory all = pool.loansOf(id);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (pool.getLoan(all[i]).status == IPoolV2.LoanStatus.Active) n++;
        }
        list = new uint256[](n);
        n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (pool.getLoan(all[i]).status == IPoolV2.LoanStatus.Active) list[n++] = all[i];
        }
    }

    function _sweep(uint256 id) internal returns (uint256 arrived, uint256 put, uint256 forwarded, uint256 released) {
        vm.prank(keeper);
        return router.sweep(id, _open(id));
    }

    /// A sweep with the exact list that must revert with `err` (the list is read before the expectation is set).
    function _sweepReverts(uint256 id, bytes memory err) internal {
        uint256[] memory list = _open(id);
        vm.prank(keeper);
        vm.expectRevert(err);
        router.sweep(id, list);
    }

    /// Repay `loanId` through the router with its agent's exact open-loan list (what the keeper passes).
    function _repay(uint256 loanId) internal returns (uint256) {
        uint256[] memory list = _open(pool.getLoan(loanId).agentId);
        return router.repay(loanId, list);
    }

    function _repayAs(address who, uint256 loanId) internal returns (uint256) {
        uint256[] memory list = _open(pool.getLoan(loanId).agentId);
        vm.prank(who);
        return router.repay(loanId, list);
    }

    /// A repay with the exact list that must revert with `err` (the list is read before the expectation is set).
    function _repayReverts(uint256 loanId, bytes memory err) internal {
        uint256[] memory list = _open(pool.getLoan(loanId).agentId);
        vm.expectRevert(err);
        router.repay(loanId, list);
    }

    function _release(uint256 id, address o) internal returns (uint256) {
        vm.prank(keeper);
        return router.release(id, o, _open(id));
    }

    function _due(uint256 loanId) internal view returns (uint256) {
        IPoolV2.Loan memory l = pool.getLoan(loanId);
        return l.principal + l.fee;
    }

    function _loan(uint256 loanId) internal view returns (IPoolV2.Loan memory) {
        return pool.getLoan(loanId);
    }

    function _opens(uint256 loanId) internal view returns (uint64) {
        IPoolV2.Loan memory l = pool.getLoan(loanId);
        return router.opensAt(l.issuedAt, l.dueAt);
    }

    function _box(uint256 id) internal view returns (address) {
        return router.incomeAddressOf(id);
    }

    function _bal(address who) internal view returns (uint256) {
        return usdg.balanceOf(who);
    }

    function _status(uint256 loanId) internal view returns (IncomeRouter.Status) {
        return router.checkLoan(loanId).status;
    }

    function _list(uint256 a) internal pure returns (uint256[] memory l) {
        l = new uint256[](1);
        l[0] = a;
    }

    function _list(uint256 a, uint256 b) internal pure returns (uint256[] memory l) {
        l = new uint256[](2);
        l[0] = a;
        l[1] = b;
    }
}
