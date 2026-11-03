// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev The two calls of an ERC-8460 credit line the key makes. CreditPoolV2 has both, with these exact signatures.
interface ILineKeyLine {
    function borrow(uint256 agentId, uint256 amount, uint64 term, address to, uint256 maxFee)
        external
        returns (uint256 loanId);
    function isController(uint256 agentId, address account) external view returns (bool);
}

interface ILineKeyRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
}

/// @dev Where a line names its identity registry and its asset: ERC-8460's names, then CreditPoolV2's.
interface ILineKeyLineMeta {
    function identityRegistry() external view returns (address);
    function asset() external view returns (address);
    function registry() external view returns (address);
    function usdg() external view returns (address);
}

/// @title LineKey
/// @notice A spending key for an agent's credit line (docs/LINE-KEY.md; the "agent card" of
///         docs/research/2026-11-03-credit-notes/README.md 3.3, named as that section asks: never a card in public).
///         The agent's owner names this contract as the line's delegate (`setDelegate(agentId, lineKey)` on
///         CreditPoolV2, or on any ERC-8460 line) and sets the terms here: an operator (the agent's hot key), a cap per
///         payment, a cap per trailing period, the payees and, for each, an optional cap of its own, the loan term and
///         the most fee per draw, and an expiry. The operator's `spend` then draws a loan on the agent's line paid
///         straight to the payee (`borrow(agentId, amount, term, to = payee, maxFee)`): the dollars go from the line to
///         the payee in one call and never pass through this contract or the agent's wallet.
///
///         The key holds nothing: no token, no approval, no ETH. It can only ask the line for a loan to a listed payee,
///         within the caps, while the owner who set it still holds the agent. Everything else the line decides as for
///         any delegate (pause, line size, the backer's rules, the fee, the term's range): its refusal comes back as
///         `LineRefused(the line's own revert data)`, and a refused payment uses no room.
///
///         The period is a trailing window, as ERC-8427's (a payment at time s counts while block.timestamp <
///         s + period), not a calendar reset: in any span of `period` seconds the payments sum to at most `perPeriod`,
///         so a stolen operator key takes at most one period's cap per period, never two across a boundary. Each
///         payment is stored once in the key's window and once in its payee's; a window holds at most MAX_PAYMENTS.
///
///         A key is bound to the owner that set it. A transfer of the agent stops it at once (every spend reads the
///         registry's owner), and the line's own delegate lapses at the same moment. The new holder's first `configure`
///         starts a new generation: none of the old payees, usage or operator. If the agent comes back to the owner
///         that set the key, the key works again, as the pool's delegate does; anyone may `revoke` a key while the
///         registry names another owner, which ends it for good. The owner may revoke at any time.
///
///         Repayment is not the key's: each payment is an ordinary loan of the agent on its line, recorded with the
///         owner at the draw, repaid by anyone (the agent, AutoRepayV2, IncomeRouter), defaulted as any other. Not
///         upgradeable, no admin, no pause of its own.
contract LineKey is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Payees a key can list.
    uint256 public constant MAX_PAYEES = 32;
    /// @notice Payments one window (the key's, or one payee's) can hold at once: bounds the gas of a spend.
    uint256 public constant MAX_PAYMENTS = 64;
    uint64 public constant MAX_PERIOD = 365 days;
    uint256 public constant BPS = 10_000;

    /// @notice Why the key refuses a payment (`check`, and `Refused` from `spend`). `NotDelegate` only from `check`:
    ///         `spend` leaves that to the line, which refuses with its own error.
    enum Reason {
        Ok,
        NoKey,
        OwnerChanged,
        Expired,
        NotOperator,
        ZeroAmount,
        PayeeNotAllowed,
        OverPerPayment,
        RefUsed,
        TooManyPayments,
        OverPeriod,
        OverPayeePeriod,
        NotDelegate
    }

    /// @notice The owner's terms. Amounts are in the line's asset's base units (USDG: 6 decimals).
    struct Terms {
        address operator; // the hot key that may spend
        uint64 expiresAt; // spends need block.timestamp < expiresAt
        uint64 period; // the trailing window, in seconds; fixed for the life of a key
        uint64 term; // the loan term of every draw, in seconds
        uint16 maxFeeBps; // the most fee a draw may cost, in basis points of its amount
        uint128 perPayment; // the most one payment may be
        uint128 perPeriod; // the most the payments of any trailing period may sum to
    }

    /// @notice A listed payee and its own cap per trailing period (0: only the key's caps apply).
    struct Payee {
        address payee;
        uint128 perPeriod;
    }

    struct Key {
        address owner; // the registry owner that set the key; 0 for none
        uint64 generation; // 1 for an agent's first key, +1 for each new one; payees and windows are per generation
        Terms terms;
    }

    /// @dev Live payments of one window are debits[head..tail); `sum` is theirs.
    struct Window {
        uint64 head;
        uint64 tail;
        uint128 sum;
    }

    ILineKeyLine public immutable line;
    ILineKeyRegistry public immutable registry;
    address public immutable asset;

    mapping(uint256 => Key) internal _keys;
    mapping(uint256 => mapping(uint64 => EnumerableSet.AddressSet)) internal _payees;
    mapping(uint256 => mapping(uint64 => mapping(address => uint128))) internal _payeeCap;
    /// @dev keccak256(agentId, generation, scope), scope address(0) for the key's own window, else the payee's
    mapping(bytes32 => Window) internal _windows;
    /// @dev the same id => index => (timestamp << 128 | amount)
    mapping(bytes32 => mapping(uint256 => uint256)) internal _debits;
    /// @notice A nonzero reference is paid once per agent and payee, whatever the key's generation.
    mapping(uint256 => mapping(address => mapping(bytes32 => bool))) public refUsed;

    event KeySet(uint256 indexed agentId, address indexed owner, uint64 indexed generation, Terms terms);
    event PayeeSet(
        uint256 indexed agentId, uint64 indexed generation, address indexed payee, bool allowed, uint128 perPeriod
    );
    /// @notice `ownerChanged`: the key ended because its owner no longer holds the agent (anyone's revoke, or the new
    ///         holder's first configure).
    event KeyRevoked(uint256 indexed agentId, uint64 indexed generation, address indexed by, bool ownerChanged);
    /// @notice One payment: `amount` of the line's asset from the line to `payee`, as loan `loanId` of the agent.
    event Paid(
        uint256 indexed agentId,
        address indexed payee,
        bytes32 indexed ref,
        uint256 amount,
        uint256 loanId,
        address operator,
        uint64 generation
    );

    error BadLine(address line);
    error NotOwner(uint256 agentId, address caller);
    error NoKey(uint256 agentId);
    error ZeroOperator();
    error BadCaps();
    error BadPeriod();
    error BadExpiry();
    error BadTerm();
    error BadFee();
    error PeriodFixed();
    error BadPayee(address payee);
    error TooManyPayees();
    error NotRevoker(uint256 agentId, address caller);
    error Refused(Reason reason);
    error LineRefused(bytes reason);

    /// @param line_ An ERC-8460 line (`identityRegistry()`, `asset()`) or CreditPoolV2 (`registry()`, `usdg()`).
    constructor(address line_) {
        if (line_.code.length == 0) revert BadLine(line_);
        address reg =
            _readAddress(line_, ILineKeyLineMeta.identityRegistry.selector, ILineKeyLineMeta.registry.selector);
        address a = _readAddress(line_, ILineKeyLineMeta.asset.selector, ILineKeyLineMeta.usdg.selector);
        if (reg == address(0) || a == address(0) || reg.code.length == 0 || a.code.length == 0) revert BadLine(line_);
        line = ILineKeyLine(line_);
        registry = ILineKeyRegistry(reg);
        asset = a;
    }

    // ------------------------------------------------------------------
    // The owner's side
    // ------------------------------------------------------------------

    /// @notice Set the key's terms and add (or update) payees. The agent's registry owner only. A first key, a key
    ///         after a revoke, or the key of an earlier owner: a new generation, with no payee and no usage. The
    ///         owner's own live key: the terms change in place and every payment already made still counts (a new
    ///         operator, a later expiry, tighter caps); the period cannot change (revoke, then configure).
    function configure(uint256 agentId, Terms calldata t, Payee[] calldata add) external nonReentrant {
        address o = _registryOwner(agentId);
        if (o != msg.sender) revert NotOwner(agentId, msg.sender);
        _validate(t);
        Key storage k = _keys[agentId];
        if (k.owner != o) {
            if (k.owner != address(0)) emit KeyRevoked(agentId, k.generation, msg.sender, true);
            k.owner = o;
            k.generation += 1;
        } else if (k.terms.period != t.period) {
            revert PeriodFixed();
        }
        k.terms = t;
        uint64 g = k.generation;
        emit KeySet(agentId, o, g, t);
        for (uint256 i = 0; i < add.length; i++) {
            _setPayee(agentId, g, add[i].payee, true, add[i].perPeriod);
        }
    }

    /// @notice List a payee (with its own cap per period, 0 for none), change its cap, or take it off the list.
    function setPayee(uint256 agentId, address payee, bool allowed, uint128 perPeriod) external nonReentrant {
        Key storage k = _keys[agentId];
        if (k.owner == address(0)) revert NoKey(agentId);
        if (_registryOwner(agentId) != msg.sender || k.owner != msg.sender) revert NotOwner(agentId, msg.sender);
        _setPayee(agentId, k.generation, payee, allowed, perPeriod);
    }

    /// @notice End the key: its owner, at any time; anyone, once the registry names another owner of the agent (a
    ///         registry that fails to answer is no ground: the key pays nothing meanwhile, and only its owner ends it).
    function revoke(uint256 agentId) external nonReentrant {
        Key storage k = _keys[agentId];
        address ko = k.owner;
        if (ko == address(0)) revert NoKey(agentId);
        (bool answered, address o) = _tryOwner(agentId);
        bool stale = answered && o != ko;
        if (!stale && msg.sender != ko) revert NotRevoker(agentId, msg.sender);
        emit KeyRevoked(agentId, k.generation, msg.sender, stale);
        delete k.owner;
        delete k.terms;
    }

    // ------------------------------------------------------------------
    // The operator's side
    // ------------------------------------------------------------------

    /// @notice Pay `payee` `amount` from the agent's line, as a loan of the agent. The operator only, within the key's
    ///         terms; `ref` (an invoice, a job), when nonzero, is paid once per payee. Returns the line's loan id.
    function spend(uint256 agentId, address payee, uint256 amount, bytes32 ref)
        external
        nonReentrant
        returns (uint256 loanId)
    {
        Key storage k = _keys[agentId];
        Reason r = _gate(agentId, k, msg.sender, payee, amount, ref);
        if (r != Reason.Ok) revert Refused(r);
        uint64 g = k.generation;
        // booked before the line pays: a payee that runs code on receipt sees the payment already counted
        _book(agentId, g, k.terms, payee, amount);
        if (ref != bytes32(0)) refUsed[agentId][payee][ref] = true;
        loanId = _draw(agentId, payee, amount, k.terms.term, k.terms.maxFeeBps);
        emit Paid(agentId, payee, ref, amount, loanId, msg.sender, g);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function keyOf(uint256 agentId) external view returns (Key memory) {
        return _keys[agentId];
    }

    /// @notice The live key's payees and their caps (none without a key).
    function payeesOf(uint256 agentId) external view returns (Payee[] memory list) {
        Key storage k = _keys[agentId];
        if (k.owner == address(0)) return list;
        EnumerableSet.AddressSet storage s = _payees[agentId][k.generation];
        list = new Payee[](s.length());
        for (uint256 i = 0; i < list.length; i++) {
            address p = s.at(i);
            list[i] = Payee(p, _payeeCap[agentId][k.generation][p]);
        }
    }

    function payeeRule(uint256 agentId, address payee) external view returns (bool allowed, uint128 perPeriod) {
        Key storage k = _keys[agentId];
        if (k.owner == address(0)) return (false, 0);
        allowed = _payees[agentId][k.generation].contains(payee);
        perPeriod = _payeeCap[agentId][k.generation][payee];
    }

    /// @notice What the payments of the live key's trailing period sum to, how many they are, and when the oldest
    ///         leaves the window (0 if none): for the whole key with `payee` = address(0), else to that payee.
    function spentInPeriod(uint256 agentId, address payee)
        external
        view
        returns (uint256 spent, uint256 payments, uint64 releaseAt)
    {
        Key storage k = _keys[agentId];
        if (k.owner == address(0)) return (0, 0, 0);
        return _peek(_windowId(agentId, k.generation, payee), k.terms.period);
    }

    /// @notice What the key's own rules let it still pay in this trailing period, to all payees together: 0 when they
    ///         let it pay nothing (none, its owner no longer holds the agent, expired, MAX_PAYMENTS payments in the
    ///         window). The line may refuse more (the key not its delegate, its minimum loan, its capacity):
    ///         `isActive` and `check` read the delegate, and `LineRefused` gives the line's reason.
    function remaining(uint256 agentId) external view returns (uint256) {
        Key storage k = _keys[agentId];
        if (!_usable(agentId, k)) return 0;
        (uint256 s, uint256 n,) = _peek(_windowId(agentId, k.generation, address(0)), k.terms.period);
        if (n >= MAX_PAYMENTS) return 0;
        return k.terms.perPeriod > s ? k.terms.perPeriod - s : 0;
    }

    /// @notice The largest payment to `payee` the key's rules allow now. The line may still refuse it (its minimum loan,
    ///         5 USDG on CreditPoolV2, its capacity, the key not its delegate).
    function maxPayment(uint256 agentId, address payee) external view returns (uint256 m) {
        Key storage k = _keys[agentId];
        if (!_usable(agentId, k) || !_payees[agentId][k.generation].contains(payee)) return 0;
        Terms memory t = k.terms;
        (uint256 sk, uint256 nk,) = _peek(_windowId(agentId, k.generation, address(0)), t.period);
        if (nk >= MAX_PAYMENTS) return 0;
        m = t.perPeriod > sk ? t.perPeriod - sk : 0;
        if (t.perPayment < m) m = t.perPayment;
        uint128 cap = _payeeCap[agentId][k.generation][payee];
        if (cap != 0) {
            (uint256 sp,,) = _peek(_windowId(agentId, k.generation, payee), t.period);
            uint256 room = cap > sp ? cap - sp : 0;
            if (room < m) m = room;
        }
    }

    /// @notice Whether the key would let `operator` pay `payee` `amount` for `ref` now, and if not why: the same rules
    ///         `spend` applies, in the same order, and last whether the line names this key the agent's controller.
    function check(uint256 agentId, address operator, address payee, uint256 amount, bytes32 ref)
        external
        view
        returns (Reason r)
    {
        Key storage k = _keys[agentId];
        r = _gate(agentId, k, operator, payee, amount, ref);
        if (r != Reason.Ok) return r;
        uint64 g = k.generation;
        uint64 period = k.terms.period;
        (uint256 sk, uint256 nk,) = _peek(_windowId(agentId, g, address(0)), period);
        (uint256 sp,,) = _peek(_windowId(agentId, g, payee), period);
        r = _room(k.terms.perPeriod, _payeeCap[agentId][g][payee], amount, sk, nk, sp);
        if (r == Reason.Ok && !_isDelegate(agentId)) r = Reason.NotDelegate;
    }

    /// @notice The key is live: set, held by its owner, not expired, and the line's controller for the agent. A live
    ///         key may still refuse a given payment (its caps, a full window): `maxPayment` and `check` say.
    function isActive(uint256 agentId) external view returns (bool) {
        return _usable(agentId, _keys[agentId]) && _isDelegate(agentId);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _validate(Terms calldata t) internal view {
        if (t.operator == address(0)) revert ZeroOperator();
        if (t.perPayment == 0 || t.perPayment > t.perPeriod) revert BadCaps();
        if (t.period == 0 || t.period > MAX_PERIOD) revert BadPeriod();
        if (t.expiresAt <= block.timestamp) revert BadExpiry();
        if (t.term == 0 || t.term > MAX_PERIOD) revert BadTerm();
        if (t.maxFeeBps > BPS) revert BadFee();
    }

    function _setPayee(uint256 agentId, uint64 g, address payee, bool allowed, uint128 perPeriod) internal {
        if (
            payee == address(0) || payee == address(this) || payee == address(line) || payee == address(registry)
                || payee == asset
        ) revert BadPayee(payee);
        EnumerableSet.AddressSet storage s = _payees[agentId][g];
        if (allowed) {
            if (s.add(payee) && s.length() > MAX_PAYEES) revert TooManyPayees();
            _payeeCap[agentId][g][payee] = perPeriod;
        } else {
            if (!s.remove(payee)) return; // not listed: nothing changes, nothing to say
            delete _payeeCap[agentId][g][payee];
            perPeriod = 0;
        }
        emit PayeeSet(agentId, g, payee, allowed, perPeriod);
    }

    /// @dev Every rule but the windows'.
    function _gate(uint256 agentId, Key storage k, address operator, address payee, uint256 amount, bytes32 ref)
        internal
        view
        returns (Reason)
    {
        address ko = k.owner;
        if (ko == address(0)) return Reason.NoKey;
        if (_registryOwner(agentId) != ko) return Reason.OwnerChanged;
        if (block.timestamp >= k.terms.expiresAt) return Reason.Expired;
        if (operator != k.terms.operator) return Reason.NotOperator;
        if (amount == 0) return Reason.ZeroAmount;
        if (!_payees[agentId][k.generation].contains(payee)) return Reason.PayeeNotAllowed;
        if (amount > k.terms.perPayment) return Reason.OverPerPayment;
        if (ref != bytes32(0) && refUsed[agentId][payee][ref]) return Reason.RefUsed;
        return Reason.Ok;
    }

    /// @dev The windows' rules, from what the key's window (`sk`, `nk` payments) and the payee's (`sp`) hold now.
    function _room(uint256 perPeriod, uint128 payeeCap, uint256 amount, uint256 sk, uint256 nk, uint256 sp)
        internal
        pure
        returns (Reason)
    {
        if (nk >= MAX_PAYMENTS) return Reason.TooManyPayments;
        if (sk + amount > perPeriod) return Reason.OverPeriod;
        if (payeeCap != 0 && sp + amount > payeeCap) return Reason.OverPayeePeriod;
        return Reason.Ok;
    }

    /// @dev Roll both windows (the key's and the payee's), apply their rules, and record the payment in both.
    function _book(uint256 agentId, uint64 g, Terms storage t, address payee, uint256 amount) internal {
        bytes32 wk = _windowId(agentId, g, address(0));
        bytes32 wp = _windowId(agentId, g, payee);
        uint64 period = t.period;
        (uint256 sk, uint256 nk) = _roll(wk, period);
        (uint256 sp,) = _roll(wp, period);
        Reason r = _room(t.perPeriod, _payeeCap[agentId][g][payee], amount, sk, nk, sp);
        if (r != Reason.Ok) revert Refused(r);
        _push(wk, amount);
        _push(wp, amount);
    }

    /// @dev The draw: a loan of the agent paid straight to `payee`, its fee at most `maxFeeBps` of `amount`. The line's
    ///      refusal comes back whole in LineRefused, and reverts everything the payment booked.
    function _draw(uint256 agentId, address payee, uint256 amount, uint64 term, uint16 maxFeeBps)
        internal
        returns (uint256 loanId)
    {
        try line.borrow(agentId, amount, term, payee, amount * maxFeeBps / BPS) returns (uint256 id) {
            loanId = id;
        } catch (bytes memory reason) {
            revert LineRefused(reason);
        }
    }

    function _usable(uint256 agentId, Key storage k) internal view returns (bool) {
        return k.owner != address(0) && _registryOwner(agentId) == k.owner && block.timestamp < k.terms.expiresAt;
    }

    function _isDelegate(uint256 agentId) internal view returns (bool) {
        try line.isController(agentId, address(this)) returns (bool c) {
            return c;
        } catch {
            return false;
        }
    }

    /// @dev The registry's owner of the agent; address(0) when the registry does not answer (a burnt or unknown agent,
    ///      or a registry that fails): every check then fails closed.
    function _registryOwner(uint256 agentId) internal view returns (address o) {
        (, o) = _tryOwner(agentId);
    }

    /// @dev A low-level call: a registry that reverts, returns less than a word or a word that is not an address is no
    ///      answer (a `try` would let the failed decoding revert the caller, the owner's own revoke included).
    function _tryOwner(uint256 agentId) internal view returns (bool answered, address o) {
        (bool ok, bytes memory r) = address(registry).staticcall(abi.encodeCall(ILineKeyRegistry.ownerOf, (agentId)));
        if (!ok || r.length < 32) return (false, address(0));
        uint256 v = abi.decode(r, (uint256));
        if (v >> 160 != 0) return (false, address(0));
        return (true, address(uint160(v)));
    }

    function _windowId(uint256 agentId, uint64 g, address scope) internal pure returns (bytes32) {
        return keccak256(abi.encode(agentId, g, scope));
    }

    /// @dev Drop the payments that left the window (a payment at s counts while block.timestamp < s + period, and
    ///      timestamps never decrease, so they leave in order); returns what is left and how many.
    function _roll(bytes32 id, uint64 period) internal returns (uint256 sum, uint256 count) {
        Window storage w = _windows[id];
        uint64 h = w.head;
        uint64 tl = w.tail;
        uint128 s = w.sum;
        while (h < tl) {
            uint256 d = _debits[id][h];
            if (uint256(d >> 128) + period > block.timestamp) break;
            // forge-lint: disable-next-line(unsafe-typecast)
            s -= uint128(d); // the low 128 bits are the amount (_push)
            h++;
        }
        if (h != w.head) {
            w.head = h;
            w.sum = s;
        }
        return (s, tl - h);
    }

    function _peek(bytes32 id, uint64 period) internal view returns (uint256 sum, uint256 count, uint64 releaseAt) {
        Window storage w = _windows[id];
        uint64 h = w.head;
        uint64 tl = w.tail;
        sum = w.sum;
        while (h < tl) {
            uint256 d = _debits[id][h];
            if (uint256(d >> 128) + period > block.timestamp) {
                // forge-lint: disable-next-line(unsafe-typecast)
                releaseAt = uint64(d >> 128) + period; // the high bits are a block timestamp
                break;
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            sum -= uint128(d);
            h++;
        }
        count = tl - h;
    }

    function _push(bytes32 id, uint256 amount) internal {
        Window storage w = _windows[id];
        _debits[id][w.tail] = (block.timestamp << 128) | amount;
        w.tail += 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        w.sum += uint128(amount); // amount <= perPayment, a uint128
    }

    /// @dev The address `a()` returns, else the one `b()` returns, else address(0).
    function _readAddress(address target, bytes4 a, bytes4 b) private view returns (address) {
        (bool ok, bytes memory r) = target.staticcall(abi.encodeWithSelector(a));
        if (!ok || r.length != 32) (ok, r) = target.staticcall(abi.encodeWithSelector(b));
        if (!ok || r.length != 32) return address(0);
        uint256 v = abi.decode(r, (uint256));
        return v >> 160 == 0 ? address(uint160(v)) : address(0);
    }
}
