// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SeatVaultV5} from "../../src/SeatVaultV5.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {ISwapLimiter} from "../../src/interfaces/ISwapLimiter.sol";
import {ISeatSizerV4, IV4SwapOnce, IPermit2V5, IExtsloadV5, V5PoolKey} from "../../src/interfaces/IV5Deps.sol";
import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {C} from "../../src/v5/V5Types.sol";
import {V5Auto} from "../../src/v5/V5Auto.sol";
import {IV5Lens} from "./IV5Lens.sol";
import {
    MockUSDG,
    MockPriors,
    MockRegistryV5,
    MockPoolManager,
    MockSizer,
    MockLimiter,
    MockSwapper,
    MockPermit2
} from "./V5Mocks.sol";

/// @dev The rest of CreditPoolV2's surface the tests drive (the agents' and the guardian's side).
interface IPoolT is ICreditPoolV2 {
    function setDelegate(uint256 id, address delegate) external;
    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        returns (uint256 loanId);
    function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue) external;
    function leave(uint256 agentId) external;
    function pause() external;
    function unpause() external;
    function totalShares() external view returns (uint256);
}

/// @dev The V5 test rig: the real CreditPoolV2 (deployed from its artifact, see test/autopay/IPoolV2.sol for why), a
///      freezable USDG, a burnable $PRIORS, a registry that can fail, the SeatSizer, the PoolManager's slot0, the
///      SwapLimiter, a swapper over a constant price and Permit2, every one a mock with the live contract's surface.
///      Agents are qualified on the pool the way 2.4's entry reads them (3 loans held 7 days under another root, 14
///      days since enrolment) before the tests start.
abstract contract V5Base is Test {
    uint256 internal constant U = 1e6; // one USDG
    uint256 internal constant T = 1e18; // one $PRIORS
    uint256 internal constant EPOCH0 = 1_789_948_800; // a Monday 00:00 UTC
    uint256 internal constant P0 = 1e15; // $0.001 per $PRIORS, 18-decimal price

    MockUSDG internal usdg;
    MockPriors internal priors;
    MockRegistryV5 internal reg;
    IPoolT internal pool;
    MockPoolManager internal pm;
    MockSizer internal sizer;
    MockLimiter internal limiter;
    MockSwapper internal swapper;
    MockPermit2 internal permit2;
    SeatVaultV5 internal v5;
    IV5Lens internal lens;
    bytes32 internal priceSlot;
    V5PoolKey internal key;

    address internal timelock = makeAddr("timelock");
    address internal guardian = makeAddr("guardian");
    address internal keeper = makeAddr("keeper");
    address internal bb = makeAddr("buyAndBack");
    address internal retireTo = makeAddr("retireTo");
    address internal lender = makeAddr("lender");
    address internal funder = makeAddr("funder");
    address internal otherRootOwner = makeAddr("otherRootOwner");
    address internal backer1 = makeAddr("backer1");
    address internal backer2 = makeAddr("backer2");
    address internal anyone = makeAddr("anyone");

    uint256 internal ROOT; // V5's root identity
    uint256 internal OROOT; // another root, for agents' histories and handoffs

    uint256[] internal pks;
    uint256[] internal agents;
    mapping(uint256 => uint256) internal pkOf; // agent id => owner key

    function _poolParams() internal pure virtual returns (ICreditPoolV2.Params memory) {
        return ICreditPoolV2.Params({
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
            maxUtilizationBps: 10_000,
            keeperBounty: 0
        });
    }

    function _agentCount() internal pure virtual returns (uint256) {
        return 4;
    }

    /// @dev The pool's v1 (`importFromV1`'s source): none by default.
    function _v1() internal virtual returns (address) {
        return address(0);
    }

    function _baseInit() internal view returns (SeatVaultV5.Init memory i) {
        i.pool = pool;
        i.priors = IERC20(address(priors));
        i.permit2 = IPermit2V5(address(permit2));
        i.swapper = IV4SwapOnce(address(swapper));
        i.swapLimiter = ISwapLimiter(address(limiter));
        i.poolKey = key;
        i.poolManager = IExtsloadV5(address(pm));
        i.buyAndBack = bb;
        i.sizer = ISeatSizerV4(address(sizer));
        i.rootId = ROOT;
        i.guardian = guardian;
        i.timelock = timelock;
        i.retireTo = retireTo;
        i.keeper = keeper;
        i.epoch0 = EPOCH0;
        i.maxSwapUsdg = 1_900 * U;
        i.openRoom = 500 * U;
        i.raiseRoom = 500 * U;
        i.vouchCap = 1_083_790_000;
    }

    function _deployV5() internal returns (SeatVaultV5) {
        return new SeatVaultV5(_baseInit());
    }

    function setUp() public virtual {
        vm.warp(EPOCH0 + 3 days + 6 hours);
        usdg = new MockUSDG();
        priors = new MockPriors();
        reg = new MockRegistryV5();
        pool = IPoolT(
            deployCode(
                "CreditPoolV2.sol:CreditPoolV2",
                abi.encode(address(usdg), address(reg), _v1(), timelock, guardian, _poolParams())
            )
        );
        usdg.mint(address(this), 1 * U);
        usdg.approve(address(pool), 1 * U);
        (bool ok,) = address(pool).call(abi.encodeWithSignature("seed()"));
        require(ok, "seed");
        usdg.mint(lender, 100_000 * U);
        vm.startPrank(lender);
        usdg.approve(address(pool), type(uint256).max);
        (ok,) = address(pool).call(abi.encodeWithSignature("deposit(uint256,address,uint256)", 50_000 * U, lender, 0));
        require(ok, "deposit");
        vm.stopPrank();

        pm = new MockPoolManager();
        key = V5PoolKey(address(usdg), address(priors), 0, 200, makeAddr("ponsHook"));
        priceSlot = keccak256(abi.encode(keccak256(abi.encode(key)), uint256(6)));
        sizer = new MockSizer();
        limiter = new MockLimiter();
        swapper = new MockSwapper(usdg, priors, pm);
        swapper.setSlot(priceSlot);
        permit2 = new MockPermit2();
        _setSpot(P0);

        ROOT = reg.register("v5-root");
        v5 = _deployV5();
        lens = IV5Lens(address(v5));
        reg.safeTransferFrom(address(this), address(v5), ROOT);
        usdg.mint(funder, 10_000 * U);
        vm.startPrank(funder);
        usdg.approve(address(v5), type(uint256).max);
        v5.fund(1_100 * U);
        vm.stopPrank();

        // another root with no hook: the agents' histories and the handoff's old sponsor
        usdg.mint(otherRootOwner, 100_000 * U);
        vm.startPrank(otherRootOwner);
        OROOT = reg.register("other-root");
        usdg.approve(address(pool), type(uint256).max);
        (ok,) = address(pool).call(abi.encodeWithSignature("enrollRoot(uint256,uint256)", OROOT, 20_000 * U));
        require(ok, "enrollRoot");
        vm.stopPrank();

        for (uint256 i = 0; i < _agentCount(); i++) {
            _newAgent(0xA11CE + i);
        }
        _qualifyAll();
        _keeperPass(P0);

        address[3] memory who = [backer1, backer2, anyone];
        for (uint256 i = 0; i < who.length; i++) {
            _fundAccount(who[i]);
        }
    }

    // ------------------------------------------------------------------
    // prices and the keeper
    // ------------------------------------------------------------------

    /// @dev The sqrtPriceX96 of a price in USDG per $PRIORS (18-decimal fixed point), USDG currency0 (6 dp).
    function _sqrtFor(uint256 pE18) internal pure returns (uint160) {
        return uint160(Math.sqrt(1e30 * (uint256(1) << 64) / pE18) * (uint256(1) << 64));
    }

    function _setSpot(uint256 pE18) internal {
        pm.setSlot(priceSlot, _sqrtFor(pE18));
    }

    /// @dev The keeper's pass: a SeatSizer observation at `pE18` (median and observation both), then V5's `sync()`.
    function _keeperPass(uint256 pE18) internal {
        uint160 s = _sqrtFor(pE18);
        sizer.set(s, s);
        v5.sync();
    }

    /// @dev Seven UTC days with a keeper pass each: the fail-safe lifts and a flat ring reads calm.
    function _calmWeek() internal {
        for (uint256 i = 0; i < 7; i++) {
            vm.warp(block.timestamp + 1 days);
            _keeperPass(P0);
        }
    }

    function _skip(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
    }

    /// @dev Move time and keep the keeper's cache fresh at P0.
    function _skipFresh(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        _keeperPass(P0);
    }

    // ------------------------------------------------------------------
    // accounts and agents
    // ------------------------------------------------------------------

    function _fundAccount(address who) internal {
        usdg.mint(who, 100_000 * U);
        priors.mint(who, 100_000_000 * T);
        vm.startPrank(who);
        usdg.approve(address(v5), type(uint256).max);
        priors.approve(address(v5), type(uint256).max);
        usdg.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _owner(uint256 id) internal view returns (address) {
        return vm.addr(pkOf[id]);
    }

    function _newAgent(uint256 pk) internal returns (uint256 id) {
        address o = vm.addr(pk);
        _fundAccount(o);
        vm.prank(o);
        id = reg.register("agent");
        pks.push(pk);
        agents.push(id);
        pkOf[id] = pk;
    }

    function _consent(uint256 id, uint256 sponsor, uint256 cap)
        internal
        view
        returns (ICreditPoolV2.Consent memory c, bytes memory sig)
    {
        c = ICreditPoolV2.Consent({
            agentId: id,
            sponsorId: sponsor,
            owner: _owner(id),
            maxPremiumBps: cap,
            nonce: pool.nonces(id),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkOf[id], pool.consentDigest(c));
        sig = abi.encodePacked(r, s, v);
    }

    /// @dev Every agent: a line from OROOT, three $5 loans held 7 days and repaid, then 14 days since enrolment.
    function _qualifyAll() internal {
        uint256[] memory loans = new uint256[](agents.length * 3);
        for (uint256 i = 0; i < agents.length; i++) {
            uint256 id = agents[i];
            (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, OROOT, 0);
            vm.prank(otherRootOwner);
            pool.vouchWithConsent(OROOT, id, 100 * U, 0, c, sig);
            for (uint256 j = 0; j < 3; j++) {
                loans[i * 3 + j] = _borrowRaw(id, 5 * U, 7 days);
            }
        }
        _skip(7 days);
        for (uint256 i = 0; i < loans.length; i++) {
            _repay(loans[i]);
        }
        _skip(7 days + 1);
    }

    function _borrowRaw(uint256 id, uint256 amount, uint64 term) internal returns (uint256 loanId) {
        address o = _owner(id);
        vm.prank(o);
        (bool ok, bytes memory r) = address(pool)
            .call(
                abi.encodeWithSignature(
                    "borrow(uint256,uint256,uint64,address,uint256)", id, amount, term, o, type(uint256).max
                )
            );
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
        loanId = abi.decode(r, (uint256));
    }

    function _repay(uint256 loanId) internal {
        ICreditPoolV2.Loan memory l = pool.getLoan(loanId);
        address o = l.owner;
        usdg.mint(o, l.principal + l.fee);
        vm.prank(o);
        usdg.approve(address(pool), type(uint256).max);
        vm.prank(o);
        (bool ok, bytes memory r) = address(pool)
            .call(abi.encodeWithSignature("repay(uint256,uint256,uint256)", loanId, l.agentId, type(uint256).max));
        if (!ok) {
            assembly {
                revert(add(r, 32), mload(r))
            }
        }
    }

    // ------------------------------------------------------------------
    // V5 actions
    // ------------------------------------------------------------------

    function _open(uint256 id, uint256 tokens) internal {
        (ICreditPoolV2.Consent memory c, bytes memory sig) = _consent(id, ROOT, 0);
        vm.prank(_owner(id));
        v5.open(id, tokens, false, c, sig);
    }

    /// @dev The owner's refresh, then a borrow on V5's line.
    function _borrow(uint256 id, uint256 amount, uint64 term) internal returns (uint256 loanId) {
        vm.prank(_owner(id));
        v5.refresh(id);
        loanId = _borrowRaw(id, amount, term);
    }

    function _back(address who, uint256 id, uint256 tokens) internal {
        vm.prank(who);
        v5.back(id, tokens, false);
    }

    function _gen(uint256 id) internal view returns (S.Gen memory) {
        return lens.getGen(id, lens.latestGen(id));
    }

    function _today() internal view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    /// @dev V5's $PRIORS ledger plus auto-add's carry, which its balance must equal less donations (V5-TOK).
    function _ledger() internal view returns (uint256 l, uint256 carry) {
        (,,, l, carry,,) = lens.totals();
    }

    /// @dev V5-USDG's solvency: V5's USDG + what the pool owes its root ≥ holders' credits + buffer + C's fees.
    function _solvent() internal view returns (bool) {
        (uint256 h, uint256 b, uint256 p,,,,) = lens.totals();
        return usdg.balanceOf(address(v5)) + pool.sponsorFees(ROOT) >= h + b + p;
    }

    function priors_() internal view returns (IERC20) {
        return IERC20(address(priors));
    }

    function swapper_() internal view returns (IV4SwapOnce) {
        return IV4SwapOnce(address(swapper));
    }

    function limiter_() internal view returns (ISwapLimiter) {
        return ISwapLimiter(address(limiter));
    }

    function pm_() internal view returns (IExtsloadV5) {
        return IExtsloadV5(address(pm));
    }

    function sizer_() internal view returns (ISeatSizerV4) {
        return ISeatSizerV4(address(sizer));
    }
}
