// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICreditPoolV2} from "../interfaces/ICreditPoolV2.sol";
import {ISwapLimiter} from "../interfaces/ISwapLimiter.sol";
import {ISeatSizerV4, IV4SwapOnce, IPermit2V5, IExtsloadV5, V5PoolKey} from "../interfaces/IV5Deps.sol";

/// @notice The constructor immutables of SeatVaultV5, handed to its linked libraries on every call (they run by
///         DELEGATECALL in V5's context and cannot read V5's immutables themselves).
struct Env {
    ICreditPoolV2 pool;
    IERC20 usdg;
    IERC20 priors;
    address registry;
    ISeatSizerV4 sizer;
    ISwapLimiter limiter;
    address buyAndBack;
    IV4SwapOnce swapper;
    IPermit2V5 permit2;
    IExtsloadV5 poolManager;
    bytes32 priceSlot;
    uint256 root;
    uint256 epoch0;
    V5PoolKey key;
}

/// @notice Constants of SeatVaultV5 (docs/PRIORS-UNDERWRITING-SPEC.md rev 5, section 8: "Constants, with no setter").
///         USDG amounts are in raw units (6 decimals), $PRIORS in raw units (18 decimals). k is stored doubled
///         (3 = 1.5, 4 = 2, 6 = 3) so every k is an integer.
library C {
    // line, tiers, loans (2.3, 2.4)
    uint256 internal constant LINE_STEP = 5e6; // lines floor to $5
    uint256 internal constant MIN_LINE = 25e6; // the line an owner's minimum opens
    uint64 internal constant MAX_LOAN_TERM = 10 days; // question 4, a constant with no setter
    uint64 internal constant COUNT_MIN_TERM = 8 days; // a counted loan's term is 8-10 days
    uint64 internal constant COUNT_MIN_HOLD = 7 days; // ... repaid at least 7 days after taken
    uint256 internal constant LIST_CAP = 3; // question 4: 3, since 5 measured over 200,000 gas cold (docs/V5-BUILD.md)
    uint256 internal constant ENTRY_QUALIFIED = 3; // the most `minEntryLoans` may be (the spec's T1 entry)
    uint64 internal constant ENTRY_AGE = 14 days; // the most `minEntryDays` may be, in days
    uint64 internal constant PROMO_WAIT = 14 days; // at a tier before a promotion
    uint256 internal constant PROMO_COUNT = 3; // counted loans at the current tier step
    uint64 internal constant LATE_BAN = 28 days; // no placement after a late repayment
    // book lifecycle (2.4, 2.5, 2.8)
    uint64 internal constant IDLE_AFTER = 30 days;
    uint64 internal constant REOPEN_BAN = 30 days;
    uint64 internal constant OPEN_GAP = 7 days; // one open per owner address, rolling
    uint64 internal constant DELEGATE_WAIT = 1 days;
    uint64 internal constant WARMUP = 1 days;
    uint64 internal constant RELEASE_WAIT = 7 days;
    uint64 internal constant USDG_WINDOW = 3 days; // an exit entry's window, and the parked-stake wait
    uint64 internal constant RAISE_HOLD = 1 hours; // question 40: a vouch lives this long after a raise
    uint256 internal constant MIN_BACK = 1000e18; // minimum back and leave
    // money (2.6, 2.7)
    uint256 internal constant OWNER_BURN_BPS = 7500;
    uint256 internal constant BACK_BURN_BPS = 5000;
    uint256 internal constant BOOK_BPS = 7500; // the book's part of every fee; the buffer takes the rest
    uint256 internal constant INDEX = 1e36; // fee index scale
    uint256 internal constant HEADROOM_FEE_BPS = 200; // the steward's fee ceiling, reserved at every vouch
    uint256 internal constant PREMIUM_MAX_BPS = 200; // the pool's MAX_PREMIUM_BPS
    // prices and guards (2.3, 2.8, 2A.1, 2A.5)
    uint64 internal constant FRESH = 45 minutes;
    uint64 internal constant SNAP_MAX_AGE = 2 hours;
    uint64 internal constant GUARD_RECOVERY = 1 days;
    uint256 internal constant DEPTH_MIN = 500e6; // depth guard's $500
    uint256 internal constant FEE_CEILING_BPS = 400; // question 41
    uint8 internal constant K_CALM = 3;
    uint8 internal constant K_NORMAL = 4;
    uint8 internal constant K_WILD = 6;
    // circuit breaker (2.8)
    uint256 internal constant BREAKER_FLOOR = 250e6;
    uint256 internal constant BREAKER_BPS = 500;
    uint256 internal constant BREAKER_DAYS = 30;
    // rooms (2.8)
    uint256 internal constant PROMO_SHARE_BPS = 6000;
    uint256 internal constant STAKE_BOOK_BPS = 1000; // 25% of the 40% stake share
    uint256 internal constant MAX_ROOM = 5000e6;
    // exits (2A.1)
    uint256 internal constant EXIT_CHUNK_MAX = 250e6;
    uint256 internal constant EXIT_CHUNK_BPS = 35; // 0.35% of D
    uint256 internal constant SELL_BUDGET_BPS = 100; // 1% of D a day
    uint256 internal constant MIN_CHUNK = 5e6;
    uint256 internal constant MODE2_FLOOR = 25e6; // question 43
    // auto-add (2A.1)
    uint256 internal constant COMPOUND_MIN = 5e6;
    uint256 internal constant COMPOUND_ITEM_MIN = 5e5;
    uint256 internal constant COMPOUND_MAX_ITEMS = 50;
    // outside calls
    uint256 internal constant READ_GAS = 100_000; // 2.2's bounded reads
    uint256 internal constant CLAIM_GAS = 300_000; // flush/collect/compound's claim of the pool's fees
    // the SwapLimiter's depth and fee views, each called with a fixed budget the caller must leave whole (deep audit
    // H-01): two 100,000-gas fee reads with their 5,000 margin, the 8 snapshot slots and the live form's reads fit
    uint256 internal constant DEPTH_READ_GAS = 300_000;
    uint256 internal constant FEE_READ_GAS = 250_000;
    uint256 internal constant READ_MARGIN = 10_000; // kept back to finish after a fixed-budget read
    // leaving buckets retired per layer per poke (deep audit I-01); the head pointer resumes at the next poke
    uint256 internal constant RETIRE_MAX = 64;
    // pause (section 8)
    uint64 internal constant MAX_PAUSE = 14 days;
    uint64 internal constant PAUSE_COOLDOWN = 14 days;
    // layers
    uint8 internal constant OWNER = 0; // A, the owner stake: opens line, 75% burn
    uint8 internal constant OTHERS = 1; // others' backing: 50% burn
    uint8 internal constant OWN = 2; // the owner's own backing and BuyAndBack's C: 50% burn
    // generation status
    uint8 internal constant NONE = 0;
    uint8 internal constant OPEN = 1;
    uint8 internal constant CLOSED = 2; // no new stake or loans; loans may still run ("closing")
    uint8 internal constant SETTLED = 3;
    // swap limits
    uint160 internal constant MIN_SQRT_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function ceiling(uint8 tier) internal pure returns (uint256) {
        if (tier <= 1) return 50e6;
        if (tier == 2) return 100e6;
        if (tier == 3) return 175e6;
        if (tier == 4) return 300e6;
        return 500e6;
    }
}

/// @notice Every event SeatVaultV5 emits (section 8's list, plus the settings'), declared once so the linked
///         libraries emit them as V5 (a DELEGATECALLed library's logs carry V5's address).
interface IV5Events {
    event BookOpened(uint256 indexed id, uint32 indexed gen, address indexed owner, uint256 aTokens, uint256 line);
    event Backed(
        uint256 indexed id, uint32 indexed gen, address indexed holder, uint8 layer, uint256 tokens, uint256 usdgIn
    );
    event LeaveQueued(
        uint256 indexed id, uint32 indexed gen, address indexed holder, uint256 tokens, uint8 exitMode, uint32 bucketDay
    );
    event ExitQueued(uint256 indexed entryId, uint256 indexed id, uint32 gen, address indexed holder, uint256 shares);
    event Released(uint256 indexed id, uint32 indexed gen, address indexed holder, uint256 tokens, uint256 usdgOut);
    event ReleasedFrozen(uint256 indexed id, uint32 indexed gen, address indexed holder, uint256 tokens);
    event ExitFilled(uint256 indexed entryId, uint256 tokens, uint256 usdg);
    event ExitSold(uint256 indexed entryId, uint256 tokens, uint256 usdg);
    event ExitReturned(uint256 indexed entryId, uint256 tokens);
    event ExitSkipped(uint256 indexed entryId, uint8 reason);
    event Settled(
        uint256 indexed id,
        uint32 indexed gen,
        uint256 loanId,
        uint256 ownerBurned,
        uint256 backingBurned,
        uint256 cBurned
    );
    event SettledClaimed(uint256 indexed id, uint32 indexed gen, address indexed holder, uint256 tokens);
    event LoanRecorded(uint256 indexed id, uint32 indexed gen, uint256 indexed loanId, uint8 tier, bool viaHook);
    event LoanReconciled(uint256 indexed id, uint32 indexed gen, uint256 indexed loanId, bool counted, bool late);
    event Promoted(uint256 indexed id, uint32 indexed gen, uint8 tier);
    event Demoted(uint256 indexed id, uint32 indexed gen, uint8 tier);
    event RoomCharged(uint256 indexed id, uint32 indexed gen, uint8 room, uint256 amount);
    event Refreshed(uint256 indexed id, uint32 indexed gen, uint256 vouched);
    event OwnerChanged(uint256 indexed id, uint32 indexed gen);
    event BookClosed(uint256 indexed id, uint32 indexed gen, uint8 how);
    event ProtocolBackingSet(uint256 indexed id, bool on);
    event OthersBackingSet(uint256 indexed id, bool on);
    event AutoAddSet(uint256 indexed id, address indexed holder, bool on);
    event FeesPoked(uint256 indexed id, uint32 indexed gen, uint256 toBook, uint256 toBuffer);
    event Collected(address indexed holder, uint256 usdg);
    event Compounded(uint256 indexed id, address indexed holder, uint256 usdg, uint256 tokens);
    event ExtraReturned(uint256 indexed id, address indexed holder, uint256 tokens);
    event Flushed(uint256 claimed, uint256 bufferAdded, uint256 toBuyAndBack);
    event Synced(uint160 median, uint160 weekLow, uint8 k);
    event KChanged(uint8 k, uint160 maxSqrt, uint160 minSqrt);
    event GuardChanged(uint8 guard, bool on);
    event BreakerRecorded(uint256 indexed loanId, uint256 principal, uint32 day, bool defaulted);
    /// @notice A forced move to leaving (audit L-03): a whole layer (`holder` 0: a close, an owner change, a switch, a
    ///         deferred close of `onRelease`) or one position (`holder` BuyAndBack: C's opt-out or late move), its
    ///         counted and uncounted stake into the bucket of `bucketDay`, the release clock running from `at`.
    event LayerMoved(
        uint256 indexed id,
        uint32 indexed gen,
        uint8 layer,
        address holder,
        uint32 bucketDay,
        uint64 at,
        uint256 counted,
        uint256 uncounted
    );
    event BreakerTripped(uint256 sum, uint256 threshold);
    event BreakerCleared(uint64 at);
    event PremiumTargetSet(uint256 indexed id, uint256 bps);
    event KeeperSet(address indexed keeper);
    event DelegateNoted(uint256 indexed id, address delegate);
    event Funded(address indexed from, uint256 amount);
    event Retired(uint256 shares, uint256 assets);
    event SettingSet(bytes32 indexed what, uint256 value);
    event PausedUntil(uint64 until);
}

/// @notice Every custom error of SeatVaultV5 and its libraries.
interface IV5Errors {
    error Reentrancy();
    error NotTimelock();
    error NotGuardian();
    error NotKeeper();
    error NotBuyAndBack();
    error NotOwner();
    error NotPool();
    error ReadStarved();
    error RegistryRead();
    error ZeroAmount();
    error BadSetting();
    error Paused();
    error PauseCooldown();
    error BreakerOn();
    error DepthGuardOn();
    error SpotGuardOn();
    error NoPrice();
    error StalePrice();
    error StaleSizer();
    error OwnerChangedLatch();
    error BookNotOpen();
    error BookOpen();
    error LoanOpen();
    error AgentDefaulted();
    error NotEligible(uint8 why);
    error ReopenBan();
    error OpenTooSoon();
    error PremiumCap();
    error LineTooSmall(uint256 line);
    error TooMuchStake();
    error NoRoom();
    error TooSmall();
    error BackingClosed();
    error LateGuard();
    error NothingToLeave();
    error ReleaseNotReady();
    error NotQueued();
    error AlreadyQueued();
    error NotHead();
    error NoRecord();
    error NotSettled();
    error AlreadySettled();
    error BadProof();
    error DefaultUnseen();
    error StillSponsored();
    error NotIdle();
    error UsdgPathClosed(uint8 reason);
    error SplitNeeded(uint256 usdg, uint256 cap);
    error BadTransfer();
    error SwapShort(uint256 got, uint256 minOut);
    error PayBand();
    error TooManyItems();
    error CompoundTooSmall();
    error NoFeeRoom();
    error AlreadySeen();
    error NotOurLoan();
    error NotPromotable(uint8 why);
    error ClaimShort();
    error RootNotReady();
    /// @notice A deposit would land in the slot of a pending bucket of another day that has not merged (2.2, 2.7):
    ///         never reached, a guard against any path that skips a guard (deep audit D-01).
    error ThirdSlot();
}
