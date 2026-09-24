// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {TreasurySponsorV4} from "../src/TreasurySponsorV4.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {MockPonsFeeEscrow} from "../src/mocks/MockPonsFeeEscrow.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";

/// @dev Random sequences of creator fees, sweeps, invites, raises, reclaims, loans, handoffs, freezes and pauses.
contract TreasuryV4Handler is Test {
    uint256 constant USDC = 1e6;
    uint256 constant INVITER_PK = 0xA11CE;

    TreasurySponsorV4 public treasury;
    CreditPoolV2 public pool;
    MockUSDC public usdc;
    MockIdentityRegistry public reg;
    MockPonsFeeEscrow public escrow;
    address public owner;
    address public timelock;
    uint256 public tid; // the treasury's root
    uint256 public rootId; // another backer
    address public rootOp;

    uint256[] public agentPks;
    uint256[] public agents;
    uint256[] public loans;

    uint256 public inflow; // every unit of the pool asset ever given to the treasury
    mapping(uint256 => bool) public openedByInvite; // the treasury line now open was opened by firstLine
    mapping(uint256 => uint256) public invitesUsed;
    uint64 public epochSeen;
    uint256 public spentThisEpoch; // the model of the epoch budget
    uint256 public inviteNonce;
    bool public priceFell;
    bool public badRaise; // a raise that landed on a line not open now
    bool public badReclaim; // a reclaim of a line with a loan open or not idle
    bool public strangerLined; // a first line without the owner's consent

    uint256 public okFirstLines;
    uint256 public okRaises;
    uint256 public okReclaims;
    uint256 public okBorrows;
    uint256 public okRepays;
    uint256 public okDefaults;
    uint256 public okSweeps;
    uint256 public okHandoffs;

    constructor(
        TreasurySponsorV4 t,
        CreditPoolV2 p,
        MockUSDC u,
        MockIdentityRegistry r,
        MockPonsFeeEscrow e,
        address o,
        address tl,
        uint256 root,
        address rootOwner
    ) {
        treasury = t;
        pool = p;
        usdc = u;
        reg = r;
        escrow = e;
        owner = o;
        timelock = tl;
        tid = t.agentId();
        rootId = root;
        rootOp = rootOwner;
        epochSeen = t.epochStart();
        for (uint256 i = 0; i < 10; i++) {
            uint256 pk = 0xC000 + i;
            address a = vm.addr(pk);
            agentPks.push(pk);
            usdc.mint(a, 1_000_000 * USDC);
            vm.startPrank(a);
            usdc.approve(address(pool), type(uint256).max);
            agents.push(reg.register(""));
            vm.stopPrank();
        }
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
            if (pool.getAgent(agents[i]).sponsor != tid) openedByInvite[agents[i]] = false;
        }
    }

    function _spent(uint256 amount) internal {
        if (treasury.epochStart() != epochSeen) {
            epochSeen = treasury.epochStart();
            spentThisEpoch = 0;
        }
        spentThisEpoch += amount;
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

    function _invite(uint256 id, uint64 expiry) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(INVITER_PK, treasury.inviteDigest(id, expiry));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // Money in
    // ------------------------------------------------------------------

    function creatorFees(uint256 amount) external track {
        amount = bound(amount, 1, 200 * USDC);
        usdc.mint(address(this), amount);
        usdc.approve(address(escrow), amount);
        escrow.creditToken(address(treasury), address(usdc), amount);
        inflow += amount;
    }

    function stray(uint256 amount) external track {
        amount = bound(amount, 1, 5 * USDC);
        usdc.mint(address(treasury), amount);
        inflow += amount;
    }

    function sweep() external track {
        try treasury.sweep() {
            okSweeps++;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Lines
    // ------------------------------------------------------------------

    function firstLine(uint256 a, bool fresh) external track {
        uint256 j = a % agents.length;
        uint256 id = agents[j];
        uint64 expiry = uint64(_now() + 1 days + (fresh ? ++inviteNonce : 0));
        bytes memory inv = _invite(id, expiry);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, tid, agentPks[j]);
        uint256 line;
        (, line,,,,,,,) = treasury.rules();
        try treasury.firstLine(id, expiry, inv, c, sig) {
            _spent(line);
            openedByInvite[id] = true;
            invitesUsed[id]++;
            okFirstLines++;
        } catch {}
    }

    /// An invite with a consent signed by somebody other than the owner must never open a line.
    function firstLineStranger(uint256 a) external track {
        uint256 id = agents[a % agents.length];
        uint64 expiry = uint64(_now() + 2 days + ++inviteNonce);
        bytes memory inv = _invite(id, expiry);
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, tid, 0xBAD);
        try treasury.firstLine(id, expiry, inv, c, sig) {
            strangerLined = true;
        } catch {}
    }

    function raise(uint256 a) external track {
        uint256 id = agents[a % agents.length];
        CreditPoolV2.Agent memory before = pool.getAgent(id);
        (,,,,, uint64 minSeasoning,,,) = treasury.rules();
        uint256 seasoned = uint256(before.enrolledAt) + minSeasoning;
        if (before.enrolledAt != 0 && seasoned > _now() && a % 2 == 0) vm.warp(seasoned);
        try treasury.raise(id) {
            if (before.sponsor != tid || before.frozen || before.defaulted || before.delegatedIn == 0) badRaise = true;
            _spent(pool.getAgent(id).delegatedIn - before.delegatedIn);
            okRaises++;
        } catch {}
    }

    function reclaim(uint256 a) external track {
        uint256 id = agents[a % agents.length];
        uint256 at = treasury.reclaimableAt(id);
        if (at > _now() && a % 2 == 0) vm.warp(at); // half the time, wait until it is idle
        CreditPoolV2.Agent memory before = pool.getAgent(id);
        uint256 last = treasury.lineAt(id);
        if (before.lastBorrowAt > last) last = before.lastBorrowAt;
        if (before.lastRepayAt > last) last = before.lastRepayAt;
        (,,,,,,,, uint64 idleAfter) = treasury.rules();
        try treasury.reclaim(id) {
            if (before.activeLoans != 0 || _now() < last + idleAfter) badReclaim = true;
            okReclaims++;
        } catch {}
    }

    function leave(uint256 a) external track {
        uint256 j = a % agents.length;
        vm.prank(vm.addr(agentPks[j]));
        try pool.leave(agents[j]) {} catch {}
    }

    function handoff(uint256 a, uint256 amount) external track {
        if (a % 3 != 0) return; // rarer: it moves agents away from the treasury
        uint256 j = (a / 3) % agents.length;
        (CreditPoolV2.Consent memory c, bytes memory sig) = _consent(agents[j], rootId, agentPks[j]);
        vm.prank(rootOp);
        try pool.vouchWithConsent(rootId, agents[j], bound(amount, 1 * USDC, 30 * USDC), 0, c, sig) {
            okHandoffs++;
        } catch {}
    }

    function freeze(uint256 a, bool f) external track {
        vm.prank(owner);
        try treasury.freeze(agents[a % agents.length], f) {} catch {}
    }

    // ------------------------------------------------------------------
    // Loans
    // ------------------------------------------------------------------

    function borrow(uint256 a, uint256 amount, uint256 term) external track {
        uint256 j = a % agents.length;
        // mostly on a treasury line
        for (uint256 k = 0; k < agents.length && a % 4 != 0; k++) {
            if (pool.getAgent(agents[(j + k) % agents.length]).sponsor == tid) {
                j = (j + k) % agents.length;
                break;
            }
        }
        uint256 id = agents[j];
        CreditPoolV2.Agent memory ag = pool.getAgent(id);
        uint256 room = ag.delegatedIn > ag.principalOut ? ag.delegatedIn - ag.principalOut : 0;
        amount = room >= 5 * USDC ? bound(amount, 5 * USDC, room) : 5 * USDC;
        address op = vm.addr(agentPks[j]);
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

    function repay(uint256 i, uint256 hold) external track {
        (uint256 l, bool ok) = _activeLoan(i);
        if (!ok) return;
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        // hold it a while, so records qualify for a raise
        uint256 term = ln.dueAt - ln.issuedAt;
        uint256 minHold = hold % 2 == 0 && term >= ln.minScoreTerm ? ln.minScoreTerm : 0;
        uint256 t = ln.issuedAt + bound(hold, minHold, term);
        if (t > _now()) vm.warp(t);
        vm.prank(vm.addr(agentPks[0]));
        try pool.repay(l, ln.agentId, type(uint256).max) {
            okRepays++;
        } catch {}
    }

    function markDefault(uint256 i) external track {
        if (i % 4 != 0) return; // rarer: a default marks its owner for good
        (uint256 l, bool ok) = _activeLoan(i / 4);
        if (!ok) return;
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        if (_now() <= ln.defaultableAt) vm.warp(ln.defaultableAt + 1);
        try pool.markDefault(l) {
            okDefaults++;
        } catch {}
    }

    // ------------------------------------------------------------------
    // Fees, owner, time
    // ------------------------------------------------------------------

    function collect() external track {
        try treasury.collect() {} catch {}
    }

    function retire(uint256 frac) external track {
        uint256 sh = pool.convertToShares(pool.freeBacking(tid)) * bound(frac, 1, 100) / 100;
        if (sh == 0) return;
        vm.prank(owner);
        try treasury.retire(sh, owner) {} catch {}
    }

    /// Rare pauses (a pause blocks new lines for up to 14 days); unpausing is common.
    function pausePool(uint256 p) external track {
        vm.prank(timelock);
        if (p % 10 == 0) pool.pause();
        else pool.unpause();
    }

    function warp(uint256 dt) external track {
        vm.warp(_now() + bound(dt, 1 hours, 12 days));
    }
}

contract TreasurySponsorV4Invariants is Test {
    uint256 constant USDC = 1e6;
    TreasuryV4Handler h;
    TreasurySponsorV4 treasury;
    CreditPoolV2 pool;
    MockUSDC usdc;
    MockIdentityRegistry reg;
    MockPonsFeeEscrow escrow;
    address owner = makeAddr("owner");
    address timelock = makeAddr("timelock");
    address sink = makeAddr("sink");
    uint256 TID;

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        escrow = new MockPonsFeeEscrow();
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
        treasury = new TreasurySponsorV4(
            pool, IPonsFeeEscrow(address(escrow)), IPonsFactoryCreator(address(escrow)), owner, sink
        );
        address lender = makeAddr("lender");
        usdc.mint(lender, 100_000 * USDC);
        vm.startPrank(lender);
        usdc.approve(address(pool), type(uint256).max);
        pool.deposit(100_000 * USDC, lender, 0);
        vm.stopPrank();
        vm.startPrank(owner);
        TID = reg.register("treasury");
        reg.safeTransferFrom(owner, address(treasury), TID);
        treasury.adopt(TID);
        treasury.setInviter(vm.addr(0xA11CE), true);
        TreasurySponsorV4.Rules memory r = TreasurySponsorV4.Rules({
            reserveBps: 5000,
            firstLine: 5e6,
            secondLine: 50e6,
            epochCap: 100e6,
            epochLength: 7 days,
            minSeasoning: 7 days,
            minQualified: 1,
            minScore: 30,
            idleAfter: 20 days
        });
        treasury.setRules(r);
        vm.stopPrank();
        address rootOp = makeAddr("rootOp");
        usdc.mint(rootOp, 1_000 * USDC);
        vm.startPrank(rootOp);
        usdc.approve(address(pool), type(uint256).max);
        uint256 root = reg.register("other-backer");
        pool.enrollRoot(root, 500 * USDC);
        vm.stopPrank();

        h = new TreasuryV4Handler(treasury, pool, usdc, reg, escrow, owner, timelock, root, rootOp);
        targetContract(address(h));
    }

    /// Every unit of creator fees is accounted for: in the reserve, staked, waiting here, or still in escrow.
    function invariant_moneyInAccounted() public view {
        uint256 held = usdc.balanceOf(address(treasury));
        assertEq(
            treasury.totalToReserve() + treasury.totalStaked() + held
                + escrow.balanceOfToken(address(treasury), address(usdc)),
            h.inflow()
        );
        assertLe(treasury.pendingStake(), held);
    }

    /// Every treasury line was opened by an invite plus the owner's consent, and sits within the second tier.
    function invariant_everyLineStandsOnAnInvite() public view {
        (,, uint256 secondLine,,,,,,) = treasury.rules();
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            CreditPoolV2.Agent memory a = pool.getAgent(id);
            if (a.sponsor != TID) continue;
            assertTrue(h.openedByInvite(id), "a treasury line without an invite");
            assertGt(pool.nonces(id), 0, "and without a consent");
            assertLe(a.delegatedIn, secondLine);
            assertLe(a.principalOut, a.delegatedIn);
        }
        assertFalse(h.strangerLined(), "a line on a stranger's signature");
    }

    /// The epoch budget bounds everything the rules can open (first lines and raises), and it matches a model.
    function invariant_epochCapHolds() public view {
        (,,, uint256 epochCap,,,,,) = treasury.rules();
        assertLe(treasury.vouchedThisEpoch(), epochCap);
        if (treasury.epochStart() == h.epochSeen()) assertEq(treasury.vouchedThisEpoch(), h.spentThisEpoch());
    }

    /// A raise only tops up a line open now; a reclaim only takes an idle line with no loan open.
    function invariant_raiseAndReclaimByTheRules() public view {
        assertFalse(h.badRaise(), "raise on a closed or frozen line");
        assertFalse(h.badReclaim(), "reclaim of a line in use");
    }

    /// Defaults are paid by the treasury's own shares: no bad debt, the share price never falls, the stake
    /// covers every line (to the pool's rounding dust).
    function invariant_noDefaultReachesLenders() public view {
        assertEq(pool.totalBadDebt(), 0);
        assertFalse(h.priceFell(), "share price fell");
        CreditPoolV2.Agent memory t = pool.getAgent(TID);
        assertLe(t.delegatedOut, pool.backing(TID) + 3 * t.childrenDefaulted + 1);
    }

    /// Sponsor fees reach the sink and nowhere else, exactly.
    function invariant_feesToTheSink() public view {
        assertEq(usdc.balanceOf(sink), treasury.totalCollected());
        uint256 sum;
        for (uint256 i = 0; i < h.agentCount(); i++) {
            sum += pool.feesFrom(TID, h.agents(i));
        }
        assertEq(treasury.totalCollected() + pool.sponsorFees(TID), sum);
    }

    function afterInvariant() public view {
        console2.log("firstLines", h.okFirstLines(), "raises", h.okRaises());
        console2.log("reclaims", h.okReclaims(), "handoffs", h.okHandoffs());
        console2.log("borrows", h.okBorrows(), "repays", h.okRepays());
        console2.log("defaults", h.okDefaults(), "sweeps", h.okSweeps());
    }
}
