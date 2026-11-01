// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMarketRegistry, IMarketPoolV2} from "./IAgentMarket.sol";

/// @notice The ERC-8004 registry as AgentLease reads it: the market's registry plus the agent's payment wallet.
interface ILeaseRegistry is IMarketRegistry {
    function getAgentWallet(uint256 id) external view returns (address);
}

/// @notice CreditPoolV2 as AgentLease reads it: the market's reads plus `isController` (the owner, or the delegate the
///         owner named), the accounts that can borrow on the agent's line.
interface ILeasePoolV2 is IMarketPoolV2 {
    function isController(uint256 id, address who) external view returns (bool);
}

/// @title IAgentLease
/// @notice AgentLease (src/AgentLease.sol) as the index, the gas gate, Go mode, the board and the MCP call it. Its
///         calls, events and errors are the ones sdk/agent-lease.mjs fixes (docs/AGENT-LEASE.md); a change here is a
///         change to that seam first.
interface IAgentLease {
    /// @notice A standing offer to rent agent `id` out. `owner` zero: none. Void once `ownerOf(id)` is no longer
    ///         `owner`, or once the agent sold on the market since the offer (`soldAt`, the market's `lastSoldAt`).
    ///         `feeBps` and `minFee` are the market's fee at the offer: a lease pins the lower rate and the lower
    ///         minimum of these and the market's at its rent.
    struct Offer {
        address owner;
        uint96 dayPrice; // USDG units a day; 0 only for a named renter
        address renter; // zero: anyone
        uint8 minDays; // 1 to maxDays
        uint8 maxDays; // at most MAX_DAYS
        uint64 expiry;
        uint64 soldAt;
        uint16 feeBps;
        uint96 minFee;
    }

    /// @notice One lease per agent, running while `block.timestamp < start + term days`. `renter` zero: none. Day `k`
    ///         (0-based) runs from `start + k days` to `start + (k+1) days` and is paid once it has ended, to whoever
    ///         held the agent then, less its own share of the fee: F(k+1) - F(k), where F(n) is the market's rule on n
    ///         days' rent at the lease's `feeBps` and `minFee` (0 for no day, or a day price of 0). `paidDays` of the
    ///         `term` are paid out (0 at `rent`); `holder` is the agent's owner at the last payout (`settledAt`). The
    ///         contract holds the rest, `(term - paidDays) x dayPrice`. An end first pays the days that ended to their
    ///         holders (on the renter's own end of a sound lease, the day under way too; with no owner, only the days
    ///         that ended by a market sale since the last payout), then sends every day not paid back to the renter:
    ///         `refundsOf`, not this struct, gives that figure. `maxDays` is the rented offer's longest term, which
    ///         `extend` stays within (an offer by the owner during the lease sets it to `term`); `owner` is the owner
    ///         that rented it out.
    struct Lease {
        address renter;
        uint64 start;
        uint8 term; // days, at most maxDays
        uint8 paidDays;
        uint8 maxDays;
        address holder;
        uint96 dayPrice;
        address owner;
        uint64 settledAt;
        uint16 feeBps; // the lease's fee pin, set at rent: the lower rate
        uint96 minFee; // and the lower minimum of the offer's and the market's
    }

    event RentOffered(
        uint256 indexed agentId,
        address indexed owner,
        address indexed renter,
        uint256 dayPrice,
        uint8 minDays,
        uint8 maxDays,
        uint64 expiry
    );
    event RentOfferCancelled(uint256 indexed agentId, address indexed by);
    event Rented(
        uint256 indexed agentId,
        address indexed owner,
        address indexed renter,
        uint64 start,
        uint64 until,
        uint256 total,
        uint256 fee
    );
    event Extended(uint256 indexed agentId, address indexed owner, address indexed renter, uint64 until, uint256 total);
    event RentPaid(uint256 indexed agentId, address indexed to, uint256 amount);
    event FeeTaken(uint256 indexed agentId, address indexed to, uint256 amount);
    event LeaseEnded(uint256 indexed agentId, address indexed renter, address indexed by, uint256 refund);
    event RentHeld(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    error NoOffer(uint256 id);
    error OfferExpired(uint256 id, uint64 expiry);
    error OfferGone(uint256 id);
    error Leased(uint256 id, uint64 until);
    error NotForYou(uint256 id);
    error SelfRent();
    error RenterIsWallet(uint256 id);
    error RenterControls(uint256 id);
    error Listed(uint256 id, address market);
    error BadDays();
    error DayBelowFee(uint256 dayPrice, uint256 fee);
    error NoLease(uint256 id);
    error CannotEnd(uint256 id, address caller);
    error NothingOwed(address account);
    error PayOutOfGas();
    error NotRenter(uint256 id, address caller);
    error ChangedHands(uint256 id);
    error RefundBelow(uint256 refund, uint256 minRefund);
    error RegistryFailed(uint256 id);
    // with the market's signatures, so one error map serves both
    error NotOwner(uint256 id, address seller);
    error Custodian(address account);
    error Refused(address account);
    error Marked(address account);
    error IsRoot(uint256 id, address pool);
    error AgentDefaulted(uint256 id, address pool);
    error RecordChanged(uint256 id);
    error UriChanged(uint256 id);
    error PriceTooLow(uint256 price);
    error PriceAbove(uint256 price, uint256 maxPrice);
    error BadExpiry(uint64 expiry);
    error CannotCancel(uint256 id, address caller);

    /// @notice Offer agent `id` for rent: `dayPrice` USDG units a day, for `minDays` to `maxDays` days, to `renter`
    ///         (zero: anyone), until `expiry`. The caller owns the agent. A new offer replaces the standing one.
    function offerRent(uint256 id, uint256 dayPrice, uint8 minDays, uint8 maxDays, address renter, uint64 expiry)
        external;
    /// @notice Drop the offer on `id`: its owner, or anyone once the agent changed hands, sold, or the offer expired.
    function cancelOffer(uint256 id) external;
    /// @notice Rent agent `id` for `days_` days from its standing offer, paying the whole rent now into the lease,
    ///         which pays each day out as it ends. The fee is taken from those payouts, never from the rent as it is
    ///         paid in. A lease that ran out unclaimed before it is paid out first, as `claim` would pay it.
    function rent(uint256 id, uint256 days_, uint256 maxTotal, bytes32 recordHash, bytes32 uriHash)
        external
        returns (uint64 until);
    /// @notice Add `days_` days to `id`'s running lease, at its own day price, paid now into the lease: the renter
    ///         only, up to the rented offer's longest term from the start, while the owner that rented it out still
    ///         holds the agent and it has not sold since, with `rent`'s checks on the agent, both accounts, the record
    ///         and the file.
    function extend(uint256 id, uint256 days_, uint256 maxTotal, bytes32 recordHash, bytes32 uriHash)
        external
        returns (uint64 until);
    /// @notice Pay out every day of `id`'s lease that has ended and is not paid yet, each to whoever held the agent
    ///         when it ended (exact for one market sale since the last payout, a V2 buy or acceptBid or a v1 sale; a
    ///         plain transfer with no sale since gives every unpaid day to its receiver, so a client claims before and
    ///         after each change of hands). Anyone. On a broken agent, before the lease's date or after, it ends the
    ///         lease instead. Returns what it paid out; 0, and nothing logged, with no lease stored.
    function claim(uint256 id) external returns (uint256 paid);
    /// @notice End `id`'s lease now: the renter or the agent's owner while it runs, or anyone once the agent is broken
    ///         (then also after its date). On a sound agent the days ended are paid to their holders, and the renter's
    ///         own end also pays the day under way, which the owner's end sends back. On a broken agent every end sends
    ///         the day under way back: with an owner (a default) the days ended are paid to their holders; with none
    ///         (burnt, or held by the lease) only the days that ended by a market sale since the last payout, to the
    ///         holder then. Every other day goes back to the renter, and the call reverts rather than send back less
    ///         than `minRefund`. A renter that also holds the agent ends as the renter.
    function endLease(uint256 id, uint256 minRefund) external returns (uint256 refund);
    /// @notice Send `account` what a payout to it could not deliver (`owed`). Anyone may call it; it pays `account`
    ///         only.
    function withdraw(address account) external returns (uint256 amount);

    /// @notice The renter while the lease runs (`block.timestamp < until`) and the agent has an owner, else zero
    ///         (EIP-4907's view).
    function userOf(uint256 id) external view returns (address);
    /// @notice The lease's end while it runs and the agent has an owner, else 0 (EIP-4907's view).
    function userExpires(uint256 id) external view returns (uint256);
    function leaseOf(uint256 id) external view returns (Lease memory);
    function offerOf(uint256 id) external view returns (Offer memory);
    /// @notice What `rent(id, days_)` costs now in all, and the fee the whole term carries, taken from its payouts.
    function quote(uint256 id, uint256 days_) external view returns (uint256 total, uint256 fee);
    /// @notice What `claim(id)` pays out now, in all, net of the fee (on a broken agent, what its end pays the
    ///         holders).
    function claimable(uint256 id) external view returns (uint256);
    /// @notice What an end of `id`'s lease now sends back to its renter: `byRenter` on the renter's own end, `byOwner`
    ///         on the owner's (the day under way too). Equal on a broken agent; (0, 0) once a sound lease is over. A
    ///         renter that also holds the agent ends as the renter: its figure is `byRenter`.
    function refundsOf(uint256 id) external view returns (uint256 byRenter, uint256 byOwner);
    /// @notice USDG a payout could not deliver to `account`, waiting for its `withdraw`.
    function owed(address account) external view returns (uint256);
}
