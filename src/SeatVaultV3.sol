// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {CreditPoolV2, IBackerHook} from "./CreditPoolV2.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";

interface ISeatToken {
    function burn(uint256 amount) external;
}

interface IIdentityMint {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title SeatVaultV3
/// @notice $PRIORS seats on CreditPoolV2. A staker puts a seat's worth of $PRIORS behind an agent; the vault, a
///         root backer that holds its own ERC-8004 identity and its own USDG stake as pool shares, vouches that
///         agent a small line. The tokens are the agent's collateral for exactly as long as the line is open.
///
///           offer(agent)             a staker escrows a seat under the vault's current terms (line, burn share).
///           accept(agent, s, c, sig) the agent's owner or pool delegate takes staker `s`'s offer and forwards the
///                                    owner's signed pool consent: nobody is seated without saying yes.
///           close(agent)             staker or controller: the vault freezes the line. With no loan open the
///                                    seat closes at once; otherwise new borrows stop and the seat closes the
///                                    moment the last loan is repaid. Every token goes back to the staker.
///           graduation               the agent leaves, or hands off to another backer (both only with no loan
///                                    open): the pool tells the vault (onRelease) and the seat closes in the same
///                                    transaction, every token back to the staker.
///           default                  the pool tells the vault (onDefault) and the seat settles in the same
///                                    transaction: `burnBps` of it is burnt, the rest goes back. A seat whose
///                                    agent defaulted is never treated as a graduation.
///           settle(agent, loanId)    the manual path for any of the above, if a hook call ever failed.
///
///         Fees: the staker earns the sponsor share of every fee its agent pays while seated, read exactly from
///         the pool's per-agent ledger (`feesFrom[vault][agent]`), whatever the pool's fee split does meanwhile.
///         The premium is 0. Fees paid on a defaulted agent's leftover loans after its seat settled go to the fee
///         sink with any other surplus.
///
///         Who carries what: the vault funder's USDG (the root's stake, held as pool shares) backs every seated
///         line 100%; a default is paid from it, so the funder carries the credit risk, and lenders never do. The
///         stake earns the pool's lender yield, which compounds into the vault's backing and belongs to the
///         funder: the owner takes free backing out with `retire` (the pool refuses anything that would leave a
///         line unbacked). Stakers earn the sponsor fees and risk `burnBps` of their seat; the burn is the
///         deterrent that makes a seat worth more intact than a stolen line. The owner can never move a
///         staker's tokens or fees.
///
///         What v2 removed from v1's known limits: the squat (a line needs the agent owner's consent), the
///         forever-sponsor (handoff), the rolling-loan lock (close freezes the line), approximate fees (exact per
///         agent), manual settlement (hooks).
///
///         What v3 changes from v2 (audit V-2, "the levers and ownership do not reach open seats"), and nothing
///         else:
///           - the pause and a repricing reach open seats: `canBorrow` refuses a new loan while seats are paused,
///             or on a seat whose size, burn share or line no longer meets the vault's current terms. Loans
///             already open are untouched, and closing, settling and claiming always work.
///           - a seat is bound to the owner who accepted it: `canBorrow` refuses a loan once the agent has changed
///             hands, and anyone may then `close` the seat, every token back to the staker. The staker trusted
///             an owner, not an id (v2 bound offers only, audit X-1).
///           - `freezeSeat` lets the owner (the Safe) close any open seat, as the staker could: the line freezes
///             and the seat closes when its last loan does, every token back. It can evict a seat that squats
///             capacity; it can never burn or keep a staker's tokens.
contract SeatVaultV3 is Ownable2Step, IERC721Receiver, IERC1271, IBackerHook {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    uint256 public constant MAX_OPEN_SEATS = 200; // bounds the loop in skim()
    uint256 public constant MIN_BURN_BPS = 2500; // a default always costs at least a quarter of the seat
    uint64 public constant MAX_EPOCH = 365 days;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 internal constant MAGIC_1271 = 0x1626ba7e;
    bytes32 internal constant LOCK = keccak256("priors.seatvault.v3.lock");
    bytes32 internal constant CONSENT = keccak256("priors.seatvault.v3.consent");

    enum Status {
        None,
        Open,
        Closed,
        Settled
    }

    struct Params {
        uint256 seatSize; // $PRIORS a seat must hold
        uint256 line; // USDG the vault vouches behind a seated agent
        uint256 burnBps; // share of the seat burnt if the agent defaults
        uint256 maxOpenSeats; // open seats at once
        uint256 epochCap; // USDG of new lines per epoch, all seats combined
        uint64 epochLength; // seconds
    }

    struct Terms {
        uint128 line;
        uint128 burnBps;
        address owner; // the agent's owner when the offer was made: the staker trusted this address, not the id
    }

    struct Seat {
        address staker;
        uint64 openedAt;
        bool closing; // the line is frozen; the seat closes when the last loan does
        Status status;
        uint128 line; // fixed at opening
        uint128 burnBps; // fixed at opening
        uint256 amount; // $PRIORS held for this seat
        uint256 feeMark; // feesFrom[vault][agent] already credited to this seat's staker
        address owner; // the agent's owner when the seat opened: loans stop if the agent changes hands (V-2)
    }

    CreditPoolV2 public immutable pool;
    IERC20 public immutable usdg;
    IERC20 public immutable token; // $PRIORS
    IERC8004Identity public immutable registry;

    uint256 public agentId; // the vault's own ERC-8004 identity (its root), once adopted
    address public feeSink; // where fees owed to no staker go (the buyback wallet)
    bool public seatsPaused; // stops new offers and new seats; closing, settling and claiming always work
    Params public params;

    uint64 public epochStart;
    uint256 public linedThisEpoch;

    /// @notice Loans an agent must already have repaid (its pool record, v1 history included) before a seat can
    ///         back it. $PRIORS has no market price, so a seat's burn can be worth nothing; this is what stops a
    ///         fresh identity from being seated, drawn and walked away from (audit X-3). 0 disables the gate.
    uint256 public minRepaid;
    /// @notice A seat whose agent has not borrowed for this long (and has no loan open) can be closed by anyone,
    ///         every token back, so idle seats cannot hold the vault's slots and backing forever (audit X-2).
    ///         0 disables expiry.
    uint64 public idleAfter;

    mapping(uint256 => Seat) public seats; // agentId => its current (or last) seat
    mapping(uint256 => mapping(address => uint256)) public offers; // agentId => staker => $PRIORS escrowed
    mapping(uint256 => mapping(address => Terms)) public offerTerms; // the terms each offer was made under
    mapping(address => uint256) public feesOwed; // staker => USDG credited, not yet claimed

    uint256[] internal _open; // agent ids with an open seat
    mapping(uint256 => uint256) internal _openIndex; // agentId => index in _open, plus one

    uint256 public tokensHeld; // $PRIORS owed back to stakers: open seats plus pending offers
    uint256 public totalFeesOwed; // USDG credited to stakers, not yet claimed
    uint256 public totalBurnt;
    uint256 public totalFunded; // USDG ever staked through fund() (not net of retire or slashing)

    event Adopted(uint256 indexed agentId);
    event Funded(address indexed from, uint256 amount);
    event Retired(uint256 shares, uint256 assets, address indexed to);
    event Offered(uint256 indexed agentId, address indexed staker, uint256 amount);
    event OfferWithdrawn(uint256 indexed agentId, address indexed staker, uint256 amount, address indexed by);
    event SeatOpened(uint256 indexed agentId, address indexed staker, uint256 amount, uint256 line, uint256 burnBps);
    event CloseRequested(uint256 indexed agentId, address indexed by);
    event SeatClosed(uint256 indexed agentId, address indexed staker, uint256 returned);
    event SeatSettled(uint256 indexed agentId, address indexed staker, uint256 burnt, uint256 returned);
    event FeesCredited(uint256 indexed agentId, address indexed staker, uint256 amount);
    event FeesClaimed(address indexed staker, address indexed to, uint256 amount);
    event Skimmed(uint256 amount, address indexed to);
    event ParamsUpdated(Params params);
    event SeatsPaused(bool paused);
    event FeeSinkUpdated(address indexed feeSink);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event GatesUpdated(uint256 minRepaid, uint64 idleAfter);
    event SeatExpired(uint256 indexed agentId, address indexed by);
    event SeatFrozen(uint256 indexed agentId, address indexed by);

    error Reentrancy();
    error NotAdopted();
    error AlreadyAdopted();
    error NotOurs(uint256 agentId);
    error Paused();
    error ZeroAmount();
    error NotController(uint256 agentId, address caller);
    error NoOffer(uint256 agentId, address staker);
    error OfferExists(uint256 agentId, address staker);
    error OfferTooSmall(uint256 agentId, uint256 offered, uint256 seatSize);
    error TermsChanged(uint256 agentId);
    error NotSeatable(uint256 agentId);
    error NoOpenSeat(uint256 agentId);
    error NotStakerOrController(uint256 agentId, address caller);
    error AgentDefaulted(uint256 agentId);
    error StillBacked(uint256 agentId);
    error BadProof(uint256 agentId, uint256 loanId);
    error TooManySeats(uint256 open, uint256 max);
    error EpochCapReached(uint256 wanted, uint256 left);
    error BadTransfer(uint256 expected, uint256 received);
    error InvalidParams();
    error Protected(address token);
    error OwnerChanged(uint256 agentId, address offeredTo, address owner);
    error NotIdle(uint256 agentId);

    constructor(CreditPoolV2 pool_, IERC20 token_, address owner_, address feeSink_, Params memory p) Ownable(owner_) {
        pool = pool_;
        usdg = pool_.usdg();
        registry = pool_.registry();
        token = token_;
        if (address(token_) == address(0) || address(token_) == address(usdg)) revert InvalidParams();
        feeSink = feeSink_ == address(0) ? owner_ : feeSink_;
        _setParams(p);
        epochStart = uint64(block.timestamp);
        usdg.forceApprove(address(pool_), type(uint256).max);
    }

    /// @dev One lock for the entry points and for the hooks. A hook that arrives while the vault holds the lock
    ///      is a callback of the vault's own pool call (close freezing a line); it is skipped, and the function
    ///      that made the call reconciles the seat itself right after.
    modifier nonReentrant() {
        _enter();
        _;
        LOCK.asBoolean().tstore(false);
    }

    function _enter() internal {
        if (LOCK.asBoolean().tload()) revert Reentrancy();
        LOCK.asBoolean().tstore(true);
    }

    // ------------------------------------------------------------------
    // Identity and stake
    // ------------------------------------------------------------------

    /// @notice Bind the vault to a fresh ERC-8004 identity it owns: register one, transfer it here, adopt. Once.
    function adopt(uint256 id) external onlyOwner {
        if (agentId != 0) revert AlreadyAdopted();
        if (registry.ownerOf(id) != address(this)) revert NotOurs(id);
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.enrolledAt != 0 || a.isRoot) revert NotOurs(id); // fresh: it enrolls as a root on the first fund()
        agentId = id;
        emit Adopted(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Put USDG behind the vault's root as pool shares. Anyone may add; the first call must meet the
    ///         pool's minimum stake, enrolls the root and makes this vault its hook (immediate: nothing is
    ///         vouched yet). The stake is what seated lines stand on, and all a default can cost.
    function fund(uint256 amount) external nonReentrant {
        uint256 root = agentId;
        if (root == 0) revert NotAdopted();
        if (amount == 0) revert ZeroAmount();
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        if (pool.getAgent(root).isRoot) {
            pool.addStake(root, amount);
        } else {
            pool.enrollRoot(root, amount);
            pool.setHook(root, address(this));
        }
        totalFunded += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Take out stake shares that back nothing (principal plus the lender yield they earned), for the
    ///         funder. The pool refuses anything vouched to an open line.
    function retire(uint256 shares, address to) external onlyOwner nonReentrant returns (uint256 assets) {
        assets = pool.unlock(agentId, shares, to);
        emit Retired(shares, assets, to);
    }

    // ------------------------------------------------------------------
    // Seats
    // ------------------------------------------------------------------

    /// @notice Escrow a seat of $PRIORS for `id` under the vault's current terms. Nothing is vouched until the
    ///         agent's controller accepts. The staker can withdraw it, or the controller turn it down, until then.
    function offer(uint256 id) external nonReentrant {
        _offer(id, msg.sender);
    }

    /// @notice Take staker `staker`'s offer: the vault vouches the offer's line behind `id`, with the agent owner's
    ///         signed pool consent `c` (naming the vault's root, premium cap any: the vault charges none).
    ///         Only the agent's owner or pool delegate may call it, so a consent in the mempool cannot be
    ///         redirected to another staker's offer. An agent sponsored elsewhere with no loan open moves here.
    function accept(uint256 id, address staker, CreditPoolV2.Consent calldata c, bytes calldata sig)
        external
        nonReentrant
    {
        if (!pool.isController(id, msg.sender)) revert NotController(id, msg.sender);
        _openSeat(id, staker, c, sig);
    }

    /// @notice Offer and accept in one call: an agent's controller seating it with its own tokens.
    function seat(uint256 id, CreditPoolV2.Consent calldata c, bytes calldata sig) external nonReentrant {
        if (!pool.isController(id, msg.sender)) revert NotController(id, msg.sender);
        if (offers[id][msg.sender] == 0) _offer(id, msg.sender);
        _openSeat(id, msg.sender, c, sig);
    }

    /// @notice Register a new ERC-8004 identity, seat it with the caller's $PRIORS, and hand it to the caller, in
    ///         one transaction and with no signature to make.
    ///
    ///         The vault owns the new NFT while it seats it, so the pool's consent must come from the vault. It
    ///         gives it by EIP-1271: right before its own `vouchWithConsent` call it writes the exact consent
    ///         digest it built (this id, this vault's root, the vault as owner, premium cap 0, the current nonce,
    ///         deadline now) to transient storage, and `isValidSignature` approves only that digest; the slot is
    ///         cleared as the call returns. Nothing else is ever approved: not another id, not another sponsor,
    ///         not any digest outside this call. Nobody could vouch the new id in between anyway (that needs its
    ///         owner's consent), so this is a convenience, not a squat defence.
    function registerAndSeat(string calldata agentURI) external nonReentrant returns (uint256 id) {
        id = IIdentityMint(address(registry)).register(agentURI);
        if (registry.ownerOf(id) != address(this)) revert NotOurs(id);
        _offer(id, msg.sender);
        CreditPoolV2.Consent memory c = CreditPoolV2.Consent({
            agentId: id,
            sponsorId: agentId,
            owner: address(this),
            maxPremiumBps: 0,
            nonce: pool.nonces(id),
            deadline: block.timestamp
        });
        CONSENT.asBytes32().tstore(pool.consentDigest(c));
        _openSeat(id, msg.sender, c, "");
        CONSENT.asBytes32().tstore(bytes32(0));
        // the vault held the identity only to seat it: the seat belongs to the owner it is handed to now
        seats[id].owner = msg.sender;
        IIdentityMint(address(registry)).transferFrom(address(this), msg.sender, id);
    }

    /// @notice EIP-1271: the vault approves exactly one digest, the consent registerAndSeat is using right now.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        bytes32 approved = CONSENT.asBytes32().tload();
        return approved != bytes32(0) && hash == approved ? MAGIC_1271 : bytes4(0xffffffff);
    }

    /// @notice Give an untaken offer back. The staker can always; the agent's controller can turn one down.
    function withdrawOffer(uint256 id, address staker) external nonReentrant {
        if (msg.sender != staker && !pool.isController(id, msg.sender)) revert NotStakerOrController(id, msg.sender);
        uint256 amount = offers[id][staker];
        if (amount == 0) revert NoOffer(id, staker);
        offers[id][staker] = 0;
        delete offerTerms[id][staker];
        tokensHeld -= amount;
        token.safeTransfer(staker, amount);
        emit OfferWithdrawn(id, staker, amount, msg.sender);
    }

    /// @notice Close a seat. The staker or the agent's controller may call it at any time: the vault freezes the
    ///         line in the pool, which stops new borrows and hands back the undrawn line now. With no loan open
    ///         the seat closes in this call; otherwise it closes, every token back to the staker, in the same
    ///         transaction that repays the last loan. If that loan defaults instead, the seat settles.
    ///         Once the agent has changed hands since the seat opened, anyone may close it: the staker backed the
    ///         owner who accepted, and a new owner cannot borrow on it anyway (`canBorrow`).
    function close(uint256 id) external nonReentrant {
        Seat storage s = seats[id];
        if (s.status != Status.Open) revert NoOpenSeat(id);
        if (msg.sender != s.staker && !pool.isController(id, msg.sender) && registry.ownerOf(id) == s.owner) {
            revert NotStakerOrController(id, msg.sender);
        }
        _close(id, s);
    }

    /// @notice The owner's lever on an open seat (audit V-2): close it exactly as its staker could. The line
    ///         freezes now, and the seat closes (every token back to the staker) with no loan open, or when the
    ///         last loan is repaid. It never burns and never keeps a staker's tokens; a default still settles
    ///         the seat by its terms, as for any seat.
    function freezeSeat(uint256 id) external onlyOwner nonReentrant {
        Seat storage s = seats[id];
        if (s.status != Status.Open) revert NoOpenSeat(id);
        emit SeatFrozen(id, msg.sender);
        _close(id, s);
    }

    function _close(uint256 id, Seat storage s) internal {
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.defaulted) revert AgentDefaulted(id); // settle() burns it
        if (a.sponsor == agentId) {
            pool.freeze(id, true); // our own onRelease callback is skipped: this call reconciles below
            if (!s.closing) {
                s.closing = true;
                emit CloseRequested(id, msg.sender);
            }
            if (a.activeLoans != 0) return; // the last repayment closes it (onRelease), or settle()
        }
        _end(id, s, false);
    }

    /// @notice Close an idle seat. Anyone may, once its agent has not borrowed for `idleAfter` since the seat opened
    ///         (or since its last borrow, whichever is later) and has no loan open: the line is frozen and every
    ///         token goes back to the staker, exactly as `close`. This is what keeps seats that never borrow from
    ///         holding the vault's slots and backing forever (audit X-2).
    function expire(uint256 id) external nonReentrant {
        Seat storage s = seats[id];
        if (s.status != Status.Open) revert NoOpenSeat(id);
        uint64 idle = idleAfter;
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.defaulted) revert AgentDefaulted(id); // settle() burns it
        // idle since the seat opened or the agent last borrowed OR repaid: a 30-day loan repaid today is not idle
        uint64 since = a.lastBorrowAt > s.openedAt ? a.lastBorrowAt : s.openedAt;
        if (a.lastRepayAt > since) since = a.lastRepayAt;
        if (idle == 0 || a.activeLoans != 0 || block.timestamp < uint256(since) + idle) revert NotIdle(id);
        if (a.sponsor == agentId) pool.freeze(id, true); // our own onRelease callback is skipped: reconciled below
        emit SeatExpired(id, msg.sender);
        _end(id, s, false);
    }

    /// @notice Reconcile a seat with the pool by hand, for when a hook call failed. Anyone.
    ///         - The agent defaulted while the vault still backs it: the seat settles (`burnBps` burnt).
    ///         - The agent defaulted and the vault no longer backs it: `loanId` must be one of the agent's
    ///           defaulted loans. Backed by this seat (the vault's root, borrowed since the seat opened): the seat
    ///           settles. Backed by another sponsor: the agent had left this seat cleanly first (a defaulted
    ///           agent can never change sponsor), so every token goes back.
    ///         - The agent did not default and the vault no longer backs it (it left or handed off): every token
    ///           goes back.
    function settle(uint256 id, uint256 loanId) external nonReentrant {
        Seat storage s = seats[id];
        if (s.status != Status.Open) revert NoOpenSeat(id);
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        bool burn;
        if (a.sponsor == agentId) {
            if (!a.defaulted) revert StillBacked(id);
            burn = true;
        } else if (a.defaulted) {
            CreditPoolV2.Loan memory l = pool.getLoan(loanId);
            if (l.agentId != id || l.status != CreditPoolV2.LoanStatus.Defaulted || loanId == 0) {
                revert BadProof(id, loanId);
            }
            if (l.sponsorId == agentId) {
                if (l.issuedAt < s.openedAt) revert BadProof(id, loanId);
                burn = true;
            }
        }
        _end(id, s, burn);
    }

    // ------------------------------------------------------------------
    // Backer hooks (called by the pool, which holds its own lock throughout)
    // ------------------------------------------------------------------

    /// @notice Borrows are allowed only on an open seat that is not closing, while seats are not paused, from the
    ///         owner who accepted the seat, and only while the seat still meets the vault's current terms (its
    ///         size, burn share and line). The pause and a repricing therefore reach seats already open (V-2).
    ///         `owner` is the agent's registry owner, as the pool read it for this loan.
    function canBorrow(uint256 rootId, uint256 id, uint256, uint64, uint256, address, address owner, address)
        external
        view
        returns (bool)
    {
        Seat storage s = seats[id];
        if (rootId != agentId || s.status != Status.Open || s.closing || seatsPaused) return false;
        if (owner != s.owner) return false;
        Params storage p = params;
        return s.amount >= p.seatSize && s.burnBps >= p.burnBps && s.line <= p.line;
    }

    function onBorrow(uint256, uint256, uint256) external {}

    /// @notice A loan under this vault defaulted: the agent's open seat settles now, `burnBps` burnt, the rest
    ///         back to the staker. Calls not from the pool, or for another root, are ignored.
    function onDefault(uint256 rootId, uint256 id, uint256, uint256, bool) external {
        if (!_hookCall(rootId)) return;
        Seat storage s = seats[id];
        if (s.status != Status.Open) return; // a second default on a seat already settled
        _enter();
        _end(id, s, true);
        LOCK.asBoolean().tstore(false);
    }

    /// @notice Part of a line came back. If the sponsorship ended (leave, handoff, a frozen line's last loan, an
    ///         unvouch), the seat closes: every token back, unless the agent is defaulted (the residual after a
    ///         default whose onDefault did not settle the seat), in which case it settles per its terms.
    function onRelease(uint256 rootId, uint256 id, uint256, uint8) external {
        if (!_hookCall(rootId)) return;
        Seat storage s = seats[id];
        if (s.status != Status.Open) return;
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.sponsor == rootId) return; // part of the line only; the seat stays open
        _enter();
        _end(id, s, a.defaulted);
        LOCK.asBoolean().tstore(false);
    }

    function _hookCall(uint256 rootId) internal view returns (bool) {
        return msg.sender == address(pool) && rootId == agentId && rootId != 0 && !LOCK.asBoolean().tload();
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------

    /// @notice Credit an open seat's staker with the fees its agent has paid since the last credit. Anyone.
    function poke(uint256 id) external nonReentrant {
        Seat storage s = seats[id];
        if (s.status != Status.Open) revert NoOpenSeat(id);
        _credit(id, s);
    }

    /// @notice Pay out the fees credited to the caller.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        amount = feesOwed[msg.sender];
        if (amount == 0) revert ZeroAmount();
        feesOwed[msg.sender] = 0;
        totalFeesOwed -= amount;
        if (usdg.balanceOf(address(this)) < amount) _collect(); // credits never exceed what the pool owes
        usdg.safeTransfer(to, amount);
        emit FeesClaimed(msg.sender, to, amount);
    }

    /// @notice Credit every open seat, then send what no staker is owed (fees on a defaulted agent's leftover
    ///         loans, stray USDG) to the fee sink. Anyone.
    function skim() external nonReentrant returns (uint256 amount) {
        uint256 n = _open.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _open[i];
            _credit(id, seats[id]);
        }
        _collect();
        uint256 bal = usdg.balanceOf(address(this));
        amount = bal > totalFeesOwed ? bal - totalFeesOwed : 0;
        if (amount > 0) usdg.safeTransfer(feeSink, amount);
        emit Skimmed(amount, feeSink);
    }

    /// @notice USDG the staker of `id`'s open seat would be credited now. Exact.
    function pendingFees(uint256 id) external view returns (uint256) {
        Seat storage s = seats[id];
        if (s.status != Status.Open) return 0;
        uint256 cur = pool.feesFrom(agentId, id);
        return cur > s.feeMark ? cur - s.feeMark : 0;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function getSeat(uint256 id) external view returns (Seat memory) {
        return seats[id];
    }

    function openSeats() external view returns (uint256[] memory) {
        return _open;
    }

    function openCount() external view returns (uint256) {
        return _open.length;
    }

    /// @notice How much of new lines the vault may still open this epoch.
    function epochRoom() public view returns (uint256) {
        uint256 used = block.timestamp >= epochStart + params.epochLength ? 0 : linedThisEpoch;
        return params.epochCap > used ? params.epochCap - used : 0;
    }

    /// @notice Whether a seat could open behind `id` now, as far as the agent's record goes (the pool still
    ///         checks consent, v1, and a loan open under another sponsor).
    function seatable(uint256 id) public view returns (bool) {
        uint256 root = agentId;
        if (root == 0 || id == 0 || id == root || seats[id].status == Status.Open) return false;
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        return !a.isRoot && !a.defaulted && a.sponsor != root && a.loansRepaid >= minRepaid;
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function setParams(Params calldata p) external onlyOwner {
        _setParams(p);
    }

    /// @notice Set the history gate and the idle expiry. Neither touches a seat already open, except that an idle
    ///         one becomes expirable under the new `idleAfter`.
    function setGates(uint256 minRepaid_, uint64 idleAfter_) external onlyOwner {
        if (idleAfter_ != 0 && (idleAfter_ < 1 days || idleAfter_ > MAX_EPOCH)) revert InvalidParams();
        minRepaid = minRepaid_;
        idleAfter = idleAfter_;
        emit GatesUpdated(minRepaid_, idleAfter_);
    }

    function pauseSeats(bool paused_) external onlyOwner {
        seatsPaused = paused_;
        emit SeatsPaused(paused_);
    }

    function setFeeSink(address sink) external onlyOwner {
        if (sink == address(0)) revert InvalidParams();
        feeSink = sink;
        emit FeeSinkUpdated(sink);
    }

    /// @notice Recover a token sent here by mistake. Stakers' $PRIORS is out of reach (only $PRIORS above
    ///         `tokensHeld` can leave this way); USDG never leaves this way (the surplus leaves by `skim()`).
    function rescue(address token_, address to) external onlyOwner nonReentrant {
        if (token_ == address(usdg)) revert Protected(token_);
        uint256 bal = IERC20(token_).balanceOf(address(this));
        uint256 amount = token_ == address(token) ? (bal > tokensHeld ? bal - tokensHeld : 0) : bal;
        if (amount == 0) revert Protected(token_);
        IERC20(token_).safeTransfer(to, amount);
        emit Rescued(token_, to, amount);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _offer(uint256 id, address staker) internal {
        if (seatsPaused) revert Paused();
        if (!seatable(id)) revert NotSeatable(id);
        if (offers[id][staker] != 0) revert OfferExists(id, staker);
        registry.ownerOf(id); // the identity must exist (reverts otherwise)
        uint256 size = params.seatSize;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(staker, address(this), size);
        uint256 got = token.balanceOf(address(this)) - before;
        if (got != size) revert BadTransfer(size, got); // no fee-on-transfer surprises: a seat is exact
        offers[id][staker] = size;
        offerTerms[id][staker] =
            Terms({line: uint128(params.line), burnBps: uint128(params.burnBps), owner: registry.ownerOf(id)});
        tokensHeld += size;
        emit Offered(id, staker, size);
    }

    function _openSeat(uint256 id, address staker, CreditPoolV2.Consent memory c, bytes memory sig) internal {
        if (seatsPaused) revert Paused();
        uint256 root = agentId;
        if (root == 0) revert NotAdopted();
        uint256 amount = offers[id][staker];
        if (amount == 0) revert NoOffer(id, staker);
        if (amount < params.seatSize) revert OfferTooSmall(id, amount, params.seatSize);
        Terms memory t = offerTerms[id][staker];
        // the staker agreed to these terms and no others; if the vault's have moved, it must offer again
        if (t.line != params.line || t.burnBps != params.burnBps) revert TermsChanged(id);
        // the staker backed the owner it saw, not whoever holds the id now: a sale kills the offer (audit X-1)
        address holder = registry.ownerOf(id);
        if (holder != t.owner) revert OwnerChanged(id, t.owner, holder);
        if (!seatable(id)) revert NotSeatable(id);
        if (_open.length >= params.maxOpenSeats) revert TooManySeats(_open.length, params.maxOpenSeats);
        _spend(t.line);
        offers[id][staker] = 0; // the offer becomes the seat; tokensHeld is unchanged
        delete offerTerms[id][staker];

        seats[id] = Seat({
            staker: staker,
            openedAt: uint64(block.timestamp),
            closing: false,
            status: Status.Open,
            line: t.line,
            burnBps: t.burnBps,
            amount: amount,
            feeMark: pool.feesFrom(root, id),
            owner: holder
        });
        _open.push(id);
        _openIndex[id] = _open.length;
        pool.vouchWithConsent(root, id, t.line, 0, c, sig);
        emit SeatOpened(id, staker, amount, t.line, t.burnBps);
    }

    /// @dev Close (`burn` false: every token back, the line refunded to this epoch's budget) or settle (`burn`
    ///      true: `burnBps` of the seat burnt, the rest back) an open seat, crediting its last fees first.
    function _end(uint256 id, Seat storage s, bool burn) internal {
        _credit(id, s);
        s.status = burn ? Status.Settled : Status.Closed;
        _unlist(id);
        uint256 amount = s.amount;
        address staker = s.staker;
        tokensHeld -= amount;
        if (burn) {
            uint256 burnt = amount * s.burnBps / 10_000;
            totalBurnt += burnt;
            if (burnt > 0) _burn(burnt);
            if (amount > burnt) token.safeTransfer(staker, amount - burnt);
            emit SeatSettled(id, staker, burnt, amount - burnt);
        } else {
            // a line that closed without a loss carried no risk: without this refund, opening and closing a
            // seat in a loop would use up the epoch's budget for gas only
            if (s.openedAt >= epochStart) {
                uint256 line = s.line;
                linedThisEpoch -= line < linedThisEpoch ? line : linedThisEpoch;
            }
            token.safeTransfer(staker, amount);
            emit SeatClosed(id, staker, amount);
        }
    }

    /// @dev Exact: the pool records each sponsor's fees per agent, and an agent has one seat at a time.
    function _credit(uint256 id, Seat storage s) internal {
        uint256 cur = pool.feesFrom(agentId, id);
        if (cur <= s.feeMark) return;
        uint256 owed = cur - s.feeMark;
        s.feeMark = cur;
        feesOwed[s.staker] += owed;
        totalFeesOwed += owed;
        emit FeesCredited(id, s.staker, owed);
    }

    function _collect() internal {
        uint256 root = agentId;
        if (root != 0 && pool.sponsorFees(root) > 0) pool.claimSponsorFees(root, address(this));
    }

    function _spend(uint256 amount) internal {
        if (block.timestamp >= epochStart + params.epochLength) {
            epochStart = uint64(block.timestamp);
            linedThisEpoch = 0;
        }
        uint256 left = params.epochCap > linedThisEpoch ? params.epochCap - linedThisEpoch : 0;
        if (amount > left) revert EpochCapReached(amount, left);
        linedThisEpoch += amount;
    }

    function _unlist(uint256 id) internal {
        uint256 idx = _openIndex[id];
        uint256 last = _open[_open.length - 1];
        _open[idx - 1] = last;
        _openIndex[last] = idx;
        _open.pop();
        delete _openIndex[id];
    }

    function _burn(uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        try ISeatToken(address(token)).burn(amount) {} catch {}
        uint256 afterBal = token.balanceOf(address(this));
        uint256 gone = afterBal < before ? before - afterBal : 0;
        // no burn(), or one that did not take the whole amount: send the rest where nobody can spend it
        if (gone < amount) token.safeTransfer(DEAD, amount - gone);
    }

    function _setParams(Params memory p) internal {
        if (
            p.seatSize == 0 || p.line == 0 || p.line > type(uint128).max || p.burnBps < MIN_BURN_BPS
                || p.burnBps > 10_000 || p.maxOpenSeats == 0 || p.maxOpenSeats > MAX_OPEN_SEATS || p.epochLength == 0
                || p.epochLength > MAX_EPOCH
        ) revert InvalidParams();
        params = p;
        emit ParamsUpdated(p);
    }
}
