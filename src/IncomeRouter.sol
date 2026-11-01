// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @dev The parts of CreditPoolV2 the IncomeRouter reads and calls. `Loan` and `Agent` have the pool's own layouts
///      (src/CreditPoolV2.sol is never imported: an importer joins the pool's via-IR build, foundry.toml).
interface IIncomeRouterPool {
    struct Loan {
        uint256 agentId;
        uint256 sponsorId;
        uint256 principal;
        uint256 fee;
        uint256 sponsorCut;
        uint256 reserveCut;
        uint256 premium;
        address owner;
        uint64 issuedAt;
        uint64 dueAt;
        uint64 defaultableAt;
        uint64 minScoreTerm;
        uint64 closedAt;
        uint8 status;
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
        uint256 delegatedOut;
        uint256 principalOut;
        uint256 activeLoans;
        uint256 premiumBps;
        uint256 premiumCap;
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    function usdg() external view returns (IERC20);
    function registry() external view returns (address);
    function getLoan(uint256 loanId) external view returns (Loan memory);
    function getAgent(uint256 agentId) external view returns (Agent memory);
    function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue) external;
}

/// @dev The ERC-8004 identity registry: who owns an agent.
interface IIncomeRouterRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
}

/// @title IncomeBox
/// @notice One agent's income address. Payments to the agent land here and wait. Only the IncomeRouter that deployed
///         the box can move what it holds: it has no owner, no settings, no key and no signature check (no ERC-1271),
///         so nobody can move its money with a signature either. Not audited.
contract IncomeBox {
    using SafeERC20 for IERC20;

    /// @notice The router that deployed this box, the only caller it obeys.
    address public immutable router;

    error NotRouter(address caller);

    constructor() {
        router = msg.sender;
    }

    /// @notice Send `amount` of `token` to `to`. The router alone.
    function move(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != router) revert NotRouter(msg.sender);
        token.safeTransfer(to, amount);
    }
}

/// @title IncomeRouter
/// @notice Repay from income (docs/proposals/2026-11-01-income-repay-and-inference-on-credit.md, section 2). Not
///         audited.
///
///  Every agent has its own income address, an IncomeBox at an address known before it exists (`incomeAddressOf`):
///  CREATE2 from this router, with the agent id as the salt and the same code for every agent. x402 payments, hire
///  payments, anything sent there, wait in the box. The router keeps every rule, setting and event; the box only moves
///  money when the router calls.
///
///  The agent's registry owner sets a plan (`enroll`): a share of each sweep set aside for the agent's open loans
///  taken under that owner (`Loan.owner`), within a cap per loan; an address the rest goes to (the payout); and
///  whether a loan is repaid in its window (AutoRepayV2's rule and constants) or as soon as its money is set aside.
///  - `sweep` (anyone) splits the money that arrived since the last call: the plan's share, up to what the owner's
///    open loans still need, is set aside in the box; the rest goes to the payout, with whatever is set aside beyond
///    the loans' need (a loan repaid by hand, or defaulted).
///  - `repay` (anyone) repays one loan from what is set aside for its owner, in its window, earliest due first among
///    that owner's open loans: the box pays the router the exact due, the router repays the pool in the same call. The
///    pool records the router as the payer, and the router's `IncomeRepaid` names the agent and the owner.
///  - A plan counts only while the agent keeps the owner who set it (an epoch on the owner alone, as AutoRepayV2's).
///    Set-asides belong to the owner they were set aside for: after a change of hands they still repay that owner's
///    loans only, then go to that owner's payout (`release`). New income waits in the box for the new owner's plan.
///
///  What is set aside in a box is one pot, held by its owners in shares (`potOf`, `stakeOf`; `setAsideOf` is an
///  owner's value). Before any loss every share is worth exactly 1e-18 of a USDG unit and every amount is exact. When
///  the box holds less than its pot (only an issuer can take USDG from a box), the next sweep, repay, release or sync
///  writes the pot down to the balance (`WrittenDown`): every owner's set-aside falls pro rata, and money that arrives
///  later is new money for the owner holding the agent, never a refill of the loss. If the pot falls to nothing, its
///  shares are void.
///
///  The router holds no USDG between calls and nobody approves it to spend anything: it can only move money already in
///  a box, and only to the pool, for a loan of the box's own agent taken under the owner the money was set aside for,
///  or to that owner's payout. Any other token sent to a box goes to the agent's registry owner (`rescue`). No owner, no
///  setter, no upgrade. The Safe's only power is to pause `sweep` and `repay`, at most 14 days a call, renewable and
///  liftable; leaving, moving a payout, releasing and syncing never pause.
///
///  Known limits:
///  - A sale and buy-back (A to B to A) the router never saw: it reads the owner only when a call does (enroll, sweep,
///    rescue, sync), so it cannot tell. Income not yet swept follows the agent: it is split under the plan of the owner
///    holding the agent when it is swept, so A's earlier plan resumes. B had nothing at the router, or a call would
///    have seen the sale. The keeper syncs on every registry Transfer to keep this window short.
///  - The Safe's pause stops `sweep` and `repay` (the owner's choice, as AutoRepayV2's): a pause longer than a loan's
///    grace can let it default. During a pause owners repay by hand on the pool; `release` then returns the set-aside
///    to their payout, never elsewhere.
///  - With more open loans than MAX_LOANS (32), `sweep`, `release` and `repay` (each checks the whole list) stop until
///    some loans close (proposal 2.3); the money waits in the box.
///  - A seizure and a deposit between the same two calls cannot be told apart from the balance alone: the deposit then
///    covers part of the loss. The keeper's frequent sweeps and syncs bound that window.
///  - Earliest due first is strict: a later loan of the same owner waits while an earlier one is open, even when the
///    set-aside covers only the later one.
///  - After a write-down, the shares a set-aside mints and a payment burns are rounded up (an owner's set-aside grows
///    by at least what it sets aside, and an owner pays its own rounding when money leaves): at most one share's
///    worth, far under a USDG unit, can move between owners. Before any write-down there is no rounding.
///  - A payout is refused when it is a deployed box or the agent's own box; a box of another agent deployed after the
///    payout was set receives what is forwarded to it.
contract IncomeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants and immutables
    // ------------------------------------------------------------------

    uint256 public constant VERSION = 1;
    uint64 public constant MIN_WINDOW = 2 hours; // AutoRepayV2's: the on-time attempts a loan of just over a week keeps
    uint64 public constant MAX_WINDOW = 24 hours;
    uint64 public constant MIN_AGE = 1 hours; // never in a loan's first hour, unless the plan says early
    uint64 public constant SEASON = 7 days; // score v2's week-long hold
    uint64 public constant MAX_PAUSE = 14 days;
    uint256 public constant MAX_CAP = 2_000e6; // 2,000 USDG per loan, as AutoRepayV2's; fits the plan's uint32
    uint256 public constant MAX_SHARE = 10_000; // 100%, in basis points: everything until the loans are covered
    uint256 public constant MAX_LOANS = 32; // open loans one call checks; with more, the money waits in the box
    uint256 public constant SCALE = 1e18; // shares per USDG unit in a pot that never lost anything
    uint256 public constant MAX_SHARES_PER_UNIT = 1e42; // a pot diluted past this by losses is void (bounds shares)
    uint8 private constant ACTIVE = 1; // CreditPoolV2.LoanStatus.Active

    IIncomeRouterPool public immutable pool;
    IERC20 public immutable usdg;
    IIncomeRouterRegistry public immutable registry;
    address public immutable PAUSER;
    uint64 public immutable WINDOW;
    /// @notice keccak256 of IncomeBox's creation code: the same for every agent and every router.
    bytes32 public immutable BOX_CODE_HASH;

    // ------------------------------------------------------------------
    // Plans, the pot, set-asides
    // ------------------------------------------------------------------

    /// @notice An owner's plan for one agent, set in the agent's epoch `epoch`. One storage slot. `leave` turns it off
    ///         and keeps the rest, so what was set aside under it still repays its loans within `cap`, and `early`.
    struct Plan {
        address payout;
        uint16 shareBps;
        uint32 cap;
        uint32 epoch;
        bool on;
        bool early;
    }

    /// @notice The agent's registry owner as the router last saw it, and the epoch: how many changes of it the router
    ///         has seen. It moves when a write here (enroll, sweep, rescue, sync) finds the owner changed.
    struct Seen {
        address owner;
        uint32 epoch;
    }

    /// @notice What is set aside in an agent's box, every owner together, as recorded at the last write (`value`), and
    ///         the shares its owners hold. `gen` moves when the pot is void; shares of an earlier `gen` are worth
    ///         nothing.
    struct Pot {
        uint256 value;
        uint192 shares;
        uint32 gen;
    }

    /// @notice One owner's shares of an agent's pot, of the pot's generation `gen`.
    struct Stake {
        uint192 shares;
        uint32 gen;
    }

    enum Status {
        Ready,
        NotActive,
        Paused,
        NoPlan,
        OverCap,
        TooEarly,
        Short,
        NotEarliest
    }

    /// @notice What `repay(loanId, openLoans)` would do now, and why not when it would not. `checkLoan` leaves the
    ///         order out (`earlier` zero): only `checkRepay`, given the open-loan list, can tell `NotEarliest`.
    struct Quote {
        Status status;
        uint256 agentId;
        address owner; // the loan's owner (`Loan.owner`): whose set-aside pays it
        uint256 due;
        uint256 cap;
        uint256 setAside; // the loan's owner's set-aside, written down if the box holds less than its pot
        uint64 opens; // when its window opens (its issue time when the plan says early)
        uint256 earlier; // an open loan of the same owner, within the cap, due before it (checkRepay only)
    }

    /// @notice An agent's box and its owner's plan, now.
    struct Summary {
        address box;
        bool deployed;
        uint256 balance; // USDG in the box
        uint256 setAsideTotal; // set aside in it for every owner's loans, written down to the balance if need be
        uint256 writeDown; // what the next write will write the pot down by (the box holds less than the pot)
        uint256 unswept; // what a sweep would split now
        address owner; // the agent's registry owner (zero when the registry does not answer)
        uint32 epoch; // the agent's epoch now (the next one when the owner changed since the router last saw it)
        bool planOn; // the owner's plan counts now: on, and set in this epoch
        Plan plan; // the owner's plan as stored
        uint256 setAside; // the owner's set-aside
    }

    /// @notice agentId => owner => plan. An earlier owner's plan stays stored, off by its epoch.
    mapping(uint256 => mapping(address => Plan)) public planOf;
    /// @notice agentId => its pot, as recorded at the last write (`setAsideTotal` applies a pending write-down).
    mapping(uint256 => Pot) public potOf;
    /// @notice agentId => owner => its shares of the pot (`setAsideOf` is their value).
    mapping(uint256 => mapping(address => Stake)) public stakeOf;
    mapping(uint256 => Seen) public seen;
    mapping(address => bool) public isBox;
    uint64 public pausedUntil;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event Enrolled(
        uint256 indexed agentId,
        address indexed owner,
        uint256 shareBps,
        address payout,
        uint256 cap,
        bool early,
        uint256 epoch
    );
    event Left(uint256 indexed agentId, address indexed owner);
    event PayoutSet(uint256 indexed agentId, address indexed owner, address payout);
    event Swept(
        uint256 indexed agentId,
        address indexed owner,
        uint256 arrived,
        uint256 setAside,
        uint256 forwarded,
        uint256 released,
        address payout
    );
    event IncomeRepaid(uint256 indexed loanId, uint256 indexed agentId, address indexed owner, uint256 due);
    event Released(uint256 indexed agentId, address indexed owner, uint256 amount, address payout);
    event WrittenDown(uint256 indexed agentId, uint256 from, uint256 to);
    event Synced(uint256 indexed agentId, address owner, uint256 epoch);
    event BoxDeployed(uint256 indexed agentId, address box);
    event Rescued(uint256 indexed agentId, address indexed token, address to, uint256 amount);
    event PausedUntil(uint64 until);

    error ZeroAddress();
    error BadWindow(uint64 window);
    error BadShare(uint256 shareBps);
    error BadCap(uint256 cap);
    error BadPayout(address payout);
    error NotOwner(uint256 agentId, address caller);
    error NoPlan(uint256 agentId, address owner);
    error NotPauser();
    error PauseTooLong(uint64 until, uint256 max);
    error IsPaused(uint64 until);
    error TooManyLoans(uint256 agentId, uint256 activeLoans);
    error WrongLoanCount(uint256 agentId, uint256 listed, uint256 activeLoans);
    error BadLoanList(uint256 loanId);
    error LoanNotActive(uint256 loanId);
    error OverCap(uint256 loanId, uint256 due, uint256 cap);
    error TooEarly(uint256 loanId, uint64 opens);
    error Shortfall(uint256 loanId, uint256 due, uint256 setAside);
    error NotEarliest(uint256 loanId, uint256 earlierLoanId);
    error NotRescuable(address token);

    constructor(IIncomeRouterPool pool_, address pauser_, uint64 window_) {
        if (address(pool_) == address(0) || pauser_ == address(0)) revert ZeroAddress();
        if (window_ < MIN_WINDOW || window_ > MAX_WINDOW) revert BadWindow(window_);
        pool = pool_;
        usdg = pool_.usdg();
        registry = IIncomeRouterRegistry(pool_.registry());
        PAUSER = pauser_;
        WINDOW = window_;
        BOX_CODE_HASH = keccak256(type(IncomeBox).creationCode);
    }

    // ------------------------------------------------------------------
    // The box
    // ------------------------------------------------------------------

    /// @notice The agent's income address: its box, whether or not it is deployed yet. Payments may land there at
    ///         once; the first sweep deploys it.
    function incomeAddressOf(uint256 agentId) public view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(agentId), BOX_CODE_HASH))))
        );
    }

    /// @dev The agent's box, deployed when it is not there yet.
    function _box(uint256 agentId) internal returns (IncomeBox box) {
        box = IncomeBox(incomeAddressOf(agentId));
        if (address(box).code.length == 0) {
            box = new IncomeBox{salt: bytes32(agentId)}();
            isBox[address(box)] = true;
            emit BoxDeployed(agentId, address(box));
        }
    }

    // ------------------------------------------------------------------
    // Plans: set, leave, payout, sync, pause
    // ------------------------------------------------------------------

    /// @notice The agent's registry owner sets (or replaces) its plan: `shareBps` of each sweep (0 to 10,000; 10,000
    ///         is everything until the loans are covered, 0 makes the box a plain forwarder) is set aside for the
    ///         agent's open loans taken under this owner whose due is at most `cap`; the rest goes to `payout`. With
    ///         `early`, a loan is repaid as soon as its money is set aside; without, in its window. It applies from
    ///         the next sweep; what is already set aside stays. The plan lasts while the agent keeps this owner.
    function enroll(uint256 agentId, uint256 shareBps, address payout, uint256 cap, bool early) external nonReentrant {
        if (shareBps > MAX_SHARE) revert BadShare(shareBps);
        if (cap == 0 || cap > MAX_CAP) revert BadCap(cap);
        _checkPayout(agentId, payout);
        Seen memory s = _sync(agentId);
        if (s.owner != msg.sender) revert NotOwner(agentId, msg.sender);
        planOf[agentId][msg.sender] = Plan({
            payout: payout,
            // forge-lint: disable-next-line(unsafe-typecast)
            shareBps: uint16(shareBps),
            // forge-lint: disable-next-line(unsafe-typecast)
            cap: uint32(cap),
            epoch: s.epoch,
            on: true,
            early: early
        });
        emit Enrolled(agentId, msg.sender, shareBps, payout, cap, early, s.epoch);
    }

    /// @notice Turn the caller's plan for `agentId` off. What was set aside under it still repays its loans, then is
    ///         released; new income waits in the box. Reads nothing; works while paused.
    function leave(uint256 agentId) external nonReentrant {
        planOf[agentId][msg.sender].on = false;
        emit Left(agentId, msg.sender);
    }

    /// @notice A plan's owner moves its payout, at any time: after the agent changed hands, after `leave`, while
    ///         paused, so a sweep or a release never sticks on a payout that cannot receive.
    function setPayout(uint256 agentId, address payout) external nonReentrant {
        Plan storage p = planOf[agentId][msg.sender];
        if (p.payout == address(0)) revert NoPlan(agentId, msg.sender);
        _checkPayout(agentId, payout);
        p.payout = payout;
        emit PayoutSet(agentId, msg.sender, payout);
    }

    /// @notice Record the agent's registry owner now (when it changed since the router last saw it, a new epoch starts
    ///         and plans from earlier ones stop counting), and write the agent's pot down to its box's balance if the
    ///         box holds less. Anyone may call (the keeper does, on every registry Transfer and every write-down it
    ///         sees); works while paused. Returns the epoch.
    function sync(uint256 agentId) external nonReentrant returns (uint256) {
        _settle(agentId);
        return _sync(agentId).epoch;
    }

    /// @notice The Safe stops `sweep` and `repay` until `until`, at most 14 days ahead; renewable; `pause(0)` lifts it.
    function pause(uint64 until) external nonReentrant {
        if (msg.sender != PAUSER) revert NotPauser();
        if (until > block.timestamp + MAX_PAUSE) revert PauseTooLong(until, block.timestamp + MAX_PAUSE);
        pausedUntil = until;
        emit PausedUntil(until);
    }

    /// @dev Any payout but nothing, the router, the pool, USDG, a deployed box or the agent's own box.
    function _checkPayout(uint256 agentId, address payout) internal view {
        if (
            payout == address(0) || payout == address(this) || payout == address(pool) || payout == address(usdg)
                || isBox[payout] || payout == incomeAddressOf(agentId)
        ) revert BadPayout(payout);
    }

    /// @dev The agent's owner now, written with a new epoch when it changed. Reverts when the registry does not answer.
    function _sync(uint256 agentId) internal returns (Seen memory s) {
        address o = registry.ownerOf(agentId);
        s = seen[agentId];
        if (s.owner != o) {
            s.owner = o;
            ++s.epoch;
            seen[agentId] = s;
            emit Synced(agentId, o, s.epoch);
        }
    }

    // ------------------------------------------------------------------
    // Sweep, repay, release, rescue
    // ------------------------------------------------------------------

    /// @notice Split the money that arrived in the agent's box since the last call, under its owner's plan: the plan's
    ///         share, rounded up and at most what the owner's open loans still need, is set aside; the rest, with
    ///         whatever is set aside beyond that need, goes to the payout. A write-down comes first: new money is the
    ///         box's balance beyond the pot as written down. `openLoans` lists every open loan of the agent, ids
    ///         strictly rising (as many as the pool's `activeLoans`, at most 32). Anyone may call; deploys the box if
    ///         it is not there yet. Reverts with no plan, a plan of an earlier owner, more open loans than one call
    ///         checks, or a payout that cannot receive: the money waits in the box.
    function sweep(uint256 agentId, uint256[] calldata openLoans)
        external
        nonReentrant
        returns (uint256 arrived, uint256 put, uint256 forwarded, uint256 released)
    {
        _notPaused();
        Seen memory s = _sync(agentId);
        Plan memory p = planOf[agentId][s.owner];
        if (!p.on || p.epoch != s.epoch) revert NoPlan(agentId, s.owner);
        (uint256 dues,) = _scan(agentId, s.owner, p.cap, openLoans, 0);
        IncomeBox box = _box(agentId);
        (arrived, put, forwarded, released) = _split(agentId, s.owner, p.shareBps, dues);
        if (forwarded + released != 0) box.move(usdg, p.payout, forwarded + released);
        emit Swept(agentId, s.owner, arrived, put, forwarded, released, p.payout);
    }

    /// @dev The sweep's arithmetic, written to the pot: after a write-down, new money is the box's balance beyond the
    ///      pot; what the owner holds beyond its loans' need is released; the owner's share of the new money (rounded
    ///      up) is set aside, up to that need.
    function _split(uint256 agentId, address owner, uint256 shareBps, uint256 dues)
        internal
        returns (uint256 arrived, uint256 put, uint256 forwarded, uint256 released)
    {
        (uint256 bal, uint256 value) = _settle(agentId);
        arrived = bal - value;
        uint256 held = _valueOf(potOf[agentId], stakeOf[agentId][owner]);
        if (held > dues) {
            released = held - dues;
            _take(agentId, owner, released, held);
        } else {
            put = _min(dues - held, (arrived * shareBps + MAX_SHARE - 1) / MAX_SHARE);
            _put(agentId, owner, put);
        }
        forwarded = arrived - put;
    }

    /// @notice Repay loan `loanId` in full from what is set aside for its owner in its agent's box: within the
    ///         owner's plan's cap, in the loan's window unless the plan says early, with no closing time (the grace
    ///         period, and after it until a default is marked), and only when no other open loan of the same owner
    ///         within the cap is due before it (equal due times: the lower id first). `openLoans` lists every open loan
    ///         of the agent, as for `sweep`. A write-down comes first. Works after `leave` and after the agent changed
    ///         hands, for that owner's loans. Anyone may call; the caller pays nothing and gets nothing.
    function repay(uint256 loanId, uint256[] calldata openLoans) external nonReentrant returns (uint256 due) {
        (bool found, IIncomeRouterPool.Loan memory l) = _loan(loanId);
        if (!found || l.status != ACTIVE) revert LoanNotActive(loanId);
        _settle(l.agentId);
        Quote memory q = _quoteInOrder(loanId, l, openLoans);
        if (q.status == Status.Paused) revert IsPaused(pausedUntil);
        if (q.status == Status.NoPlan) revert NoPlan(q.agentId, q.owner);
        if (q.status == Status.OverCap) revert OverCap(loanId, q.due, q.cap);
        if (q.status == Status.TooEarly) revert TooEarly(loanId, q.opens);
        if (q.status == Status.Short) revert Shortfall(loanId, q.due, q.setAside);
        if (q.status == Status.NotEarliest) revert NotEarliest(loanId, q.earlier);
        due = q.due;
        _take(q.agentId, q.owner, due, q.setAside);
        IncomeBox(incomeAddressOf(q.agentId)).move(usdg, address(this), due);
        usdg.forceApprove(address(pool), due);
        pool.repay(loanId, q.agentId, due);
        emit IncomeRepaid(loanId, q.agentId, q.owner, due);
    }

    /// @notice Send what is set aside for `owner` in the agent's box beyond its open loans' need to that owner's
    ///         payout: after a change of hands, after `leave`, or when its loans closed without the router. The need
    ///         is the dues of `owner`'s open loans within its plan's cap; `openLoans` as for `sweep`. A write-down
    ///         comes first. Anyone may call; works while paused. Returns what was sent (0: nothing to release).
    function release(uint256 agentId, address owner, uint256[] calldata openLoans)
        external
        nonReentrant
        returns (uint256 released)
    {
        Plan memory p = planOf[agentId][owner];
        (uint256 dues,) = _scan(agentId, owner, p.cap, openLoans, 0);
        _settle(agentId);
        uint256 held = _valueOf(potOf[agentId], stakeOf[agentId][owner]);
        if (held <= dues) return 0;
        released = held - dues;
        _take(agentId, owner, released, held);
        IncomeBox(incomeAddressOf(agentId)).move(usdg, p.payout, released);
        emit Released(agentId, owner, released, p.payout);
    }

    /// @notice The agent's registry owner takes any token but USDG out of the box (sent there by mistake), all of it,
    ///         to itself. Deploys the box if it is not there yet.
    function rescue(uint256 agentId, IERC20 token) external nonReentrant returns (uint256 amount) {
        if (address(token) == address(usdg)) revert NotRescuable(address(token));
        if (_sync(agentId).owner != msg.sender) revert NotOwner(agentId, msg.sender);
        IncomeBox box = _box(agentId);
        amount = token.balanceOf(address(box));
        box.move(token, msg.sender, amount);
        emit Rescued(agentId, address(token), msg.sender, amount);
    }

    function _notPaused() internal view {
        if (block.timestamp < pausedUntil) revert IsPaused(pausedUntil);
    }

    /// @dev Checks `loans` is exactly the agent's open loans: as many as the pool's `activeLoans` (at most
    ///      MAX_LOANS), each open and of this agent, ids strictly rising, so a caller can hide no loan. Returns the
    ///      dues of `owner`'s open loans within `cap`, and the first of them whose (dueAt, id) comes before `before`
    ///      (zero: none; `before` zero asks nothing).
    function _scan(uint256 agentId, address owner, uint256 cap, uint256[] calldata loans, uint256 before)
        internal
        view
        returns (uint256 dues, uint256 earlier)
    {
        {
            uint256 active = pool.getAgent(agentId).activeLoans;
            if (active > MAX_LOANS) revert TooManyLoans(agentId, active);
            if (loans.length != active) revert WrongLoanCount(agentId, loans.length, active);
        }
        uint256 last;
        for (uint256 i = 0; i < loans.length; ++i) {
            uint256 loanId = loans[i];
            if (loanId <= last) revert BadLoanList(loanId);
            last = loanId;
            (bool found, IIncomeRouterPool.Loan memory l) = _loan(loanId);
            if (!found || l.agentId != agentId || l.status != ACTIVE) revert BadLoanList(loanId);
            if (l.owner != owner || l.principal + l.fee > cap) continue;
            dues += l.principal + l.fee;
            if (earlier == 0 && _order(l.dueAt, loanId) < before) earlier = loanId;
        }
    }

    /// @dev A loan's place in the repayment order: earliest due first, the lower id first on equal due times.
    function _order(uint64 dueAt, uint256 loanId) internal pure returns (uint256) {
        return (uint256(dueAt) << 192) | loanId;
    }

    // ------------------------------------------------------------------
    // The pot
    // ------------------------------------------------------------------

    /// @dev The agent's pot as the next write will leave it: written down to the box's balance when the box holds
    ///      less (only an issuer takes from a box), void when that leaves nothing or dilutes a share past
    ///      MAX_SHARES_PER_UNIT. Also returns the balance.
    function _potNow(uint256 agentId) internal view returns (Pot memory p, uint256 bal) {
        p = potOf[agentId];
        bal = usdg.balanceOf(incomeAddressOf(agentId));
        if (bal < p.value) {
            if (bal == 0 || p.shares / bal > MAX_SHARES_PER_UNIT) {
                p.value = 0;
                p.shares = 0;
                ++p.gen;
            } else {
                p.value = bal;
            }
        }
    }

    /// @dev Write the pot down to the box's balance when the box holds less. Returns the balance and the pot's value.
    function _settle(uint256 agentId) internal returns (uint256 bal, uint256 value) {
        uint256 recorded = potOf[agentId].value;
        Pot memory p;
        (p, bal) = _potNow(agentId);
        value = p.value;
        if (value != recorded) {
            potOf[agentId] = p;
            emit WrittenDown(agentId, recorded, value);
        }
    }

    /// @dev An owner's value in the pot: its shares' part of the pot, rounded down; nothing from a void pot.
    function _valueOf(Pot memory p, Stake memory s) internal pure returns (uint256) {
        if (s.gen != p.gen || p.shares == 0) return 0;
        return Math.mulDiv(s.shares, p.value, p.shares);
    }

    /// @dev Set `amount` aside for `owner`: shares at the pot's price, rounded up, so its value grows by at least
    ///      `amount` (exactly, in a pot that never lost anything).
    function _put(uint256 agentId, address owner, uint256 amount) internal {
        if (amount == 0) return;
        Pot storage p = potOf[agentId];
        Stake storage s = stakeOf[agentId][owner];
        if (s.gen != p.gen) (s.shares, s.gen) = (0, p.gen); // shares of a void pot
        uint256 m = p.shares == 0 ? amount * SCALE : Math.mulDiv(amount, p.shares, p.value, Math.Rounding.Ceil);
        uint192 m192 = SafeCast.toUint192(m);
        s.shares += m192;
        p.shares += m192;
        p.value += amount;
    }

    /// @dev Take `amount` of `owner`'s value `value` out of the pot: all its shares when it takes all of it, else the
    ///      shares rounded up (the owner pays its own rounding). The last shares out leave the pot empty: what dust
    ///      is left in the box is new money.
    function _take(uint256 agentId, address owner, uint256 amount, uint256 value) internal {
        Pot storage p = potOf[agentId];
        Stake storage s = stakeOf[agentId][owner];
        uint192 b =
            amount == value ? s.shares : SafeCast.toUint192(Math.mulDiv(amount, p.shares, p.value, Math.Rounding.Ceil));
        s.shares -= b;
        p.shares -= b;
        p.value = p.shares == 0 ? 0 : p.value - amount;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice What is set aside in the agent's box, every owner together, written down to the box's balance if it
    ///         holds less.
    function setAsideTotal(uint256 agentId) public view returns (uint256) {
        (Pot memory p,) = _potNow(agentId);
        return p.value;
    }

    /// @notice What is set aside in the agent's box for `owner`'s loans, written down if the box holds less than its
    ///         pot.
    function setAsideOf(uint256 agentId, address owner) public view returns (uint256) {
        (Pot memory p,) = _potNow(agentId);
        return _valueOf(p, stakeOf[agentId][owner]);
    }

    /// @notice What `repay` would do now, the order among the owner's loans left out (`checkRepay` tells it). The
    ///         keeper's and the pages' read; never reverts on a bad id.
    function checkLoan(uint256 loanId) external view returns (Quote memory q) {
        (bool found, IIncomeRouterPool.Loan memory l) = _loan(loanId);
        if (!found || l.status != ACTIVE) {
            q.status = Status.NotActive;
            return q;
        }
        return _quote(l);
    }

    /// @notice What `repay(loanId, openLoans)` would do now, the order included. Reverts on a list `repay` would
    ///         refuse.
    function checkRepay(uint256 loanId, uint256[] calldata openLoans) external view returns (Quote memory q) {
        (bool found, IIncomeRouterPool.Loan memory l) = _loan(loanId);
        if (!found || l.status != ACTIVE) {
            q.status = Status.NotActive;
            return q;
        }
        return _quoteInOrder(loanId, l, openLoans);
    }

    /// @notice The agent's box, its balance, what is set aside in it, a pending write-down, what a sweep would split,
    ///         the owner now and its plan. Never reverts: a registry that does not answer reads as owner zero. An
    ///         earlier owner's set-aside is `setAsideOf(agentId, owner)`; each loan's state is `checkLoan`.
    function check(uint256 agentId) external view returns (Summary memory v) {
        v.box = incomeAddressOf(agentId);
        v.deployed = v.box.code.length != 0;
        (Pot memory p, uint256 bal) = _potNow(agentId);
        v.balance = bal;
        v.setAsideTotal = p.value;
        v.writeDown = potOf[agentId].value - p.value;
        v.unswept = bal - p.value;
        Seen memory s = seen[agentId];
        (bool ok, bytes memory r) =
            address(registry).staticcall(abi.encodeCall(IIncomeRouterRegistry.ownerOf, (agentId)));
        if (!ok || r.length < 32) return v;
        v.owner = abi.decode(r, (address));
        v.epoch = v.owner == s.owner ? s.epoch : s.epoch + 1;
        v.plan = planOf[agentId][v.owner];
        v.planOn = v.plan.on && v.plan.epoch == v.epoch;
        v.setAside = _valueOf(p, stakeOf[agentId][v.owner]);
    }

    /// @notice When a loan's window opens, AutoRepayV2's rule: the last `WINDOW` before `dueAt`, but for a term over a
    ///         week never before day 7 unless that would leave under `MIN_WINDOW` of on-time attempts; and never in
    ///         the loan's first `MIN_AGE`.
    function opensAt(uint64 issuedAt, uint64 dueAt) public view returns (uint64 opens) {
        uint64 term = dueAt - issuedAt;
        opens = dueAt - (term < WINDOW ? term : WINDOW);
        if (term > SEASON) {
            uint64 seasoned = issuedAt + SEASON;
            uint64 floor = dueAt - MIN_WINDOW;
            uint64 bound = seasoned < floor ? seasoned : floor;
            if (bound > opens) opens = bound;
        }
        uint64 aged = issuedAt + MIN_AGE;
        if (aged > opens) opens = aged;
    }

    /// @dev The quote of an open loan `l`, the order left out.
    function _quote(IIncomeRouterPool.Loan memory l) internal view returns (Quote memory q) {
        Plan memory p = planOf[l.agentId][l.owner];
        q.agentId = l.agentId;
        q.owner = l.owner;
        q.due = l.principal + l.fee;
        q.cap = p.cap;
        q.setAside = setAsideOf(l.agentId, l.owner);
        q.opens = p.early ? l.issuedAt : opensAt(l.issuedAt, l.dueAt);
        if (block.timestamp < pausedUntil) q.status = Status.Paused;
        else if (p.payout == address(0)) q.status = Status.NoPlan;
        else if (q.due > q.cap) q.status = Status.OverCap;
        else if (block.timestamp < q.opens) q.status = Status.TooEarly;
        else if (q.setAside < q.due) q.status = Status.Short;
    }

    /// @dev The quote of an open loan `l` with the order: NotEarliest instead of Ready while an earlier loan of the
    ///      same owner within the cap is open. Checks the list as `_scan` does.
    function _quoteInOrder(uint256 loanId, IIncomeRouterPool.Loan memory l, uint256[] calldata openLoans)
        internal
        view
        returns (Quote memory q)
    {
        q = _quote(l);
        (, q.earlier) = _scan(l.agentId, l.owner, q.cap, openLoans, _order(l.dueAt, loanId));
        if (q.status == Status.Ready && q.earlier != 0) q.status = Status.NotEarliest;
    }

    function _loan(uint256 loanId) internal view returns (bool, IIncomeRouterPool.Loan memory) {
        try pool.getLoan(loanId) returns (IIncomeRouterPool.Loan memory l) {
            return (true, l);
        } catch {
            IIncomeRouterPool.Loan memory none;
            return (false, none);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
