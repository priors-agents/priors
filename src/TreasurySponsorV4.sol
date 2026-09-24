// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CreditPoolV2} from "./CreditPoolV2.sol";
import {ScoreLib} from "./libraries/ScoreLib.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "./interfaces/IPonsFeeEscrow.sol";

/// @title TreasurySponsorV4
/// @notice Treasury v3's rules on CreditPoolV2. Creator fees the project token earns on Pons land here; a sweep
///         sends a share to the pool's reserve and stakes the rest as pool shares under the treasury's own
///         ERC-8004 identity, a root backer. The treasury holds that identity's NFT, so it is the only caller
///         of the pool's owner-only root functions (vouchWithConsent, vouch, unvouch, freeze, unlock,
///         claimSponsorFees) for it. From that stake it vouches by rule, not by judgement:
///
///           firstLine(agent)  a small first line, only with TWO signatures: an invite from an inviter the
///                             owner named (EIP-712, "Priors Treasury" version "4"), and the agent owner's
///                             pool consent. Anyone may submit them (a relayer, the invite bot, the owner),
///                             so it is one signature for the agent's owner. Registration is permissionless;
///                             treasury money is not.
///           raise(agent)      a seasoned, clean line the treasury backs is topped up to the second tier.
///           reclaim(agent)    a line nobody has borrowed or repaid on for `idleAfter` goes back to the
///                             treasury, so the capacity seats the next agent instead of a dead identity.
///
///         What v2 changes:
///           - Every line is 100% the treasury's own stake (no earned credit), and a default burns the
///             treasury's shares worth the principal. Lenders never take a loss. So a raise is simply a
///             top-up vouch out of the treasury's own free backing, and the epoch cap bounds how much new
///             exposure the rules can open per epoch, first lines and raises combined.
///           - Reclaim reads the pool's own `lastBorrowAt`/`lastRepayAt`, so v3's two-look watermark is gone.
///             An open loan always counts as activity.
///           - Imported v1 agents may be invited (v3 refused any identity the pool already knew); an agent
///             whose v1 record was protocol-seeded is flagged by the owner and never raised by rule.
///           - Premium is 0: treasury lines cost the base fee only.
///
///         Kept from the v3 audit: a raise only tops up a line that is open right now (a reclaimed seat stays
///         closed until a fresh invite reopens it, so reclaim/raise cannot be alternated to burn the epoch's
///         budget), an invite seats an agent once (inviteUsed by digest), and a sweep never splits a waiting
///         stake share again.
///
///         Sweep, raise, reclaim and collect are permissionless. The owner changes parameters, names inviters,
///         can freeze a treasury line (wind-down: new borrows stop and the line comes back as its loans close),
///         and pulls back stake that backs nothing. The stake's lender yield compounds into the treasury's
///         backing; sponsor fees go to the fee sink (the buyback wallet).
contract TreasurySponsorV4 is Ownable2Step, IERC721Receiver, EIP712 {
    using SafeERC20 for IERC20;

    /// @dev EIP-712: Invite(uint256 agentId,uint64 expiry). Bound to this contract and chain by the domain.
    bytes32 public constant INVITE_TYPEHASH = keccak256("Invite(uint256 agentId,uint64 expiry)");
    uint64 public constant MAX_EPOCH = 365 days;

    struct Rules {
        uint256 reserveBps; // share of each sweep that goes to the reserve; the rest is staked
        uint256 firstLine; // USDG, line for an invited identity
        uint256 secondLine; // USDG, line after a clean record
        uint256 epochCap; // USDG vouched per epoch (first lines and raises combined)
        uint64 epochLength; // seconds
        uint64 minSeasoning; // seconds since enrollment before a raise
        uint256 minQualified; // qualified loans repaid before a raise
        uint256 minScore; // score before a raise
        uint64 idleAfter; // seconds without a borrow, a repayment or a line change before a line can be reclaimed
    }

    CreditPoolV2 public immutable pool;
    IERC20 public immutable asset;
    IERC8004Identity public immutable registry;
    IPonsFeeEscrow public immutable escrow; // may be zero on chains without Pons
    IPonsFactoryCreator public immutable factory;

    uint256 public agentId; // the treasury's own ERC-8004 identity (its root), once adopted
    address public feeSink; // where collected sponsor fees go (the buyback wallet)
    Rules public rules;

    uint64 public epochStart;
    uint256 public vouchedThisEpoch;
    mapping(address => bool) public inviters; // keys whose signature seats an agent
    mapping(bytes32 => bool) public inviteUsed; // a signed invite seats an agent once, reopening included
    mapping(uint256 => bool) public firstLined; // ever lined by this treasury
    mapping(uint256 => uint64) public lineAt; // when the line was last opened or raised (activity for reclaim)
    mapping(uint256 => bool) public seeded; // protocol-seeded v1 record: never raised by rule
    uint256 public pendingStake; // asset already split for stake but not yet staked

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
    event SeededSet(uint256 indexed agentId, bool seeded);
    event Retired(uint256 shares, uint256 assets, address indexed to);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error NotAdopted();
    error AlreadyAdopted();
    error NotOurs(uint256 agentId);
    error AlreadyLined(uint256 agentId);
    error NotEligible(uint256 agentId);
    error OwnerDefaulted(address owner);
    error EpochCapReached(uint256 wanted, uint256 left);
    error NotInvited(uint256 agentId, address signer);
    error InviteExpired(uint256 agentId, uint64 expiry);
    error InviteUsed(uint256 agentId);
    error NotIdle(uint256 agentId, uint256 reclaimableAt);
    error LoanOpen(uint256 agentId);
    error NothingToReclaim(uint256 agentId);
    error InvalidRules();
    error InvalidAddress();
    error UseSweep();
    error TransferFailed();

    constructor(
        CreditPoolV2 pool_,
        IPonsFeeEscrow escrow_,
        IPonsFactoryCreator factory_,
        address owner_,
        address feeSink_
    ) Ownable(owner_) EIP712("Priors Treasury", "4") {
        pool = pool_;
        asset = pool_.usdg();
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
        asset.forceApprove(address(pool_), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Identity
    // ------------------------------------------------------------------

    /// @notice Bind the treasury to a fresh ERC-8004 identity it owns: register one, transfer it here, adopt.
    ///         Once only; the identity becomes a root on the first sweep that meets the pool's minimum stake.
    function adopt(uint256 id) external onlyOwner {
        if (agentId != 0) revert AlreadyAdopted();
        if (registry.ownerOf(id) != address(this)) revert NotOurs(id);
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.enrolledAt != 0 || a.isRoot) revert NotOurs(id); // fresh: no record, no hook, no line
        agentId = id;
        emit Adopted(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------
    // Money in: creator fees -> reserve + stake
    // ------------------------------------------------------------------

    /// @notice Claim what the Pons escrow owes in the pool asset, then split what arrived since the last sweep:
    ///         a share to the reserve, the rest staked as pool shares behind the treasury's root. Permissionless.
    ///         The stake share waits here as `pendingStake` while there is no identity, the pool is paused, or
    ///         it is below the pool's minimum stake (first enrollment) or too small to mint a share.
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
        /* Only money that arrived since the last sweep is split (v3 audit): the waiting stake share must not
           have the reserve share carved out of it again by a permissionless sweep. */
        uint256 fresh = bal > pendingStake ? bal - pendingStake : 0;
        toReserve = fresh * rules.reserveBps / 10_000;
        toStake = bal - toReserve;
        if (toReserve > 0) {
            pool.fundReserve(toReserve); // never paused
            totalToReserve += toReserve;
        }
        if (toStake > 0) {
            bool staked;
            if (agentId != 0 && block.timestamp >= pool.pausedUntil() && pool.convertToShares(toStake) > 0) {
                if (!pool.getAgent(agentId).isRoot) {
                    if (toStake >= pool.getParams().minStake) {
                        pool.enrollRoot(agentId, toStake);
                        staked = true;
                    }
                } else {
                    pool.addStake(agentId, toStake);
                    staked = true;
                }
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

    /// @notice Open a first line behind `id`. Two people have agreed: an inviter the owner named signed
    ///         `Invite(id, expiry)`, and the agent's NFT owner signed the pool consent `c` naming this treasury's
    ///         root (EIP-712 on the pool; EIP-1271 for a contract owner). Anyone may submit both, so the agent's
    ///         owner signs once and a relayer pays the gas. The consent is forwarded to the pool as is.
    ///
    ///         Any identity that is not a root, has never defaulted (here or on v1) and is not already on a
    ///         treasury line qualifies, including agents imported from v1 and agents whose line was reclaimed.
    ///         An agent sponsored elsewhere with no loan open moves over (the pool's handoff). An invite seats
    ///         an agent once: reopening a reclaimed seat needs a fresh invite.
    function firstLine(
        uint256 id,
        uint64 expiry,
        bytes calldata invite,
        CreditPoolV2.Consent calldata c,
        bytes calldata consentSig
    ) external {
        uint256 root = agentId;
        if (root == 0) revert NotAdopted();
        if (pool.getAgent(id).sponsor == root) revert AlreadyLined(id);
        if (block.timestamp > expiry) revert InviteExpired(id, expiry);
        bytes32 digest = inviteDigest(id, expiry);
        if (inviteUsed[digest]) revert InviteUsed(id);
        address signer = ECDSA.recover(digest, invite);
        if (!inviters[signer]) revert NotInvited(id, signer);
        // an owner a default marked cannot borrow: a line behind it would only sit idle on the budget
        if (pool.ownerDefaults(c.owner) != 0 && !pool.custodian(c.owner)) revert OwnerDefaulted(c.owner);
        inviteUsed[digest] = true;
        uint256 line = rules.firstLine;
        _spend(line);
        firstLined[id] = true;
        lineAt[id] = uint64(block.timestamp);
        pool.vouchWithConsent(root, id, line, 0, c, consentSig);
        emit Invited(id, signer, expiry);
        emit FirstLine(id, line, msg.sender);
    }

    /// @notice The EIP-712 digest an inviter signs to seat `id` until `expiry`. Off-chain signers use the same
    ///         domain: name "Priors Treasury", version "4", this chain, this contract.
    function inviteDigest(uint256 id, uint64 expiry) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(INVITE_TYPEHASH, id, expiry)));
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Take back the line of a treasury agent with no loan open that has not borrowed, repaid, or had its
    ///         line opened or raised for `idleAfter`. Anyone. The whole line goes back to the treasury's free
    ///         backing and the sponsorship ends; the identity keeps its record and may be invited again.
    function reclaim(uint256 id) external returns (uint256 amount) {
        uint256 root = agentId;
        if (root == 0) revert NotAdopted();
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.sponsor != root || a.defaulted || a.delegatedIn == 0) revert NothingToReclaim(id);
        if (a.activeLoans != 0) revert LoanOpen(id); // an open loan is activity; a frozen line comes back by itself
        uint256 at = _idleSince(id, a) + rules.idleAfter;
        if (block.timestamp < at) revert NotIdle(id, at);
        amount = a.delegatedIn;
        pool.unvouch(root, id, amount);
        emit Reclaimed(id, amount, msg.sender);
    }

    /// @notice When `reclaim(id)` succeeds if nothing else happens; 0 if there is nothing to reclaim or a loan is
    ///         open.
    function reclaimableAt(uint256 id) external view returns (uint256) {
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (agentId == 0 || a.sponsor != agentId || a.defaulted || a.delegatedIn == 0 || a.activeLoans != 0) {
            return 0;
        }
        return _idleSince(id, a) + rules.idleAfter;
    }

    function _idleSince(uint256 id, CreditPoolV2.Agent memory a) internal view returns (uint256 t) {
        t = lineAt[id];
        if (a.lastBorrowAt > t) t = a.lastBorrowAt;
        if (a.lastRepayAt > t) t = a.lastRepayAt;
    }

    /// @notice Top up the line of an agent this treasury backs to the second tier, once its record qualifies.
    ///         Anyone. The top-up is the treasury's own stake, like the first line, and it is charged to the
    ///         epoch cap. Only a line open right now (not frozen) is raised, so a reclaimed seat stays closed
    ///         until a fresh invite reopens it. A raise counts as activity for `reclaim`.
    function raise(uint256 id) external {
        if (!eligibleForRaise(id)) revert NotEligible(id);
        uint256 lineNow = pool.getAgent(id).delegatedIn;
        uint256 add = rules.secondLine - lineNow;
        _spend(add);
        lineAt[id] = uint64(block.timestamp);
        pool.vouch(agentId, id, add);
        emit Raised(id, add, lineNow + add);
    }

    /// @notice Whether `raise(id)` would pass the record checks now (it still needs epoch room and free backing).
    function eligibleForRaise(uint256 id) public view returns (bool) {
        uint256 root = agentId;
        if (root == 0 || seeded[id]) return false;
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (
            a.sponsor != root || a.defaulted || a.frozen || a.childrenDefaulted != 0 || a.delegatedIn == 0
                || a.delegatedIn >= rules.secondLine || a.qualifiedRepaid < rules.minQualified
                || block.timestamp < uint256(a.enrolledAt) + rules.minSeasoning || _score(a) < rules.minScore
        ) return false;
        address o = registry.ownerOf(id);
        return pool.ownerDefaults(o) == 0 || pool.custodian(o);
    }

    /// @notice The v1 score, computed from the pool's v2 record (the same formula as CreditLensV2).
    function score(uint256 id) external view returns (uint256) {
        return _score(pool.getAgent(id));
    }

    function _score(CreditPoolV2.Agent memory a) internal view returns (uint256) {
        if (a.enrolledAt == 0) return 0;
        return ScoreLib.score(
            ScoreLib.Inputs({
                defaulted: a.defaulted,
                qualifiedRepaid: a.qualifiedRepaid,
                dollarSecondsRepaid: a.dollarSecondsRepaid,
                backing: a.delegatedIn,
                recourseHonored: a.recourseHonored,
                childrenDefaulted: a.childrenDefaulted,
                ageSeconds: block.timestamp - a.enrolledAt
            })
        );
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

    /// @notice Send the sponsor fees the treasury's agents have paid to the fee sink. Anyone; 0 if none.
    function collect() external returns (uint256 amount) {
        uint256 root = agentId;
        if (root == 0) revert NotAdopted();
        if (pool.sponsorFees(root) == 0) return 0;
        amount = pool.claimSponsorFees(root, feeSink);
        totalCollected += amount;
        emit Collected(amount, feeSink);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function setRules(Rules calldata r) external onlyOwner {
        if (
            r.reserveBps > 10_000 || r.epochLength == 0 || r.epochLength > MAX_EPOCH || r.firstLine == 0
                || r.secondLine < r.firstLine || r.idleAfter == 0
        ) revert InvalidRules();
        rules = r;
        emit RulesUpdated(r);
    }

    /// @notice Name or revoke a key whose signed invites seat agents. A revoked key's invites stop at once.
    function setInviter(address who, bool allowed) external onlyOwner {
        inviters[who] = allowed;
        emit InviterSet(who, allowed);
    }

    function setFeeSink(address sink) external onlyOwner {
        if (sink == address(0)) revert InvalidAddress();
        feeSink = sink;
        emit FeeSinkUpdated(sink);
    }

    /// @notice Flag agents whose v1 volume the protocol seeded: they may still be invited, never raised by rule.
    function setSeeded(uint256[] calldata ids, bool flag) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) {
            seeded[ids[i]] = flag;
            emit SeededSet(ids[i], flag);
        }
    }

    /// @notice Stop (or restart) new borrows on a treasury line. Loans out run to term; the pool hands the line
    ///         back as they close. The wind-down path: freeze every line, then `retire` as backing frees up.
    function freeze(uint256 id, bool frozen) external onlyOwner {
        pool.freeze(id, frozen);
    }

    /// @notice Unlock pool shares of the treasury's stake that back nothing, as cash (principal plus the lender
    ///         yield they earned). The pool refuses anything that would leave a line unbacked.
    function retire(uint256 shares, address to) external onlyOwner returns (uint256 assets) {
        assets = pool.unlock(agentId, shares, to);
        emit Retired(shares, assets, to);
    }

    /// @notice Redirect the launch token's future creator fees elsewhere. Claim first.
    function transferCreatorFeeRecipient(address launchToken, address newRecipient) external onlyOwner {
        factory.transferCreatorFeeRecipient(launchToken, newRecipient);
    }

    /// @notice Withdraw any other asset the escrow credited here (ETH, vested launch tokens). The pool asset only
    ///         ever leaves through `sweep`.
    function rescue(address token, address to) external onlyOwner {
        if (token == address(0)) {
            if (address(escrow) != address(0) && escrow.balanceOf(address(this)) > 0) escrow.claim();
            uint256 bal = address(this).balance;
            (bool ok,) = to.call{value: bal}("");
            if (!ok) revert TransferFailed();
            emit Rescued(address(0), to, bal);
        } else {
            if (token == address(asset)) revert UseSweep();
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
