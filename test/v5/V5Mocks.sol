// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V5PoolKey} from "../../src/interfaces/IV5Deps.sol";

/// @dev USDG stand-in: 6 decimals, an issuer that can freeze any address (`isFrozen`, as USDG's), and a switch that
///      makes `isFrozen` misbehave the ways 2.2's bounded read must survive.
contract MockUSDG is ERC20 {
    mapping(address => bool) public frozenOf;
    uint8 public frozenMode; // 0 normal, 1 revert, 2 burn all gas, 3 dirty word

    constructor() ERC20("Global Dollar (mock)", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function freeze(address who, bool f) external {
        frozenOf[who] = f;
    }

    function setFrozenMode(uint8 m) external {
        frozenMode = m;
    }

    function isFrozen(address who) external view returns (bool) {
        if (frozenMode == 1) revert("isFrozen down");
        if (frozenMode == 2) {
            uint256 x;
            while (gasleft() > 1000) x++;
        }
        if (frozenMode == 3) {
            assembly {
                mstore(0, 7)
                return(0, 32)
            }
        }
        return frozenOf[who];
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!frozenOf[from] && !frozenOf[to], "frozen");
        super._update(from, to, v);
    }
}

/// @dev $PRIORS stand-in: 18 decimals, `burn`, no permit. A switch makes `burn` fail (V5 then sends to 0x…dEaD).
contract MockPriors is ERC20 {
    bool public burnBroken;
    address public skimFrom; // a transfer from this address arrives 1 wei short (a fee-on-transfer token)

    constructor() ERC20("Priors (mock)", "PRIORS") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function burn(uint256 a) external {
        require(!burnBroken, "no burn");
        _burn(msg.sender, a);
    }

    function setBurnBroken(bool b) external {
        burnBroken = b;
    }

    function setSkimFrom(address a) external {
        skimFrom = a;
    }

    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (from != address(0) && from == skimFrom && to != address(0) && v != 0) _burn(to, 1);
    }
}

/// @dev The ERC-8004 registry, with the failure modes 2.2 names: a revert, a reply that burns every unit of gas, an
///      empty reply, a short reply, a dirty address word, and a huge reply.
contract MockRegistryV5 is ERC721 {
    uint256 public nextId = 1;
    uint8 public mode; // 0 normal, 1 revert, 2 burn gas, 3 empty, 4 short, 5 dirty word, 6 huge

    constructor() ERC721("ERC-8004 Agent (mock)", "AGENT") {}

    function register(string calldata) external returns (uint256 id) {
        id = nextId++;
        _mint(msg.sender, id);
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function ownerOf(uint256 id) public view override returns (address) {
        uint8 m = mode;
        if (m == 1) revert("registry down");
        if (m == 2) {
            uint256 x;
            while (gasleft() > 1000) x++;
        }
        if (m == 3) {
            assembly {
                return(0, 0)
            }
        }
        if (m == 4) {
            assembly {
                mstore(0, 0)
                return(0, 16)
            }
        }
        if (m == 5) {
            address o = super.ownerOf(id);
            assembly {
                mstore(0, or(o, shl(200, 1)))
                return(0, 32)
            }
        }
        if (m == 6) {
            assembly {
                return(0, 100000)
            }
        }
        return super.ownerOf(id);
    }
}

/// @dev The Uniswap v4 PoolManager's raw storage read, for slot0 of the one pool.
contract MockPoolManager {
    mapping(bytes32 => bytes32) public slots;

    function setSlot(bytes32 slot, uint160 sqrtP) external {
        slots[slot] = bytes32(uint256(sqrtP));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }
}

/// @dev SeatSizerV4's reads: a median (reverting with fewer than 24 observations), the observations and `lastObsAt`.
contract MockSizer {
    uint160 public median;
    uint160 public lastObservation;
    uint64 public lastObsAt;
    uint256 public obsCount;
    bool public tooFew;

    function set(uint160 median_, uint160 obs_) external {
        median = median_;
        lastObservation = obs_;
        lastObsAt = uint64(block.timestamp);
        obsCount += 1;
    }

    function setObsAt(uint64 at) external {
        lastObsAt = at;
    }

    function setTooFew(bool b) external {
        tooFew = b;
    }

    function medianSqrtPrice() external view returns (uint160) {
        require(!tooFew, "NotEnoughObservations");
        return median;
    }

    function observation(uint256) external view returns (uint160) {
        return lastObservation;
    }
}

/// @dev The SwapLimiter's surface (src/interfaces/ISwapLimiter.sol), with every reading settable.
contract MockLimiter {
    uint256 public term = 5_000e6;
    uint256 public age = 60;
    bool public ok_ = true;
    uint256 public termMedian = 5_000e6;
    uint256 public depth = 77_911e6;
    bool public depthOk = true;
    uint256 public cap = 2_169e6;
    bool public capOk = true;
    uint256 public fee = 300;
    bool public feeOk = true;
    uint256 public expectedFeeBps = 400;
    uint256 public ceiling = 1_900e6;
    uint256 public hourLeft = 2_169e6;
    bool public swapped;
    bool public consumeReverts;
    bool public viewReverts;
    bool public feeReverts;
    bool public starveCheck; // the real SwapLimiter's bounded fee reads: under 100,000 × 64/63 + 5,000 left, ReadStarved
    uint256 public consumed;
    uint256 public consumeCount;

    function setDepthTerm(uint256 live, uint256 median_, uint256 age_, bool ok) external {
        term = live;
        termMedian = median_;
        age = age_;
        ok_ = ok;
    }

    function setDepth(uint256 d, bool ok) external {
        depth = d;
        depthOk = ok;
    }

    function setCap(uint256 c, bool ok) external {
        cap = c;
        capOk = ok;
    }

    function setFee(uint256 f, bool ok) external {
        fee = f;
        feeOk = ok;
    }

    function setHourLeft(uint256 h) external {
        hourLeft = h;
    }

    function setSwapped(bool s) external {
        swapped = s;
    }

    function setConsumeReverts(bool r) external {
        consumeReverts = r;
    }

    function setViewReverts(bool r) external {
        viewReverts = r;
    }

    function setFeeReverts(bool r) external {
        feeReverts = r;
    }

    error ReadStarved();
    uint256 internal constant STARVE_AT = uint256(100_000) * 64 / 63 + 5_000;

    function setStarveCheck(bool on) external {
        starveCheck = on;
    }

    /// @dev SwapLimiter._readWord's check, for each of the hook's two fee reads (deep audit H-01's lever).
    function _feeReads() internal view {
        if (!starveCheck) return;
        if (gasleft() < STARVE_AT) revert ReadStarved();
        uint256 g0 = gasleft();
        while (g0 - gasleft() < 3_000) {} // a cheap hook read
        if (gasleft() < STARVE_AT) revert ReadStarved();
    }

    function setCeiling(uint256 c) external {
        ceiling = c;
    }

    function depthTerm(uint160, bool medianForm) external view returns (uint256, uint256, bool) {
        require(!viewReverts, "view down");
        _feeReads();
        return (medianForm ? termMedian : term, age, ok_);
    }

    function liveDepth() external view returns (uint256, bool) {
        return (depth, depthOk);
    }

    function liveCap() external view returns (uint256, bool) {
        return (cap, capOk);
    }

    function liveFeeBps() external view returns (uint256, bool) {
        require(!feeReverts, "fee view down");
        _feeReads();
        return (fee, feeOk);
    }

    function hourRemaining() external view returns (uint256) {
        return hourLeft;
    }

    function swappedThisBlock() external view returns (bool) {
        return swapped;
    }

    function consume(uint256 usdg) external {
        require(!consumeReverts, "limiter refuses");
        require(fee <= expectedFeeBps, "fee above ceiling");
        consumed += usdg;
        consumeCount += 1;
        hourLeft = hourLeft > usdg ? hourLeft - usdg : 0;
    }
}

/// @dev V4SwapOnce's surface over a constant price: the price is the mock PoolManager's slot0, the output pays the
///      hook's cut (`feeBps`), `minOut` and the deadline behave as V4SwapOnce's (`TooLittleOut`, `Expired`). It pulls
///      the input from `msg.sender` and mints the output to `to`. Switches: a generic failure (the hook reverting,
///      wrapped by the PoolManager), a short fill, and a callback into V5 (a hostile hook).
contract MockSwapper {
    error Expired();
    error TooLittleOut(uint256 out, uint256 minOut);
    error WrappedError(address target, bytes4 selector, bytes reason, bytes details);

    MockUSDG public immutable usdg;
    MockPriors public immutable priors;
    MockPoolManager public immutable pm;
    bytes32 public slot;
    uint256 public feeBps = 300;
    bool public broken;
    uint256 public payPartBps = 10_000; // share of usdgIn actually consumed
    uint256 public deliverBps = 10_000; // share of the reported output actually delivered (a lying swapper)
    address public reenterTarget;
    bytes public reenterData;

    constructor(MockUSDG u, MockPriors p, MockPoolManager pm_) {
        usdg = u;
        priors = p;
        pm = pm_;
    }

    function setSlot(bytes32 s) external {
        slot = s;
    }

    function setFee(uint256 f) external {
        feeBps = f;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setPayPart(uint256 bps) external {
        payPartBps = bps;
    }

    function setDeliver(uint256 bps) external {
        deliverBps = bps;
    }

    function setReenter(address t, bytes calldata d) external {
        reenterTarget = t;
        reenterData = d;
    }

    function _sqrt() internal view returns (uint160) {
        return uint160(uint256(pm.extsload(slot)));
    }

    function swapExactIn(
        V5PoolKey calldata,
        bool zeroForOne,
        uint128 amountIn,
        uint256 minOut,
        uint160,
        address to,
        uint256 deadline
    ) external returns (uint256 paid, uint256 out) {
        if (block.timestamp > deadline) revert Expired();
        if (broken) revert WrappedError(address(0), bytes4(0), "", "");
        if (reenterTarget != address(0)) {
            (bool ok, bytes memory r) = reenterTarget.call(reenterData);
            if (!ok) {
                assembly {
                    revert(add(r, 32), mload(r))
                }
            }
        }
        uint160 s = _sqrt();
        paid = uint256(amountIn) * payPartBps / 10_000;
        if (zeroForOne) {
            // USDG in, $PRIORS out: raw PRIORS = usdg × s² ÷ 2^192
            out = Math.mulDiv(Math.mulDiv(paid, s, 1 << 96), s, 1 << 96) * (10_000 - feeBps) / 10_000;
            if (out < minOut) revert TooLittleOut(out, minOut);
            require(usdg.transferFrom(msg.sender, address(this), paid), "pull");
            priors.mint(to, out * deliverBps / 10_000);
        } else {
            out = Math.mulDiv(Math.mulDiv(paid, 1 << 96, s), 1 << 96, s) * (10_000 - feeBps) / 10_000;
            if (out < minOut) revert TooLittleOut(out, minOut);
            require(priors.transferFrom(msg.sender, address(this), paid), "pull");
            usdg.mint(to, out);
        }
    }
}

/// @dev Permit2's AllowanceTransfer, reduced: an owner approves this contract on the token, `permit` records an
///      allowance for a spender (no signature check here), and `transferFrom` spends it.
contract MockPermit2 {
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    mapping(address => mapping(address => mapping(address => uint256))) public allowance; // owner, token, spender

    function permit(address owner, PermitSingle calldata p, bytes calldata) external {
        allowance[owner][p.details.token][p.spender] = p.details.amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint256 a = allowance[from][token][msg.sender];
        require(a >= amount, "permit2 allowance");
        allowance[from][token][msg.sender] = a - amount;
        require(IERC20(token).transferFrom(from, to, amount), "permit2 pull");
    }
}

/// @dev The v1 pool's `getAgent` as CreditPoolV2's `importFromV1` reads it (src/CreditPool.sol's Agent, field by
///      field, so its ABI matches): one settable record per id, none by default.
contract MockV1Pool {
    struct Agent {
        bool enrolled;
        bool isRoot;
        bool defaulted;
        uint64 enrolledAt;
        uint256 sponsor;
        uint256 delegatedIn;
        uint256 delegatedOut;
        uint256 earned;
        uint256 stake;
        uint256 principalOut;
        uint256 activeLoans;
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint64 epochStart;
        uint256 earnedThisEpoch;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    mapping(uint256 => Agent) internal agents;

    function set(uint256 id, uint64 enrolledAt, uint256 activeLoans, uint256 loansRepaid, uint256 childrenDefaulted)
        external
    {
        Agent storage a = agents[id];
        a.enrolled = enrolledAt != 0;
        a.enrolledAt = enrolledAt;
        a.activeLoans = activeLoans;
        a.loansRepaid = loansRepaid;
        a.childrenDefaulted = childrenDefaulted;
    }

    function getAgent(uint256 id) external view returns (Agent memory) {
        return agents[id];
    }
}
