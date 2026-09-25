// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {SeatVaultV3} from "../src/SeatVaultV3.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {MockPriors} from "./helpers/TokenMocks.sol";

/// @dev Random sequences of everything anyone can do to a seat, a loan, the pool's fee split or the vault.
///      Reverts are expected and ignored. After every call the handler records how each seat moved, so the
///      invariants can check that a graduation returned every token and a default burnt exactly its share.
contract SeatV2Handler is Test {
    uint256 constant USDC = 1e6;
    uint256 constant INITIAL = 10_000_000e18;
    uint256 constant MAX_AGENTS = 14;

    SeatVaultV3 public vault;
    CreditPoolV2 public pool;
    MockUSDC public usdc;
    MockPriors public priors;
    MockIdentityRegistry public reg;
    address public owner;
    address public timelock;
    uint256 public vaultId;
    uint256 public rootId; // another backer agents graduate to
    address public rootOp;

    uint256[] public actorPks;
    address[] public actors;
    uint256[] public agents;
    mapping(uint256 => uint256) public ownerPk; // agent id => its owner's key
    uint256[] public loans;

    // seat transitions, as last seen
    mapping(uint256 => SeatVaultV3.Status) public lastStatus;
    mapping(address => uint256) public burntFrom;
    mapping(address => uint256) public expectedFees;
    mapping(address => uint256) public claimed;
    uint256 public expectedBurn;
    mapping(uint256 => mapping(address => uint256)) public ghostOffer; // the model of the vault's offers
    mapping(address => uint256) public offeredBy;
    bool public priceFell;
    bool public defaultNotSettled;
    bool public graduationMissed;

    uint256 public okOpens;
    uint256 public okCloses;
    uint256 public okGraduations;
    uint256 public okSettles;
    uint256 public okDefaults;
    uint256 public okRepays;
    uint256 public okClaims;
    uint256 public okRegisters;
    uint256 public okBorrows;

    constructor(
        SeatVaultV3 v,
        CreditPoolV2 p,
        MockUSDC u,
        MockPriors t,
        MockIdentityRegistry r,
        address o,
        address tl,
        uint256 root,
        address rootOwner
    ) {
        vault = v;
        pool = p;
        usdc = u;
        priors = t;
        reg = r;
        owner = o;
        timelock = tl;
        vaultId = v.agentId();
        rootId = root;
        rootOp = rootOwner;
        for (uint256 i = 0; i < 8; i++) {
            uint256 pk = 0x7000 + i;
            address a = vm.addr(pk);
            actorPks.push(pk);
            actors.push(a);
            priors.mint(a, INITIAL);
            usdc.mint(a, 1_000_000 * USDC);
            vm.startPrank(a);
            priors.approve(address(vault), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
        // one agent per actor to start (a default marks its owner for good, so owners are spread wide)
        for (uint256 i = 0; i < 8; i++) {
            vm.prank(actors[i]);
            uint256 id = reg.register("");
            agents.push(id);
            ownerPk[id] = actorPks[i];
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    modifier track() {
        uint256 before = pool.totalAssets() * 1e18 / pool.totalShares();
        _;
        uint256 after_ = pool.totalAssets() * 1e18 / pool.totalShares();
        if (after_ < before) priceFell = true;
        for (uint256 i = 0; i < agents.length; i++) {
            uint256 id = agents[i];
            SeatVaultV3.Seat memory s = vault.getSeat(id);
            SeatVaultV3.Status was = lastStatus[id];
            if (was == SeatVaultV3.Status.Open && s.status == SeatVaultV3.Status.Settled) {
                uint256 b = s.amount * s.burnBps / 10_000;
                burntFrom[s.staker] += b;
                expectedBurn += b;
                okSettles++;
            } else if (was == SeatVaultV3.Status.Open && s.status == SeatVaultV3.Status.Closed) {
                okCloses++;
            }
            lastStatus[id] = s.status;
        }
    }

    function _agent(uint256 seed) internal view returns (uint256 id, uint256 pk) {
        id = agents[seed % agents.length];
        pk = ownerPk[id];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _consent(uint256 id, uint256 sponsor, uint256 pk)
        internal
        view
        returns (CreditPoolV2.Consent memory c, bytes memory sig)
    {
        c = CreditPoolV2.Consent({
            agentId: id,
            sponsorId: sponsor,
            owner: vm.addr(pk),
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: _now() + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, pool.consentDigest(c));
        sig = abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // Seats
    // ------------------------------------------------------------------

    function _consumed(uint256 id, address staker) internal {
        offeredBy[staker] -= ghostOffer[id][staker];
        ghostOffer[id][staker] = 0;
    }

    function offer(uint256 who, uint256 a) external track {
        (uint256 id,) = _agent(a);
        address w = _actor(who);
        vm.prank(w);
        try vault.offer(id) {
            uint256 amt = vault.offers(id, w);
            ghostOffer[id][w] = amt;
            offeredBy[w] += amt;
        } catch {}
    }

    function withdrawOffer(uint256 who, uint256 a, uint256 s) external track {
        (uint256 id,) = _agent(a);
        vm.prank(_actor(who));
        try vault.withdrawOffer(id, _actor(s)) {
            _consumed(id, _actor(s));
        } catch {}
    }

    function accept(uint256 a, uint256 s, bool stranger) external track {
        (uint256 id, uint256 pk) = _agent(a);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, vaultId, pk);
        vm.prank(stranger ? _actor((s % actors.length) + 1) : vm.addr(pk));
        try vault.accept(id, _actor(s), c, sig) {
            _consumed(id, _actor(s));
            okOpens++;
        } catch {}
    }

    function seat(uint256 a) external track {
        (uint256 id, uint256 pk) = _agent(a);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, vaultId, pk);
        vm.prank(vm.addr(pk));
        try vault.seat(id, c, sig) {
            _consumed(id, vm.addr(pk));
            okOpens++;
        } catch {}
    }

    function registerAndSeat(uint256 who) external track {
        if (agents.length >= MAX_AGENTS) return;
        uint256 k = who % actors.length;
        vm.prank(actors[k]);
        try vault.registerAndSeat("") returns (uint256 id) {
            agents.push(id);
            ownerPk[id] = actorPks[k];
            lastStatus[id] = SeatVaultV3.Status.Open;
            okOpens++;
            okRegisters++;
        } catch {}
    }

    function close(uint256 who, uint256 a) external track {
        (uint256 id, uint256 pk) = _agent(a);
        address caller = who % 3 == 0 ? vm.addr(pk) : (who % 3 == 1 ? vault.getSeat(id).staker : _actor(who));
        vm.prank(caller);
        try vault.close(id) {} catch {}
    }

    function settle(uint256 a, uint256 i) external track {
        (uint256 id,) = _agent(a);
        uint256 l = loans.length == 0 ? 0 : loans[i % loans.length];
        try vault.settle(id, l) {} catch {}
    }

    /// The agent leaves its sponsor (only with no loan open). If it was seated, that is a graduation.
    function leave(uint256 a) external track {
        (uint256 id, uint256 pk) = _agent(a);
        SeatVaultV3.Seat memory s = vault.getSeat(id);
        bool seated = s.status == SeatVaultV3.Status.Open && pool.getAgent(id).sponsor == vaultId;
        uint256 bal = priors.balanceOf(s.staker);
        vm.prank(vm.addr(pk));
        try pool.leave(id) {
            if (seated) {
                okGraduations++;
                if (
                    vault.getSeat(id).status != SeatVaultV3.Status.Closed
                        || priors.balanceOf(s.staker) != bal + s.amount
                ) {
                    graduationMissed = true;
                }
            }
        } catch {}
    }

    /// Another backer takes the agent over with its owner's consent: a graduation.
    function handoff(uint256 a, uint256 amount) external track {
        (uint256 id, uint256 pk) = _agent(a);
        SeatVaultV3.Seat memory s = vault.getSeat(id);
        bool seated = s.status == SeatVaultV3.Status.Open && pool.getAgent(id).sponsor == vaultId;
        uint256 bal = priors.balanceOf(s.staker);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, rootId, pk);
        vm.prank(rootOp);
        try pool.vouchWithConsent(rootId, id, bound(amount, 1 * USDC, 20 * USDC), 0, c, sig) {
            if (seated) {
                okGraduations++;
                if (
                    vault.getSeat(id).status != SeatVaultV3.Status.Closed
                        || priors.balanceOf(s.staker) != bal + s.amount
                ) {
                    graduationMissed = true;
                }
            }
        } catch {}
    }

    // ------------------------------------------------------------------
    // Loans
    // ------------------------------------------------------------------

    function borrow(uint256 a, uint256 amount, uint256 term) external track {
        (uint256 id, uint256 pk) = _agent(a);
        uint256[] memory open = vault.openSeats();
        if (open.length > 0 && a % 5 != 0) {
            id = open[(a / 5) % open.length];
            pk = ownerPk[id];
        }
        if (vault.getSeat(id).status != SeatVaultV3.Status.Open) {
            (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, vaultId, pk);
            vm.prank(vm.addr(pk));
            try vault.seat(id, c, sig) {
                _consumed(id, vm.addr(pk));
                okOpens++;
            } catch {}
        }
        CreditPoolV2.Agent memory ag = pool.getAgent(id);
        uint256 room = ag.delegatedIn > ag.principalOut ? ag.delegatedIn - ag.principalOut : 0;
        amount = room >= 5 * USDC ? bound(amount, 5 * USDC, room) : 5 * USDC;
        address op = vm.addr(pk);
        vm.prank(op);
        try pool.borrow(id, amount, uint64(bound(term, 1 days, 30 days)), op, type(uint256).max) returns (uint256 l) {
            loans.push(l);
            okBorrows++;
        } catch {}
    }

    function _activeLoan(uint256 i) internal view returns (uint256 l, bool ok) {
        uint256 n = loans.length;
        if (n == 0) return (0, false);
        i %= n;
        for (uint256 k = 0; k < n; k++) {
            l = loans[(i + k) % n];
            if (pool.getLoan(l).status == CreditPoolV2.LoanStatus.Active) return (l, true);
        }
    }

    function repay(uint256 i) external track {
        (uint256 l, bool ok) = _activeLoan(i);
        if (!ok) return;
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        SeatVaultV3.Seat memory s = vault.getSeat(ln.agentId);
        bool credited = ln.sponsorId == vaultId && s.status == SeatVaultV3.Status.Open;
        vm.prank(actors[0]);
        try pool.repay(l, ln.agentId, type(uint256).max) {
            okRepays++;
            if (credited) expectedFees[s.staker] += ln.sponsorCut + ln.premium;
        } catch {}
    }

    /// Rarer than a repayment: a default marks its owner, who then cannot borrow again.
    function markDefault(uint256 i) external track {
        if (i % 3 != 0) return;
        (uint256 l, bool ok) = _activeLoan(i / 3);
        if (!ok) return;
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        if (_now() <= ln.defaultableAt) vm.warp(ln.defaultableAt + 1);
        bool seated = ln.sponsorId == vaultId && vault.getSeat(ln.agentId).status == SeatVaultV3.Status.Open;
        try pool.markDefault(l) {
            okDefaults++;
            if (seated && vault.getSeat(ln.agentId).status != SeatVaultV3.Status.Settled) defaultNotSettled = true;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------

    function poke(uint256 a) external track {
        (uint256 id,) = _agent(a);
        try vault.poke(id) {} catch {}
    }

    function claim(uint256 who) external track {
        who %= actors.length;
        address w = _actor(who);
        for (uint256 k = 0; k < actors.length && vault.feesOwed(w) == 0; k++) {
            w = _actor(who + k);
        }
        uint256 owed = vault.feesOwed(w);
        vm.prank(w);
        try vault.claim(address(0xC1A1)) {
            claimed[w] += owed;
            okClaims++;
        } catch {}
    }

    function skim() external track {
        try vault.skim() {} catch {}
    }

    /// The pool's sponsor share moves; a seat's fees must not.
    function setSponsorBps(uint256 bps) external track {
        CreditPoolV2.Params memory p = pool.getParams();
        p.sponsorFeeBps = bound(bps, 0, 8500);
        vm.prank(timelock);
        pool.setParams(p);
    }

    function strayUSDG(uint256 amount) external track {
        usdc.mint(address(vault), bound(amount, 1, 1 * USDC));
    }

    // ------------------------------------------------------------------
    // Owner, time
    // ------------------------------------------------------------------

    function retune(uint256 burnBps, uint256 seatSize, uint256 line) external track {
        SeatVaultV3.Params memory p = SeatVaultV3.Params({
            seatSize: bound(seatSize, 1e18, 50_000e18),
            line: bound(line, 5 * USDC, 15 * USDC),
            burnBps: bound(burnBps, 2500, 10_000),
            maxOpenSeats: 5,
            epochCap: 60 * USDC,
            epochLength: 7 days
        });
        vm.prank(owner);
        vault.setParams(p);
    }

    function retire(uint256 frac) external track {
        uint256 sh = pool.convertToShares(pool.freeBacking(vaultId)) * bound(frac, 1, 100) / 100;
        if (sh == 0) return;
        vm.prank(owner);
        try vault.retire(sh, owner) {} catch {}
    }

    function fund(uint256 amount) external track {
        amount = bound(amount, 1 * USDC, 50 * USDC);
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        try vault.fund(amount) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external track {
        vm.warp(_now() + bound(dt, 1 hours, 10 days));
    }
}

contract SeatVaultV3Invariants is Test {
    uint256 constant USDC = 1e6;
    SeatV2Handler h;
    SeatVaultV3 vault;
    CreditPoolV2 pool;
    MockUSDC usdc;
    MockPriors priors;
    MockIdentityRegistry reg;
    address owner = makeAddr("owner");
    address timelock = makeAddr("timelock");
    uint256 VAULT_ID;
    uint256 supply0;

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPoolV2(
            IERC20(address(usdc)),
            IERC8004Identity(address(reg)),
            CreditPool(address(0)),
            timelock,
            timelock,
            CreditPoolV2.Params({
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
                keeperBounty: 1e5
            })
        );
        usdc.mint(address(this), 21 * USDC);
        usdc.approve(address(pool), type(uint256).max);
        pool.seed();
        pool.fundReserve(20 * USDC);
        priors = new MockPriors();
        vault = new SeatVaultV3(
            pool,
            IERC20(address(priors)),
            owner,
            makeAddr("sink"),
            SeatVaultV3.Params({
                seatSize: 25_000e18,
                line: 5 * USDC,
                burnBps: 5000,
                maxOpenSeats: 5,
                epochCap: 60 * USDC,
                epochLength: 7 days
            })
        );
        address lender = makeAddr("lender");
        usdc.mint(lender, 100_000 * USDC);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(100_000 * USDC, lender, 0);
        vm.stopPrank();
        vm.startPrank(owner);
        VAULT_ID = reg.register("seats");
        reg.safeTransferFrom(owner, address(vault), VAULT_ID);
        vault.adopt(VAULT_ID);
        usdc.mint(owner, 150 * USDC);
        usdc.approve(address(vault), 150 * USDC);
        vault.fund(150 * USDC);
        vm.stopPrank();
        address rootOp = makeAddr("rootOp");
        usdc.mint(rootOp, 1_000 * USDC);
        vm.startPrank(rootOp);
        usdc.approve(address(pool), type(uint256).max);
        uint256 root = reg.register("big-backer");
        pool.enrollRoot(root, 500 * USDC);
        vm.stopPrank();

        h = new SeatV2Handler(vault, pool, usdc, priors, reg, owner, timelock, root, rootOp);
        supply0 = priors.totalSupply();
        targetContract(address(h));
    }

    function _idx(address a) internal view returns (uint256) {
        for (uint256 k = 0; k < h.actorCount(); k++) {
            if (h.actors(k) == a) return k;
        }
        revert("unknown staker");
    }

    /// Each actor's escrowed $PRIORS: its offers (the handler's model of them) plus its open seats.
    function _escrow() internal view returns (uint256[] memory e, uint256 total) {
        uint256 n = h.actorCount();
        e = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            e[k] = h.offeredBy(h.actors(k));
            total += e[k];
        }
        for (uint256 i = 0; i < h.agentCount(); i++) {
            SeatVaultV3.Seat memory s = vault.getSeat(h.agents(i));
            if (s.status == SeatVaultV3.Status.Open) {
                e[_idx(s.staker)] += s.amount;
                total += s.amount;
            }
        }
    }

    /// Every $PRIORS the vault holds is owed back to a staker (open seats plus offers), and nothing else sits
    /// there. And every staker's tokens are accounted for: in its wallet, escrowed, or burnt by a default of its
    /// own seat at exactly that seat's burnBps. So a graduation or close returns every token, and a default burns
    /// exactly its share and returns the rest.
    function invariant_tokensHeldEqualsOwed_everyTokenAccounted() public view {
        (uint256[] memory e, uint256 total) = _escrow();
        assertEq(priors.balanceOf(address(vault)), vault.tokensHeld());
        assertEq(total, vault.tokensHeld(), "offers + open seats == held");
        for (uint256 k = 0; k < e.length; k++) {
            address a = h.actors(k);
            assertEq(priors.balanceOf(a) + e[k] + h.burntFrom(a), 10_000_000e18, "a staker's tokens");
        }
    }

    /// $PRIORS leaves circulation only through settled defaults, by exactly the seats' burn shares.
    function invariant_burnsAreExact() public view {
        assertEq(supply0 - priors.totalSupply(), vault.totalBurnt());
        assertEq(vault.totalBurnt(), h.expectedBurn());
    }

    /// Credits never exceed what the vault holds or is owed by the pool, and add up.
    function invariant_feesSolvent() public view {
        assertGe(usdc.balanceOf(address(vault)) + pool.sponsorFees(VAULT_ID), vault.totalFeesOwed());
        uint256 sum;
        for (uint256 k = 0; k < h.actorCount(); k++) {
            sum += vault.feesOwed(h.actors(k));
        }
        assertEq(sum, vault.totalFeesOwed());
    }

    /// Every staker is owed exactly the sponsor cut of its own agents' loans repaid while seated: credited,
    /// claimed or pending, to the unit, whatever the pool's sponsor share did meanwhile.
    function invariant_feesExact() public view {
        uint256 n = h.actorCount();
        uint256[] memory pending = new uint256[](n);
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            SeatVaultV3.Seat memory s = vault.getSeat(id);
            if (s.status == SeatVaultV3.Status.Open) pending[_idx(s.staker)] += vault.pendingFees(id);
        }
        for (uint256 k = 0; k < n; k++) {
            address a = h.actors(k);
            assertEq(vault.feesOwed(a) + h.claimed(a) + pending[k], h.expectedFees(a));
        }
    }

    /// A line from the vault stands behind an agent exactly when its seat is open, and no open seat has lost
    /// its line.
    function invariant_noLineWithoutASeat() public view {
        uint256 open;
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            CreditPoolV2.Agent memory a = pool.getAgent(id);
            bool seated = vault.getSeat(id).status == SeatVaultV3.Status.Open;
            if (seated) open++;
            assertEq(seated, a.sponsor == VAULT_ID && !a.defaulted, "seat open <=> live vault line");
            if (seated) assertGt(a.delegatedIn + a.principalOut, 0);
        }
        assertEq(open, vault.openCount());
        assertLe(vault.openCount(), 5);
    }

    /// Defaults are paid by the vault's stake alone: no bad debt, the share price never falls, the stake covers
    /// every line (to the pool's rounding dust).
    function invariant_noDefaultReachesLenders() public view {
        assertEq(pool.totalBadDebt(), 0);
        assertFalse(h.priceFell(), "share price fell");
        CreditPoolV2.Agent memory v = pool.getAgent(VAULT_ID);
        assertLe(v.delegatedOut, pool.backing(VAULT_ID) + 3 * v.childrenDefaulted + 1);
    }

    /// Hooks did their job in the same transaction: every default of a seated agent settled it, every
    /// graduation returned every token.
    function invariant_hooksSettleInTheSameTransaction() public view {
        assertFalse(h.defaultNotSettled(), "a default left its seat open");
        assertFalse(h.graduationMissed(), "a graduation kept tokens");
    }

    function afterInvariant() public view {
        console2.log("opens", h.okOpens(), "closes", h.okCloses());
        console2.log("graduations", h.okGraduations(), "registers", h.okRegisters());
        console2.log("defaults", h.okDefaults(), "settles", h.okSettles());
        console2.log("repays", h.okRepays(), "claims", h.okClaims());
        console2.log("borrows", h.okBorrows());
    }
}
