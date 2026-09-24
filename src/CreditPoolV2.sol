// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {CreditPool} from "./CreditPool.sol";
import {PoolV2Lib} from "./libraries/PoolV2Lib.sol";

/// @title CreditPoolV2
/// @notice Unsecured credit for ERC-8004 agents in which every line is 100% backed. See docs/POOL-v2-SPEC.md.
///
///  - Lenders deposit USDG for pool shares. They never take a loan loss: there is no path by which one reaches
///    them, so the share price never falls.
///  - Roots (backers) lock pool shares as stake. Locked shares fund loans and earn lender yield like any
///    other, and they back the lines the root vouches, 1:1. A default burns the backer's shares worth the
///    principal, which leaves the share price where it was.
///  - Agents get a line from exactly one sponsor at a time, only with their owner's signed consent, and can
///    move to another sponsor (handoff) whenever no loan is open.
///  - Every field used to close a loan is fixed when it is borrowed.
///  - The owner is a timelock (48 h). The guardian can pause new risk for at most 14 days at a time; exits
///    never pause.
contract CreditPoolV2 is Ownable2Step, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    uint64 public constant MAX_PERIOD = 365 days;
    uint64 public constant MIN_GRACE = 1 days;
    uint64 public constant MAX_PAUSE = 14 days;
    uint64 public constant HOOK_DELAY = 48 hours;
    uint64 public constant MIN_HOLD = 7 days;
    uint256 public constant EARLY_EXIT_BPS = 50;
    uint256 public constant MAX_FEE_BPS = 500; // base fee per 30 days
    uint256 public constant MAX_PREMIUM_BPS = 200; // sponsor premium per 30 days
    uint256 public constant MAX_KEEPER_BOUNTY = 5e6;
    uint256 public constant HOOK_GAS = 300_000;
    uint256 public constant HOOK_OVERHEAD = 12_000;
    uint256 public constant SEED = 1e6; // 1 USDG of dead shares, minted once, against share inflation
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant MAX_IMPORT_COUNT = 1e9;
    uint256 private constant MAX_IMPORT_AMOUNT = 1e15;

    bytes32 public constant CONSENT_TYPEHASH = keccak256(
        "Consent(uint256 agentId,uint256 sponsorId,address owner,uint256 maxPremiumBps,uint256 nonce,uint256 deadline)"
    );

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum LoanStatus {
        None,
        Active,
        Repaid,
        Defaulted
    }

    enum Release {
        Unvouch,
        Leave,
        Handoff,
        Freeze,
        DefaultResidual
    }

    struct Agent {
        bool enrolled;
        bool isRoot;
        bool defaulted;
        bool frozen;
        bool importedFromV1;
        uint64 enrolledAt;
        uint64 lastBorrowAt;
        uint64 lastRepayAt;
        uint256 sponsor;
        uint256 delegatedIn;
        uint256 delegatedOut; // roots
        uint256 principalOut;
        uint256 activeLoans;
        uint256 premiumBps; // charged on this agent's future loans, 100% to its sponsor
        uint256 premiumCap; // the most its owner consented to
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored; // imported only
        uint256 childrenDefaulted; // roots, per defaulted loan
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    struct Loan {
        uint256 agentId;
        uint256 sponsorId;
        uint256 principal;
        uint256 fee; // base + premium
        uint256 sponsorCut; // of the base fee
        uint256 reserveCut; // of the base fee
        uint256 premium; // all to the sponsor
        address owner; // NFT owner at borrow: the address a default marks
        uint64 issuedAt;
        uint64 dueAt;
        uint64 defaultableAt;
        uint64 minScoreTerm; // held at least this long to count as a qualified loan
        uint64 closedAt;
        LoanStatus status;
    }

    struct Params {
        uint256 minLoan;
        uint256 maxLoan;
        uint64 minTerm;
        uint64 maxTerm;
        uint64 grace;
        uint64 minScoreTerm;
        uint256 feeBps; // base fee per 30 days of term
        uint256 sponsorFeeBps; // of the base fee
        uint256 protocolFeeBps; // of the base fee, to the reserve
        uint256 minStake;
        uint256 maxUtilizationBps;
        uint256 keeperBounty;
    }

    struct Consent {
        uint256 agentId;
        uint256 sponsorId;
        address owner;
        uint256 maxPremiumBps;
        uint256 nonce;
        uint256 deadline;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    IERC20 public immutable usdg;
    IERC8004Identity public immutable registry;
    CreditPool public immutable v1; // the pool this one replaces; zero on a chain without one

    Params internal params;
    address public guardian;
    uint64 public pausedUntil;
    bool public seeded;

    // pool accounting
    uint256 public poolLiquidity; // USDG behind shares, not lent out
    uint256 public totalPrincipalOut;
    uint256 public totalShares;
    uint256 public reserve;
    uint256 public unclaimedSponsorFees;
    uint256 public totalFeesEarned; // lenders' share, cumulative
    uint256 public totalSlashed; // principal paid by backers' shares on defaults
    uint256 public totalBadDebt; // must stay 0; kept so an invariant can say so
    /// @notice Fees of the open loans a backer stands behind, held out of its free backing (final audit N-1): a
    ///         default burns the backer's shares for the principal AND the unpaid fee, so self-default is never free.
    mapping(uint256 => uint256) public feeLocked;

    // lenders
    mapping(address => uint256) public shares;
    mapping(address => uint64) public lastDepositAt;

    // roots
    mapping(uint256 => uint256) public rootShares; // locked, backing the root's lines
    mapping(uint256 => address) public hook;
    mapping(uint256 => address) public pendingHook;
    mapping(uint256 => uint64) public hookEta;

    // agents
    mapping(uint256 => Agent) internal _agents;
    mapping(uint256 => address) public delegateOf;
    mapping(uint256 => address) private _delegateOwner;
    mapping(uint256 => uint256) public nonces; // consent nonces, per agent

    // sponsor fees
    mapping(uint256 => uint256) public sponsorFees; // claimable
    mapping(uint256 => mapping(uint256 => uint256)) public feesFrom; // sponsor => child => cumulative fees

    // defaults follow the person
    mapping(address => uint256) public ownerDefaults;
    mapping(address => bool) public custodian; // backers holding agent NFTs; their marks are skipped

    Loan[] internal _loans; // loanId = index, 0 is a sentinel
    mapping(uint256 => uint256[]) internal _loansOf;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event Seeded(address indexed by);
    event Deposited(address indexed lender, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lender, uint256 assets, uint256 shares);
    event RootEnrolled(uint256 indexed rootId, uint256 assets, uint256 shares);
    event StakeAdded(uint256 indexed rootId, address indexed from, uint256 assets, uint256 shares);
    event StakeUnlocked(uint256 indexed rootId, uint256 assets, uint256 shares, address to);
    event RootRetired(uint256 indexed rootId);
    event HookQueued(uint256 indexed rootId, address hook, uint64 eta);
    event HookSet(uint256 indexed rootId, address hook);
    event HookFailed(uint256 indexed rootId, bytes4 selector);
    event Vouched(uint256 indexed sponsorId, uint256 indexed agentId, uint256 amount, uint256 delegatedIn);
    event Released(uint256 indexed sponsorId, uint256 indexed agentId, uint256 amount, Release reason);
    event SponsorChanged(uint256 indexed agentId, uint256 indexed from, uint256 indexed to);
    event PremiumSet(uint256 indexed sponsorId, uint256 indexed agentId, uint256 premiumBps);
    event Frozen(uint256 indexed sponsorId, uint256 indexed agentId, bool frozen);
    event Borrowed(
        uint256 indexed loanId,
        uint256 indexed agentId,
        uint256 indexed sponsorId,
        uint256 principal,
        uint256 fee,
        uint64 dueAt,
        address to
    );
    event Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer);
    event FeeSplit(
        uint256 indexed loanId, uint256 indexed sponsorId, uint256 toLenders, uint256 toSponsor, uint256 toReserve
    );
    event Defaulted(
        uint256 indexed loanId,
        uint256 indexed agentId,
        uint256 indexed sponsorId,
        uint256 principal,
        uint256 sharesBurnt,
        address owner
    );
    event KeeperPaid(address indexed keeper, uint256 amount);
    event SponsorFeesClaimed(uint256 indexed sponsorId, address indexed to, uint256 amount);
    event DelegateSet(uint256 indexed agentId, address delegate);
    event ImportedFromV1(uint256 indexed agentId, uint256 loansRepaid, bool defaulted);
    event ReserveFunded(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event ReserveStaked(uint256 indexed rootId, uint256 amount, uint256 shares);
    event CustodianSet(address indexed who, bool allowed);
    event GuardianSet(address indexed guardian);
    event PausedUntil(uint64 until);
    event ParamsUpdated(Params params);

    error Paused();
    error NotSeeded();
    error AlreadySeeded();
    error ZeroAmount();
    error NotOwnerOf(uint256 id, address caller);
    error NotController(uint256 id, address caller);
    error NotGuardian();
    error InvalidAgent(uint256 id);
    error NotRoot(uint256 id);
    error IsRoot(uint256 id);
    error AgentDefaulted(uint256 id);
    error V1Busy(uint256 id);
    error WrongSponsor(uint256 id, uint256 sponsor);
    error LoanOpen(uint256 id);
    error BadConsent();
    error ConsentExpired();
    error PremiumTooHigh(uint256 bps, uint256 cap);
    error InsufficientBacking(uint256 rootId, uint256 requested, uint256 free);
    error InsufficientCapacity(uint256 id, uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error UtilizationTooHigh();
    error LoanSizeOutOfRange(uint256 amount);
    error TermOutOfRange(uint64 term);
    error FeeTooHigh(uint256 fee, uint256 maxFee);
    error IsFrozen(uint256 id);
    error OwnerDefaulted(address owner);
    error BorrowBlockedByBacker(uint256 rootId);
    error LoanNotActive(uint256 loanId);
    error LoanNotDue(uint256 loanId, uint64 defaultableAt);
    error WrongLoan(uint256 loanId);
    error DueTooHigh(uint256 due, uint256 maxDue);
    error BelowMinStake(uint256 amount, uint256 minStake);
    error SlippageShares(uint256 minted, uint256 minShares);
    error InvalidHook(address hook);
    error HookNotReady(uint64 eta);
    error StillBacking(uint256 rootId);
    error ReserveShort(uint256 requested, uint256 reserve);
    error AlreadyImported(uint256 id);
    error NoV1();
    error ImportOutOfRange(uint256 id);
    error InvalidParams();
    error Renounce();

    // ------------------------------------------------------------------
    // Construction, pause
    // ------------------------------------------------------------------

    constructor(
        IERC20 usdg_,
        IERC8004Identity registry_,
        CreditPool v1_,
        address owner_,
        address guardian_,
        Params memory p
    ) Ownable(owner_) EIP712("Priors Credit", "2") {
        usdg = usdg_;
        registry = registry_;
        v1 = v1_;
        guardian = guardian_;
        _setParams(p);
        _loans.push();
    }

    /// @notice Mint the dead shares that make share inflation impossible. Once, by anyone who pays 1 USDG.
    function seed() external nonReentrant {
        if (seeded) revert AlreadySeeded();
        seeded = true;
        usdg.safeTransferFrom(msg.sender, address(this), SEED);
        poolLiquidity += SEED;
        totalShares += SEED;
        shares[DEAD] += SEED;
        emit Seeded(msg.sender);
    }

    modifier whenNotPaused() {
        if (block.timestamp < pausedUntil) revert Paused();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        _;
    }

    /// @notice Stop new risk (deposits, stake, vouches, borrows) for at most 14 days. Exits never stop.
    function pause() external onlyGuardian nonReentrant {
        pausedUntil = uint64(block.timestamp) + MAX_PAUSE;
        emit PausedUntil(pausedUntil);
    }

    function unpause() external onlyGuardian nonReentrant {
        pausedUntil = 0;
        emit PausedUntil(0);
    }

    function renounceOwnership() public pure override {
        revert Renounce();
    }

    // ------------------------------------------------------------------
    // Identity
    // ------------------------------------------------------------------

    function _ownerOf(uint256 id) internal view returns (address o) {
        try registry.ownerOf(id) returns (address o_) {
            o = o_;
        } catch {
            revert InvalidAgent(id);
        }
    }

    function isController(uint256 id, address who) public view returns (bool) {
        if (id == 0) return false;
        try registry.ownerOf(id) returns (address o) {
            return o == who || (who != address(0) && delegateOf[id] == who && _delegateOwner[id] == o);
        } catch {
            return false;
        }
    }

    function _onlyOwnerOf(uint256 id) internal view {
        if (_ownerOf(id) != msg.sender) revert NotOwnerOf(id, msg.sender);
    }

    function _onlyController(uint256 id) internal view {
        if (!isController(id, msg.sender)) revert NotController(id, msg.sender);
    }

    /// @notice Let a hot key act for the agent (borrow, repay-roll, leave). It lapses when the NFT changes hands.
    function setDelegate(uint256 id, address delegate) external nonReentrant {
        address o = _ownerOf(id);
        if (o != msg.sender) revert NotOwnerOf(id, msg.sender);
        delegateOf[id] = delegate;
        _delegateOwner[id] = o;
        emit DelegateSet(id, delegate);
    }

    function _v1Clean(uint256 id) internal view returns (bool) {
        return PoolV2Lib.v1Clean(v1, id);
    }

    function _enroll(Agent storage a) internal {
        if (!a.enrolled) {
            a.enrolled = true;
            if (a.enrolledAt == 0) a.enrolledAt = uint64(block.timestamp);
        }
    }

    // ------------------------------------------------------------------
    // Lenders
    // ------------------------------------------------------------------

    function totalAssets() public view returns (uint256) {
        return poolLiquidity + totalPrincipalOut;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 ta = totalAssets();
        if (totalShares == 0 || ta == 0) return assets;
        return assets * totalShares / ta;
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        if (totalShares == 0) return shares_;
        return shares_ * totalAssets() / totalShares;
    }

    function _mintFor(uint256 assets) internal returns (uint256 minted) {
        if (!seeded) revert NotSeeded();
        if (assets == 0) revert ZeroAmount();
        minted = convertToShares(assets);
        if (minted == 0) revert ZeroAmount();
        usdg.safeTransferFrom(msg.sender, address(this), assets);
        poolLiquidity += assets;
        totalShares += minted;
    }

    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 minted)
    {
        minted = _mintFor(assets);
        if (minted < minShares) revert SlippageShares(minted, minShares);
        uint256 held = shares[receiver];
        shares[receiver] += minted;
        // share-weighted hold clock (see v1): a dust deposit cannot restart a stranger's seven days
        lastDepositAt[receiver] = held == 0
            ? uint64(block.timestamp)
            : uint64((held * uint256(lastDepositAt[receiver]) + minted * block.timestamp) / (held + minted));
        emit Deposited(receiver, assets, minted);
    }

    /// @notice Leave, liquidity permitting. Inside `MIN_HOLD` a 0.5% fee stays with the lenders who stayed.
    function withdraw(uint256 shares_, address receiver) external nonReentrant returns (uint256 out) {
        if (shares_ == 0) revert ZeroAmount();
        uint256 assets = convertToAssets(shares_);
        if (assets > poolLiquidity) revert InsufficientLiquidity(assets, poolLiquidity);
        shares[msg.sender] -= shares_;
        uint256 fee =
            block.timestamp < uint256(lastDepositAt[msg.sender]) + MIN_HOLD ? assets * EARLY_EXIT_BPS / 10_000 : 0;
        out = assets - fee;
        totalShares -= shares_;
        poolLiquidity -= out;
        usdg.safeTransfer(receiver, out);
        emit Withdrawn(msg.sender, out, shares_);
    }

    // ------------------------------------------------------------------
    // Roots
    // ------------------------------------------------------------------

    /// @notice Make an identity a backer, with at least `minStake` of USDG locked as pool shares.
    function enrollRoot(uint256 rootId, uint256 assets) external nonReentrant whenNotPaused {
        _onlyOwnerOf(rootId);
        Agent storage r = _agents[rootId];
        if (r.isRoot) revert IsRoot(rootId);
        if (r.defaulted) revert AgentDefaulted(rootId);
        if (r.sponsor != 0 || r.delegatedIn != 0 || r.activeLoans != 0) revert LoanOpen(rootId);
        if (assets < params.minStake) revert BelowMinStake(assets, params.minStake);
        uint256 minted = _mintFor(assets);
        r.isRoot = true;
        _enroll(r);
        rootShares[rootId] += minted;
        emit RootEnrolled(rootId, assets, minted);
    }

    /// @notice Add stake behind a root. Anyone may; only the root's owner can ever take it out.
    function addStake(uint256 rootId, uint256 assets) external nonReentrant whenNotPaused {
        if (!_agents[rootId].isRoot) revert NotRoot(rootId);
        uint256 minted = _mintFor(assets);
        rootShares[rootId] += minted;
        emit StakeAdded(rootId, msg.sender, assets, minted);
    }

    function backing(uint256 rootId) public view returns (uint256) {
        return convertToAssets(rootShares[rootId]);
    }

    function freeBacking(uint256 rootId) public view returns (uint256) {
        uint256 b = backing(rootId);
        uint256 out = _agents[rootId].delegatedOut + feeLocked[rootId];
        return b > out ? b - out : 0;
    }

    /// @notice Take out stake that backs nothing, as cash. No exit fee; liquidity owed to the queue is kept.
    function unlock(uint256 rootId, uint256 shares_, address to) external nonReentrant returns (uint256 assets) {
        _onlyOwnerOf(rootId);
        if (shares_ == 0) revert ZeroAmount();
        uint256 left = rootShares[rootId] - shares_;
        uint256 out = _agents[rootId].delegatedOut + feeLocked[rootId];
        if (convertToAssets(left) < out) {
            revert InsufficientBacking(rootId, convertToAssets(shares_), freeBacking(rootId));
        }
        assets = convertToAssets(shares_);
        if (assets > poolLiquidity) revert InsufficientLiquidity(assets, poolLiquidity);
        rootShares[rootId] = left;
        totalShares -= shares_;
        poolLiquidity -= assets;
        usdg.safeTransfer(to, assets);
        emit StakeUnlocked(rootId, assets, shares_, to);
    }

    /// @notice Turn a backer with nothing locked and nothing vouched back into a plain identity.
    function retireRoot(uint256 rootId) external nonReentrant {
        _onlyOwnerOf(rootId);
        Agent storage r = _agents[rootId];
        if (!r.isRoot) revert NotRoot(rootId);
        if (rootShares[rootId] != 0 || r.delegatedOut != 0) revert StillBacking(rootId);
        r.isRoot = false;
        delete hook[rootId];
        delete pendingHook[rootId];
        emit RootRetired(rootId);
    }

    /// @notice Point a root's backer hook. Immediate while it backs nothing; otherwise after 48 hours.
    function setHook(uint256 rootId, address h) external nonReentrant {
        _onlyOwnerOf(rootId);
        if (!_agents[rootId].isRoot) revert NotRoot(rootId);
        if (h != address(0)) {
            if (h == address(this) || h == address(usdg) || h == address(registry) || h.code.length == 0) {
                revert InvalidHook(h);
            }
        }
        if (_agents[rootId].delegatedOut == 0) {
            hook[rootId] = h;
            delete pendingHook[rootId];
            delete hookEta[rootId];
            emit HookSet(rootId, h);
        } else {
            pendingHook[rootId] = h;
            hookEta[rootId] = uint64(block.timestamp) + HOOK_DELAY;
            emit HookQueued(rootId, h, hookEta[rootId]);
        }
    }

    function applyHook(uint256 rootId) external nonReentrant {
        uint64 eta = hookEta[rootId];
        if (eta == 0 || block.timestamp < eta) revert HookNotReady(eta);
        hook[rootId] = pendingHook[rootId];
        delete pendingHook[rootId];
        delete hookEta[rootId];
        emit HookSet(rootId, hook[rootId]);
    }

    function claimSponsorFees(uint256 sponsorId, address to) external nonReentrant returns (uint256 amount) {
        _onlyOwnerOf(sponsorId);
        amount = sponsorFees[sponsorId];
        if (amount == 0) revert ZeroAmount();
        sponsorFees[sponsorId] = 0;
        unclaimedSponsorFees -= amount;
        usdg.safeTransfer(to, amount);
        emit SponsorFeesClaimed(sponsorId, to, amount);
    }

    // ------------------------------------------------------------------
    // Consent, vouching, handoff
    // ------------------------------------------------------------------

    function consentDigest(Consent calldata c) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(CONSENT_TYPEHASH, c.agentId, c.sponsorId, c.owner, c.maxPremiumBps, c.nonce, c.deadline)
            )
        );
    }

    /// @notice Start (or hand off to) a sponsorship, with the agent owner's signed consent. Only the sponsor's
    ///         owner can use a consent, so nobody can front-run it. If the agent has another sponsor and no loan
    ///         open, that sponsor's whole line goes back to it first.
    function vouchWithConsent(
        uint256 sponsorId,
        uint256 agentId,
        uint256 amount,
        uint256 premiumBps,
        Consent calldata c,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        _onlyOwnerOf(sponsorId);
        Agent storage s = _agents[sponsorId];
        if (!s.isRoot) revert NotRoot(sponsorId);
        if (agentId == 0 || agentId == sponsorId) revert InvalidAgent(agentId);
        Agent storage a = _agents[agentId];
        if (a.isRoot) revert IsRoot(agentId);
        if (a.defaulted) revert AgentDefaulted(agentId);
        if (!_v1Clean(agentId)) revert V1Busy(agentId);
        if (
            c.agentId != agentId || c.sponsorId != sponsorId || c.owner != _ownerOf(agentId)
                || c.nonce != nonces[agentId] || c.maxPremiumBps > MAX_PREMIUM_BPS
                || !PoolV2Lib.validSig(c.owner, consentDigest(c), sig)
        ) revert BadConsent();
        if (block.timestamp > c.deadline) revert ConsentExpired();
        if (premiumBps > c.maxPremiumBps) revert PremiumTooHigh(premiumBps, c.maxPremiumBps);
        nonces[agentId] = c.nonce + 1;

        uint256 old = a.sponsor;
        if (old != 0 && old != sponsorId) {
            if (a.activeLoans != 0) revert LoanOpen(agentId);
            _endSponsorship(old, agentId, a, Release.Handoff);
        }
        if (a.sponsor != sponsorId) {
            a.sponsor = sponsorId;
            a.frozen = false;
            _enroll(a);
            emit SponsorChanged(agentId, old, sponsorId);
        }
        a.premiumCap = c.maxPremiumBps;
        a.premiumBps = premiumBps;
        emit PremiumSet(sponsorId, agentId, premiumBps);
        if (amount > 0) _vouch(sponsorId, s, agentId, a, amount);
    }

    /// @notice Add to a line this sponsor already backs.
    function vouch(uint256 sponsorId, uint256 agentId, uint256 amount) external nonReentrant whenNotPaused {
        _onlyOwnerOf(sponsorId);
        Agent storage a = _agents[agentId];
        if (a.sponsor != sponsorId || sponsorId == 0) revert WrongSponsor(agentId, a.sponsor);
        if (a.defaulted) revert AgentDefaulted(agentId);
        if (!_v1Clean(agentId)) revert V1Busy(agentId);
        _vouch(sponsorId, _agents[sponsorId], agentId, a, amount);
    }

    function _vouch(uint256 sponsorId, Agent storage s, uint256 agentId, Agent storage a, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 free = freeBacking(sponsorId);
        if (amount > free) revert InsufficientBacking(sponsorId, amount, free);
        s.delegatedOut += amount;
        a.delegatedIn += amount;
        emit Vouched(sponsorId, agentId, amount, a.delegatedIn);
    }

    /// @notice Pull back line the agent has not drawn. Taking it all ends the sponsorship.
    function unvouch(uint256 sponsorId, uint256 agentId, uint256 amount) external nonReentrant {
        _onlyOwnerOf(sponsorId);
        Agent storage a = _agents[agentId];
        if (a.sponsor != sponsorId || sponsorId == 0) revert WrongSponsor(agentId, a.sponsor);
        if (amount == 0) revert ZeroAmount();
        uint256 undrawn = a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0;
        if (amount > undrawn) revert InsufficientCapacity(agentId, amount, undrawn);
        a.delegatedIn -= amount;
        _agents[sponsorId].delegatedOut -= amount;
        if (a.delegatedIn == 0 && a.activeLoans == 0) {
            _clearSponsor(agentId, a);
        }
        _notifyRelease(sponsorId, agentId, amount, Release.Unvouch);
    }

    /// @notice The agent ends its sponsorship. Only with no loan open; the whole line goes back to the sponsor.
    function leave(uint256 agentId) external nonReentrant {
        _onlyController(agentId);
        Agent storage a = _agents[agentId];
        uint256 s = a.sponsor;
        if (s == 0) revert WrongSponsor(agentId, 0);
        if (a.activeLoans != 0) revert LoanOpen(agentId);
        _endSponsorship(s, agentId, a, Release.Leave);
        emit SponsorChanged(agentId, s, 0);
    }

    /// @notice The sponsor stops new borrows. Loans out run to term, and the undrawn line comes
    ///         back as they close; once nothing is left, the sponsorship ends.
    function freeze(uint256 agentId, bool frozen_) external nonReentrant {
        Agent storage a = _agents[agentId];
        uint256 s = a.sponsor;
        if (s == 0) revert WrongSponsor(agentId, 0);
        _onlyOwnerOf(s);
        a.frozen = frozen_;
        emit Frozen(s, agentId, frozen_);
        if (frozen_) _releaseFrozen(agentId, a);
    }

    /// @notice A sponsor can lower (or raise up to the consented cap) the premium on future loans.
    function setPremium(uint256 agentId, uint256 premiumBps) external nonReentrant {
        Agent storage a = _agents[agentId];
        uint256 s = a.sponsor;
        if (s == 0) revert WrongSponsor(agentId, 0);
        _onlyOwnerOf(s);
        if (premiumBps > a.premiumCap) revert PremiumTooHigh(premiumBps, a.premiumCap);
        a.premiumBps = premiumBps;
        emit PremiumSet(s, agentId, premiumBps);
    }

    function _endSponsorship(uint256 s, uint256 agentId, Agent storage a, Release reason) internal {
        uint256 amount = a.delegatedIn;
        if (amount > 0) {
            a.delegatedIn = 0;
            _agents[s].delegatedOut -= amount;
        }
        _clearSponsor(agentId, a);
        _notifyRelease(s, agentId, amount, reason);
    }

    function _clearSponsor(uint256, Agent storage a) internal {
        a.sponsor = 0;
        a.frozen = false;
        a.premiumBps = 0;
        a.premiumCap = 0;
    }

    function _releaseFrozen(uint256 agentId, Agent storage a) internal {
        uint256 s = a.sponsor;
        uint256 undrawn = a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0;
        if (undrawn > 0) {
            a.delegatedIn -= undrawn;
            _agents[s].delegatedOut -= undrawn;
        }
        if (a.delegatedIn == 0 && a.activeLoans == 0) _clearSponsor(agentId, a);
        if (undrawn > 0) _notifyRelease(s, agentId, undrawn, Release.Freeze);
    }

    /// @dev A dead agent's leftover line goes back once its last loan has closed.
    function _settleDead(uint256 agentId, Agent storage a) internal {
        if (!a.defaulted || a.activeLoans != 0) return;
        uint256 s = a.sponsor;
        uint256 rest = a.delegatedIn;
        if (rest > 0) {
            a.delegatedIn = 0;
            _agents[s].delegatedOut -= rest;
        }
        if (s != 0) {
            _clearSponsor(agentId, a);
            _notifyRelease(s, agentId, rest, Release.DefaultResidual);
        }
    }

    // ------------------------------------------------------------------
    // Loans
    // ------------------------------------------------------------------

    function quoteFee(uint256 agentId, uint256 principal, uint64 term)
        public
        view
        returns (uint256 fee, uint256 sponsorCut, uint256 reserveCut, uint256 premium)
    {
        uint256 base = principal * params.feeBps * term / (10_000 * 30 days);
        sponsorCut = base * params.sponsorFeeBps / 10_000;
        reserveCut = base * params.protocolFeeBps / 10_000;
        premium = principal * _agents[agentId].premiumBps * term / (10_000 * 30 days);
        fee = base + premium;
    }

    function _checkBorrower(uint256 agentId, Agent storage a) internal view returns (address o) {
        if (a.sponsor == 0 || a.isRoot) revert WrongSponsor(agentId, a.sponsor);
        if (a.defaulted) revert AgentDefaulted(agentId);
        if (a.frozen) revert IsFrozen(agentId);
        if (!_v1Clean(agentId)) revert V1Busy(agentId);
        o = _ownerOf(agentId);
        if (ownerDefaults[o] != 0 && !custodian[o]) revert OwnerDefaulted(o);
    }

    function _newLoan(uint256 agentId, uint256 sponsorId, uint256 principal, uint64 term, address o)
        internal
        view
        returns (Loan memory l)
    {
        if (term < params.minTerm || term > params.maxTerm) revert TermOutOfRange(term);
        (l.fee, l.sponsorCut, l.reserveCut, l.premium) = quoteFee(agentId, principal, term);
        l.agentId = agentId;
        l.sponsorId = sponsorId;
        l.principal = principal;
        l.owner = o;
        l.issuedAt = uint64(block.timestamp);
        l.dueAt = uint64(block.timestamp) + term;
        l.defaultableAt = l.dueAt + params.grace;
        l.minScoreTerm = params.minScoreTerm;
        l.status = LoanStatus.Active;
    }

    function _askBacker(Loan memory l, uint64 term, address to) internal view {
        if (!_canBorrow(
                l.sponsorId, abi.encode(l.sponsorId, l.agentId, l.principal, term, l.fee, msg.sender, l.owner, to)
            )) {
            revert BorrowBlockedByBacker(l.sponsorId);
        }
    }

    function _checkRoom(uint256 agentId, Agent storage a, uint256 amount) internal view {
        if (amount < params.minLoan || amount > params.maxLoan) revert LoanSizeOutOfRange(amount);
        uint256 avail = a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0;
        if (amount > avail) revert InsufficientCapacity(agentId, amount, avail);
        if (amount > poolLiquidity) revert InsufficientLiquidity(amount, poolLiquidity);
        if ((totalPrincipalOut + amount) * 10_000 > params.maxUtilizationBps * totalAssets()) {
            revert UtilizationTooHigh();
        }
    }

    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 loanId)
    {
        _onlyController(agentId);
        Agent storage a = _agents[agentId];
        address o = _checkBorrower(agentId, a);
        _checkRoom(agentId, a, amount);
        Loan memory l = _newLoan(agentId, a.sponsor, amount, term, o);
        if (l.fee > maxFee) revert FeeTooHigh(l.fee, maxFee);
        _askBacker(l, term, to);
        uint256 fb = freeBacking(l.sponsorId);
        if (l.fee > fb) revert InsufficientBacking(l.sponsorId, l.fee, fb);
        feeLocked[l.sponsorId] += l.fee;

        loanId = _loans.length;
        _loans.push(l);
        _loansOf[agentId].push(loanId);
        a.principalOut += amount;
        a.activeLoans += 1;
        a.lastBorrowAt = uint64(block.timestamp);
        poolLiquidity -= amount;
        totalPrincipalOut += amount;
        usdg.safeTransfer(to, amount);
        emit Borrowed(loanId, agentId, l.sponsorId, amount, l.fee, l.dueAt, to);
        _notify(l.sponsorId, abi.encodeWithSelector(IBackerHook.onBorrow.selector, l.sponsorId, agentId, loanId));
    }

    function _splitFee(uint256 loanId, Loan storage l) internal {
        uint256 toSponsor = l.sponsorCut + l.premium;
        uint256 toLenders = l.fee - toSponsor - l.reserveCut;
        poolLiquidity += toLenders;
        totalFeesEarned += toLenders;
        if (toSponsor > 0) {
            sponsorFees[l.sponsorId] += toSponsor;
            feesFrom[l.sponsorId][l.agentId] += toSponsor;
            unclaimedSponsorFees += toSponsor;
        }
        if (l.reserveCut > 0) {
            reserve += l.reserveCut;
        }
        emit FeeSplit(loanId, l.sponsorId, toLenders, toSponsor, l.reserveCut);
    }

    /// @notice Anyone can repay. `expectedAgentId` and `maxDue` make sure it is the loan the payer meant.
    function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue) external nonReentrant {
        if (loanId == 0 || loanId >= _loans.length) revert LoanNotActive(loanId);
        Loan storage l = _loans[loanId];
        if (l.status != LoanStatus.Active) revert LoanNotActive(loanId);
        if (l.agentId != expectedAgentId) revert WrongLoan(loanId);
        uint256 due = l.principal + l.fee;
        if (due > maxDue) revert DueTooHigh(due, maxDue);
        usdg.safeTransferFrom(msg.sender, address(this), due);

        Agent storage a = _agents[l.agentId];
        l.status = LoanStatus.Repaid;
        l.closedAt = uint64(block.timestamp);
        a.principalOut -= l.principal;
        feeLocked[l.sponsorId] -= l.fee;
        a.activeLoans -= 1;
        a.lastRepayAt = uint64(block.timestamp);
        totalPrincipalOut -= l.principal;
        poolLiquidity += l.principal;
        _splitFee(loanId, l);

        a.loansRepaid += 1;
        a.volumeRepaid += l.principal;
        a.feesPaid += l.fee;
        uint256 term = l.dueAt - l.issuedAt;
        uint256 held = block.timestamp - l.issuedAt;
        if (held > term) held = term;
        a.dollarSecondsRepaid += l.principal * held;
        if (held >= l.minScoreTerm) a.qualifiedRepaid += 1;
        emit Repaid(loanId, l.agentId, l.principal, l.fee, msg.sender);

        if (a.defaulted) _settleDead(l.agentId, a);
        else if (a.frozen) _releaseFrozen(l.agentId, a);
    }

    /// @notice Anyone, once a loan is past its grace. The backer's shares pay the principal and the unpaid fee (to the
    ///         remaining shares), both held since the borrow; lenders are untouched and a self-default costs the fee.
    function markDefault(uint256 loanId) external nonReentrant {
        if (loanId == 0 || loanId >= _loans.length) revert LoanNotActive(loanId);
        Loan storage l = _loans[loanId];
        if (l.status != LoanStatus.Active) revert LoanNotActive(loanId);
        if (block.timestamp <= l.defaultableAt) revert LoanNotDue(loanId, l.defaultableAt);

        uint256 p = l.principal;
        uint256 s = l.sponsorId;
        uint256 agentId = l.agentId;
        uint256 f = l.fee;
        feeLocked[s] -= f;
        uint256 burnt = _slash(s, p, f);

        l.status = LoanStatus.Defaulted;
        l.closedAt = uint64(block.timestamp);
        Agent storage a = _agents[agentId];
        a.principalOut -= p;
        a.activeLoans -= 1;
        a.delegatedIn -= p;
        a.defaulted = true;
        _agents[s].delegatedOut -= p;
        _agents[s].childrenDefaulted += 1;
        if (!custodian[l.owner]) ownerDefaults[l.owner] += 1;
        emit Defaulted(loanId, agentId, s, p, burnt, l.owner);

        _payKeeper();
        _notify(s, abi.encodeWithSelector(IBackerHook.onDefault.selector, s, agentId, loanId, p, a.activeLoans == 0));
        _settleDead(agentId, a);
    }

    /// @dev Burn the backer's shares worth `p + f`, rounding up so the share price can only rise: `p` is the principal
    ///      that left the pool, `f` the unpaid fee, which stays with the remaining shares (the lenders' income).
    function _slash(uint256 s, uint256 p, uint256 f) internal returns (uint256 burn) {
        uint256 ts = totalShares;
        uint256 ta = totalAssets();
        burn = ((p + f) * ts + ta - 1) / ta;
        uint256 held = rootShares[s];
        if (burn > held) {
            /* Only reachable by rounding: each burn rounds up by under one share, so a fully vouched backer can
               end up a unit or two short on a later default. The reserve tops up exactly enough that the share
               price still cannot fall; anything the reserve cannot cover is recorded, never hidden. */
            burn = held;
            // price after = (ta - p + gap) / (ts - held) must be >= ta / ts
            uint256 need = p * ts > held * ta ? (p * ts - held * ta + ts - 1) / ts : 0;
            uint256 gap = need < reserve ? need : reserve;
            reserve -= gap;
            poolLiquidity += gap;
            if (need > gap) totalBadDebt += need - gap;
        }
        rootShares[s] = held - burn;
        totalShares = ts - burn;
        totalPrincipalOut -= p;
        totalSlashed += p;
    }

    function _payKeeper() internal {
        uint256 bounty = params.keeperBounty < reserve ? params.keeperBounty : reserve;
        if (bounty > 0) {
            reserve -= bounty;
            usdg.safeTransfer(msg.sender, bounty);
            emit KeeperPaid(msg.sender, bounty);
        }
    }

    // ------------------------------------------------------------------
    // Backer hooks
    // ------------------------------------------------------------------

    /// @dev No hook: allowed. Otherwise the hook decides (see PoolV2Lib.canBorrow).
    function _canBorrow(uint256 s, bytes memory args) internal view returns (bool) {
        address h = hook[s];
        if (h == address(0)) return true;
        return PoolV2Lib.canBorrow(h, abi.encodePacked(IBackerHook.canBorrow.selector, args));
    }

    function _notify(uint256 s, bytes memory data) internal {
        address h = hook[s];
        if (h == address(0)) return;
        if (!PoolV2Lib.notify(h, data)) {
            bytes4 sel;
            assembly {
                sel := mload(add(data, 0x20))
            }
            emit HookFailed(s, sel);
        }
    }

    function _notifyRelease(uint256 s, uint256 agentId, uint256 amount, Release reason) internal {
        emit Released(s, agentId, amount, reason);
        _notify(s, abi.encodeWithSelector(IBackerHook.onRelease.selector, s, agentId, amount, uint8(reason)));
    }

    // ------------------------------------------------------------------
    // Migration
    // ------------------------------------------------------------------

    /// @notice Carry an agent's v1 record over. Anyone, once per agent, once it has no loan open on v1. Adds to
    ///         what v2 holds; a v1 default makes it defaulted here. No money moves.
    function importFromV1(uint256 agentId) external nonReentrant {
        if (address(v1) == address(0)) revert NoV1();
        Agent storage a = _agents[agentId];
        if (a.importedFromV1) revert AlreadyImported(agentId);
        PoolV2Lib.V1Record memory o = PoolV2Lib.v1Record(v1, agentId);
        if (o.activeLoans != 0) revert V1Busy(agentId);
        if (o.enrolledAt == 0 && o.loansRepaid == 0) revert InvalidAgent(agentId);
        a.importedFromV1 = true;
        a.loansRepaid += o.loansRepaid;
        a.volumeRepaid += o.volumeRepaid;
        a.feesPaid += o.feesPaid;
        a.recourseHonored += o.recourseHonored;
        a.childrenDefaulted += o.childrenDefaulted;
        a.qualifiedRepaid += o.qualifiedRepaid;
        a.dollarSecondsRepaid += o.dollarSecondsRepaid;
        if (
            a.loansRepaid > MAX_IMPORT_COUNT || a.recourseHonored > MAX_IMPORT_COUNT
                || a.childrenDefaulted > MAX_IMPORT_COUNT || a.qualifiedRepaid > MAX_IMPORT_COUNT
                || a.volumeRepaid > MAX_IMPORT_AMOUNT || a.feesPaid > MAX_IMPORT_AMOUNT
                || a.dollarSecondsRepaid > MAX_IMPORT_AMOUNT * uint256(MAX_PERIOD)
        ) revert ImportOutOfRange(agentId);
        if (o.enrolledAt != 0 && o.enrolledAt <= block.timestamp && (a.enrolledAt == 0 || o.enrolledAt < a.enrolledAt))
        {
            a.enrolledAt = o.enrolledAt;
        }
        if (o.defaulted && !a.defaulted) {
            a.defaulted = true;
            _settleDead(agentId, a);
        }
        emit ImportedFromV1(agentId, o.loansRepaid, o.defaulted);
    }

    // ------------------------------------------------------------------
    // Reserve
    // ------------------------------------------------------------------

    function fundReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }

    // ------------------------------------------------------------------
    // Owner (a 48 h timelock)
    // ------------------------------------------------------------------

    function withdrawReserve(uint256 amount, address to) external onlyOwner nonReentrant {
        if (amount > reserve) revert ReserveShort(amount, reserve);
        reserve -= amount;
        usdg.safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    /// @notice Move reserve into a backer's stake: protocol capital as senior backing.
    function reserveToStake(uint256 rootId, uint256 amount) external onlyOwner nonReentrant {
        if (!_agents[rootId].isRoot) revert NotRoot(rootId);
        if (amount == 0) revert ZeroAmount();
        if (amount > reserve) revert ReserveShort(amount, reserve);
        uint256 minted = convertToShares(amount);
        if (minted == 0) revert ZeroAmount();
        reserve -= amount;
        poolLiquidity += amount;
        totalShares += minted;
        rootShares[rootId] += minted;
        emit ReserveStaked(rootId, amount, minted);
    }

    function setCustodian(address who, bool allowed) external onlyOwner {
        custodian[who] = allowed;
        emit CustodianSet(who, allowed);
    }

    function setGuardian(address g) external onlyOwner {
        guardian = g;
        emit GuardianSet(g);
    }

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    function _setParams(Params memory p) internal {
        if (
            p.minLoan == 0 || p.minLoan > p.maxLoan || p.minTerm == 0 || p.minTerm > p.maxTerm || p.maxTerm > MAX_PERIOD
                || p.grace < MIN_GRACE || p.grace > MAX_PERIOD || p.minScoreTerm > p.maxTerm || p.feeBps > MAX_FEE_BPS
                || p.sponsorFeeBps + p.protocolFeeBps > 10_000 || p.maxUtilizationBps == 0
                || p.maxUtilizationBps > 10_000 || p.keeperBounty > MAX_KEEPER_BOUNTY
        ) revert InvalidParams();
        params = p;
        emit ParamsUpdated(p);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getParams() external view returns (Params memory) {
        return params;
    }

    function getAgent(uint256 id) external view returns (Agent memory) {
        return _agents[id];
    }

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    function loanCount() external view returns (uint256) {
        return _loans.length - 1;
    }

    function loansOf(uint256 id) external view returns (uint256[] memory) {
        return _loansOf[id];
    }
}

/// @notice What a backer contract implements to hear from the pool. `rootId` says which of its roots is involved.
interface IBackerHook {
    function canBorrow(
        uint256 rootId,
        uint256 agentId,
        uint256 amount,
        uint64 term,
        uint256 fee,
        address caller,
        address owner,
        address to
    ) external view returns (bool);
    function onBorrow(uint256 rootId, uint256 agentId, uint256 loanId) external;
    function onDefault(uint256 rootId, uint256 agentId, uint256 loanId, uint256 principal, bool lastLoan) external;
    function onRelease(uint256 rootId, uint256 agentId, uint256 amount, uint8 reason) external;
}
