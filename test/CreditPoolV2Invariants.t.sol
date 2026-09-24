// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2, IBackerHook} from "../src/CreditPoolV2.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockIdentityRegistry} from "../src/mocks/MockIdentityRegistry.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";

/// @dev A hook the fuzzer can switch between allowing, refusing and reverting.
contract FlakyHook is IBackerHook {
    uint256 public mode; // 0 allow, 1 refuse, 2 revert

    function setMode(uint256 m) external {
        mode = m % 3;
    }

    function canBorrow(uint256, uint256, uint256, uint64, uint256, address, address, address)
        external
        view
        returns (bool)
    {
        if (mode == 2) revert("x");
        return mode == 0;
    }

    function onBorrow(uint256, uint256, uint256) external view {
        if (mode == 2) revert("x");
    }

    function onDefault(uint256, uint256, uint256, uint256, bool) external view {
        if (mode == 2) revert("x");
    }

    function onRelease(uint256, uint256, uint256, uint8) external view {
        if (mode == 2) revert("x");
    }
}

contract V2Handler is Test {
    uint256 constant USDC = 1e6;
    CreditPoolV2 public pool;
    MockUSDC public usdc;
    MockIdentityRegistry public reg;
    address public owner;
    FlakyHook public hookA;

    address[] public lenders;
    uint256[] public roots;
    address[] public rootOwners;
    uint256[] public agents;
    uint256[] public agentPks;
    uint256[] public loans;

    mapping(uint256 => mapping(uint256 => bool)) public consented; // agent => root
    mapping(uint256 => uint256) public claimed; // root => fees claimed
    bool public priceFell;
    uint256 public okBorrows;
    uint256 public okRepays;
    uint256 public okDefaults;
    uint256 public okHandoffs;
    uint256 public okFreezes;
    uint256 public okLeaves;

    constructor(CreditPoolV2 p, MockUSDC u, MockIdentityRegistry r, address o) {
        pool = p;
        usdc = u;
        reg = r;
        owner = o;
        hookA = new FlakyHook();
        for (uint256 i = 0; i < 3; i++) {
            address l = address(uint160(0x9000 + i));
            lenders.push(l);
            usdc.mint(l, 1_000_000 * USDC);
            vm.prank(l);
            usdc.approve(address(pool), type(uint256).max);
        }
        for (uint256 i = 0; i < 3; i++) {
            address ro = address(uint160(0xA000 + i));
            rootOwners.push(ro);
            usdc.mint(ro, 1_000_000 * USDC);
            vm.startPrank(ro);
            usdc.approve(address(pool), type(uint256).max);
            uint256 id = reg.register("");
            pool.enrollRoot(id, 200 * USDC);
            vm.stopPrank();
            roots.push(id);
        }
        vm.prank(rootOwners[0]);
        pool.setHook(roots[0], address(hookA));
        for (uint256 i = 0; i < 12; i++) {
            uint256 pk = 0xC000 + i;
            address ao = vm.addr(pk);
            agentPks.push(pk);
            usdc.mint(ao, 1_000_000 * USDC);
            vm.startPrank(ao);
            usdc.approve(address(pool), type(uint256).max);
            agents.push(reg.register(""));
            vm.stopPrank();
        }
    }

    modifier watchPrice() {
        uint256 before = pool.totalAssets() * 1e18 / pool.totalShares();
        _;
        uint256 after_ = pool.totalAssets() * 1e18 / pool.totalShares();
        if (after_ < before) priceFell = true;
    }

    function agentCount() external view returns (uint256) {
        return agents.length;
    }

    function rootCount() external view returns (uint256) {
        return roots.length;
    }

    function lenderCount() external view returns (uint256) {
        return lenders.length;
    }

    function deposit(uint256 i, uint256 amt) external watchPrice {
        address l = lenders[i % lenders.length];
        amt = bound(amt, 1, 50_000 * USDC);
        vm.prank(l);
        try pool.deposit(amt, l, 0) {} catch {}
    }

    function withdraw(uint256 i, uint256 frac) external watchPrice {
        address l = lenders[i % lenders.length];
        uint256 s = pool.shares(l) * bound(frac, 1, 100) / 100;
        if (s == 0) return;
        vm.prank(l);
        try pool.withdraw(s, l) {} catch {}
    }

    function addStake(uint256 r, uint256 amt) external watchPrice {
        amt = bound(amt, 1, 1_000 * USDC);
        vm.prank(lenders[0]);
        try pool.addStake(roots[r % roots.length], amt) {} catch {}
    }

    function unlock(uint256 r, uint256 frac) external watchPrice {
        uint256 k = r % roots.length;
        uint256 s = pool.rootShares(roots[k]) * bound(frac, 1, 100) / 100;
        if (s == 0) return;
        vm.prank(rootOwners[k]);
        try pool.unlock(roots[k], s, rootOwners[k]) {} catch {}
    }

    function sponsor(uint256 r, uint256 a, uint256 amt, uint256 prem) external watchPrice {
        _sponsor(r, a, amt, prem);
    }

    function _sponsor(uint256 r, uint256 a, uint256 amt, uint256 prem) internal {
        uint256 k = r % roots.length;
        uint256 j = a % agents.length;
        uint256 id = agents[j];
        CreditPoolV2.Consent memory c = CreditPoolV2.Consent({
            agentId: id,
            sponsorId: roots[k],
            owner: vm.addr(agentPks[j]),
            maxPremiumBps: bound(prem, 0, 200),
            nonce: pool.nonces(id),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(agentPks[j], pool.consentDigest(c));
        uint256 old = pool.getAgent(id).sponsor;
        amt = bound(amt, 1 * USDC, 60 * USDC);
        vm.prank(rootOwners[k]);
        try pool.vouchWithConsent(roots[k], id, amt, c.maxPremiumBps, c, abi.encodePacked(rr, ss, v)) {
            consented[id][roots[k]] = true;
            if (old != 0 && old != roots[k]) okHandoffs++;
        } catch {}
    }

    function topUp(uint256 a, uint256 amt) external watchPrice {
        uint256 id = agents[a % agents.length];
        uint256 s = pool.getAgent(id).sponsor;
        if (s == 0) return;
        amt = bound(amt, 1, 20 * USDC);
        vm.prank(reg.ownerOf(s));
        try pool.vouch(s, id, amt) {} catch {}
    }

    function unvouch(uint256 a, uint256 frac) external watchPrice {
        uint256 id = agents[a % agents.length];
        CreditPoolV2.Agent memory ag = pool.getAgent(id);
        if (ag.sponsor == 0) return;
        uint256 undrawn = ag.delegatedIn > ag.principalOut ? ag.delegatedIn - ag.principalOut : 0;
        uint256 amt = undrawn * bound(frac, 1, 100) / 100;
        if (amt == 0) return;
        vm.prank(reg.ownerOf(ag.sponsor));
        try pool.unvouch(ag.sponsor, id, amt) {} catch {}
    }

    function leave(uint256 a) external watchPrice {
        uint256 j = a % agents.length;
        vm.prank(vm.addr(agentPks[j]));
        try pool.leave(agents[j]) {
            okLeaves++;
        } catch {}
    }

    function freeze(uint256 a, bool f) external watchPrice {
        uint256 id = agents[a % agents.length];
        uint256 s = pool.getAgent(id).sponsor;
        if (s == 0) return;
        vm.prank(reg.ownerOf(s));
        try pool.freeze(id, f) {
            if (f) okFreezes++;
        } catch {}
    }

    function borrow(uint256 a, uint256 amt, uint256 term) external watchPrice {
        uint256 j = a % agents.length;
        address ao = vm.addr(agentPks[j]);
        amt = bound(amt, 5 * USDC, 40 * USDC);
        if (pool.getAgent(agents[j]).sponsor == 0) _sponsor(a >> 8, j, amt + (term % (20 * USDC)), term);
        CreditPoolV2.Agent memory ag = pool.getAgent(agents[j]);
        uint256 room = ag.delegatedIn > ag.principalOut ? ag.delegatedIn - ag.principalOut : 0;
        if (room >= 5 * USDC) amt = bound(amt, 5 * USDC, room);
        term = bound(term, 1 days, 30 days);
        vm.prank(ao);
        try pool.borrow(agents[j], amt, uint64(term), ao, type(uint256).max) returns (uint256 l) {
            loans.push(l);
            okBorrows++;
        } catch {}
    }

    function repay(uint256 i) external watchPrice {
        if (loans.length == 0) return;
        uint256 l = loans[i % loans.length];
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        if (ln.status != CreditPoolV2.LoanStatus.Active) return;
        vm.prank(lenders[0]);
        try pool.repay(l, ln.agentId, type(uint256).max) {
            okRepays++;
        } catch {}
    }

    function markDefault(uint256 i) external watchPrice {
        if (loans.length == 0) return;
        uint256 l = loans[i % loans.length];
        CreditPoolV2.Loan memory ln = pool.getLoan(l);
        if (ln.status != CreditPoolV2.LoanStatus.Active) return;
        if (block.timestamp <= ln.defaultableAt) vm.warp(ln.defaultableAt + 1);
        try pool.markDefault(l) {
            okDefaults++;
        } catch {}
    }

    function claim(uint256 r) external watchPrice {
        uint256 k = r % roots.length;
        uint256 f = pool.sponsorFees(roots[k]);
        if (f == 0) return;
        vm.prank(rootOwners[k]);
        try pool.claimSponsorFees(roots[k], rootOwners[k]) {
            claimed[roots[k]] += f;
        } catch {}
    }

    function hookMode(uint256 m) external {
        hookA.setMode(m);
    }

    function retune(uint256 fee, uint256 grace, uint256 sp) external watchPrice {
        CreditPoolV2.Params memory p = pool.getParams();
        p.feeBps = bound(fee, 0, 500);
        p.grace = uint64(bound(grace, 1 days, 10 days));
        p.sponsorFeeBps = bound(sp, 0, 8000);
        vm.prank(owner);
        pool.setParams(p);
    }

    function warp(uint256 dt) external watchPrice {
        vm.warp(block.timestamp + bound(dt, 1 hours, 15 days));
    }
}

contract CreditPoolV2Invariants is Test {
    uint256 constant USDC = 1e6;
    V2Handler h;
    CreditPoolV2 pool;
    MockUSDC usdc;
    MockIdentityRegistry reg;
    address owner = makeAddr("timelock");

    function setUp() public {
        usdc = new MockUSDC();
        reg = new MockIdentityRegistry();
        pool = new CreditPoolV2(
            IERC20(address(usdc)),
            IERC8004Identity(address(reg)),
            CreditPool(address(0)),
            owner,
            owner,
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
        usdc.mint(address(this), 100 * USDC);
        usdc.approve(address(pool), type(uint256).max);
        pool.seed();
        pool.fundReserve(20 * USDC); // covers rounding dust (see _slash)
        h = new V2Handler(pool, usdc, reg, owner);
        address l0 = h.lenders(0);
        vm.prank(l0);
        pool.deposit(10_000 * USDC, l0, 0);
        targetContract(address(h));
    }

    /// Every agent's drawn principal sits inside its line.
    function invariant_drawnWithinLine() public view {
        uint256 sumIn;
        uint256 sumOut;
        for (uint256 i = 0; i < h.agentCount(); i++) {
            CreditPoolV2.Agent memory a = pool.getAgent(h.agents(i));
            assertLe(a.principalOut, a.delegatedIn);
            sumIn += a.delegatedIn;
            sumOut += a.principalOut;
        }
        uint256 sumDel;
        for (uint256 r = 0; r < h.rootCount(); r++) {
            sumDel += pool.getAgent(h.roots(r)).delegatedOut;
        }
        assertEq(sumIn, sumDel, "every line comes from a backer");
        assertEq(sumOut, pool.totalPrincipalOut());
    }

    /// Every backer can pay for every line it vouched (to within rounding the reserve covers).
    function invariant_backersCoverTheirLines() public view {
        for (uint256 r = 0; r < h.rootCount(); r++) {
            uint256 id = h.roots(r);
            CreditPoolV2.Agent memory ro = pool.getAgent(id);
            assertLe(ro.delegatedOut, pool.backing(id) + 3 * ro.childrenDefaulted + 1);
        }
    }

    /// No loss ever reaches lenders.
    function invariant_noBadDebtPriceNeverFalls() public view {
        assertEq(pool.totalBadDebt(), 0);
        assertFalse(h.priceFell(), "share price fell");
    }

    function invariant_cashCoversEveryClaim() public view {
        assertGe(usdc.balanceOf(address(pool)), pool.poolLiquidity() + pool.reserve() + pool.unclaimedSponsorFees());
    }

    function invariant_sharesAddUp() public view {
        uint256 sum = pool.shares(pool.DEAD());
        for (uint256 i = 0; i < h.lenderCount(); i++) {
            sum += pool.shares(h.lenders(i));
        }
        for (uint256 r = 0; r < h.rootCount(); r++) {
            sum += pool.rootShares(h.roots(r));
        }
        assertEq(sum, pool.totalShares());
    }

    function invariant_feesAttributedExactly() public view {
        for (uint256 r = 0; r < h.rootCount(); r++) {
            uint256 id = h.roots(r);
            uint256 sum;
            for (uint256 i = 0; i < h.agentCount(); i++) {
                sum += pool.feesFrom(id, h.agents(i));
            }
            assertEq(pool.sponsorFees(id) + h.claimed(id), sum);
        }
    }

    /// Nobody is sponsored without having signed for that sponsor.
    function invariant_consentBehindEverySponsorship() public view {
        for (uint256 i = 0; i < h.agentCount(); i++) {
            uint256 id = h.agents(i);
            uint256 s = pool.getAgent(id).sponsor;
            if (s != 0) assertTrue(h.consented(id, s));
        }
    }

    function afterInvariant() public view {
        console2.log("borrows", h.okBorrows(), "repays", h.okRepays());
        console2.log("defaults", h.okDefaults(), "handoffs", h.okHandoffs());
        console2.log("freezes", h.okFreezes(), "leaves", h.okLeaves());
    }
}
