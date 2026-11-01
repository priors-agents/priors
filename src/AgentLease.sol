// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {GuardianPause} from "./GuardianPause.sol";
import {ICreditPoolV2} from "./interfaces/ICreditPoolV2.sol";
import {IAgentMarket, IMarketPoolV1} from "./interfaces/IAgentMarket.sol";
import {IAgentLease, ILeaseRegistry, ILeasePoolV2} from "./interfaces/IAgentLease.sol";

/// @title AgentLease
/// @notice Renting an agent out (the renting spec, P11, with the owner's answers of 2026-10-27, 2026-10-30 and
///         2026-10-31; docs/AGENT-LEASE.md): the right to run an ERC-8004 agent on Priors for a fixed term of 1 to 90
///         days, sell its work and take paid jobs under its name, paid to the renter's own address. A sidecar beside
///         AgentMarketV2: it reads the market's public views (the fee, its destination, the refused list, the listings,
///         the record pin and the last sale) and changes nothing there. It never holds the agent: the agent stays in
///         its owner's wallet, so its record, its line and its Score v2 stay where they are, and the owner can sell it
///         like any other agent. Nobody but the renter is named by `userOf`, and only by its own `rent`.
///
///         An offer is the owner's own transaction (`offerRent`): a day price, a range of days, an expiry, anyone or
///         one named address. A rent (`rent`) takes it: the renter pays the whole term into this contract, which pays
///         each day out once it has ended (`claim`, anyone, at any time), to whoever held the agent then: the holder at
///         the last payout gets the days that ended by the agent's last sale on the market since (rounded down), the
///         owner now the rest. That split is exact for one sale between two payouts, and only then: the market shows
///         only its last sale, and the registry no transfer at all. So a plain transfer with no sale since gives every
///         unpaid day to its receiver, and with two changes of hands between payouts the middle holder is paid nothing:
///         its days go to the holder at the last payout when the later change is a market sale, and to the owner now
///         when it is a plain transfer. The client rule (docs/AGENT-LEASE.md): every operation on Priors that changes
///         hands claims before and after the change, in the same operation (Go mode's and the board's Buy, Accept, Sell
///         and transfer). There is no keeper: owners collect their own rent, and an owner that never claims loses no
///         day to a default.
///
///         The fee is the market's rule, taken from each payout, never from what `rent` or `extend` pays in: after a
///         payout, the fee taken on a lease in all is F(paidDays), where F(n) =
///         max(n x dayPrice x feeBps / 10,000, minFee) for n > 0 (0 for no day, or a day price of 0), at the pin the
///         lease takes at `rent`: the lower rate and the lower minimum of the offer's and the market's then. So each
///         day carries its own share, F(k+1) - F(k), however the payouts are grouped, and a day never paid carries
///         none. Each payout's share goes to the market's `feeTo`, read then. An offer's day price must be above the
///         fee on its longest term at the market's fee now (`DayBelowFee`), which the lease's pin can only lower: every
///         payout leaves its holder something, and every refund is whole days in full.
///
///         A lease ends at its date by itself, or early: by its renter, or by the agent's owner (whoever holds it then,
///         a buyer or a bid's maker included). The days that ended go to their holders, and every day not paid goes
///         back to the renter from this contract, never less than the `minRefund` the caller asks for: the renter's own
///         end pays the day under way, the owner's end sends it back too. A sale does not end a lease.
///
///         A broken agent's lease anyone ends (`claim` or `endLease`), before its date or after. An agent that
///         defaulted on pool v2 or v1 and still has an owner pays every day that ended to its holders, as a claim does,
///         and sends the day under way and the days not begun back to the renter; until that end, the renter runs it
///         and pays for the days that end. An agent with no owner (burnt, or sent to this contract: its owner's own
///         act) pays the holder at the last payout only the days that ended by a market sale since, and every other day
///         not paid goes back to the renter; `userOf` names nobody. Only the registry's own word that the agent is gone
///         counts as a burn: while it fails to answer, claims and ends wait (`RegistryFailed`).
///
///         `extend` adds days to a running lease at its own day price, paid into this contract: the renter only, up to
///         the rented offer's longest term from the start, while the owner that rented it out still holds the agent and
///         it has not sold since (`ChangedHands`: a buyer gets the lease it saw), with `rent`'s checks on the agent,
///         both accounts, the record and the file. An offer the owner makes during a lease closes its extensions.
///
///         The rules at `rent`: the offer stands, has not expired, and its owner still holds the agent, which has not
///         sold on the market since; no lease runs; the renter is the one named (if any), and is not the owner, the
///         agent's registry wallet or anyone who can borrow on its line (`isController`); neither is a pool custodian,
///         refused on the market, or marked by the pool; the agent is not a root and not defaulted (pool v2 or v1); its
///         record and its file are the ones the renter read (`recordHash`, `uriHash`); no listing of it stands on the
///         market or on `previous`, by anyone (one by an earlier holder is buyable again once the agent goes back to
///         it, and anyone may cancel it there first); the days are in the offer's range and the rent within the
///         renter's `maxTotal`.
///
///         A payout USDG refuses (a frozen holder, renter or fee destination) never stops a claim or an end: it waits
///         in `owed` for `withdraw(account)`, which anyone may send and which pays that account only. Not upgradeable;
///         no setting, no admin: the fee, its destination and the refused list are the market's. The guardian (the
///         Safe) can pause `offerRent`, `rent` and `extend` (GuardianPause: at most 14 days); `cancelOffer`, `claim`,
///         `endLease` and `withdraw` are never paused, so money can always come back. No ETH path. The contract holds
///         only USDG: (term - paidDays) x dayPrice of each lease, and what waits in `owed`.
contract AgentLease is IAgentLease, GuardianPause, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    uint256 public constant BPS = 10_000;
    /// @notice The least a paid lease costs in all, the market's MIN_PRICE: 5 USDG.
    uint256 public constant MIN_RENT = 5e6;
    /// @notice A lease lasts at most this many days.
    uint256 public constant MAX_DAYS = 90;
    /// @notice One day of rent.
    uint256 public constant DAY = 1 days;
    /// @notice An offer stands at most this long.
    uint64 public constant MAX_OFFER = 30 days;

    // ------------------------------------------------------------------
    // Immutables and storage
    // ------------------------------------------------------------------

    ILeaseRegistry public immutable registry;
    IERC20 public immutable usdg;
    ILeasePoolV2 public immutable poolV2;
    /// @notice Pool v1 (retired); zero on a chain without one.
    IMarketPoolV1 public immutable poolV1;
    /// @notice AgentMarketV2: the fee, `feeTo`, the refused list, the record pin, its listings and `lastSoldAt`.
    IAgentMarket public immutable market;
    /// @notice AgentMarket v1 (V2's `previous`), whose listings also bar a rent; zero on a chain without one.
    IAgentMarket public immutable previous;

    /// @dev One payout of a lease's ended days: `n1` to `h1` (the holder at the last payout), `n2` to `h2` (the owner
    ///      now), each net of its days' share of the fee, and `fee` in all to the market's `feeTo`.
    struct Payout {
        address h1;
        uint256 n1;
        address h2;
        uint256 n2;
        uint256 fee;
    }

    mapping(uint256 => Offer) internal _offers;
    mapping(uint256 => Lease) internal _leases;
    /// @inheritdoc IAgentLease
    mapping(address => uint256) public owed;

    /// @param registry_ the ERC-8004 identity registry
    /// @param usdg_ USDG
    /// @param poolV2_ CreditPoolV2
    /// @param poolV1_ CreditPool v1 (zero allowed)
    /// @param market_ AgentMarketV2
    /// @param previous_ AgentMarket v1, V2's `previous` (zero allowed)
    /// @param guardian_ the Safe: pause of `offerRent`, `rent` and `extend`, nothing else (it is also GuardianPause's
    ///        timelock, which owns no setting here)
    constructor(
        address registry_,
        address usdg_,
        address poolV2_,
        address poolV1_,
        address market_,
        address previous_,
        address guardian_
    ) GuardianPause(guardian_, guardian_) {
        if (registry_ == address(0) || usdg_ == address(0) || poolV2_ == address(0) || market_ == address(0)) {
            revert ZeroAddress();
        }
        registry = ILeaseRegistry(registry_);
        usdg = IERC20(usdg_);
        poolV2 = ILeasePoolV2(poolV2_);
        poolV1 = IMarketPoolV1(poolV1_);
        market = IAgentMarket(market_);
        previous = IAgentMarket(previous_);
    }

    // ------------------------------------------------------------------
    // Offers
    // ------------------------------------------------------------------

    /// @inheritdoc IAgentLease
    /// @dev The market's fee is pinned here: a lease pins no more than this. An offer may be made while a lease runs;
    ///      it can be taken once that lease ends, and it closes that lease's extensions: its date is final from then.
    function offerRent(uint256 id, uint256 dayPrice, uint8 minDays, uint8 maxDays, address renter, uint64 expiry)
        external
        nonReentrant
        whenNotPaused
    {
        if (registry.ownerOf(id) != msg.sender) revert NotOwner(id, msg.sender);
        _checkAccount(msg.sender);
        _checkLeasable(id);
        if (minDays == 0 || minDays > maxDays || maxDays > MAX_DAYS) revert BadDays();
        if (dayPrice > type(uint96).max) revert PriceAbove(dayPrice, type(uint96).max);
        if (renter == msg.sender) revert SelfRent();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_OFFER) revert BadExpiry(expiry);
        uint256 bps = market.feeBps();
        uint256 floor = market.minFee();
        if (dayPrice == 0) {
            // free only to one named address
            if (renter == address(0)) revert PriceTooLow(0);
        } else {
            if (dayPrice * minDays < MIN_RENT) revert PriceTooLow(dayPrice * minDays);
            // the fee on the longest term stays under a day at the market's fee now, which the lease pins as its
            // highest: every payout leaves its holder something, and every refund is whole days
            uint256 fee = _feeOf(dayPrice * maxDays, bps, floor);
            if (dayPrice <= fee) revert DayBelowFee(dayPrice, fee);
        }
        Lease storage cur = _leases[id];
        // the owner's new terms close the running lease's extensions: its date is final from now
        if (cur.renter != address(0) && block.timestamp < _untilOf(cur.start, cur.term) && cur.maxDays > cur.term) {
            cur.maxDays = cur.term;
        }
        _offers[id] = Offer({
            owner: msg.sender,
            // safe cast: checked above
            // forge-lint: disable-next-line(unsafe-typecast)
            dayPrice: uint96(dayPrice),
            renter: renter,
            minDays: minDays,
            maxDays: maxDays,
            expiry: expiry,
            soldAt: market.lastSoldAt(id),
            feeBps: SafeCast.toUint16(bps),
            minFee: SafeCast.toUint96(floor)
        });
        emit RentOffered(id, msg.sender, renter, dayPrice, minDays, maxDays, expiry);
    }

    /// @inheritdoc IAgentLease
    /// @dev Never paused. An owner the registry cannot name (a burnt agent) counts as a change of hands.
    function cancelOffer(uint256 id) external nonReentrant {
        Offer memory o = _offers[id];
        if (o.owner == address(0)) revert NoOffer(id);
        if (msg.sender != o.owner && _offerStands(id, o)) revert CannotCancel(id, msg.sender);
        delete _offers[id];
        emit RentOfferCancelled(id, msg.sender);
    }

    // ------------------------------------------------------------------
    // Rent
    // ------------------------------------------------------------------

    /// @inheritdoc IAgentLease
    /// @param days_ the term, within the offer's range
    /// @param maxTotal the most the renter pays in all: the day price it read times `days_`
    /// @param recordHash_ the market's record pin the renter read (the record and the line it rents under)
    /// @param uriHash_ keccak256 of the token URI the renter read
    /// @dev The whole rent goes to the lease, which pays each day out once it has ended: none of this rent goes to the
    ///      owner or to `feeTo` here. A lease that ran out unclaimed before it is paid out first, as `claim` would pay
    ///      it (its RentPaid and FeeTaken logged before Rented). `Rented.fee` is the fee the whole term carries,
    ///      F(term), taken from its payouts.
    function rent(uint256 id, uint256 days_, uint256 maxTotal, bytes32 recordHash_, bytes32 uriHash_)
        external
        nonReentrant
        whenNotPaused
        returns (uint64 until)
    {
        (Offer memory o, address owner, Lease memory cur) = _checkRent(id, recordHash_, uriHash_);
        if (days_ < o.minDays || days_ > o.maxDays) revert BadDays();
        uint256 total = uint256(o.dayPrice) * days_;
        if (total > maxTotal) revert PriceAbove(total, maxTotal);
        // the lease's pin: the lower rate and the lower minimum of the offer's and the market's now
        uint256 bps = Math.min(o.feeBps, market.feeBps());
        uint256 floor = Math.min(o.minFee, market.minFee());
        until = _open(id, o, owner, cur, days_, bps, floor);
        if (total != 0) usdg.safeTransferFrom(msg.sender, address(this), total);
        uint256 fee = total == 0 ? 0 : _feeOf(total, bps, floor);
        // safe cast: a timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Rented(id, owner, msg.sender, uint64(block.timestamp), until, total, fee);
    }

    /// @inheritdoc IAgentLease
    /// @param days_ the days to add: at least 1, and the term then at most the rented offer's longest
    /// @param maxTotal the most the renter pays: the lease's day price times `days_`
    /// @param recordHash_ the market's record pin the renter read
    /// @param uriHash_ keccak256 of the token URI the renter read
    /// @dev No fee here: the added days carry their share of it when they are paid out. Not checked again: the offer's
    ///      expiry (it bounded when the lease could start) and MIN_RENT (the lease met it at the rent).
    function extend(uint256 id, uint256 days_, uint256 maxTotal, bytes32 recordHash_, bytes32 uriHash_)
        external
        nonReentrant
        whenNotPaused
        returns (uint64 until)
    {
        Lease memory l = _leases[id];
        if (l.renter == address(0) || block.timestamp >= _until(l)) revert NoLease(id);
        if (msg.sender != l.renter) revert NotRenter(id, msg.sender);
        if (days_ == 0 || days_ > uint256(l.maxDays) - l.term) revert BadDays();
        uint256 total = uint256(l.dayPrice) * days_;
        if (total > maxTotal) revert PriceAbove(total, maxTotal);
        _checkExtend(id, l, recordHash_, uriHash_);
        // safe cast: term + days_ <= maxDays <= MAX_DAYS
        // forge-lint: disable-next-line(unsafe-typecast)
        l.term = uint8(uint256(l.term) + days_);
        _leases[id].term = l.term;
        until = _until(l);
        if (total != 0) usdg.safeTransferFrom(msg.sender, address(this), total);
        emit Extended(id, l.owner, msg.sender, until, total);
    }

    /// @inheritdoc IAgentLease
    /// @dev Never paused. A lease that ran to its date is closed by its last claim (or the next rent). On a broken
    ///      agent a claim ends the lease, before its date or after, as `endLease` does. With no lease stored it returns
    ///      0 and logs nothing, so a claim before and after a change of hands never reverts the operation.
    function claim(uint256 id) external nonReentrant returns (uint256 paid) {
        Lease memory l = _leases[id];
        if (l.renter == address(0)) return 0;
        if (_broken(id)) {
            (paid,) = _end(id, l, msg.sender, true, 0);
            return paid;
        }
        Payout memory p = _settle(id, l, _ended(l));
        if (block.timestamp >= _until(l)) delete _leases[id];
        else _leases[id] = l;
        _payOut(id, p);
        paid = p.n1 + p.n2;
    }

    /// @inheritdoc IAgentLease
    /// @dev Never paused. The owner here is whoever holds the agent now: a buyer can end a lease it bought with the
    ///      agent, and it pays nothing for it. On a sound agent who ends decides the day under way: the renter's end
    ///      pays it, the owner's sends it back. A broken agent's lease anyone ends, before its date or after, and the
    ///      day under way comes back whoever ends. A renter that also holds the agent ends as the renter.
    function endLease(uint256 id, uint256 minRefund) external nonReentrant returns (uint256 refund) {
        Lease memory l = _leases[id];
        if (l.renter == address(0)) revert NoLease(id);
        bool broken = _broken(id);
        if (!broken) {
            if (block.timestamp >= _until(l)) revert NoLease(id);
            if (msg.sender != l.renter && msg.sender != _ownerOrZero(id)) revert CannotEnd(id, msg.sender);
        }
        (, refund) = _end(id, l, msg.sender, broken, minRefund);
    }

    /// @inheritdoc IAgentLease
    /// @dev Never paused. Pays `account` only, whoever sends it: USDG refused it once, and it is still that account's
    ///      (a fee splitter or a treasury contract can't send the call itself).
    function withdraw(address account) external nonReentrant returns (uint256 amount) {
        amount = owed[account];
        if (amount == 0) revert NothingOwed(account);
        owed[account] = 0;
        usdg.safeTransfer(account, amount);
        emit Withdrawn(account, amount);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IAgentLease
    function userOf(uint256 id) external view returns (address) {
        Lease memory l = _leases[id];
        if (l.renter == address(0) || block.timestamp >= _until(l)) return address(0);
        return _ownerOrZero(id) == address(0) ? address(0) : l.renter;
    }

    /// @inheritdoc IAgentLease
    function userExpires(uint256 id) external view returns (uint256) {
        Lease memory l = _leases[id];
        if (l.renter == address(0) || block.timestamp >= _until(l)) return 0;
        return _ownerOrZero(id) == address(0) ? 0 : _until(l);
    }

    /// @inheritdoc IAgentLease
    function leaseOf(uint256 id) external view returns (Lease memory) {
        return _leases[id];
    }

    /// @inheritdoc IAgentLease
    function offerOf(uint256 id) external view returns (Offer memory) {
        return _offers[id];
    }

    /// @inheritdoc IAgentLease
    function quote(uint256 id, uint256 days_) external view returns (uint256 total, uint256 fee) {
        Offer memory o = _offers[id];
        if (o.owner == address(0)) revert NoOffer(id);
        if (days_ < o.minDays || days_ > o.maxDays) revert BadDays();
        total = uint256(o.dayPrice) * days_;
        if (total != 0) fee = _feeOf(total, Math.min(o.feeBps, market.feeBps()), Math.min(o.minFee, market.minFee()));
    }

    /// @inheritdoc IAgentLease
    function claimable(uint256 id) external view returns (uint256) {
        Lease memory l = _leases[id];
        if (l.renter == address(0)) return 0;
        Payout memory p = _settle(id, l, _ended(l));
        return p.n1 + p.n2;
    }

    /// @inheritdoc IAgentLease
    function refundsOf(uint256 id) external view returns (uint256 byRenter, uint256 byOwner) {
        Lease memory l = _leases[id];
        if (l.renter == address(0)) return (0, 0);
        if (_broken(id)) {
            _settle(id, l, _ended(l));
            byRenter = (uint256(l.term) - l.paidDays) * l.dayPrice;
            return (byRenter, byRenter);
        }
        if (block.timestamp >= _until(l)) return (0, 0);
        // a sound lease that runs has a day under way, and nothing after the days ended is paid
        uint256 e = _ended(l);
        byRenter = (uint256(l.term) - e - 1) * l.dayPrice;
        byOwner = (uint256(l.term) - e) * l.dayPrice;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev rent's checks but the days and the price (the contract's notice): returns the offer, the owner and the
    ///      lease that stood before (ran out, or none).
    function _checkRent(uint256 id, bytes32 recordHash_, bytes32 uriHash_)
        internal
        view
        returns (Offer memory o, address owner, Lease memory cur)
    {
        o = _offers[id];
        if (o.owner == address(0)) revert NoOffer(id);
        if (block.timestamp >= o.expiry) revert OfferExpired(id, o.expiry);
        owner = registry.ownerOf(id);
        if (owner != o.owner || market.lastSoldAt(id) != o.soldAt) revert OfferGone(id);
        cur = _leases[id];
        if (cur.renter != address(0) && block.timestamp < _until(cur)) revert Leased(id, _until(cur));
        if (o.renter != address(0) && o.renter != msg.sender) revert NotForYou(id);
        if (msg.sender == owner) revert SelfRent();
        if (msg.sender == registry.getAgentWallet(id)) revert RenterIsWallet(id);
        if (poolV2.isController(id, msg.sender)) revert RenterControls(id);
        _checkAccount(owner);
        _checkAccount(msg.sender);
        _checkLeasable(id);
        if (market.recordHash(id) != recordHash_) revert RecordChanged(id);
        if (keccak256(bytes(registry.tokenURI(id))) != uriHash_) revert UriChanged(id);
        _checkUnlisted(id, market);
        if (address(previous) != address(0)) _checkUnlisted(id, previous);
    }

    /// @dev extend's checks but the days and the price (the contract's notice): the owner that rented the agent out
    ///      still holds it and it has not sold since (a sale, an accepted bid, a plain transfer, a burn or the agent
    ///      sent here: the buyer or receiver keeps the lease it saw), then rent's checks on the agent, both accounts,
    ///      the record, the file and the listings. A plain round trip back to that owner counts as no change, as for
    ///      offers; a sale in the rent's own second, before it, is no sale since.
    function _checkExtend(uint256 id, Lease memory l, bytes32 recordHash_, bytes32 uriHash_) internal view {
        if (_ownerOrZero(id) != l.owner || market.lastSoldAt(id) > l.start) revert ChangedHands(id);
        if (msg.sender == registry.getAgentWallet(id)) revert RenterIsWallet(id);
        if (poolV2.isController(id, msg.sender)) revert RenterControls(id);
        _checkAccount(l.owner);
        _checkAccount(msg.sender);
        _checkLeasable(id);
        if (market.recordHash(id) != recordHash_) revert RecordChanged(id);
        if (keccak256(bytes(registry.tokenURI(id))) != uriHash_) revert UriChanged(id);
        // a buyer in flight never meets a longer lease
        _checkUnlisted(id, market);
        if (address(previous) != address(0)) _checkUnlisted(id, previous);
    }

    /// @dev rent's effects: the lease that ran out before it settled (every one of its days has ended, and the agent is
    ///      sound here, as rent checked: a claim's payout), the offer gone, the new lease stored with the lease's fee
    ///      pin and nothing paid out of it yet, then the old lease's payout.
    function _open(
        uint256 id,
        Offer memory o,
        address owner,
        Lease memory cur,
        uint256 days_,
        uint256 bps,
        uint256 floor
    ) internal returns (uint64 until) {
        Payout memory p;
        if (cur.renter != address(0)) p = _settle(id, cur, cur.term);
        delete _offers[id];
        // field by field, so the legacy code generator keeps its stack
        Lease memory n;
        n.renter = msg.sender;
        // safe casts: a timestamp; days_ within the offer's range (at most MAX_DAYS); bps and floor at most the
        // offer's own pin (uint16, uint96)
        // forge-lint: disable-next-line(unsafe-typecast)
        n.start = uint64(block.timestamp);
        // forge-lint: disable-next-line(unsafe-typecast)
        n.term = uint8(days_);
        n.maxDays = o.maxDays;
        n.holder = owner;
        n.dayPrice = o.dayPrice;
        n.owner = owner;
        n.settledAt = n.start;
        // forge-lint: disable-next-line(unsafe-typecast)
        n.feeBps = uint16(bps);
        // forge-lint: disable-next-line(unsafe-typecast)
        n.minFee = uint96(floor);
        _leases[id] = n;
        until = _until(n);
        _payOut(id, p);
    }

    /// @dev An end at `by`'s call: the days that ended to their holders (the renter's own end of a sound lease also
    ///      the day under way), every day not paid back to the renter, never less than `minRefund`. Storage first,
    ///      then the payouts.
    function _end(uint256 id, Lease memory l, address by, bool broken, uint256 minRefund)
        internal
        returns (uint256 paid, uint256 refund)
    {
        uint256 to = _ended(l);
        // a sound lease ends early only while it runs, so a day is under way: the renter's own end keeps it paid
        if (!broken && by == l.renter) to += 1;
        Payout memory p = _settle(id, l, to);
        refund = (uint256(l.term) - l.paidDays) * l.dayPrice;
        if (refund < minRefund) revert RefundBelow(refund, minRefund);
        delete _leases[id];
        _payOut(id, p);
        if (refund != 0) _send(l.renter, refund);
        emit LeaseEnded(id, l.renter, by, refund);
        paid = p.n1 + p.n2;
    }

    /// @dev The days of `l` from `paidDays` to `to` (ended, or the day under way on the renter's end), split between
    ///      who held the agent when each ended: the holder at the last payout gets the days that ended by the agent's
    ///      last market sale since (rounded down), the owner now the rest; with no sale since and a new owner, the
    ///      owner now gets them all. Exact for one sale since the last payout (the contract's notice). With no owner
    ///      (burnt, or held here) only the holder's days are paid, and the rest stay unpaid (an end sends them back).
    ///      Each part is net of its days' share of the fee. Updates `l` in memory (paid days, holder, the time of this
    ///      payout) and pays nothing: the caller stores `l`, then pays the payout.
    function _settle(uint256 id, Lease memory l, uint256 to) internal view returns (Payout memory p) {
        uint256 from = l.paidDays;
        address owner = _ownerOrZero(id);
        p.h1 = l.holder;
        p.h2 = owner;
        if (to > from) {
            uint256 split = to;
            if (owner != p.h1) {
                split = from;
                uint64 sold = market.lastSoldAt(id);
                // settledAt >= start, so sold > start; rounded down: the days that ended by the sale are the holder's
                if (sold > l.settledAt) split = Math.min(Math.max((sold - l.start) / DAY, from), to);
            }
            // with no owner the days after the split are not paid
            uint256 paidTo = owner == address(0) ? split : to;
            _net(l, from, split, paidTo, p);
            // safe cast: at most l.term
            // forge-lint: disable-next-line(unsafe-typecast)
            l.paidDays = uint8(paidTo);
        }
        if (owner != address(0)) l.holder = owner;
        // safe cast: a timestamp
        // forge-lint: disable-next-line(unsafe-typecast)
        l.settledAt = uint64(block.timestamp);
    }

    /// @dev The two parts of a payout, days `from` to `split` and `split` to `paidTo`, each less its days' share of the
    ///      fee: F(split) - F(from) and F(paidTo) - F(split). Each share is under its part (F(maxDays) < dayPrice).
    function _net(Lease memory l, uint256 from, uint256 split, uint256 paidTo, Payout memory p) internal pure {
        uint256 f0 = _leaseFee(l, from);
        uint256 f1 = _leaseFee(l, split);
        uint256 f2 = _leaseFee(l, paidTo);
        p.n1 = (split - from) * l.dayPrice - (f1 - f0);
        p.n2 = (paidTo - split) * l.dayPrice - (f2 - f1);
        p.fee = f2 - f0;
    }

    function _payOut(uint256 id, Payout memory p) internal {
        if (p.n1 != 0) {
            _send(p.h1, p.n1);
            emit RentPaid(id, p.h1, p.n1);
        }
        if (p.n2 != 0) {
            _send(p.h2, p.n2);
            emit RentPaid(id, p.h2, p.n2);
        }
        if (p.fee != 0) {
            address to = market.feeTo();
            _send(to, p.fee);
            emit FeeTaken(id, to, p.fee);
        }
    }

    /// @dev USDG from this contract to `to`, or, when USDG refuses it (a frozen address), into `owed[to]` for its own
    ///      withdraw: a refused payout never stops a claim or an end. transfer as OpenZeppelin 5.1's private
    ///      _callOptionalReturnBool makes it. A call that ran out of gas reverts the whole call instead (what is left
    ///      could not have paid for it, whatever the caller's gas limit), so a gas limit cannot divert a payout.
    function _send(address to, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        address token = address(usdg);
        uint256 g = gasleft();
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        if (success && (returnSize == 0 ? token.code.length > 0 : returnValue == 1)) return;
        if (gasleft() < g / 32) revert PayOutOfGas();
        owed[to] += amount;
        emit RentHeld(to, amount);
    }

    /// @dev The days of `l` that have ended by now: day k ends at start + (k+1) days; all of them from its date on.
    function _ended(Lease memory l) internal view returns (uint256 n) {
        n = (block.timestamp - l.start) / DAY;
        if (n > l.term) n = l.term;
    }

    function _until(Lease memory l) internal pure returns (uint64) {
        return _untilOf(l.start, l.term);
    }

    function _untilOf(uint64 start, uint8 term) internal pure returns (uint64) {
        // safe cast: a timestamp plus at most 90 days
        // forge-lint: disable-next-line(unsafe-typecast)
        return start + uint64(uint256(term) * DAY);
    }

    /// @dev F(k): the fee `k` days of `l`'s rent carry in all, at its pin; none for no day or a free lease.
    function _leaseFee(Lease memory l, uint256 k) internal pure returns (uint256) {
        return k == 0 || l.dayPrice == 0 ? 0 : _feeOf(k * l.dayPrice, l.feeBps, l.minFee);
    }

    /// @dev The market's rule (AgentMarketV2 _feeOf): max(x x bps / 10,000 rounded down, floor).
    function _feeOf(uint256 x, uint256 bps, uint256 floor) internal pure returns (uint256) {
        return Math.max((x * bps) / BPS, floor);
    }

    /// @dev The offer can still be taken: not expired, its owner still holds the agent, no sale since.
    function _offerStands(uint256 id, Offer memory o) internal view returns (bool) {
        return block.timestamp < o.expiry && _ownerOrZero(id) == o.owner && market.lastSoldAt(id) == o.soldAt;
    }

    /// @dev An owner or a renter: not a pool custodian, not refused on the market, not marked by the pool (the
    ///      market's own three checks).
    function _checkAccount(address who) internal view {
        if (poolV2.custodian(who)) revert Custodian(who);
        if (market.refused(who)) revert Refused(who);
        if (poolV2.ownerDefaults(who) != 0) revert Marked(who);
    }

    /// @dev Never a root, never a defaulted agent, on pool v2 or v1.
    function _checkLeasable(uint256 id) internal view {
        ICreditPoolV2.Agent memory a = poolV2.getAgent(id);
        if (a.isRoot) revert IsRoot(id, address(poolV2));
        if (a.defaulted) revert AgentDefaulted(id, address(poolV2));
        if (address(poolV1) != address(0)) {
            IMarketPoolV1.Agent memory b = poolV1.getAgent(id);
            if (b.isRoot) revert IsRoot(id, address(poolV1));
            if (b.defaulted) revert AgentDefaulted(id, address(poolV1));
        }
    }

    /// @dev No listing of `id` stands on `m`, by anyone, so a buyer in flight never meets a new or a longer lease: one
    ///      by an earlier holder is buyable again once the agent goes back to it and it approves the market again. A
    ///      stale one blocks only until anyone cancels it (both markets let anyone cancel a listing whose seller no
    ///      longer holds the agent).
    function _checkUnlisted(uint256 id, IAgentMarket m) internal view {
        IAgentMarket.Listing memory l = m.listingOf(id);
        if (l.seller != address(0) && block.timestamp < l.expiry) revert Listed(id, address(m));
    }

    /// @dev The lease can't go on: the agent defaulted on pool v2 or v1, or no owner can hold it any more (burnt, or
    ///      sent to this contract).
    function _broken(uint256 id) internal view returns (bool) {
        if (_ownerOrZero(id) == address(0)) return true;
        if (poolV2.getAgent(id).defaulted) return true;
        return address(poolV1) != address(0) && poolV1.getAgent(id).defaulted;
    }

    /// @dev The registry's owner of `id`, or zero when the registry says it has none (ERC721NonexistentToken(id): a
    ///      burnt agent) or names this contract: nothing here can move an agent, so one sent here is gone for good, as
    ///      a burnt one, and no day is ever paid to this contract. Any other failure (another error, an empty revert, a
    ///      read out of gas) reverts `RegistryFailed`: nothing moves until the registry answers.
    function _ownerOrZero(uint256 id) internal view returns (address) {
        try registry.ownerOf(id) returns (address o) {
            return o == address(this) ? address(0) : o;
        } catch (bytes memory err) {
            if (err.length == 36 && bytes4(err) == IERC721Errors.ERC721NonexistentToken.selector) {
                uint256 named;
                assembly ("memory-safe") {
                    named := mload(add(err, 36))
                }
                if (named == id) return address(0);
            }
            revert RegistryFailed(id);
        }
    }
}
