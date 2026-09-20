// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {ScoreLib} from "./libraries/ScoreLib.sol";

/// @title CreditPool
/// @notice Unsecured micro-credit for ERC-8004 agents, underwritten by a sponsor tree.
///
///  Reputation you can't Sybil: the only record here is money that was lent and paid back.
///
///  Roles
///   - Lenders deposit USDC and receive pool shares. Fees accrue to the pool.
///   - Roots post USDC stake. Stake is credit capacity, 1:1. Roots vouch for agents and are slashed first.
///   - Agents (ERC-8004 ids) receive capacity from exactly one sponsor, borrow against it, and grow their
///     own `earned` capacity by repaying. Earned capacity is rate-limited per epoch, capped per agent, and
///     only ever granted while the first-loss reserve covers the sum of all earned capacity.
///   - The reserve (funded by the operator) is the pool's marketing and data budget: it eats bad debt first.
///
///  Capacity of agent a:
///     capacity(a)  = stake(a) + earned(a) + (sponsor(a) alive ? delegatedIn(a) : 0)
///     available(a) = capacity(a) - principalOut(a) - delegatedOut(a)
///     a non-root may delegate at most earned(a): you vouch with what you earned, never with what was lent to you.
///
///  Default of agent c with sponsor s and unpaid principal P:
///     liable = min(P, delegatedIn(c))
///     s root    -> stake(s) -= min(liable, stake(s))   (cash back to the pool, immediately)
///     s non-root-> recourse loan on s for `liable`, due in `recourseTerm`. If s defaults, it cascades up.
///     remainder -> paid from the reserve; only if the reserve is empty do lenders lose anything.
///
///  Invariant (see docs/DESIGN.md): bad debt caused by any agent <= earned(agent) <= reserve, so with the
///  reserve intact lenders never lose principal. Every dollar of unbacked credit is pre-funded.
///
///  Everything is an event. The score is a pure function of the record.
contract CreditPool is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum LoanStatus {
        None,
        Active,
        Repaid,
        Defaulted
    }

    struct Agent {
        bool enrolled;
        bool isRoot;
        bool defaulted;
        uint64 enrolledAt;
        uint256 sponsor; // agentId of the sponsor; 0 for roots (agentId 0 is reserved / never valid)
        uint256 delegatedIn; // capacity received from the sponsor
        uint256 delegatedOut; // capacity given to children
        uint256 earned; // self-earned capacity from repayments
        uint256 stake; // roots only; USDC held by this contract
        uint256 principalOut; // sum of active loan principal (incl. recourse loans)
        uint256 activeLoans;
        // history
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        // growth rate-limit
        uint64 epochStart;
        uint256 earnedThisEpoch;
        // scoring inputs that cannot be farmed with one-day loans
        uint256 qualifiedRepaid; // repaid loans with term >= params.minScoreTerm
        uint256 dollarSecondsRepaid; // sum of principal x actual holding time (capped at term) over repaid loans
    }

    struct Loan {
        uint256 agentId;
        uint256 principal;
        uint256 fee;
        uint64 issuedAt;
        uint64 dueAt;
        uint64 closedAt;
        LoanStatus status;
        bool isRecourse;
        uint256 recourseFor; // loanId of the child's defaulted loan, when isRecourse
    }

    struct Params {
        uint256 minLoan; // USDC
        uint256 maxLoan; // USDC
        uint64 minTerm; // seconds
        uint64 maxTerm; // seconds
        uint64 grace; // seconds after dueAt before a loan can be marked defaulted
        uint64 recourseTerm; // seconds a sponsor gets to cover a child's default
        uint256 feeBps; // fee per 30 days of term, in bps of principal
        uint256 growthBps; // earned capacity gained per repaid principal, bps
        uint256 maxEarned; // cap on self-earned capacity, USDC
        uint256 maxEarnPerEpoch; // rate limit on earned growth, USDC per epoch
        uint64 epochLength; // seconds
        uint64 minSeasoning; // a loan repaid before issuedAt + minSeasoning earns nothing
        uint256 minStake; // USDC required to enroll as root
        uint256 sponsorFeeBps; // share of each loan fee paid to the borrower's sponsor
        uint256 protocolFeeBps; // share of each loan fee that goes into the first-loss reserve
        uint64 minScoreTerm; // a repaid loan shorter than this does not count as a qualified loan for the score
    }

    struct CreditReport {
        bool enrolled;
        bool isRoot;
        bool defaulted;
        uint256 sponsor;
        uint256 capacity;
        uint256 available;
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
        uint64 enrolledAt;
        uint256 score;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    IERC20 public immutable usdc;
    IERC8004Identity public immutable registry;
    Params internal params;

    // pool accounting (lender money)
    uint256 public poolLiquidity; // USDC sitting here that belongs to lenders
    uint256 public totalPrincipalOut; // USDC lent out (incl. recourse loans)
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    uint256 public totalBadDebt; // cumulative principal written off (reserve + lenders)
    uint256 public totalReserveCovered; // portion of totalBadDebt paid by the reserve
    uint256 public totalFeesEarned; // lenders' share of fees, cumulative
    uint256 public totalSponsorFees; // sponsors' share, cumulative
    uint256 public totalProtocolFees; // protocol share, cumulative (all of it went into the reserve)
    uint256 public unclaimedSponsorFees; // sponsor fees sitting here, not yet claimed
    uint256 public totalExitFees; // cumulative early-exit fees kept for the lenders who stayed
    mapping(uint256 => uint256) public sponsorFees; // agentId => claimable
    uint256 public totalStake; // USDC held for roots (not lender money)
    uint256 public reserve; // first-loss reserve (not lender money)
    uint256 public totalEarned; // sum of live agents' earned capacity; never allowed above `reserve`
    bool public importsSealed; // once true, repayment history can never be written again

    mapping(uint256 => Agent) internal _agents;
    mapping(uint256 => address) public delegateOf; // agentId => an address allowed to act for the agent
    mapping(uint256 => address) private _delegateOwner;
    uint256[] public enrolledAgents;

    Loan[] internal _loans; // loanId = index; loan 0 is a sentinel
    mapping(uint256 => uint256[]) internal _loansOf;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event Deposited(address indexed lender, uint256 assets, uint256 sharesMinted);
    event Withdrawn(address indexed lender, uint256 assets, uint256 sharesBurned);
    event RootEnrolled(uint256 indexed agentId, uint256 stake);
    event StakeAdded(uint256 indexed agentId, uint256 amount);
    event StakeWithdrawn(uint256 indexed agentId, uint256 amount);
    event StakeSlashed(uint256 indexed agentId, uint256 amount, uint256 indexed forLoanId);
    event AgentEnrolled(uint256 indexed agentId, uint256 indexed sponsor);
    event Vouched(uint256 indexed sponsor, uint256 indexed agentId, uint256 amount, uint256 delegatedIn);
    event Unvouched(uint256 indexed sponsor, uint256 indexed agentId, uint256 amount, uint256 delegatedIn);
    event Borrowed(
        uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, uint64 dueAt, address to
    );
    event Repaid(uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 fee, address payer);
    event CapacityEarned(uint256 indexed agentId, uint256 gained, uint256 earned);
    /// @notice A sponsor's earned credit was written off because a delegation standing on it defaulted.
    event CapacityRetired(uint256 indexed agentId, uint256 retired, uint256 earned, uint256 indexed forLoanId);
    event FeeSplit(
        uint256 indexed loanId,
        uint256 indexed sponsor,
        uint256 fee,
        uint256 toLenders,
        uint256 toSponsor,
        uint256 toReserve
    );
    event SponsorFeesClaimed(uint256 indexed agentId, address indexed to, uint256 amount);
    event BackingReleased(uint256 indexed agentId, uint256 indexed sponsor, uint256 amount);
    event Defaulted(
        uint256 indexed loanId, uint256 indexed agentId, uint256 principal, uint256 liableSponsor, uint256 badDebt
    );
    event RecourseIssued(
        uint256 indexed loanId, uint256 indexed sponsor, uint256 indexed childAgentId, uint256 amount, uint64 dueAt
    );
    event ReserveFunded(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event ReserveCovered(uint256 indexed loanId, uint256 amount, uint256 lenderLoss);
    event RecordImported(uint256 indexed agentId, uint256 loansRepaid, uint256 volumeRepaid);
    event ImportsSealed();
    event DelegateSet(uint256 indexed agentId, address delegate);
    event ParamsUpdated(Params params);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error NotController(uint256 agentId, address caller);
    error InvalidAgent(uint256 agentId);
    error AlreadyEnrolled(uint256 agentId);
    error NotEnrolled(uint256 agentId);
    error AgentDefaulted(uint256 agentId);
    error IsRoot(uint256 agentId);
    error NotRoot(uint256 agentId);
    error WrongSponsor(uint256 agentId, uint256 currentSponsor);
    error InsufficientCapacity(uint256 agentId, uint256 requested, uint256 available);
    error DelegationInUse(uint256 agentId, uint256 requested, uint256 releasable);
    error ImportOutOfRange(uint256 agentId);

    /// Ceiling for every duration parameter. A year is far outside anything this protocol expresses, and
    /// past it the uint64 timestamp arithmetic in `repay` and `markDefault` overflows and reverts forever.
    uint64 private constant MAX_PERIOD = 365 days;
    /// Ceilings for imported history. These exist so a migration cannot brick the record it is preserving:
    /// `ScoreLib` multiplies the counters by 20, 50 and 75, and an absurd value makes `score()` and
    /// `creditReport()` revert permanently - after `vouch` sets `enrolled`, with imports already sealed and
    /// the record no longer blank, there is no way back. Both bounds are orders of magnitude past any real
    /// history: a billion loans, and a billion dollars of volume at six decimals.
    uint256 private constant MAX_IMPORT_COUNT = 1e9;
    uint256 private constant MAX_IMPORT_AMOUNT = 1e15;
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error LoanSizeOutOfRange(uint256 amount);
    error TermOutOfRange(uint64 term);
    error LoanNotActive(uint256 loanId);
    error LoanNotDue(uint256 loanId, uint64 dueAt);
    error ZeroAmount();
    error BelowMinStake(uint256 amount, uint256 minStake);
    error InvalidParams();
    error DelegationExceedsEarned(uint256 agentId, uint256 requested, uint256 earnedRoom);
    error ReserveLocked(uint256 requested, uint256 free);
    error ImportsAreSealed();
    error RecordAlreadyLive(uint256 agentId);
    error BadEnrolmentDate(uint256 agentId, uint64 enrolledAt);

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(IERC20 usdc_, IERC8004Identity registry_, address owner_) Ownable(owner_) {
        usdc = usdc_;
        registry = registry_;
        _loans.push(); // sentinel so loanId 0 is never a real loan
        params = Params({
            minLoan: 5e6,
            maxLoan: 500e6,
            minTerm: 1 days,
            maxTerm: 30 days,
            grace: 3 days,
            recourseTerm: 14 days,
            feeBps: 100, // 1% per 30 days
            growthBps: 5000, // repay $100 -> +$50 earned capacity
            maxEarned: 250e6, // at most $250 of unbacked capacity per agent
            maxEarnPerEpoch: 25e6, // and at most +$25 per epoch
            epochLength: 7 days,
            minSeasoning: 1 days,
            minStake: 10e6,
            sponsorFeeBps: 2500, // vouching pays: a quarter of every fee your agents pay
            protocolFeeBps: 1500, // and 15% of every fee grows the reserve that backs earned credit
            minScoreTerm: 7 days
        });
    }

    // ------------------------------------------------------------------
    // Modifiers / auth
    // ------------------------------------------------------------------

    /// @dev Caller must own the ERC-8004 agent or be its delegate.
    modifier onlyController(uint256 agentId) {
        if (!isController(agentId, msg.sender)) revert NotController(agentId, msg.sender);
        _;
    }

    function isController(uint256 agentId, address who) public view returns (bool) {
        if (agentId == 0) return false;
        try registry.ownerOf(agentId) returns (address o) {
            return o == who || (who != address(0) && delegateOf[agentId] == who && _delegateOwner[agentId] == o);
        } catch {
            return false;
        }
    }

    /// @notice Let another address (e.g. the agent's hot wallet) act for the agent. Only the ERC-8004 owner can set it.
    function setDelegate(uint256 agentId, address delegate) external {
        address o;
        try registry.ownerOf(agentId) returns (address o_) {
            o = o_;
        } catch {
            revert InvalidAgent(agentId);
        }
        if (o != msg.sender) revert NotController(agentId, msg.sender);
        delegateOf[agentId] = delegate;
        _delegateOwner[agentId] = o;
        emit DelegateSet(agentId, delegate);
    }

    // ------------------------------------------------------------------
    // Lenders
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // One-time history import (migration only)
    // ------------------------------------------------------------------

    /// @notice An agent's repayment record carried over from a previous deployment of this pool.
    /// @dev    Reputation ONLY. Every money field - stake, earned, delegation, loans - is deliberately
    ///         absent, so an import cannot itself create capacity or move a unit of anyone's funds: a
    ///         migrated agent still has to be vouched for here, normally, out of somebody's real backing.
    ///
    ///         It is NOT inert downstream, though, and claiming otherwise would be false.
    ///         `TreasurySponsor.eligibleForRaise` gates a second line on `enrolledAt + minSeasoning` and
    ///         on `qualifiedRepaid`, both of which come from here - so an imported record can take its
    ///         raise at once instead of seasoning first. That is what carrying history over MEANS: a
    ///         migrated agent is not a newcomer. And it hands the owner no new power, because
    ///         `TreasurySponsor.setRules` already lets them set `minSeasoning` to zero outright. What
    ///         bounds the damage is the treasury's own capacity and epoch cap, not this function.
    ///
    ///         The window closes on the first deposit, so none of it is reachable once lenders are in.
    struct ImportedRecord {
        uint256 agentId;
        uint64 enrolledAt;
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    /// @notice Carry repayment history over from a previous deployment, before this pool opens.
    ///         Batched so a migration is one atomic transaction rather than a half-imported ledger.
    ///         Capacity is NOT imported: every agent still has to be vouched for here, normally.
    function importRecords(ImportedRecord[] calldata rs) external onlyOwner {
        if (importsSealed) revert ImportsAreSealed();
        for (uint256 i = 0; i < rs.length; i++) {
            ImportedRecord calldata r = rs[i];
            Agent storage a = _agents[r.agentId];
            // Only ever onto a blank slate. Never edit a record this pool has itself written.
            if (a.enrolled || a.loansRepaid != 0 || a.enrolledAt != 0) revert RecordAlreadyLive(r.agentId);
            // `score()` ages a record with `block.timestamp - enrolledAt`. A date in the future would
            // underflow it, and score() is reached through creditReport() - the agent's page and the SDK
            // would revert for good. Reject it here rather than let one typo brick a record.
            if (r.enrolledAt == 0 || r.enrolledAt > block.timestamp) revert BadEnrolmentDate(r.agentId, r.enrolledAt);
            /* The date check above exists because one bad value there underflowed `score()`. The counters
               next to it were unchecked, and they multiply: a large `qualifiedRepaid`, `recourseHonored` or
               `childrenDefaulted` makes `score()` and `creditReport()` revert with an arithmetic panic
               permanently, unrecoverably. Bound them the same way. */
            if (
                r.loansRepaid > MAX_IMPORT_COUNT || r.recourseHonored > MAX_IMPORT_COUNT
                    || r.childrenDefaulted > MAX_IMPORT_COUNT || r.qualifiedRepaid > MAX_IMPORT_COUNT
                    || r.volumeRepaid > MAX_IMPORT_AMOUNT || r.feesPaid > MAX_IMPORT_AMOUNT
                    || r.dollarSecondsRepaid > MAX_IMPORT_AMOUNT * uint256(MAX_PERIOD)
            ) revert ImportOutOfRange(r.agentId);
            registry.ownerOf(r.agentId); // must exist in ERC-8004 (reverts otherwise)
            a.enrolledAt = r.enrolledAt;
            a.loansRepaid = r.loansRepaid;
            a.volumeRepaid = r.volumeRepaid;
            a.feesPaid = r.feesPaid;
            a.recourseHonored = r.recourseHonored;
            a.childrenDefaulted = r.childrenDefaulted;
            a.qualifiedRepaid = r.qualifiedRepaid;
            a.dollarSecondsRepaid = r.dollarSecondsRepaid;
            emit RecordImported(r.agentId, r.loansRepaid, r.volumeRepaid);
        }
    }

    /// @notice Close the import window by hand. `deposit` does it too, so it cannot be forgotten.
    function sealImports() external onlyOwner {
        _sealImports();
    }

    function _sealImports() internal {
        if (!importsSealed) {
            importsSealed = true;
            emit ImportsSealed();
        }
    }

    // ------------------------------------------------------------------
    // Lenders
    // ------------------------------------------------------------------

    /* A position that exists for zero seconds must not earn a fee.
       The lender slice of a fee lands on the share price the instant a loan is repaid, so whoever holds
       shares at that instant collects it. An audit measured both halves: a bot depositing in front of a
       repayment and leaving straight after took $2.70 of a $3 lender fee, leaving $0.30 for the lender who
       had carried thirty days of default risk; and a BORROWER could wrap its own repayment in a deposit and
       a withdrawal, atomically, and recover 54% of its own fee.

       Vesting the fee over a window is the fairer fix and was tried first. It changes when the share price
       moves, which rippled through six existing tests and - on a non-upgradeable contract about to hold real
       money - is a large blast radius for the least severe bug in this set (it steals yield, not principal).
       This is the smaller one: leaving inside `MIN_HOLD` pays a fee back to the pool, which makes a
       zero-duration position decisively unprofitable and leaves every other behaviour untouched.

       Deliberately CONSTANT rather than a parameter. An owner-tunable exit fee would be a lever to
       confiscate lender deposits, and "the owner cannot reach lender principal" is the strongest property
       this design has. A fixed 0.5% cannot become 100%. */
    uint64 public constant MIN_HOLD = 7 days;
    uint256 public constant EARLY_EXIT_BPS = 50; // 0.5%, kept by the pool for the lenders who stayed
    mapping(address => uint64) public lastDepositAt;

    /// What leaving right now would cost this holder, so a caller never has to guess.
    function earlyExitFee(address holder, uint256 shares_) public view returns (uint256) {
        if (block.timestamp >= uint256(lastDepositAt[holder]) + MIN_HOLD) return 0;
        return convertToAssets(shares_) * EARLY_EXIT_BPS / 10_000;
    }

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

    function deposit(uint256 assets, address receiver) external nonReentrant whenNotPaused returns (uint256 minted) {
        // Lender money is here: history is now whatever this pool records, and nothing else.
        _sealImports();
        if (assets == 0) revert ZeroAmount();
        minted = convertToShares(assets);
        if (minted == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), assets);
        poolLiquidity += assets;
        totalShares += minted;
        shares[receiver] += minted;
        /* The hold clock is on whoever ends up holding the shares, weighted by how much arrives.
           Setting it to `block.timestamp` outright was a griefing vector I put in and then found:
           `deposit(1, victim)` would restart a stranger's seven days and tax their exit 0.5%, for one
           unit of USDG. Keying it on `msg.sender == receiver` instead would have been worse - a sandwich
           would simply deposit to a second address of its own and pay nothing.
           A share-weighted average fixes both: one unit into a large position moves the clock by
           essentially nothing, while a sandwich-sized deposit into an empty one sets it to now. */
        uint256 held = shares[receiver] - minted;
        lastDepositAt[receiver] = held == 0
            ? uint64(block.timestamp)
            : uint64((held * uint256(lastDepositAt[receiver]) + minted * block.timestamp) / (held + minted));
        emit Deposited(receiver, assets, minted);
    }

    function withdraw(uint256 shares_, address receiver) external nonReentrant returns (uint256 assets) {
        if (shares_ == 0) revert ZeroAmount();
        assets = convertToAssets(shares_);
        if (assets > poolLiquidity) revert InsufficientLiquidity(assets, poolLiquidity);
        // Leaving inside MIN_HOLD leaves a slice behind. It never goes anywhere: `poolLiquidity` keeps it,
        // so it raises the share price for the lenders who are still carrying the risk.
        uint256 fee =
            block.timestamp < uint256(lastDepositAt[msg.sender]) + MIN_HOLD ? assets * EARLY_EXIT_BPS / 10_000 : 0;
        uint256 out = assets - fee;
        shares[msg.sender] -= shares_; // reverts on underflow
        totalShares -= shares_;
        totalExitFees += fee; // tracked so the books stay an exact identity, not an inequality
        poolLiquidity -= out;
        usdc.safeTransfer(receiver, out);
        emit Withdrawn(msg.sender, out, shares_);
        assets = out;
    }

    // ------------------------------------------------------------------
    // First-loss reserve
    // ------------------------------------------------------------------

    /// @notice Fund the reserve. Anyone can; the operator is expected to. This is what backs earned capacity.
    function fundReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice Withdraw reserve that is not backing anyone's earned capacity.
    function withdrawReserve(uint256 amount, address to) external onlyOwner nonReentrant {
        uint256 free = reserve > totalEarned ? reserve - totalEarned : 0;
        if (amount > free) revert ReserveLocked(amount, free);
        reserve -= amount;
        usdc.safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    // ------------------------------------------------------------------
    // Roots (stake-backed sponsors)
    // ------------------------------------------------------------------

    function enrollRoot(uint256 agentId, uint256 stakeAmount)
        external
        nonReentrant
        whenNotPaused
        onlyController(agentId)
    {
        Agent storage a = _agents[agentId];
        if (a.enrolled) revert AlreadyEnrolled(agentId);
        if (stakeAmount < params.minStake) revert BelowMinStake(stakeAmount, params.minStake);
        a.enrolled = true;
        a.isRoot = true;
        if (a.enrolledAt == 0) a.enrolledAt = uint64(block.timestamp); // see vouch(): keep an imported date
        a.epochStart = uint64(block.timestamp);
        enrolledAgents.push(agentId);
        _addStake(agentId, a, stakeAmount);
        emit RootEnrolled(agentId, stakeAmount);
    }

    function addStake(uint256 agentId, uint256 amount) external nonReentrant whenNotPaused {
        Agent storage a = _agents[agentId];
        if (!a.enrolled || !a.isRoot) revert NotRoot(agentId);
        if (a.defaulted) revert AgentDefaulted(agentId);
        _addStake(agentId, a, amount);
    }

    function _addStake(uint256 agentId, Agent storage a, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        a.stake += amount;
        totalStake += amount;
        emit StakeAdded(agentId, amount);
    }

    /// @notice Withdraw stake that is not backing anything (not delegated, not borrowed against).
    function withdrawStake(uint256 agentId, uint256 amount, address to) external nonReentrant onlyController(agentId) {
        Agent storage a = _agents[agentId];
        if (!a.isRoot) revert NotRoot(agentId);
        /* A defaulted agent's capacity is 0, so `_available` is 0 and its remaining stake used to be
           unreachable forever: not withdrawable, not re-stakeable (`addStake` reverts `AgentDefaulted`),
           not credited to lenders either, since `totalAssets` excludes `totalStake`. Dead weight owned by
           nobody. Once a defaulted root has no loan open and nothing delegated out, nothing is relying on
           that money and it is its own - the slashing already happened. */
        uint256 avail =
            !a.defaulted ? _available(agentId, a) : (a.activeLoans == 0 && a.delegatedOut == 0 ? a.stake : 0);
        if (amount > avail) revert InsufficientCapacity(agentId, amount, avail);
        a.stake -= amount;
        totalStake -= amount;
        usdc.safeTransfer(to, amount);
        emit StakeWithdrawn(agentId, amount);
    }

    // ------------------------------------------------------------------
    // Sponsor tree
    // ------------------------------------------------------------------

    /// @notice Delegate `amount` of the sponsor's available capacity to `agentId`. Enrolls the agent on first vouch.
    ///         An agent has exactly one sponsor at a time. If its sponsor has defaulted, a new sponsor may take over.
    function vouch(uint256 sponsorId, uint256 agentId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyController(sponsorId)
    {
        if (amount == 0) revert ZeroAmount();
        if (agentId == 0 || agentId == sponsorId) revert InvalidAgent(agentId);
        Agent storage s = _agents[sponsorId];
        if (!s.enrolled) revert NotEnrolled(sponsorId);
        if (s.defaulted) revert AgentDefaulted(sponsorId);

        Agent storage c = _agents[agentId];
        if (c.defaulted) revert AgentDefaulted(agentId);
        if (c.isRoot) revert IsRoot(agentId);

        if (!c.enrolled) {
            registry.ownerOf(agentId); // must exist in ERC-8004 (reverts otherwise)
            c.enrolled = true;
            // An imported record already carries the date it first enrolled, and age is part of the
            // score - overwriting it here would quietly reset the very history the import preserved.
            if (c.enrolledAt == 0) c.enrolledAt = uint64(block.timestamp);
            c.epochStart = uint64(block.timestamp);
            c.sponsor = sponsorId;
            enrolledAgents.push(agentId);
            emit AgentEnrolled(agentId, sponsorId);
        } else if (c.sponsor != sponsorId) {
            // takeover is allowed only if the current sponsor is dead
            Agent storage old = _agents[c.sponsor];
            if (!old.defaulted) revert WrongSponsor(agentId, c.sponsor);
            // old sponsor's delegation is void (capacity() already ignores it); clean the books
            old.delegatedOut -= c.delegatedIn;
            c.delegatedIn = 0;
            c.sponsor = sponsorId;
            emit AgentEnrolled(agentId, sponsorId);
        }

        uint256 avail = _available(sponsorId, s);
        if (amount > avail) revert InsufficientCapacity(sponsorId, amount, avail);
        if (!s.isRoot) {
            uint256 room = s.earned > s.delegatedOut ? s.earned - s.delegatedOut : 0;
            if (amount > room) revert DelegationExceedsEarned(sponsorId, amount, room);
        }
        s.delegatedOut += amount;
        c.delegatedIn += amount;
        emit Vouched(sponsorId, agentId, amount, c.delegatedIn);
    }

    /// @notice Pull back delegated capacity the child is not using.
    ///
    /// @dev A sponsor is first-loss for what it vouched, and the delegation backing a DRAWN loan cannot be
    ///      released. Bounding this by the child's `_available` was not enough: `_available` counts the
    ///      child's own earned credit, so a child with earned headroom let its sponsor detach the backing
    ///      from a loan already drawn against it, and `markDefault` then found `delegatedIn == 0`, charged
    ///      nobody, and sent the loss to the reserve. An audit measured that at $100 of reserve for $0.084
    ///      of fees, with a stake that came back intact and could be recycled.
    ///
    ///      The bound is the rule `markDefault` already uses to decide liability: a default charges
    ///      `min(principal, delegatedIn)` to the sponsor, so delegation is the primary backing for drawn
    ///      principal and exactly that much of it stays until the loan closes. Anything above it is free,
    ///      which is what keeps `TreasurySponsor.reclaim()` working - it only ever unvouches a line whose
    ///      agent has no open loan, so for that caller the whole delegation is releasable.
    function unvouch(uint256 sponsorId, uint256 agentId, uint256 amount)
        external
        nonReentrant
        onlyController(sponsorId)
    {
        Agent storage c = _agents[agentId];
        if (c.sponsor != sponsorId) revert WrongSponsor(agentId, c.sponsor);
        if (amount == 0) revert ZeroAmount();
        uint256 childAvail = _available(agentId, c);
        if (amount > childAvail) revert InsufficientCapacity(agentId, amount, childAvail);
        uint256 releasable = c.delegatedIn > c.principalOut ? c.delegatedIn - c.principalOut : 0;
        if (amount > releasable) revert DelegationInUse(agentId, amount, releasable);
        c.delegatedIn -= amount;
        _agents[sponsorId].delegatedOut -= amount;
        emit Unvouched(sponsorId, agentId, amount, c.delegatedIn);
    }

    /// @notice Sponsors collect their share of the fees their agents paid.
    function claimSponsorFees(uint256 agentId, address to)
        external
        nonReentrant
        onlyController(agentId)
        returns (uint256 amount)
    {
        amount = sponsorFees[agentId];
        if (amount == 0) revert ZeroAmount();
        sponsorFees[agentId] = 0;
        unclaimedSponsorFees -= amount;
        usdc.safeTransfer(to, amount);
        emit SponsorFeesClaimed(agentId, to, amount);
    }

    // ------------------------------------------------------------------
    // Borrow / repay / default
    // ------------------------------------------------------------------

    function quoteFee(uint256 principal, uint64 term) public view returns (uint256) {
        return principal * params.feeBps * term / (10_000 * 30 days);
    }

    function borrow(uint256 agentId, uint256 amount, uint64 term, address to)
        external
        nonReentrant
        whenNotPaused
        onlyController(agentId)
        returns (uint256 loanId)
    {
        Agent storage a = _agents[agentId];
        if (!a.enrolled) revert NotEnrolled(agentId);
        if (a.defaulted) revert AgentDefaulted(agentId);
        if (amount < params.minLoan || amount > params.maxLoan) revert LoanSizeOutOfRange(amount);
        if (term < params.minTerm || term > params.maxTerm) revert TermOutOfRange(term);
        uint256 avail = _available(agentId, a);
        if (amount > avail) revert InsufficientCapacity(agentId, amount, avail);
        if (amount > poolLiquidity) revert InsufficientLiquidity(amount, poolLiquidity);

        uint256 fee = quoteFee(amount, term);
        uint64 dueAt = uint64(block.timestamp) + term;
        loanId = _loans.length;
        _loans.push(
            Loan({
                agentId: agentId,
                principal: amount,
                fee: fee,
                issuedAt: uint64(block.timestamp),
                dueAt: dueAt,
                closedAt: 0,
                status: LoanStatus.Active,
                isRecourse: false,
                recourseFor: 0
            })
        );
        _loansOf[agentId].push(loanId);

        a.principalOut += amount;
        a.activeLoans += 1;
        poolLiquidity -= amount;
        totalPrincipalOut += amount;
        usdc.safeTransfer(to, amount);
        emit Borrowed(loanId, agentId, amount, fee, dueAt, to);
    }

    /// @notice Anyone can repay any active loan (the agent, its operator, its sponsor...).
    function repay(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.status != LoanStatus.Active) revert LoanNotActive(loanId);
        Agent storage a = _agents[l.agentId];

        uint256 due = l.principal + l.fee;
        usdc.safeTransferFrom(msg.sender, address(this), due);

        l.status = LoanStatus.Repaid;
        l.closedAt = uint64(block.timestamp);
        a.principalOut -= l.principal;
        a.activeLoans -= 1;
        totalPrincipalOut -= l.principal;
        a.feesPaid += l.fee;

        poolLiquidity += l.principal;
        _splitFee(loanId, a, l.fee, l.isRecourse);

        if (l.isRecourse) {
            a.recourseHonored += 1;
        } else {
            a.loansRepaid += 1;
            a.volumeRepaid += l.principal;
            uint64 term = l.dueAt - l.issuedAt;
            uint256 held = block.timestamp - l.issuedAt;
            if (held > term) held = term;
            a.dollarSecondsRepaid += l.principal * held;
            if (held >= params.minScoreTerm) a.qualifiedRepaid += 1;
            if (!a.defaulted && block.timestamp >= l.issuedAt + params.minSeasoning) _grow(l.agentId, a, l.principal);
        }
        emit Repaid(loanId, l.agentId, l.principal, l.fee, msg.sender);
        _settleDead(l.agentId, a);
    }

    /// @dev The fee is split three ways: lenders, the sponsor who vouched for the borrower, and the reserve.
    function _splitFee(uint256 loanId, Agent storage a, uint256 fee, bool isRecourse) internal {
        uint256 toSponsor;
        uint256 toReserve;
        uint256 sponsorId;
        if (fee > 0 && !isRecourse) {
            if (!a.isRoot && !_agents[a.sponsor].defaulted) {
                sponsorId = a.sponsor;
                toSponsor = fee * params.sponsorFeeBps / 10_000;
            }
            toReserve = fee * params.protocolFeeBps / 10_000;
        }
        uint256 toLenders = fee - toSponsor - toReserve;
        poolLiquidity += toLenders;
        totalFeesEarned += toLenders;
        if (toSponsor > 0) {
            sponsorFees[sponsorId] += toSponsor;
            unclaimedSponsorFees += toSponsor;
            totalSponsorFees += toSponsor;
        }
        if (toReserve > 0) {
            reserve += toReserve;
            totalProtocolFees += toReserve;
        }
        emit FeeSplit(loanId, sponsorId, fee, toLenders, toSponsor, toReserve);
    }

    function _grow(uint256 agentId, Agent storage a, uint256 repaidPrincipal) internal {
        if (block.timestamp >= a.epochStart + params.epochLength) {
            a.epochStart = uint64(block.timestamp);
            a.earnedThisEpoch = 0;
        }
        uint256 gain = repaidPrincipal * params.growthBps / 10_000;
        uint256 epochRoom = params.maxEarnPerEpoch > a.earnedThisEpoch ? params.maxEarnPerEpoch - a.earnedThisEpoch : 0;
        uint256 capRoom = params.maxEarned > a.earned ? params.maxEarned - a.earned : 0;
        uint256 reserveRoom = reserve > totalEarned ? reserve - totalEarned : 0;
        if (gain > epochRoom) gain = epochRoom;
        if (gain > capRoom) gain = capRoom;
        if (gain > reserveRoom) gain = reserveRoom;
        if (gain == 0) return;
        a.earned += gain;
        a.earnedThisEpoch += gain;
        totalEarned += gain;
        emit CapacityEarned(agentId, gain, a.earned);
    }

    /// @notice Permissionless. After dueAt + grace, anyone can mark the loan defaulted and push the loss up the tree.
    function markDefault(uint256 loanId) external nonReentrant {
        Loan storage l = _loans[loanId];
        if (l.status != LoanStatus.Active) revert LoanNotActive(loanId);
        uint64 deadline = l.dueAt + params.grace;
        if (block.timestamp <= deadline) revert LoanNotDue(loanId, deadline);

        uint256 agentId = l.agentId;
        Agent storage c = _agents[agentId];

        l.status = LoanStatus.Defaulted;
        l.closedAt = uint64(block.timestamp);
        c.principalOut -= l.principal;
        c.activeLoans -= 1;
        totalPrincipalOut -= l.principal;

        // the defaulter is dead: no more borrowing, no more sponsoring. Its backing (delegation and earned
        // credit) is NOT released here: the agent may still have other loans open, and each of them keeps
        // its claim on that backing until it is repaid or defaults in turn. Only the slice this loan is
        // liable for is consumed now; whatever is left over is released once the last loan closes.
        c.defaulted = true;

        uint256 liable;
        uint256 sponsorId = c.sponsor;
        if (!c.isRoot) {
            Agent storage s = _agents[sponsorId];
            s.childrenDefaulted += 1;
            /* "The sponsor is dead" used to mean "the sponsor has nothing", and for a root that is simply
               untrue: its stake is cash still sitting in this contract, still earmarked against this very
               child. The loss went to the reserve instead, and past an empty reserve to the lenders, while
               the stake stayed frozen in `totalStake` owned by nobody reachable. A dead root is still
               charged, bounded by what is left of its stake; a dead non-root genuinely has nothing to take,
               since recourse would be a loan it can never repay. */
            bool chargeable = !s.defaulted || (s.isRoot && s.stake > 0);
            if (chargeable) {
                uint256 backing = c.delegatedIn;
                liable = l.principal < backing ? l.principal : backing;
                // consume exactly the liable slice of the delegation; the rest still backs the other loans
                c.delegatedIn -= liable;
                s.delegatedOut -= liable;
            }

            if (liable > 0) {
                if (s.isRoot) {
                    // cash: slash the stake straight back into the pool (bounded by what is left of it)
                    uint256 fromStake = liable < s.stake ? liable : s.stake;
                    // Whatever the stake could not cover stood on the root's earned credit, which is
                    // reserve-backed: the reserve pays it below, and the earned must be retired here so
                    // it cannot be spent a second time. Without this the same earned backs a delegation
                    // that defaults AND remains the root's own borrowing capacity, charging the reserve
                    // twice and breaking `reserve >= totalEarned` - lenders then lose principal.
                    uint256 shortfall = liable - fromStake;
                    if (shortfall > 0) {
                        uint256 fromEarned = shortfall < s.earned ? shortfall : s.earned;
                        s.earned -= fromEarned;
                        totalEarned -= fromEarned;
                        emit CapacityRetired(sponsorId, fromEarned, s.earned, loanId);
                    }
                    liable = fromStake; // only the cash slice actually came back to the pool
                    s.stake -= fromStake;
                    totalStake -= fromStake;
                    poolLiquidity += fromStake;
                    emit StakeSlashed(sponsorId, fromStake, loanId);
                } else {
                    // credit: the sponsor now owes the pool. The debt moves; pool assets are unchanged.
                    uint64 dueAt = uint64(block.timestamp) + params.recourseTerm;
                    uint256 rId = _loans.length;
                    _loans.push(
                        Loan({
                            agentId: sponsorId,
                            principal: liable,
                            fee: 0,
                            issuedAt: uint64(block.timestamp),
                            dueAt: dueAt,
                            closedAt: 0,
                            status: LoanStatus.Active,
                            isRecourse: true,
                            recourseFor: loanId
                        })
                    );
                    _loansOf[sponsorId].push(rId);
                    s.principalOut += liable;
                    s.activeLoans += 1;
                    totalPrincipalOut += liable;
                    emit RecourseIssued(rId, sponsorId, agentId, liable, dueAt);
                }
            }
            // (sponsor already dead: liable stays 0, nobody is left to charge; the reserve takes it below)
        } else {
            // a root defaulting on its own loan: its stake covers it
            uint256 fromStake = l.principal < c.stake ? l.principal : c.stake;
            if (fromStake > 0) {
                c.stake -= fromStake;
                totalStake -= fromStake;
                poolLiquidity += fromStake;
                emit StakeSlashed(agentId, fromStake, loanId);
            }
            liable = fromStake;
        }

        uint256 badDebt = l.principal - liable;
        if (badDebt > 0) {
            // the part of this loan that stood on earned credit is written off against that credit, so the
            // reserve lock (reserve >= totalEarned) tracks what is still outstanding
            uint256 fromEarned = badDebt < c.earned ? badDebt : c.earned;
            c.earned -= fromEarned;
            totalEarned -= fromEarned;
            totalBadDebt += badDebt;
            // the reserve eats it first; lenders only lose what the reserve cannot cover
            uint256 covered = badDebt < reserve ? badDebt : reserve;
            if (covered > 0) {
                reserve -= covered;
                totalReserveCovered += covered;
                poolLiquidity += covered;
            }
            emit ReserveCovered(loanId, covered, badDebt - covered);
        }
        emit Defaulted(loanId, agentId, l.principal, liable, badDebt);
        _settleDead(agentId, c);
    }

    /// @dev Once a dead agent has no loans open, whatever backing it still holds is released: the unused
    /// delegation goes back to a living sponsor's capacity, and any earned credit left is retired.
    function _settleDead(uint256 agentId, Agent storage c) internal {
        if (!c.defaulted || c.activeLoans != 0) return;
        uint256 rest = c.delegatedIn;
        if (rest > 0) {
            c.delegatedIn = 0;
            Agent storage s = _agents[c.sponsor];
            if (!c.isRoot && !s.defaulted) s.delegatedOut -= rest;
            emit BackingReleased(agentId, c.sponsor, rest);
        }
        if (c.earned > 0) {
            totalEarned -= c.earned;
            c.earned = 0;
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getParams() external view returns (Params memory) {
        return params;
    }

    function getAgent(uint256 agentId) external view returns (Agent memory) {
        return _agents[agentId];
    }

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return _loans[loanId];
    }

    function loanCount() external view returns (uint256) {
        return _loans.length - 1;
    }

    function loansOf(uint256 agentId) external view returns (uint256[] memory) {
        return _loansOf[agentId];
    }

    function enrolledCount() external view returns (uint256) {
        return enrolledAgents.length;
    }

    function capacity(uint256 agentId) public view returns (uint256) {
        return _capacity(_agents[agentId]);
    }

    function available(uint256 agentId) public view returns (uint256) {
        return _available(agentId, _agents[agentId]);
    }

    function _capacity(Agent storage a) internal view returns (uint256) {
        if (!a.enrolled || a.defaulted) return 0;
        uint256 cap = a.stake + a.earned;
        if (!a.isRoot && !_agents[a.sponsor].defaulted) cap += a.delegatedIn;
        return cap;
    }

    function _available(uint256, Agent storage a) internal view returns (uint256) {
        uint256 cap = _capacity(a);
        uint256 used = a.principalOut + a.delegatedOut;
        return cap > used ? cap - used : 0;
    }

    /// @notice The credit-backed trust score, 0..1000, plus everything it was computed from.
    function creditReport(uint256 agentId) external view returns (CreditReport memory r) {
        Agent storage a = _agents[agentId];
        r.enrolled = a.enrolled;
        r.isRoot = a.isRoot;
        r.defaulted = a.defaulted;
        r.sponsor = a.sponsor;
        r.capacity = _capacity(a);
        r.available = _available(agentId, a);
        r.delegatedIn = a.delegatedIn;
        r.delegatedOut = a.delegatedOut;
        r.earned = a.earned;
        r.stake = a.stake;
        r.principalOut = a.principalOut;
        r.activeLoans = a.activeLoans;
        r.loansRepaid = a.loansRepaid;
        r.volumeRepaid = a.volumeRepaid;
        r.feesPaid = a.feesPaid;
        r.recourseHonored = a.recourseHonored;
        r.childrenDefaulted = a.childrenDefaulted;
        r.enrolledAt = a.enrolledAt;
        r.score = score(agentId);
        r.qualifiedRepaid = a.qualifiedRepaid;
        r.dollarSecondsRepaid = a.dollarSecondsRepaid;
    }

    function score(uint256 agentId) public view returns (uint256) {
        Agent storage a = _agents[agentId];
        if (!a.enrolled) return 0;
        uint256 backing = a.stake;
        if (!a.isRoot && !_agents[a.sponsor].defaulted) backing += a.delegatedIn;
        return ScoreLib.score(
            ScoreLib.Inputs({
                defaulted: a.defaulted,
                qualifiedRepaid: a.qualifiedRepaid,
                dollarSecondsRepaid: a.dollarSecondsRepaid,
                backing: backing,
                recourseHonored: a.recourseHonored,
                childrenDefaulted: a.childrenDefaulted,
                ageSeconds: block.timestamp - a.enrolledAt
            })
        );
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function setParams(Params calldata p) external onlyOwner {
        if (p.minLoan == 0 || p.minLoan > p.maxLoan) revert InvalidParams();
        if (p.minTerm == 0 || p.minTerm > p.maxTerm) revert InvalidParams();
        if (p.growthBps > 10_000 || p.feeBps > 10_000) revert InvalidParams();
        if (p.epochLength == 0) revert InvalidParams();
        if (p.sponsorFeeBps + p.protocolFeeBps > 10_000) revert InvalidParams();
        if (p.minScoreTerm > p.maxTerm) revert InvalidParams();
        /* Four of these are added to a uint64 timestamp elsewhere, and an unbounded value makes that
           addition overflow and revert FOREVER, which is worse than any value it could legitimately hold:
             grace, recourseTerm -> markDefault: no default can ever be recorded, so loss recognition
                                    freezes and the principal keeps inflating the share price
             minSeasoning        -> repay: no loan can be repaid
             epochLength         -> _grow, reached from repay: same
           An audit found these independently, twice. A year is already far outside anything this protocol
           means to express, so bounding them costs nothing and removes the footgun. */
        if (
            p.maxTerm > MAX_PERIOD || p.grace > MAX_PERIOD || p.recourseTerm > MAX_PERIOD || p.minSeasoning > MAX_PERIOD
                || p.epochLength > MAX_PERIOD
        ) revert InvalidParams();
        params = p;
        emit ParamsUpdated(p);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
