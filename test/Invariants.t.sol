// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// @dev Random sequences of every user action. Reverts are expected and ignored; what matters is what holds after.
contract Handler is Test {
    uint256 constant USDC = 1e6;
    CreditPool public pool;
    MockUSDC public usdc;
    MockIdentityRegistry public reg;
    address public owner;

    address[] public actors;
    uint256[] public agents; // agents[i] is owned by actors[i]
    uint256 public netDeposits; // lender deposits - withdrawals
    // ghost counters: proof the fuzzer reaches the interesting states
    uint256 public okBorrows;
    uint256 public okRepays;
    uint256 public okDefaults;
    uint256 public okVouches;
    uint256 public okRoots;
    string public lastVouchError;
    mapping(bytes4 => uint256) public vouchErrors;
    uint256 public vouchAttempts;

    constructor(CreditPool p, MockUSDC u, MockIdentityRegistry r, address o) {
        pool = p;
        usdc = u;
        reg = r;
        owner = o;
        for (uint256 i = 0; i < 8; i++) {
            address a = address(uint160(0x1000 + i));
            actors.push(a);
            usdc.mint(a, 1_000_000 * USDC);
            vm.prank(a);
            usdc.approve(address(pool), type(uint256).max);
            vm.prank(a);
            agents.push(reg.register(""));
        }
    }

    function _actor(uint256 seed) internal view returns (address, uint256) {
        uint256 i = seed % actors.length;
        return (actors[i], agents[i]);
    }

    function deposit(uint256 seed, uint256 amount) external {
        (address a,) = _actor(seed);
        amount = bound(amount, 1, 100_000 * USDC);
        vm.prank(a);
        try pool.deposit(amount, a) {
            netDeposits += amount;
        } catch {}
    }

    function withdraw(uint256 seed, uint256 sh) external {
        (address a,) = _actor(seed);
        uint256 have = pool.shares(a);
        if (have == 0) return;
        sh = bound(sh, 1, have);
        uint256 assets = pool.convertToAssets(sh);
        vm.prank(a);
        try pool.withdraw(sh, a) {
            netDeposits -= assets;
        } catch {}
    }

    function fundReserve(uint256 seed, uint256 amount) external {
        (address a,) = _actor(seed);
        amount = bound(amount, 1, 5_000 * USDC);
        vm.prank(a);
        try pool.fundReserve(amount) {} catch {}
    }

    function withdrawReserve(uint256 amount) external {
        amount = bound(amount, 1, 5_000 * USDC);
        vm.prank(owner);
        try pool.withdrawReserve(amount, owner) {} catch {}
    }

    function enrollRoot(uint256 seed, uint256 stake) external {
        (address a, uint256 id) = _actor(seed);
        stake = bound(stake, 1, 2_000 * USDC);
        vm.prank(a);
        try pool.enrollRoot(id, stake) {
            okRoots++;
        } catch {}
    }

    function addStake(uint256 seed, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        amount = bound(amount, 1, 2_000 * USDC);
        vm.prank(a);
        try pool.addStake(id, amount) {} catch {}
    }

    function withdrawStake(uint256 seed, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        amount = bound(amount, 1, 2_000 * USDC);
        vm.prank(a);
        try pool.withdrawStake(id, amount, a) {} catch {}
    }

    function vouch(uint256 seed, uint256 childSeed, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        (, uint256 child) = _actor(childSeed);
        // mostly vouch within what the sponsor can actually delegate, sometimes not
        CreditPool.Agent memory s = pool.getAgent(id);
        uint256 room = pool.available(id);
        if (!s.isRoot) {
            room = s.earned > s.delegatedOut ? (s.earned - s.delegatedOut < room ? s.earned - s.delegatedOut : room) : 0;
        }
        amount = seed % 5 == 0 ? bound(amount, 1, 1_000 * USDC) : bound(amount, 1, room > 1 ? room : 1);
        vm.prank(a);
        vouchAttempts++;
        try pool.vouch(id, child, amount) {
            okVouches++;
        } catch (bytes memory err) {
            lastVouchError = vm.toString(err);
            vouchErrors[bytes4(err)]++;
        }
    }

    function unvouch(uint256 seed, uint256 childSeed, uint256 amount) external {
        (address a, uint256 id) = _actor(seed);
        (, uint256 child) = _actor(childSeed);
        amount = bound(amount, 1, 1_000 * USDC);
        vm.prank(a);
        try pool.unvouch(id, child, amount) {} catch {}
    }

    function borrow(uint256 seed, uint256 amount, uint64 term) external {
        (address a, uint256 id) = _actor(seed);
        uint256 avail = pool.available(id);
        // mostly borrow within the line (so the walk reaches repayments, growth and defaults), sometimes not
        amount = seed % 5 == 0
            ? bound(amount, 1 * USDC, 600 * USDC)
            : bound(amount, 5 * USDC, avail > 5 * USDC ? avail : 5 * USDC);
        term = uint64(bound(term, 1 hours, 40 days));
        vm.prank(a);
        try pool.borrow(id, amount, term, a) {
            okBorrows++;
        } catch {}
    }

    function repay(uint256 seed, uint256 loanSeed) external {
        (address a,) = _actor(seed);
        uint256 n = pool.loanCount();
        if (n == 0) return;
        uint256 loanId = 1 + (loanSeed % n);
        vm.prank(a);
        try pool.repay(loanId) {
            okRepays++;
        } catch {}
    }

    function claimSponsorFees(uint256 seed) external {
        (address a, uint256 id) = _actor(seed);
        vm.prank(a);
        try pool.claimSponsorFees(id, a) {} catch {}
    }

    function markDefault(uint256 loanSeed) external {
        uint256 n = pool.loanCount();
        if (n == 0) return;
        try pool.markDefault(1 + (loanSeed % n)) {
            okDefaults++;
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 20 days));
    }
}

contract InvariantsTest is Test {
    CreditPool pool;
    MockUSDC usdc;
    MockIdentityRegistry reg;
    Handler handler;
    address owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPool(IERC20(address(usdc)), IERC8004Identity(address(reg)), owner);
        handler = new Handler(pool, usdc, reg, owner);
        targetContract(address(handler));
    }

    /// Cash in the contract is exactly lender liquidity + root stakes + reserve. Nothing leaks, nothing is double counted.
    function invariant_cashIsFullyAccounted() public view {
        assertEq(
            usdc.balanceOf(address(pool)),
            pool.poolLiquidity() + pool.totalStake() + pool.reserve() + pool.unclaimedSponsorFees()
        );
    }

    /// Every dollar of unbacked (earned) credit is pre-funded by the reserve.
    function invariant_reserveCoversEarned() public view {
        assertGe(pool.reserve(), pool.totalEarned());
    }

    /// Therefore lenders never lose principal: all written-off debt was paid by the reserve...
    function invariant_lendersNeverLose() public view {
        assertEq(pool.totalBadDebt(), pool.totalReserveCovered());
    }

    /// ...and pool assets are exactly what lenders put in plus the fees borrowers paid.
    function invariant_assetsAreDepositsPlusFees() public view {
        // Early-exit fees stay in the pool for the lenders who did not leave, so they are part of the
        // identity too. Tracked as their own accumulator rather than folded into `totalFeesEarned`, which
        // means "what borrowers paid" and should keep meaning only that.
        assertEq(pool.totalAssets(), handler.netDeposits() + pool.totalFeesEarned() + pool.totalExitFees());
    }

    /// Deterministic drive of the handler: shows the random walk reaches borrows, repayments, defaults and
    /// reserve payouts, so the invariants above are tested against real states and not just reverts.
    function test_handlerReachesInterestingStates() public {
        uint256 r = 42;
        for (uint256 i = 0; i < 6000; i++) {
            r = uint256(keccak256(abi.encode(r)));
            uint256 op = r % 14;
            r = uint256(keccak256(abi.encode(r, op))); // independent bits for the arguments, so op and actor don't alias
            if (op == 0) handler.deposit(r, r >> 8);
            else if (op == 1) handler.fundReserve(r, r >> 8);
            else if (op == 2) handler.enrollRoot(r, r >> 8);
            else if (op == 3) handler.vouch(r, r >> 16, r >> 32);
            else if (op == 4 || op == 5) handler.borrow(r, r >> 16, uint64(r >> 40));
            else if (op == 6 || op == 7) handler.repay(r, r >> 16);
            else if (op == 8) handler.markDefault(r >> 8);
            else if (op == 9) handler.warp(r >> 8);
            else if (op == 10) handler.withdraw(r, r >> 8);
            else if (op == 11) handler.withdrawReserve(r >> 8);
            else if (op == 12) handler.claimSponsorFees(r);
            else handler.addStake(r, r >> 8);
            invariant_cashIsFullyAccounted();
            invariant_reserveCoversEarned();
            invariant_lendersNeverLose();
            invariant_assetsAreDepositsPlusFees();
        }
        emit log_named_uint("roots", handler.okRoots());
        emit log_named_uint("vouch attempts", handler.vouchAttempts());
        emit log_named_uint("InsufficientCapacity", handler.vouchErrors(CreditPool.InsufficientCapacity.selector));
        emit log_named_uint("NotEnrolled", handler.vouchErrors(CreditPool.NotEnrolled.selector));
        emit log_named_uint("IsRoot", handler.vouchErrors(CreditPool.IsRoot.selector));
        emit log_named_uint("WrongSponsor", handler.vouchErrors(CreditPool.WrongSponsor.selector));
        emit log_named_uint("InvalidAgent", handler.vouchErrors(CreditPool.InvalidAgent.selector));
        emit log_named_uint("DelegationExceedsEarned", handler.vouchErrors(CreditPool.DelegationExceedsEarned.selector));
        emit log_named_uint("AgentDefaulted", handler.vouchErrors(CreditPool.AgentDefaulted.selector));
        emit log_named_uint("ZeroAmount", handler.vouchErrors(CreditPool.ZeroAmount.selector));
        emit log_named_uint("NotController", handler.vouchErrors(CreditPool.NotController.selector));
        assertGt(handler.okVouches(), 0, "no vouches");
        assertGt(handler.okBorrows(), 0, "no borrows");
        assertGt(handler.okRepays(), 0, "no repays");
        assertGt(handler.okDefaults(), 0, "no defaults");
        assertGt(pool.totalReserveCovered(), 0, "reserve never paid out");
        assertGt(pool.totalEarned() + pool.totalReserveCovered(), 0);
        emit log_named_uint("roots", handler.okRoots());
        emit log_named_string("last vouch error", handler.lastVouchError());
        emit log_named_uint("vouches", handler.okVouches());
        emit log_named_uint("borrows", handler.okBorrows());
        emit log_named_uint("repays", handler.okRepays());
        emit log_named_uint("defaults", handler.okDefaults());
        emit log_named_uint("bad debt (USDC)", pool.totalBadDebt() / 1e6);
        emit log_named_uint("reserve covered (USDC)", pool.totalReserveCovered() / 1e6);
    }

    /// No agent's exposure (borrowed + delegated) exceeds its capacity, and non-roots delegate only what they earned.
    function invariant_exposureWithinCapacity() public view {
        uint256 n = pool.enrolledCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = pool.enrolledAgents(i);
            CreditPool.Agent memory a = pool.getAgent(id);
            if (a.defaulted) continue;
            if (!a.isRoot) assertLe(a.delegatedOut, a.earned);
            if (!a.isRoot && pool.getAgent(a.sponsor).defaulted) continue; // orphan: line void, exposure may exceed
            assertLe(a.principalOut + a.delegatedOut, pool.capacity(id) + 0);
        }
    }
}
