// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev The parts of CreditPoolV2 AutoRepayV2 reads and calls. `Loan` has the pool's own layout.
interface IAutoRepayV2Pool {
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

    function usdg() external view returns (IERC20);
    function registry() external view returns (address);
    function getLoan(uint256 loanId) external view returns (Loan memory);
    function loanCount() external view returns (uint256);
    function repay(uint256 loanId, uint256 expectedAgentId, uint256 maxDue) external;
}

/// @dev The ERC-8004 identity registry: who owns an agent, and the wallet it declared.
interface IAutoRepayV2Registry {
    function ownerOf(uint256 agentId) external view returns (address);
    function getAgentWallet(uint256 agentId) external view returns (address);
}

/// @dev The savings vault (Steakhouse USDG, a Morpho Vault V2): its shares are an ERC-20, and a plain withdrawal.
interface IAutoRepayV2Savings {
    function asset() external view returns (address);
    function balanceOf(address who) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares);
}

/// @title AutoRepayV2
/// @notice Repays CreditPoolV2 loans on time, from money their payers set aside for it (docs/AUTOPAY-SPEC.md).
///         Version 2 of src/AutoRepay.sol, after the deep audit (docs/AUDIT-DEEP-ENGINES.md AR-M1 to AR-I3).
///
///  Two plans, each set once by the party that pays, and used by `run(loanId)`, which anyone may call in the hours
///  before a loan is due:
///  - the agent-wallet plan: the agent's declared ERC-8004 wallet repays its own agent's loans, from its USDG and then,
///    if it chose, its savings. It counts only while that wallet is still the declared one, for loans taken under the
///    owner it enrolled under, and only while the agent's (owner, wallet) is the one it enrolled with (its epoch);
///  - the owner plan: the agent's owner (the Go mode account) repays loans of its agents that the owner marked as its
///    own (`cover`, or `coverLast` in the same operation as its own borrow), from its USDG and then, if it chose, its
///    savings. A loan the agent's key took, which the owner never marked, is never paid from the owner's account: a
///    stolen key cannot borrow and let the owner repay (AR-M1). Beside an agent-wallet plan, it pays only what the
///    agent's wallet leaves missing.
///
///  Plans are bound to an epoch of the agent: AutoRepayV2 counts each change it sees of the agent's (owner, declared
///  wallet), and a plan or a mark from an earlier epoch never pays a later loan (AR-I2). Each plan has a limit per loan
///  and is bounded by the allowances its payer gave this contract. A run pulls exactly `due` and repays in the same
///  call, or reverts with nothing moved. No owner, no upgrade, no setter: the only power is the Safe's pause of `run`,
///  at most 14 days at a time.
contract AutoRepayV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants and immutables
    // ------------------------------------------------------------------

    uint256 public constant VERSION = 2;
    uint64 public constant MIN_WINDOW = 2 hours; // the on-time attempts a loan of just over a week keeps
    uint64 public constant MAX_WINDOW = 24 hours;
    uint64 public constant MIN_AGE = 1 hours; // no run in a loan's first hour, whatever the pool's minTerm (AR-I3)
    uint64 public constant SEASON = 7 days; // score v2's week-long hold
    uint64 public constant MAX_PAUSE = 14 days;
    uint256 public constant MAX_CAP = 2_000e6; // 2,000 USDG per loan: covers a 1,000 loan plus its fee if maxLoan rises; fits uint32
    uint8 private constant ACTIVE = 1; // CreditPoolV2.LoanStatus.Active

    IAutoRepayV2Pool public immutable pool;
    IERC20 public immutable usdg;
    IAutoRepayV2Registry public immutable registry;
    IAutoRepayV2Savings public immutable savings;
    address public immutable PAUSER;
    uint64 public immutable WINDOW;

    // ------------------------------------------------------------------
    // Plans
    // ------------------------------------------------------------------

    /// @notice The agent-wallet plan of `wallet` for one agent: `owner` is the agent's owner and `epoch` the agent's
    ///         epoch when it enrolled. One storage slot.
    struct Plan {
        uint32 cap;
        address owner;
        bool on;
        bool useSavings;
        bool late;
        uint32 epoch;
    }

    /// @notice The owner plan of an agent's owner for one of its agents, set in the agent's epoch `epoch`.
    struct OwnerPlan {
        uint32 cap;
        bool on;
        bool useSavings;
        bool late;
        uint32 epoch;
    }

    /// @notice The agent's (owner, declared wallet) as AutoRepayV2 last saw it, and the epoch: how many changes of it
    ///         it has seen. The registry keeps no such count, so this one moves when a write here (enroll,
    ///         enrollOwner, cover, coverLast, sync) finds the registry's pair changed; every read also treats a pair
    ///         that no longer matches as the next epoch.
    struct Seen {
        address owner;
        uint32 epoch;
        address wallet;
    }

    enum Status {
        Ready,
        NotActive,
        Paused,
        TooEarly,
        NoPlan,
        Short,
        RegistryDown
    }

    /// @notice What `run(loanId)` would do now: who pays how much from where (`wallet` and `owner` are zero when that
    ///         party pays nothing), and when the loan's window opens and closes for the parties that can pay. A
    ///         Savings figure is what the payer's shares are worth; a run takes what the vault can pay at that moment,
    ///         and the next source covers the rest.
    struct Quote {
        Status status;
        uint256 agentId;
        uint256 due;
        uint64 opens;
        uint64 closes;
        address wallet;
        uint256 fromWallet;
        uint256 fromWalletSavings;
        address owner;
        uint256 fromOwner;
        uint256 fromOwnerSavings;
    }

    /// @dev The parties a run may pull from (zero: that party does not pay), and whether each may use its savings.
    struct Payers {
        address wallet;
        bool walletSavings;
        address owner;
        bool ownerSavings;
    }

    mapping(address => mapping(uint256 => Plan)) public planOf; // wallet => agentId => plan
    mapping(address => mapping(uint256 => OwnerPlan)) public ownerPlanOf; // owner => agentId => plan
    mapping(address => bool) public held; // a payer that holds pays nothing, under any plan
    mapping(uint256 => Seen) public seen; // agentId => the pair last seen, and its epoch
    mapping(uint256 => uint32) public coveredIn; // loanId => the epoch the loan's owner marked it in (0: not marked)
    uint64 public pausedUntil;

    // ------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------

    event Enrolled(
        address indexed wallet,
        uint256 indexed agentId,
        address indexed owner,
        uint256 cap,
        bool useSavings,
        bool late,
        uint256 epoch
    );
    event OwnerEnrolled(
        address indexed owner, uint256 indexed agentId, uint256 cap, bool useSavings, bool late, uint256 epoch
    );
    event Revoked(address indexed wallet, uint256 indexed agentId);
    event OwnerRevoked(address indexed owner, uint256 indexed agentId);
    event Covered(uint256 indexed loanId, uint256 indexed agentId, address indexed owner, uint256 epoch);
    event Synced(uint256 indexed agentId, address owner, address wallet, uint256 epoch);
    event Held(address indexed who, bool held);
    event PausedUntil(uint64 until);
    event AutoRepaid(
        uint256 indexed loanId,
        uint256 indexed agentId,
        address wallet,
        uint256 fromWallet,
        uint256 fromWalletSavings,
        address owner,
        uint256 fromOwner,
        uint256 fromOwnerSavings
    );

    error ZeroAddress();
    error BadWindow(uint64 window);
    error WrongAsset(address asset);
    error BadCap(uint256 cap);
    error NotAgentWallet(uint256 agentId, address caller);
    error NotOwner(uint256 agentId, address caller);
    error NotLoanOwner(uint256 loanId, address caller);
    error NotNewLoan(uint256 agentId, uint256 loanId);
    error NotPauser();
    error PauseTooLong(uint64 until, uint256 max);
    error LoanNotActive(uint256 loanId);
    error IsPaused(uint64 until);
    error TooEarly(uint256 loanId, uint64 opens);
    error NoPlan(uint256 loanId);
    error RegistryDown(uint256 agentId);
    error Shortfall(uint256 due, uint256 available);
    error VaultOverpaid(uint256 asked, uint256 received);

    constructor(IAutoRepayV2Pool pool_, IAutoRepayV2Savings savings_, address pauser_, uint64 window_) {
        if (address(pool_) == address(0) || address(savings_) == address(0) || pauser_ == address(0)) {
            revert ZeroAddress();
        }
        if (window_ < MIN_WINDOW || window_ > MAX_WINDOW) revert BadWindow(window_);
        IERC20 u = pool_.usdg();
        if (savings_.asset() != address(u)) revert WrongAsset(savings_.asset());
        pool = pool_;
        usdg = u;
        registry = IAutoRepayV2Registry(pool_.registry());
        savings = savings_;
        PAUSER = pauser_;
        WINDOW = window_;
    }

    // ------------------------------------------------------------------
    // Plans: set, revoke, hold
    // ------------------------------------------------------------------

    /// @notice The agent's declared wallet repays the agent's loans, up to `cap` each, from its USDG and then (with
    ///         `useSavings`) its savings; with `late`, also in the grace period. Budget: the allowances it gives. The
    ///         plan lasts while the agent keeps this owner and this wallet.
    function enroll(uint256 agentId, uint256 cap, bool useSavings, bool late) external nonReentrant {
        _checkCap(cap);
        Seen memory s = _sync(agentId);
        if (s.wallet != msg.sender) revert NotAgentWallet(agentId, msg.sender);
        planOf[msg.sender][agentId] = Plan({
            // forge-lint: disable-next-line(unsafe-typecast)
            cap: uint32(cap),
            owner: s.owner,
            on: true,
            useSavings: useSavings,
            late: late,
            epoch: s.epoch
        });
        emit Enrolled(msg.sender, agentId, s.owner, cap, useSavings, late, s.epoch);
    }

    /// @notice The agent's owner repays the loans of the agent it marks as its own (`cover`, `coverLast`), up to `cap`
    ///         each, from its USDG and then (with `useSavings`) its savings; with `late`, also in the grace period. On
    ///         its own it pays the whole loan; beside an agent-wallet plan, only what the agent's wallet leaves
    ///         missing. The plan pays loans marked in its epoch or before, never one marked after the agent's owner or
    ///         wallet changed.
    function enrollOwner(uint256 agentId, uint256 cap, bool useSavings, bool late) external nonReentrant {
        _checkCap(cap);
        Seen memory s = _sync(agentId);
        if (s.owner != msg.sender) revert NotOwner(agentId, msg.sender);
        ownerPlanOf[msg.sender][agentId] = OwnerPlan({
            // forge-lint: disable-next-line(unsafe-typecast)
            cap: uint32(cap),
            on: true,
            useSavings: useSavings,
            late: late,
            epoch: s.epoch
        });
        emit OwnerEnrolled(msg.sender, agentId, cap, useSavings, late, s.epoch);
    }

    /// @notice The loan's owner marks loan `loanId` as its own: its owner plan may pay it. Only the loan's owner, while
    ///         it still owns the agent, and only an open loan.
    function cover(uint256 loanId) external nonReentrant {
        (bool found, IAutoRepayV2Pool.Loan memory l) = _loan(loanId);
        if (!found || l.status != ACTIVE) revert LoanNotActive(loanId);
        _cover(loanId, l);
    }

    /// @notice The owner marks the loan it just took for agent `agentId`: the pool's newest loan, of this agent,
    ///         issued in this block. Meant for the same operation as the owner's own `borrow`, right after it (the
    ///         Go mode pages send both together), so the loan it marks is the one the owner's account borrowed.
    function coverLast(uint256 agentId) external nonReentrant {
        uint256 loanId = pool.loanCount();
        IAutoRepayV2Pool.Loan memory l = pool.getLoan(loanId);
        if (l.agentId != agentId || l.issuedAt != block.timestamp || l.status != ACTIVE) {
            revert NotNewLoan(agentId, loanId);
        }
        _cover(loanId, l);
    }

    function _cover(uint256 loanId, IAutoRepayV2Pool.Loan memory l) internal {
        if (l.owner != msg.sender) revert NotLoanOwner(loanId, msg.sender);
        Seen memory s = _sync(l.agentId);
        if (s.owner != msg.sender) revert NotOwner(l.agentId, msg.sender);
        coveredIn[loanId] = s.epoch;
        emit Covered(loanId, l.agentId, msg.sender, s.epoch);
    }

    /// @notice Record the agent's (owner, wallet) now: when it changed since AutoRepayV2 last saw it, a new epoch
    ///         starts and the plans and marks of the earlier ones stop paying new loans. Anyone may call (the keeper
    ///         does, for agents with a plan). Returns the agent's epoch.
    function sync(uint256 agentId) external nonReentrant returns (uint256) {
        return _sync(agentId).epoch;
    }

    /// @notice End the caller's agent-wallet plan for `agentId`. Reads nothing; works while paused.
    function revoke(uint256 agentId) external nonReentrant {
        delete planOf[msg.sender][agentId];
        emit Revoked(msg.sender, agentId);
    }

    /// @notice End the caller's owner plan for `agentId`. Reads nothing; works while paused.
    function revokeOwner(uint256 agentId) external nonReentrant {
        delete ownerPlanOf[msg.sender][agentId];
        emit OwnerRevoked(msg.sender, agentId);
    }

    /// @notice Stop (or resume) every plan the caller pays under, at once.
    function hold(bool on) external nonReentrant {
        held[msg.sender] = on;
        emit Held(msg.sender, on);
    }

    /// @notice The Safe stops `run` until `until`, at most 14 days ahead; renewable; `pause(0)` lifts it.
    function pause(uint64 until) external nonReentrant {
        if (msg.sender != PAUSER) revert NotPauser();
        if (until > block.timestamp + MAX_PAUSE) revert PauseTooLong(until, block.timestamp + MAX_PAUSE);
        pausedUntil = until;
        emit PausedUntil(until);
    }

    /// @dev A cap is at most MAX_CAP, so it fits the plans' uint32.
    function _checkCap(uint256 cap) internal pure {
        if (cap == 0 || cap > MAX_CAP) revert BadCap(cap);
    }

    /// @dev The agent's pair now, written with a new epoch when it changed. Reverts when the registry does not answer.
    function _sync(uint256 agentId) internal returns (Seen memory s) {
        address o = registry.ownerOf(agentId);
        address w = registry.getAgentWallet(agentId);
        s = seen[agentId];
        if (s.owner != o || s.wallet != w) {
            s.owner = o;
            s.wallet = w;
            ++s.epoch;
            seen[agentId] = s;
            emit Synced(agentId, o, w, s.epoch);
        }
    }

    // ------------------------------------------------------------------
    // Run
    // ------------------------------------------------------------------

    /// @notice Repay loan `loanId` in full from its payers' plans, in its window. Anyone may call; the caller pays
    ///         nothing and gets nothing. Sources in order: the agent wallet's USDG, its savings, the owner's USDG, its
    ///         savings; a savings step takes what the vault can pay now, and the next source covers the rest.
    function run(uint256 loanId) external nonReentrant returns (uint256 due) {
        (Quote memory q, Payers memory p) = _quote(loanId);
        if (q.status == Status.NotActive) revert LoanNotActive(loanId);
        if (q.status == Status.Paused) revert IsPaused(pausedUntil);
        if (q.status == Status.TooEarly) revert TooEarly(loanId, q.opens);
        if (q.status == Status.RegistryDown) revert RegistryDown(q.agentId);
        if (q.status == Status.NoPlan) revert NoPlan(loanId);
        due = q.due;
        // the quote's Savings figures are what the shares are worth, at least what a run can take: short there, short
        if (q.status == Status.Short) {
            revert Shortfall(due, q.fromWallet + q.fromWalletSavings + q.fromOwner + q.fromOwnerSavings);
        }
        // each step pulls an exact amount, or (a savings step) counts exactly what arrived, never more than it asked
        uint256 missing = due;
        (q.fromWallet, q.fromWalletSavings, missing) = _pull(p.wallet, p.walletSavings, missing);
        (q.fromOwner, q.fromOwnerSavings, missing) = _pull(p.owner, p.ownerSavings, missing);
        if (missing != 0) revert Shortfall(due, due - missing);
        usdg.forceApprove(address(pool), due);
        pool.repay(loanId, q.agentId, due);
        emit AutoRepaid(
            loanId,
            q.agentId,
            q.fromWallet + q.fromWalletSavings == 0 ? address(0) : p.wallet,
            q.fromWallet,
            q.fromWalletSavings,
            q.fromOwner + q.fromOwnerSavings == 0 ? address(0) : p.owner,
            q.fromOwner,
            q.fromOwnerSavings
        );
    }

    /// @dev Pull up to `missing` from `from` (none when zero): its USDG, then with `useSavings` its savings.
    function _pull(address from, bool useSavings, uint256 missing)
        internal
        returns (uint256 cash, uint256 saved, uint256 left)
    {
        left = missing;
        if (from == address(0) || left == 0) return (0, 0, left);
        cash = _min(_cash(from), left);
        if (cash != 0) {
            usdg.safeTransferFrom(from, address(this), cash);
            left -= cash;
        }
        if (useSavings && left != 0) {
            saved = _withdraw(from, _min(_saved(from), left));
            left -= saved;
        }
    }

    /// @dev Take `amount` from `from`'s savings, or what the vault can pay now: the whole amount if the vault pays it,
    ///      else what it holds idle, else nothing. Returns the USDG that arrived (never more than `amount`).
    function _withdraw(address from, uint256 amount) internal returns (uint256 got) {
        if (amount == 0) return 0;
        uint256 b = usdg.balanceOf(address(this));
        if (!_tryWithdraw(amount, from)) {
            uint256 idle = _idle();
            if (idle == 0 || idle >= amount || !_tryWithdraw(idle, from)) return 0;
        }
        got = usdg.balanceOf(address(this)) - b;
        if (got > amount) revert VaultOverpaid(amount, got);
    }

    function _tryWithdraw(uint256 amount, address from) internal returns (bool) {
        try savings.withdraw(amount, address(this), from) {
            return true;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice What `run(loanId)` would do now (the keeper's and the pages' read; never reverts on a bad id, a failing
    ///         registry or a failing vault).
    function check(uint256 loanId) external view returns (Quote memory q) {
        (q,) = _quote(loanId);
    }

    /// @notice The agent's epoch now, and whether its (owner, wallet) changed since AutoRepayV2 last saw it (then the
    ///         epoch is already the next one, and a write or `sync` records it). Reverts when the registry does not
    ///         answer.
    function epochOf(uint256 agentId) external view returns (uint32 epoch, bool stale) {
        (bool ok, address o, address w) = _live(agentId);
        if (!ok) revert RegistryDown(agentId);
        return _epoch(agentId, o, w);
    }

    /// @notice When a loan's window opens: the last `WINDOW` before `dueAt`, but for a term over a week never before
    ///         day 7 unless that would leave under `MIN_WINDOW` of on-time attempts; and never in the loan's first
    ///         `MIN_AGE`.
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

    function _quote(uint256 loanId) internal view returns (Quote memory q, Payers memory p) {
        (bool found, IAutoRepayV2Pool.Loan memory l) = _loan(loanId);
        if (!found || l.status != ACTIVE) {
            q.status = Status.NotActive;
            return (q, p);
        }
        q.agentId = l.agentId;
        q.due = l.principal + l.fee;
        q.opens = opensAt(l.issuedAt, l.dueAt);
        if (block.timestamp < pausedUntil) {
            q.status = Status.Paused;
            return (q, p);
        }
        if (block.timestamp < q.opens) {
            q.status = Status.TooEarly;
            return (q, p);
        }
        // the registry must answer: without it, who the agent's wallet is cannot be told, and the owner never pays a
        // share the wallet would have paid (AR-L1)
        {
            (bool ok, address o, address wallet) = _live(l.agentId);
            if (!ok) {
                q.status = Status.RegistryDown;
                return (q, p);
            }
            (uint32 epoch,) = _epoch(l.agentId, o, wallet);
            _walletPart(q, p, l, wallet, epoch);
        }
        _ownerPart(q, p, loanId, l);
        if (p.wallet == address(0) && p.owner == address(0)) {
            q.status = Status.NoPlan;
            return (q, p);
        }

        uint256 missing = q.due;
        if (p.wallet != address(0)) {
            (q.fromWallet, q.fromWalletSavings, missing) = _estimate(p.wallet, p.walletSavings, missing);
            if (q.fromWallet + q.fromWalletSavings != 0) q.wallet = p.wallet;
        }
        if (p.owner != address(0)) {
            (q.fromOwner, q.fromOwnerSavings, missing) = _estimate(p.owner, p.ownerSavings, missing);
            if (q.fromOwner + q.fromOwnerSavings != 0) q.owner = p.owner;
        }
        q.status = missing == 0 ? Status.Ready : Status.Short;
    }

    /// @dev The agent's wallet: declared now, its own plan from this epoch, enrolled under the loan's owner, not held,
    ///      `due` within its cap, before its close. A wallet that is the owner itself (an agent that declared no key of
    ///      its own) pays under the owner plan only. (The zero address never has a plan: `enroll` is its caller's.)
    function _walletPart(
        Quote memory q,
        Payers memory p,
        IAutoRepayV2Pool.Loan memory l,
        address wallet,
        uint32 epoch
    ) internal view {
        Plan memory a = planOf[wallet][l.agentId];
        uint64 closes = a.late ? l.defaultableAt : l.dueAt;
        if (
            a.on && a.epoch == epoch && wallet != l.owner && !held[wallet] && a.owner == l.owner && q.due <= a.cap
                && block.timestamp <= closes
        ) {
            (p.wallet, p.walletSavings) = (wallet, a.useSavings);
            q.closes = closes;
        }
    }

    /// @dev The owner: the address the loan names, its own plan for this agent, on a loan it marked as its own in the
    ///      plan's epoch or before (AR-M1, AR-I2), not held, `due` within its cap, before its close.
    function _ownerPart(Quote memory q, Payers memory p, uint256 loanId, IAutoRepayV2Pool.Loan memory l)
        internal
        view
    {
        OwnerPlan memory f = ownerPlanOf[l.owner][l.agentId];
        uint32 marked = coveredIn[loanId];
        uint64 closes = f.late ? l.defaultableAt : l.dueAt;
        if (
            f.on && marked != 0 && f.epoch >= marked && !held[l.owner] && q.due <= f.cap
                && block.timestamp <= closes
        ) {
            (p.owner, p.ownerSavings) = (l.owner, f.useSavings);
            if (closes > q.closes) q.closes = closes;
        }
    }

    function _estimate(address who, bool useSavings, uint256 missing)
        internal
        view
        returns (uint256 cash, uint256 saved, uint256 left)
    {
        cash = _min(_cash(who), missing);
        left = missing - cash;
        if (useSavings && left != 0) {
            saved = _min(_saved(who), left);
            left -= saved;
        }
    }

    function _loan(uint256 loanId) internal view returns (bool, IAutoRepayV2Pool.Loan memory) {
        try pool.getLoan(loanId) returns (IAutoRepayV2Pool.Loan memory l) {
            return (true, l);
        } catch {
            IAutoRepayV2Pool.Loan memory none;
            return (false, none);
        }
    }

    /// @dev The agent's owner and declared wallet now; `ok` false when the registry does not answer either.
    function _live(uint256 agentId) internal view returns (bool ok, address o, address w) {
        (bool a, uint256 o_) = _read(address(registry), abi.encodeCall(IAutoRepayV2Registry.ownerOf, (agentId)));
        (bool b, uint256 w_) = _read(address(registry), abi.encodeCall(IAutoRepayV2Registry.getAgentWallet, (agentId)));
        if (!a || !b) return (false, address(0), address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(o_)), address(uint160(w_)));
    }

    /// @dev The epoch of the pair (o, w): the one recorded, or the next one when the pair changed since.
    function _epoch(uint256 agentId, address o, address w) internal view returns (uint32 epoch, bool stale) {
        Seen memory s = seen[agentId];
        stale = s.owner != o || s.wallet != w;
        epoch = stale ? s.epoch + 1 : s.epoch;
    }

    /// @dev USDG this contract may pull from `who` now.
    function _cash(address who) internal view returns (uint256) {
        return _min(usdg.balanceOf(who), usdg.allowance(who, address(this)));
    }

    /// @dev What `who`'s savings are worth to this contract, within its share allowance: 0 when a vault read fails.
    function _saved(address who) internal view returns (uint256) {
        address v = address(savings);
        (bool a, uint256 shares) = _read(v, abi.encodeCall(IAutoRepayV2Savings.balanceOf, (who)));
        (bool b, uint256 allowed) = _read(v, abi.encodeCall(IAutoRepayV2Savings.allowance, (who, address(this))));
        shares = _min(shares, allowed);
        if (!a || !b || shares == 0) return 0;
        (bool c, uint256 assets) = _read(v, abi.encodeCall(IAutoRepayV2Savings.previewRedeem, (shares)));
        return c ? assets : 0;
    }

    /// @dev The USDG the vault holds itself, which a withdrawal pays first (0 when the read fails).
    function _idle() internal view returns (uint256 idle) {
        (, idle) = _read(address(usdg), abi.encodeCall(IERC20.balanceOf, (address(savings))));
    }

    /// @dev A view that may fail: `ok` false, and 0, when it reverts or answers less than a word.
    function _read(address target, bytes memory data) internal view returns (bool ok, uint256 value) {
        (bool success, bytes memory r) = target.staticcall(data);
        if (success && r.length >= 32) return (true, abi.decode(r, (uint256)));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
