// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CreditPool} from "./CreditPool.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "./interfaces/IPonsFeeEscrow.sol";

/// @title TreasurySponsor
/// @notice The token is a sponsor. Creator fees the project token earns on Pons land here; a sweep sends a share
///         to the pool's first-loss reserve and stakes the rest under the treasury's own ERC-8004 identity as a
///         root sponsor. From that stake it vouches by rule, not by judgement:
///
///           firstLine(agent)  an ERC-8004 identity that has never been enrolled gets a small first line,
///                             asked for by its own owner or delegate, WITH AN INVITE signed by an inviter
///                             the owner named. Registration is permissionless; treasury money is not.
///           raise(agent)      an agent it sponsors that has repaid enough qualified loans, is seasoned and
///                             clean, gets its line raised to the second tier
///           reclaim(agent)    a line nobody has used for `idleAfter` goes back to the treasury, so the
///                             capacity seats the next agent instead of sitting under a dead identity
///
///         The rule that makes the treasury's money safe from strangers: no first line without an invite. A
///         fresh identity costs cents, so any money handed to one unconditionally is a faucet, however it is
///         rate-limited. An invite is a signature from a key the owner trusts, over the agent id and an expiry,
///         so a seat needs a person, not a script. The epoch cap still bounds what invited agents can draw in a
///         week, only the identity's controller can redeem its invite, and idle lines are reclaimable by anyone. The sponsor fees its agents pay (25% of every loan fee) are collected to the fee sink,
///         which is the buyback wallet. Losses show up as slashed stake and burnt branches on the treasury's
///         own tree. Sweep, raise, reclaim and collect are permissionless; the owner only changes parameters.
contract TreasurySponsor is Ownable2Step, IERC721Receiver, EIP712 {
    using SafeERC20 for IERC20;

    /// @dev EIP-712: Invite(uint256 agentId,uint64 expiry). Bound to this contract and chain by the domain.
    bytes32 public constant INVITE_TYPEHASH = keccak256("Invite(uint256 agentId,uint64 expiry)");

    struct Rules {
        uint256 reserveBps; // share of each sweep that goes to the reserve; the rest is staked
        uint256 firstLine; // USDC, line for a brand-new identity
        uint256 secondLine; // USDC, line after a clean record
        uint256 epochCap; // USDC vouched per epoch, all agents combined
        uint64 epochLength; // seconds
        uint64 minSeasoning; // seconds enrolled before a raise
        uint256 minQualified; // qualified loans repaid before a raise
        uint256 minScore; // score before a raise
        uint64 idleAfter; // seconds without a loan or a repayment before a line can be reclaimed
    }

    CreditPool public immutable pool;
    IERC20 public immutable asset;
    IERC8004Identity public immutable registry;
    IPonsFeeEscrow public immutable escrow; // may be zero on chains without Pons
    IPonsFactoryCreator public immutable factory;

    uint256 public agentId; // the treasury's own ERC-8004 identity, once adopted
    address public feeSink; // where collected sponsor fees go (the buyback wallet)
    Rules public rules;

    uint64 public epochStart;
    uint256 public vouchedThisEpoch;
    mapping(uint256 => bool) public firstLined;
    mapping(address => bool) public inviters; // keys whose signature seats an agent
    mapping(uint256 => uint64) public lastActive; // last time reclaim() saw the agent use its line
    mapping(uint256 => uint256) public seenRepaid; // loansRepaid the last time reclaim() looked
    mapping(bytes32 => bool) public inviteUsed; // a signed invite seats an agent once, reopening included
    uint256 public pendingStake; // asset already split for stake but not yet staked (no identity, or below minStake)

    uint256 public totalToReserve;
    uint256 public totalStaked;
    uint256 public totalCollected;

    event Adopted(uint256 indexed agentId);
    event Swept(address indexed caller, uint256 claimed, uint256 toReserve, uint256 toStake);
    event FirstLine(uint256 indexed agentId, uint256 amount, address indexed caller);
    event Invited(uint256 indexed agentId, address indexed inviter, uint64 expiry);
    event InviterSet(address indexed inviter, bool allowed);
    event Raised(uint256 indexed agentId, uint256 added, uint256 lineNow);
    event Reclaimed(uint256 indexed agentId, uint256 amount, address indexed caller);
    event Collected(uint256 amount, address indexed to);
    event RulesUpdated(Rules rules);
    event FeeSinkUpdated(address indexed feeSink);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error NotAdopted();
    error NotOurs(uint256 agentId);
    error AlreadyLined(uint256 agentId);
    error AlreadyEnrolled(uint256 agentId);
    error NotEligible(uint256 agentId);
    error EpochCapReached(uint256 wanted, uint256 left);
    error NotController(uint256 agentId, address caller);
    error NotInvited(uint256 agentId, address signer);
    error InviteExpired(uint256 agentId, uint64 expiry);
    error InviteUsed(uint256 agentId);
    error NotIdle(uint256 agentId, uint256 reclaimableAt);
    error NothingToReclaim(uint256 agentId);
    error InvalidRules();

    constructor(
        CreditPool pool_,
        IPonsFeeEscrow escrow_,
        IPonsFactoryCreator factory_,
        address owner_,
        address feeSink_
    ) Ownable(owner_) EIP712("Priors Treasury", "3") {
        pool = pool_;
        asset = pool_.usdc();
        registry = pool_.registry();
        escrow = escrow_;
        factory = factory_;
        feeSink = feeSink_ == address(0) ? owner_ : feeSink_;
        rules = Rules({
            reserveBps: 5000,
            firstLine: 5e6,
            secondLine: 50e6,
            epochCap: 100e6,
            epochLength: 7 days,
            minSeasoning: 14 days,
            minQualified: 3,
            minScore: 100,
            idleAfter: 30 days
        });
        epochStart = uint64(block.timestamp);
        asset.approve(address(pool_), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Identity
    // ------------------------------------------------------------------

    /// @notice Bind the treasury to an ERC-8004 identity it owns. Register one, transfer it here, then adopt.
    function adopt(uint256 id) external onlyOwner {
        if (registry.ownerOf(id) != address(this)) revert NotOurs(id);
        agentId = id;
        emit Adopted(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------
    // Money in: creator fees -> reserve + stake
    // ------------------------------------------------------------------

    /// @notice Claim what the Pons escrow owes in the pool asset, then split everything held here: a share to
    ///         the reserve, the rest staked as this sponsor's capacity. Permissionless.
    function sweep() external returns (uint256 toReserve, uint256 toStake) {
        uint256 claimed;
        if (address(escrow) != address(0)) {
            claimed = escrow.balanceOfToken(address(this), address(asset));
            if (claimed > 0) escrow.claimToken(address(asset));
        }
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) {
            emit Swept(msg.sender, claimed, 0, 0);
            return (0, 0);
        }
        /* Only money that arrived since the last sweep is split. The stake share of an earlier sweep that
           could not be staked yet (no identity adopted, or below the pool's minimum) waits here as
           `pendingStake`, and a second sweep must not carve the reserve share out of it again: with a
           permissionless sweep, that would let anyone move the whole stake share into the reserve one
           call at a time, and keep small deposits from ever adding up to an initial stake. */
        uint256 fresh = bal > pendingStake ? bal - pendingStake : 0;
        toReserve = fresh * rules.reserveBps / 10_000;
        toStake = bal - toReserve;
        if (toReserve > 0) {
            pool.fundReserve(toReserve);
            totalToReserve += toReserve;
        }
        if (toStake > 0) {
            bool staked;
            if (agentId == 0) {
                staked = false; // nothing to stake under yet; held until adopted
            } else if (!pool.creditReport(agentId).enrolled) {
                staked = toStake >= pool.getParams().minStake;
                if (staked) pool.enrollRoot(agentId, toStake);
            } else {
                pool.addStake(agentId, toStake);
                staked = true;
            }
            if (staked) {
                totalStaked += toStake;
                pendingStake = 0;
            } else {
                pendingStake = toStake;
                toStake = 0;
            }
        }
        emit Swept(msg.sender, claimed, toReserve, toStake);
    }

    /// @notice What a sweep would move right now.
    function sweepable() external view returns (uint256) {
        uint256 c = address(escrow) != address(0) ? escrow.balanceOfToken(address(this), address(asset)) : 0;
        return c + asset.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Vouching by rule
    // ------------------------------------------------------------------

    /// @notice Give a never-enrolled ERC-8004 identity its first line. Two people have to agree: the identity's
    ///         owner or pool delegate calls, and an inviter the owner named has signed
    ///         `Invite(agentId, expiry)` for it. Without the invite there is no line, whatever the caller does.
    ///
    ///         A seat that `reclaim()` took back can be reopened the same way, with a new invite: the
    ///         identity keeps its record, but the treasury's money goes back behind it only on a person's
    ///         fresh decision. An invite seats an agent once; the same signature cannot reopen it later.
    function firstLine(uint256 id, uint64 expiry, bytes calldata invite) external {
        if (agentId == 0) revert NotAdopted();
        if (!pool.isController(id, msg.sender)) revert NotController(id, msg.sender);
        CreditPool.CreditReport memory r = pool.creditReport(id);
        bool reopening = r.enrolled && r.sponsor == agentId && r.delegatedIn == 0 && r.activeLoans == 0 && !r.defaulted;
        if (firstLined[id] && !reopening) revert AlreadyLined(id);
        if (r.enrolled && !reopening) revert AlreadyEnrolled(id);
        if (block.timestamp > expiry) revert InviteExpired(id, expiry);
        bytes32 digest = inviteDigest(id, expiry);
        if (inviteUsed[digest]) revert InviteUsed(id);
        address signer = ECDSA.recover(digest, invite);
        if (!inviters[signer]) revert NotInvited(id, signer);
        inviteUsed[digest] = true;
        _spend(rules.firstLine);
        firstLined[id] = true;
        lastActive[id] = uint64(block.timestamp);
        seenRepaid[id] = r.loansRepaid;
        pool.vouch(agentId, id, rules.firstLine);
        emit Invited(id, signer, expiry);
        emit FirstLine(id, rules.firstLine, msg.sender);
    }

    /// @notice The EIP-712 digest an inviter signs to seat `id` until `expiry`. Off-chain signers use the same
    ///         domain: name "Priors Treasury", version "3", this chain, this contract.
    function inviteDigest(uint256 id, uint64 expiry) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(INVITE_TYPEHASH, id, expiry)));
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Take back the line of a treasury-sponsored agent that has not borrowed or repaid for
    ///         `idleAfter`. Anyone can call it; the capacity returns to the treasury's free stake.
    ///
    ///         The pool does not record when an agent last moved, so this keeps its own watermark: a call
    ///         that finds an open loan, or more repayments than it saw last time, refreshes the watermark and
    ///         returns 0. A line is only taken once two looks, `idleAfter` apart, saw nothing happen between
    ///         them - so an agent that used its line always gets at least `idleAfter` of grace from the first
    ///         look, and a reclaimed identity keeps its record and its earned capacity; only the vouch goes.
    function reclaim(uint256 id) external returns (uint256 amount) {
        if (agentId == 0) revert NotAdopted();
        CreditPool.CreditReport memory r = pool.creditReport(id);
        if (!r.enrolled || r.sponsor != agentId || r.defaulted || r.delegatedIn == 0) revert NothingToReclaim(id);
        if (r.activeLoans > 0 || r.loansRepaid != seenRepaid[id]) {
            seenRepaid[id] = r.loansRepaid;
            lastActive[id] = uint64(block.timestamp);
            return 0;
        }
        uint256 at = uint256(lastActive[id]) + rules.idleAfter;
        if (block.timestamp < at) revert NotIdle(id, at);
        amount = r.delegatedIn;
        pool.unvouch(agentId, id, amount);
        emit Reclaimed(id, amount, msg.sender);
    }

    /// @notice When `reclaim(id)` would succeed if nothing else happens: 0 if the line is not the treasury's
    ///         or the agent has moved since the last look (a look is needed first).
    function reclaimableAt(uint256 id) external view returns (uint256) {
        CreditPool.CreditReport memory r = pool.creditReport(id);
        if (!r.enrolled || r.sponsor != agentId || r.defaulted || r.delegatedIn == 0) return 0;
        if (r.activeLoans > 0 || r.loansRepaid != seenRepaid[id]) return 0;
        return uint256(lastActive[id]) + rules.idleAfter;
    }

    /// @notice Raise the line of an agent this treasury sponsors, once its record qualifies. Anyone can call it.
    ///         Only an open seat is raised: a line that `reclaim()` took back stays closed until a fresh
    ///         invite reopens it, so nobody can alternate reclaim and raise to burn the epoch's budget. A
    ///         raise counts as activity, so the bigger line gets its own `idleAfter` before it can be reclaimed.
    function raise(uint256 id) external {
        if (agentId == 0) revert NotAdopted();
        CreditPool.CreditReport memory r = pool.creditReport(id);
        if (!eligibleForRaise(r)) revert NotEligible(id);
        uint256 add = rules.secondLine - r.delegatedIn;
        _spend(add);
        lastActive[id] = uint64(block.timestamp);
        seenRepaid[id] = r.loansRepaid;
        pool.vouch(agentId, id, add);
        emit Raised(id, add, r.delegatedIn + add);
    }

    function eligibleForRaise(CreditPool.CreditReport memory r) public view returns (bool) {
        return r.enrolled && !r.defaulted && r.sponsor == agentId && r.childrenDefaulted == 0
            && r.qualifiedRepaid >= rules.minQualified && r.score >= rules.minScore
            && block.timestamp >= uint256(r.enrolledAt) + rules.minSeasoning && r.delegatedIn > 0
            && r.delegatedIn < rules.secondLine;
    }

    /// @notice How much the treasury may still vouch this epoch.
    function epochRoom() public view returns (uint256) {
        uint256 used = block.timestamp >= epochStart + rules.epochLength ? 0 : vouchedThisEpoch;
        return rules.epochCap > used ? rules.epochCap - used : 0;
    }

    function _spend(uint256 amount) internal {
        if (block.timestamp >= epochStart + rules.epochLength) {
            epochStart = uint64(block.timestamp);
            vouchedThisEpoch = 0;
        }
        uint256 left = rules.epochCap > vouchedThisEpoch ? rules.epochCap - vouchedThisEpoch : 0;
        if (amount > left) revert EpochCapReached(amount, left);
        vouchedThisEpoch += amount;
    }

    // ------------------------------------------------------------------
    // Money out: sponsor fees -> buyback wallet
    // ------------------------------------------------------------------

    /// @notice Collect the sponsor fees the treasury's agents have paid and send them to the fee sink.
    function collect() external returns (uint256 amount) {
        if (agentId == 0) revert NotAdopted();
        amount = pool.claimSponsorFees(agentId, feeSink);
        totalCollected += amount;
        emit Collected(amount, feeSink);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function setRules(Rules calldata r) external onlyOwner {
        if (
            r.reserveBps > 10_000 || r.epochLength == 0 || r.firstLine == 0 || r.secondLine < r.firstLine
                || r.idleAfter == 0
        ) revert InvalidRules();
        rules = r;
        emit RulesUpdated(r);
    }

    /// @notice Name or revoke a key whose signed invites seat agents.
    function setInviter(address who, bool allowed) external onlyOwner {
        inviters[who] = allowed;
        emit InviterSet(who, allowed);
    }

    function setFeeSink(address sink) external onlyOwner {
        feeSink = sink;
        emit FeeSinkUpdated(sink);
    }

    /// @notice Pull back stake that is not backing anything.
    function retire(uint256 amount, address to) external onlyOwner {
        pool.withdrawStake(agentId, amount, to);
    }

    /// @notice Redirect the launch token's future creator fees elsewhere. Claim first.
    function transferCreatorFeeRecipient(address launchToken, address newRecipient) external onlyOwner {
        factory.transferCreatorFeeRecipient(launchToken, newRecipient);
    }

    /// @notice Withdraw any other asset the escrow credited here (ETH, vested launch tokens).
    function rescue(address token, address to) external onlyOwner {
        if (token == address(0)) {
            if (address(escrow) != address(0) && escrow.balanceOf(address(this)) > 0) escrow.claim();
            uint256 bal = address(this).balance;
            (bool ok,) = to.call{value: bal}("");
            require(ok, "eth transfer failed");
            emit Rescued(address(0), to, bal);
        } else {
            require(token != address(asset), "use sweep");
            if (address(escrow) != address(0) && escrow.balanceOfToken(address(this), token) > 0) {
                escrow.claimToken(token);
            }
            uint256 bal = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, bal);
            emit Rescued(token, to, bal);
        }
    }

    receive() external payable {}
}
