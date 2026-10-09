// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ICreditPoolV2, IBackerHookV2} from "./interfaces/ICreditPoolV2.sol";
import {ISwapLimiter} from "./interfaces/ISwapLimiter.sol";
import {ISeatSizerV4, IV4SwapOnce, IPermit2V5, IExtsloadV5, IUsdgV5, V5PoolKey} from "./interfaces/IV5Deps.sol";
import {Env, C, IV5Events, IV5Errors} from "./v5/V5Types.sol";
import {V5Storage as S} from "./v5/V5Storage.sol";
import {V5Math as M} from "./v5/V5Math.sol";
import {V5Core as K, IV5Env} from "./v5/V5Core.sol";
import {V5Book} from "./v5/V5Book.sol";
import {V5Records} from "./v5/V5Records.sol";
import {V5Exit, IV5SellLeg} from "./v5/V5Exit.sol";
import {V5Auto} from "./v5/V5Auto.sol";
import {V5Sync} from "./v5/V5Sync.sol";
import {V5View} from "./v5/V5View.sol";
import {V5Lens} from "./v5/V5Lens.sol";

/// @title SeatVaultV5
/// @notice BACK / BURN on CreditPoolV2 (docs/PRIORS-UNDERWRITING-SPEC.md, revision 5): one book per agent, one
///         generation per `open`, three layers of $PRIORS behind it. The owner's own stake A opens the line
///         (floor to $5 of min(ceiling[tier], value(A) ÷ k)) and burns 75% on a default; others' backing B and
///         BuyAndBack's protocol backing C share the fees and burn 50%, and never raise a line (B + C ≤ A, C ≤ A/6).
///         Every line is backed 100% by the USDG of V5's root in the pool; the token is a deterrent, never the
///         lenders' protection.
///
///         Forked from SeatVaultV4: the root identity, the `vouchWithConsent` handoff, owner binding and the
///         owner-change stop, `fund`, the hooks, the idle close, close/freeze, the burn with its dead-address
///         fallback, pull-based fees, a pause that never blocks exits. No `Ownable`: the 48 h timelock and the Safe
///         (guardian) are immutables, and their powers are exactly section 8's list.
///
///         Size: the logic lives in linked libraries (V5Book, V5Records, V5Exit, V5Auto, V5Sync, V5View) that run by
///         DELEGATECALL in this contract's context, on one namespaced storage layout (V5Storage), under this
///         contract's one reentrancy lock. A library's state-changing function cannot be reached by a plain call.
contract SeatVaultV5 is IERC721Receiver, IBackerHookV2, IV5Env, IV5SellLeg, IV5Events, IV5Errors {
    using SafeERC20 for IERC20;

    bytes32 internal constant LOCK = keccak256("priors.seatvault.v5.lock");
    // CreditPoolV2's errors from `importFromV1` that mean no v1 history can ever be added to the root (I-01)
    bytes4 internal constant NO_V1 = bytes4(keccak256("NoV1()"));
    bytes4 internal constant INVALID_AGENT = bytes4(keccak256("InvalidAgent(uint256)"));
    bytes4 internal constant ALREADY_IMPORTED = bytes4(keccak256("AlreadyImported(uint256)"));

    struct Init {
        ICreditPoolV2 pool;
        IERC20 priors;
        IPermit2V5 permit2;
        IV4SwapOnce swapper;
        ISwapLimiter swapLimiter;
        V5PoolKey poolKey;
        IExtsloadV5 poolManager;
        address buyAndBack;
        ISeatSizerV4 sizer;
        uint256 rootId;
        address guardian;
        address timelock;
        address retireTo;
        address keeper;
        uint256 epoch0; // a Monday 00:00 UTC
        uint256 maxSwapUsdg;
        uint256 openRoom;
        uint256 raiseRoom;
        uint256 vouchCap;
    }

    ICreditPoolV2 public immutable pool;
    IERC20 public immutable usdg;
    IERC20 public immutable priors;
    address public immutable registry;
    IPermit2V5 public immutable permit2;
    IV4SwapOnce public immutable swapper;
    ISwapLimiter internal immutable limiter;
    IExtsloadV5 public immutable poolManager;
    bytes32 public immutable priceSlot;
    address internal immutable bb;
    ISeatSizerV4 public immutable sizer;
    uint256 public immutable rootId;
    address public immutable guardian;
    address internal immutable tl;
    address public immutable retireTo;
    uint256 public immutable EPOCH0;
    // the pool key, field by field (immutables cannot be structs)
    address internal immutable k0;
    address internal immutable k1;
    uint24 internal immutable kFee;
    int24 internal immutable kSpacing;
    address internal immutable kHooks;

    constructor(Init memory i) {
        if (
            address(i.pool) == address(0) || address(i.priors) == address(0) || i.buyAndBack == address(0)
                || i.guardian == address(0) || i.timelock == address(0) || i.retireTo == address(0) || i.rootId == 0
                || i.epoch0 % 1 days != 0 || (i.epoch0 / 1 days) % 7 != 4 || i.openRoom > C.MAX_ROOM
                || i.raiseRoom > C.MAX_ROOM || i.maxSwapUsdg == 0
        ) revert BadSetting();
        pool = i.pool;
        usdg = IERC20(i.pool.usdg());
        registry = i.pool.registry();
        priors = i.priors;
        if (i.poolKey.currency0 != address(usdg) || i.poolKey.currency1 != address(i.priors)) revert BadSetting();
        permit2 = i.permit2;
        swapper = i.swapper;
        limiter = i.swapLimiter;
        poolManager = i.poolManager;
        priceSlot = keccak256(abi.encode(keccak256(abi.encode(i.poolKey)), uint256(6)));
        bb = i.buyAndBack;
        sizer = i.sizer;
        rootId = i.rootId;
        guardian = i.guardian;
        tl = i.timelock;
        retireTo = i.retireTo;
        EPOCH0 = i.epoch0;
        k0 = i.poolKey.currency0;
        k1 = i.poolKey.currency1;
        kFee = i.poolKey.fee;
        kSpacing = i.poolKey.tickSpacing;
        kHooks = i.poolKey.hooks;
        S.Layout storage l = S.layout();
        l.keeper = i.keeper;
        l.minDrawK = C.K_CALM;
        l.maxSwapUsdg = i.maxSwapUsdg;
        l.openRoom = i.openRoom;
        l.raiseRoom = i.raiseRoom;
        l.vouchCap = i.vouchCap;
        usdg.forceApprove(address(i.pool), type(uint256).max);
        emit KeeperSet(i.keeper);
    }

    // ------------------------------------------------------------------
    // lock, roles, environment
    // ------------------------------------------------------------------

    /// @dev One lock for every state-changing entry point and the hooks (V5-REENTRANCY). A hook that arrives while V5
    ///      holds it is V5's own pool call (a freeze, an unvouch, a `markDefault` on a payout path): it is skipped, and
    ///      the call that made it completes the work.
    modifier nonReentrant() {
        _enter();
        _;
        _exit();
    }

    function _enter() private {
        bytes32 s = LOCK;
        bool locked;
        assembly {
            locked := tload(s)
        }
        if (locked) revert Reentrancy();
        assembly {
            tstore(s, 1)
        }
    }

    function _exit() private {
        bytes32 s = LOCK;
        assembly {
            tstore(s, 0)
        }
    }

    function _locked() private view returns (bool locked) {
        bytes32 s = LOCK;
        assembly {
            locked := tload(s)
        }
    }

    modifier onlyTimelock() {
        if (msg.sender != tl) revert NotTimelock();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != S.layout().keeper || msg.sender == address(0)) revert NotKeeper();
        _;
    }

    modifier onlyBuyAndBack() {
        if (msg.sender != bb) revert NotBuyAndBack();
        _;
    }

    function _env() private view returns (Env memory e) {
        e.pool = pool;
        e.usdg = usdg;
        e.priors = priors;
        e.registry = registry;
        e.sizer = sizer;
        e.limiter = limiter;
        e.buyAndBack = bb;
        e.swapper = swapper;
        e.permit2 = permit2;
        e.poolManager = poolManager;
        e.priceSlot = priceSlot;
        e.root = rootId;
        e.epoch0 = EPOCH0;
        e.key = V5PoolKey(k0, k1, kFee, kSpacing, kHooks);
    }

    /// @notice The immutables, as V5's linked libraries read them (one staticcall per library call).
    function v5Env() external view returns (Env memory) {
        return _env();
    }

    function _hookOk(uint256 root_) private view returns (bool) {
        return msg.sender == address(pool) && root_ == rootId && !_locked();
    }

    // ------------------------------------------------------------------
    // the root (V4's identity and stake)
    // ------------------------------------------------------------------

    /// @notice V5 holds one ERC-721 for good, its root identity, and has no way to send one: it accepts a safe transfer
    ///         of that token from the registry only, and refuses every other (internal audit I-02), so an agent sent
    ///         here by mistake stays with its sender. (A plain `transferFrom` runs no check anywhere and cannot be
    ///         refused.)
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external view returns (bytes4) {
        if (msg.sender != registry || tokenId != rootId) revert BadTransfer();
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Put USDG behind V5's root as pool shares (anyone; V4's `fund`). The first call, once V5 holds its root
    ///         identity, imports the root's v1 history if it has one, enrolls the root and makes V5 its hook, and
    ///         records the root's `childrenDefaulted` (V5 counts defaults from there). `vouchCap` keeps a deposit from
    ///         raising V5's vouches.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        S.Layout storage l = S.layout();
        Env memory e = _env();
        K.pull(e, usdg, amount);
        if (l.rootReady) {
            pool.addStake(rootId, amount);
        } else {
            (bool ok, address o) = K.ownerOf(e, rootId);
            if (!ok || o != address(this)) revert RootNotReady();
            _importV1();
            pool.enrollRoot(rootId, amount);
            pool.setHook(rootId, address(this));
            l.rootReady = true;
            l.childBase = pool.getAgent(rootId).childrenDefaulted;
        }
        emit Funded(msg.sender, amount);
    }

    /// @dev Internal audit I-01: `importFromV1` is open to anyone, once per id, and adds the v1 record's
    ///      `childrenDefaulted` to the root's; after `childBase` is read that would leave `defaultUnseen` true for
    ///      good. So the first `fund()` imports first (a v1 default makes `enrollRoot` refuse the root), and goes on
    ///      only when no import can ever follow: it succeeded, was already made, or there is no v1 or no v1 record.
    ///      Any other refusal (`V1Busy`, `ImportOutOfRange`) refuses the fund.
    function _importV1() private {
        try pool.importFromV1(rootId) {}
        catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (sel != NO_V1 && sel != INVALID_AGENT && sel != ALREADY_IMPORTED) revert RootNotReady();
        }
    }

    /// @notice Timelock only: take free backing out, to `retireTo` only, leaving the fee headroom of every vouched line
    ///         (2.3, section 8).
    function retire(uint256 shares) external onlyTimelock nonReentrant returns (uint256 assets) {
        assets = pool.convertToAssets(shares);
        uint256 free = pool.freeBacking(rootId);
        uint256 dOut = pool.getAgent(rootId).delegatedOut;
        if (assets + M.feeRoom(dOut, S.layout().premiumCap) > free) revert NoFeeRoom();
        assets = pool.unlock(rootId, shares, retireTo);
        emit Retired(shares, assets);
    }

    // ------------------------------------------------------------------
    // backer hooks (the pool calls them inside its own lock)
    // ------------------------------------------------------------------

    /// @notice See V5View.canBorrow. A view the pool calls by staticcall with 300,000 gas.
    function canBorrow(
        uint256 root_,
        uint256 id,
        uint256 amount,
        uint64 term,
        uint256 fee,
        address caller,
        address owner,
        address
    ) external view returns (bool) {
        return V5View.canBorrow(V5View.BorrowArgs(root_, id, amount, term, fee, caller, owner));
    }

    function onBorrow(uint256 root_, uint256 id, uint256 loanId) external {
        if (!_hookOk(root_)) return;
        _enter();
        V5Records.onBorrow(id, loanId);
        _exit();
    }

    function onDefault(uint256 root_, uint256 id, uint256 loanId, uint256 principal, bool) external {
        if (!_hookOk(root_)) return;
        _enter();
        V5Records.onDefault(id, loanId, principal);
        _exit();
    }

    function onRelease(uint256 root_, uint256 id, uint256, uint8) external {
        if (!_hookOk(root_)) return;
        _enter();
        V5Records.onRelease(id);
        _exit();
    }

    // ------------------------------------------------------------------
    // engine 1: books
    // ------------------------------------------------------------------

    /// @notice Open the agent's book with `amount` $PRIORS (2.5). The caller is the agent's registry owner.
    function open(uint256 id, uint256 amount, bool autoAdd, ICreditPoolV2.Consent calldata c, bytes calldata sig)
        external
        nonReentrant
    {
        V5Book.open(V5Book.OpenArgs(id, amount, 0, 0, 0, autoAdd), c, sig);
    }

    /// @notice Open with `priorsIn` $PRIORS (may be 0) and `usdgIn` USDG swapped for the rest in the same call, at
    ///         least `minOut`, all or nothing (question 6).
    function openWithUsdg(
        uint256 id,
        uint256 priorsIn,
        uint256 usdgIn,
        uint256 minOut,
        uint256 deadline,
        bool autoAdd,
        ICreditPoolV2.Consent calldata c,
        bytes calldata sig
    ) external nonReentrant {
        V5Book.open(V5Book.OpenArgs(id, priorsIn, usdgIn, minOut, deadline, autoAdd), c, sig);
    }

    function back(uint256 id, uint256 amount, bool autoAdd) external nonReentrant {
        V5Book.back(V5Book.OpenArgs(id, amount, 0, 0, 0, autoAdd));
    }

    function backWithUsdg(uint256 id, uint256 priorsIn, uint256 usdgIn, uint256 minOut, uint256 deadline, bool autoAdd)
        external
        nonReentrant
    {
        V5Book.back(V5Book.OpenArgs(id, priorsIn, usdgIn, minOut, deadline, autoAdd));
    }

    function leave(uint256 id, uint256 amount, uint8 exitMode) external nonReentrant {
        V5Book.leave(id, amount, exitMode);
    }

    function close(uint256 id, uint8 exitMode) external nonReentrant {
        V5Book.close(id, exitMode);
    }

    function expire(uint256 id) external nonReentrant {
        V5Book.expire(id);
    }

    /// @notice `sync(id)`: close with no burn a book V5 no longer backs (2.6).
    function sync(uint256 id) external nonReentrant {
        V5Book.syncBook(id);
    }

    function setAutoAdd(uint256 id, bool on) external nonReentrant {
        V5Records.setAutoAdd(id, on);
    }

    function setProtocolBacking(uint256 id, bool on) external nonReentrant {
        V5Records.setProtocolBacking(id, on);
    }

    function setOthersBacking(uint256 id, bool on) external nonReentrant {
        V5Records.setOthersBacking(id, on);
    }

    function reconsent(uint256 id, ICreditPoolV2.Consent calldata c, bytes calldata sig) external nonReentrant {
        V5Records.reconsent(id, c, sig);
    }

    function noteDelegate(uint256 id) external nonReentrant {
        V5Records.noteDelegate(id);
    }

    // ------------------------------------------------------------------
    // accounting (anyone)
    // ------------------------------------------------------------------

    /// @notice The no-argument `sync()`: the price cache, the ring, k, the guards and the breaker (2.3, 2.8).
    function sync() external nonReentrant {
        V5Sync.sync();
    }

    function pokeFees(uint256 id) external nonReentrant {
        V5Records.poke(id);
    }

    function recordRepay(uint256 id) external nonReentrant {
        V5Records.poke(id);
    }

    function recordLoan(uint256 loanId) external nonReentrant {
        V5Records.recordLoan(loanId);
    }

    function recordDefault(uint256 loanId) external nonReentrant {
        V5Records.recordDefault(loanId);
    }

    function settle(uint256 id, uint32 gen, uint256 loanId) external nonReentrant {
        V5Records.settle(id, gen, loanId);
    }

    function promote(uint256 id) external nonReentrant {
        V5Records.promote(id);
    }

    function refresh(uint256 id) external nonReentrant {
        V5Records.refresh(id);
    }

    function flush() external nonReentrant {
        V5Auto.flush();
    }

    // ------------------------------------------------------------------
    // exits
    // ------------------------------------------------------------------

    function release(uint256 id, uint32 gen, uint32 bucketDay, uint256 minUsdgOut, uint256 deadline)
        external
        nonReentrant
    {
        V5Exit.release(id, gen, bucketDay, minUsdgOut, deadline);
    }

    function releaseFor(uint256 id, uint32 gen, address holder, uint32 bucketDay) external nonReentrant {
        V5Exit.releaseFor(id, gen, holder, bucketDay);
    }

    /// @notice The keeper's USDG leg: one chunk of the exit queue's head sold in the pool (2A.1).
    function releaseFor(uint256 entryId, uint256 maxTokens) external onlyKeeper nonReentrant {
        V5Exit.keeperSell(entryId, maxTokens);
    }

    /// @notice The inner leg of a keeper sell, reachable only from V5 itself (a failure undoes it whole): the
    ///         SwapLimiter's `consume`, then one exact-input sale with the leaver as recipient.
    function sellLeg(uint256 tokens, uint256 minOut, address to, uint256 usdgValue) external returns (uint256 out) {
        if (msg.sender != address(this)) revert NotKeeper();
        limiter.consume(usdgValue);
        priors.forceApprove(address(swapper), tokens);
        uint256 paid;
        (paid, out) = swapper.swapExactIn(
            V5PoolKey(k0, k1, kFee, kSpacing, kHooks),
            false,
            uint128(tokens),
            minOut,
            C.MAX_SQRT_MINUS_ONE,
            to,
            block.timestamp
        );
        priors.forceApprove(address(swapper), 0);
        // a partial fill (the swap stopped at its price limit) is no sale: the leg reverts whole and the keeper's turn
        // skips, writing nothing, so the record keeps every unit (deep audit D-03)
        if (paid != tokens) revert UsdgPathClosed(5);
    }

    function finishClose(uint256 id, uint32 gen) external nonReentrant {
        V5Exit.finishClose(id, gen);
    }

    function claimSettled(uint256 id, uint32 gen, address holder) external nonReentrant {
        V5Exit.claimSettledPosition(id, gen, holder);
    }

    function claimSettled(uint256 id, uint32 gen, address holder, uint8 layer, uint32 bucketDay) external nonReentrant {
        V5Exit.claimSettledRecord(id, gen, holder, layer, bucketDay);
    }

    /// @notice Link one mode-2 leaving record into the exit queue; the record's holder or V5's keeper only (V5Exit).
    function queueExit(uint256 id, uint32 gen, address holder, uint8 layer, uint32 bucketDay) external nonReentrant {
        V5Exit.queueExit(id, gen, holder, layer, bucketDay);
    }

    function fillExit(uint256 entryId, uint256 maxTokens, uint160 sqrtFill)
        external
        onlyBuyAndBack
        nonReentrant
        returns (uint256 taken, address holder)
    {
        return V5Exit.fillExit(entryId, maxTokens, sqrtFill);
    }

    function returnExit(uint256 entryId) external onlyBuyAndBack nonReentrant {
        V5Exit.returnExit(entryId);
    }

    function collect(uint256[] calldata ids, uint32[] calldata gens) external nonReentrant returns (uint256) {
        return V5Auto.collect(ids, gens);
    }

    function compound(V5Auto.Item[] calldata items, uint256 minOut) external onlyKeeper nonReentrant {
        V5Auto.compound(items, minOut);
    }

    // ------------------------------------------------------------------
    // outside wallets: one transaction (2A.1)
    // ------------------------------------------------------------------

    /// @notice Batch calls to V5 with `msg.sender` preserved (each takes the lock on its own).
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory r) = address(this).delegatecall(data[i]);
            if (!ok) {
                assembly {
                    revert(add(r, 0x20), mload(r))
                }
            }
            results[i] = r;
        }
    }

    /// @notice USDG's EIP-2612 permit for V5, from the caller; in try/catch (a front-run permit is no harm).
    function permitUsdg(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        try IUsdgV5(address(usdg)).permit(msg.sender, address(this), value, deadline, v, r, s) {} catch {}
    }

    /// @notice A Permit2 allowance for V5, from the caller; in try/catch.
    function permit2Allow(IPermit2V5.PermitSingle calldata p, bytes calldata sig) external {
        try permit2.permit(msg.sender, p, sig) {} catch {}
    }

    // ------------------------------------------------------------------
    // the timelock's settings (section 8, V5-ACCESS)
    // ------------------------------------------------------------------

    function setKeeper(address k) external onlyTimelock {
        S.layout().keeper = k;
        emit KeeperSet(k);
    }

    function setOpenBacking(bool on) external onlyTimelock {
        S.layout().openBacking = on;
        emit SettingSet("openBacking", on ? 1 : 0);
    }

    /// @notice V5's premium cap: 0 until Stage 3, at most the pool's 200 bps.
    function setPremiumCap(uint256 bps) external onlyTimelock {
        if (bps > C.PREMIUM_MAX_BPS) revert BadSetting();
        S.layout().premiumCap = bps;
        emit SettingSet("premiumCap", bps);
    }

    /// @notice The `setPremium` forwarder (2.9): sets the book's target premium (at most V5's cap), and forwards it to
    ///         the pool while the agent's consent allows it.
    function setPremium(uint256 id, uint256 bps) external onlyTimelock nonReentrant {
        S.Layout storage l = S.layout();
        if (bps > l.premiumCap) revert BadSetting();
        l.targetPremium[id] = bps;
        ICreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.sponsor == rootId && bps <= a.premiumCap) pool.setPremium(id, bps);
        emit PremiumTargetSet(id, bps);
    }

    /// @notice Stage 3's re-consent check in `canBorrow`, effective 7 days after it is switched on (the notice).
    function setPremiumCheck(bool on) external onlyTimelock {
        S.Layout storage l = S.layout();
        l.premiumCheck = on;
        l.premiumCheckFrom = uint64(block.timestamp) + 7 days;
        emit SettingSet("premiumCheck", on ? 1 : 0);
    }

    /// @notice At most the SwapLimiter's timelocked ceiling.
    function setMaxSwapUsdg(uint256 v) external onlyTimelock {
        if (v == 0 || v > limiter.ceiling()) revert BadSetting();
        S.layout().maxSwapUsdg = v;
        emit SettingSet("maxSwapUsdg", v);
    }

    /// @notice The open room and the raise room, each at most $5,000 a week.
    function setRooms(uint256 openRoom_, uint256 raiseRoom_) external onlyTimelock {
        if (openRoom_ > C.MAX_ROOM || raiseRoom_ > C.MAX_ROOM) revert BadSetting();
        S.Layout storage l = S.layout();
        l.openRoom = openRoom_;
        l.raiseRoom = raiseRoom_;
        emit SettingSet("openRoom", openRoom_);
        emit SettingSet("raiseRoom", raiseRoom_);
    }

    /// @notice `minDrawK` (question 34), doubled: 3 (1.5), 4 (2) or 6 (3).
    function setMinDrawK(uint8 kx2) external onlyTimelock {
        if (kx2 != C.K_CALM && kx2 != C.K_NORMAL && kx2 != C.K_WILD) revert BadSetting();
        S.layout().minDrawK = kx2;
        emit SettingSet("minDrawK", kx2);
    }

    /// @notice The T1 entry rule (the owner's addition): `loans` repaid loans held 7 days (`qualifiedRepaid`), at most 3,
    ///         and `days_` days since pool enrolment, at most 14. 0 and 0, stake-only entry, at deployment.
    function setEntryRule(uint8 loans, uint32 days_) external onlyTimelock {
        if (loans > C.ENTRY_QUALIFIED || uint256(days_) * 1 days > C.ENTRY_AGE) revert BadSetting();
        S.Layout storage l = S.layout();
        l.minEntryLoans = loans;
        l.minEntryDays = days_;
        emit SettingSet("minEntryLoans", loans);
        emit SettingSet("minEntryDays", days_);
    }

    /// @notice `vouchCap` (question 34): V5's root's `delegatedOut` never above it after a V5 vouch.
    function setVouchCap(uint256 cap) external onlyTimelock {
        S.layout().vouchCap = cap;
        emit SettingSet("vouchCap", cap);
    }

    // ------------------------------------------------------------------
    // the guardian (the Safe): pause, clear(), stopKeeper(), nothing else
    // ------------------------------------------------------------------

    /// @notice Pause new books, backing, zaps, compound items, placement, refresh-up, `promote`, fills, keeper sells
    ///         and new loans for 14 days; never an exit. Not again while paused or within 14 days after a pause ends.
    function pause() external onlyGuardian {
        S.Layout storage l = S.layout();
        if (block.timestamp < l.pausedUntil || (l.pauseEnd != 0 && block.timestamp < l.pauseEnd + C.PAUSE_COOLDOWN)) {
            revert PauseCooldown();
        }
        l.pausedUntil = uint64(block.timestamp) + C.MAX_PAUSE;
        l.pauseEnd = l.pausedUntil;
        emit PausedUntil(l.pausedUntil);
    }

    function unpause() external onlyGuardian {
        S.Layout storage l = S.layout();
        if (block.timestamp >= l.pausedUntil) revert Paused();
        l.pausedUntil = uint64(block.timestamp);
        l.pauseEnd = uint64(block.timestamp);
        emit PausedUntil(uint64(block.timestamp));
    }

    /// @notice Clear the circuit breaker's latch: the defaulted side's buckets zeroed, the time recorded (2.8).
    function clear() external onlyGuardian {
        S.Layout storage l = S.layout();
        for (uint256 i = 0; i < 30; i++) {
            delete l.defB[i];
        }
        l.tripped = false;
        l.clearedAt = uint64(block.timestamp);
        emit BreakerCleared(uint64(block.timestamp));
    }

    /// @notice Stop V5's keeper at once (only to address(0); a new keeper takes the timelock).
    function stopKeeper() external onlyGuardian {
        S.layout().keeper = address(0);
        emit KeeperSet(address(0));
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    function timelock() external view returns (address) {
        return tl;
    }

    function buyAndBack() external view returns (address) {
        return bb;
    }

    function swapLimiter() external view returns (address) {
        return address(limiter);
    }

    function poolKey() external view returns (V5PoolKey memory) {
        return V5PoolKey(k0, k1, kFee, kSpacing, kHooks);
    }

    // ------------------------------------------------------------------
    // views: served by V5Lens (view functions only), through the fallback
    // ------------------------------------------------------------------

    /// @notice Every getter (ISeatVaultV5Lens) runs in V5Lens by DELEGATECALL; V5Lens holds only view functions, so
    ///         nothing reached this way can change V5's state, and an unknown selector reverts there.
    fallback() external {
        address lens = address(V5Lens);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), lens, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
