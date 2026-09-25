// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SeatVaultV3} from "./SeatVaultV3.sol";

/// @notice The piece of a Uniswap V4 PoolManager this contract reads: raw storage, so no oracle hook is needed.
interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title SeatSizer
/// @notice Keeps a SeatVaultV3's seat worth about `LINES` lines of USDG in $PRIORS, without a Safe signature each time.
///
///         It owns the vault. The Safe owns it, and keeps every owner power through `execute` (pause, freeze, gates,
///         retire, rescue, setParams, and handing the vault back with `transferOwnership` + the new owner's accept).
///         What it adds is one bounded lever for a keeper:
///
///           poke()    records the pool's price (sqrtPriceX96 read from the PoolManager's storage), at most once per
///                     OBS_INTERVAL, in a ring of WINDOW observations (only the last MAX_AGE count).
///           resize()  when the seat has drifted out of band (under 80% or over 2x of the target computed from the
///                     MEDIAN observation): a raise goes to the target at once; a cut at most halves the seat, once
///                     per CUT_INTERVAL; never under `floorSize` or over `ceilingSize`. Every other vault term is
///                     kept as it is, except that seats are paused when the ceiling leaves the burn under 1.5 lines.
///
///         Why the keeper and not anyone: the $PRIORS pool charges no swap fee, so a public poke could be sandwiched
///         in one transaction (pump, poke, dump) at almost no cost, and 24 of them would own the median. A keeper
///         poke cannot be placed inside someone else's transaction. A stolen keeper key can still record bad
///         observations, and the bounds are what cap it: a cut is at most MAX_STEP per day and the seat stays in
///         [floorSize, ceilingSize] (a bad raise only makes seats bigger, which pauses nothing but new loans on
///         smaller seats); the Safe can replace the keeper, or take the vault back, at any time. The keeper
///         never touches funds: the vault's USDG, stakers' tokens and fees are out of this contract's reach except
///         through the Safe's `execute`.
///
///         A raise reaches seats already open (SeatVaultV3.canBorrow refuses a loan on a seat below the current
///         size): their stakers top up by closing and offering again. A cut does not: a seat above the size keeps
///         borrowing.
contract SeatSizer is Ownable2Step {
    uint256 public constant WINDOW = 48; // 24 h of observations at the keeper's 30-minute pass
    uint256 public constant MIN_OBS = 24; // no resize on less than 12 h of history
    uint64 public constant OBS_INTERVAL = 29 minutes; // the keeper passes every 30: 24 observations span over 11 h
    uint64 public constant MAX_AGE = 1 days; // only the last day's observations size the seat
    uint64 public constant CUT_INTERVAL = 1 days;
    uint256 public constant LINES = 5; // a seat is worth 5 lines
    uint256 public constant MAX_STEP = 2; // a cut at most halves the seat
    uint256 internal constant Q96 = 1 << 96;

    SeatVaultV3 public immutable vault;
    IExtsload public immutable poolManager;
    bytes32 public immutable priceSlot; // pools[poolId].slot0 in the PoolManager's storage

    address public keeper;
    uint256 public floorSize; // raw $PRIORS
    uint256 public ceilingSize; // raw $PRIORS
    uint160[WINDOW] internal obs;
    uint64[WINDOW] internal obsAt;
    uint256 public obsCount;
    uint64 public lastObsAt;
    uint64 public lastCutAt;

    event Poked(uint160 sqrtPriceX96, uint256 count);
    event Resized(uint256 from, uint256 to, uint256 target, uint160 medianSqrtPriceX96);
    event PausedByPrice(uint256 seatSize, uint256 target);
    event KeeperSet(address keeper);
    event BoundsSet(uint256 floorSize, uint256 ceilingSize);

    error NotKeeper(address caller);
    error TooSoon(uint64 next);
    error PriceUnreadable();
    error NotEnoughObservations(uint256 have, uint256 need);
    error InBand(uint256 current, uint256 target);
    error Unchanged(uint256 seatSize);
    error BadBounds();
    error NoRenounce();

    constructor(
        SeatVaultV3 vault_,
        IExtsload poolManager_,
        bytes32 poolId,
        address safe,
        address keeper_,
        uint256 floor_,
        uint256 ceiling_
    ) Ownable(safe) {
        vault = vault_;
        poolManager = poolManager_;
        priceSlot = keccak256(abi.encode(poolId, uint256(6))); // PoolManager: mapping(PoolId => Pool.State) at slot 6
        _setBounds(floor_, ceiling_);
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper(msg.sender);
        _;
    }

    // ------------------------------------------------------------------
    // The keeper's lever
    // ------------------------------------------------------------------

    function poke() public onlyKeeperOrOwner {
        uint64 next = lastObsAt + OBS_INTERVAL;
        if (lastObsAt != 0 && block.timestamp < next) revert TooSoon(next);
        uint160 p = uint160(uint256(poolManager.extsload(priceSlot)));
        if (p == 0) revert PriceUnreadable();
        obs[obsCount % WINDOW] = p;
        obsAt[obsCount % WINDOW] = uint64(block.timestamp);
        obsCount += 1;
        lastObsAt = uint64(block.timestamp);
        emit Poked(p, obsCount);
    }

    /// @notice Raises go to the target at once and at any time (a smaller seat is the unsafe side, so it must not
    ///         wait); cuts move at most MAX_STEP, once per CUT_INTERVAL. If the ceiling leaves the seat's burn under
    ///         1.5 lines at the median price (a $PRIORS collapse), new seats and new loans on seats are paused
    ///         (SeatVaultV3.canBorrow reads the pause), until the Safe decides. The manual path applies the same rule
    ///         (ops/seat-price-guard.mjs boundedSeatSize): change one, change both.
    function resize() external onlyKeeperOrOwner returns (uint256 next) {
        uint160 m = medianSqrtPrice();
        uint256 t = targetFor(m);
        SeatVaultV3.Params memory p = _params();
        uint256 cur = p.seatSize;
        if (cur * 10 >= t * 8 && cur <= t * 2) revert InBand(cur, t);
        next = t;
        if (next < floorSize) next = floorSize;
        if (next > ceilingSize) next = ceilingSize;
        // a cut is decided after the bounds (a seat the Safe set above the ceiling is cut too), and at most halves
        bool cut = next < cur;
        if (cut) {
            uint64 allowed = lastCutAt + CUT_INTERVAL;
            if (lastCutAt != 0 && block.timestamp < allowed) revert TooSoon(allowed);
            if (next * MAX_STEP < cur) next = cur / MAX_STEP;
        }
        // the seat is worth LINES lines at t, so its burn is LINES * burnBps/10000 * next/t lines: under 1.5 lines
        // when next * burnBps * LINES < t * 15000. Checked even when the size cannot move (at the ceiling).
        bool pause = next * p.burnBps * LINES < t * 15_000 && !vault.seatsPaused();
        if (next == cur && !pause) revert Unchanged(cur);
        if (next != cur) {
            p.seatSize = next;
            vault.setParams(p);
            if (cut) lastCutAt = uint64(block.timestamp);
            emit Resized(cur, next, t, m);
        }
        if (pause) {
            vault.pauseSeats(true);
            emit PausedByPrice(next, t);
        }
    }

    // ------------------------------------------------------------------
    // Reads
    // ------------------------------------------------------------------

    /// @notice The upper median of the last MAX_AGE's observations (a higher sqrtPrice is a cheaper $PRIORS, so a
    ///         bigger seat: on an even count this errs towards the safer seat). Older ones are ignored, so a keeper
    ///         that stopped for days cannot resume and size the seat on the price of days ago.
    function medianSqrtPrice() public view returns (uint160) {
        uint256 stored = obsCount < WINDOW ? obsCount : WINDOW;
        uint160[] memory a = new uint160[](stored);
        uint256 n;
        for (uint256 i = 0; i < stored; i++) {
            if (obsAt[i] + MAX_AGE >= block.timestamp) a[n++] = obs[i];
        }
        if (n < MIN_OBS) revert NotEnoughObservations(n, MIN_OBS);
        for (uint256 i = 1; i < n; i++) {
            uint160 v = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > v) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = v;
        }
        return a[n / 2];
    }

    /// @notice The seat worth LINES lines at `sqrtPriceX96` (USDG currency0, 6 dp; $PRIORS currency1, 18 dp), rounded up
    ///         to two significant digits in whole $PRIORS, as ops/seat-price-guard.mjs targetSeatSize does.
    function targetFor(uint160 sqrtPriceX96) public view returns (uint256) {
        uint256 ratioX96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96); // raw $PRIORS per raw USDG, x 2^96
        uint256 whole = Math.mulDiv(ratioX96, _params().line * LINES, Q96 * 1e18);
        uint256 unit = 1;
        while (whole / unit >= 100) unit *= 10;
        return ((whole + unit - 1) / unit) * unit * 1e18;
    }

    function observation(uint256 i) external view returns (uint160) {
        return obs[i % WINDOW];
    }

    // ------------------------------------------------------------------
    // The Safe
    // ------------------------------------------------------------------

    /// @notice Any owner call on the vault, from the Safe only (pause, freeze, gates, retire, rescue, setParams,
    ///         transferOwnership to hand the vault back).
    function execute(bytes calldata data) external onlyOwner returns (bytes memory ret) {
        if (data.length >= 4 && bytes4(data[:4]) == Ownable.renounceOwnership.selector) revert NoRenounce();
        bool ok;
        (ok, ret) = address(vault).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// @notice Complete the vault's two-step handover to this contract.
    function acceptVaultOwnership() external onlyOwner {
        vault.acceptOwnership();
    }

    /// @notice Nobody renounces: an ownerless sizer (or vault) could never be unpaused, retired, rescued or handed back.
    function renounceOwnership() public pure override {
        revert NoRenounce();
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setBounds(uint256 floor_, uint256 ceiling_) external onlyOwner {
        _setBounds(floor_, ceiling_);
    }

    function _setBounds(uint256 floor_, uint256 ceiling_) internal {
        if (floor_ == 0 || ceiling_ < floor_) revert BadBounds();
        floorSize = floor_;
        ceilingSize = ceiling_;
        emit BoundsSet(floor_, ceiling_);
    }

    function _params() internal view returns (SeatVaultV3.Params memory p) {
        (p.seatSize, p.line, p.burnBps, p.maxOpenSeats, p.epochCap, p.epochLength) = vault.params();
    }
}
