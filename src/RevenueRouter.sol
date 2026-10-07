// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GuardianPause} from "./GuardianPause.sol";
import {IRevenueRouter} from "./interfaces/IRevenueRouter.sol";

/// @title RevenueRouter
/// @notice Every revenue stream's USDG arrives here and leaves by exactly two outflows: BuyAndBack (engine 2) and
///         PriorsLiquidity (engine 3), both immutable (docs/PRIORS-UNDERWRITING-SPEC.md 2A.4, section 8, section 12
///         RR-SPLIT). Not upgradeable; the timelock's address is immutable.
///
///         `distribute()` (anyone, at most once a day, from a balance of 20 USDG):
///         1. splits only what arrived since the last split, new = balance - owedBuy - owedLiq: owedBuy +=
///            floor(new x buyBps / 10,000) and owedLiq += the rest, so the two add to what arrived;
///         2. sends BuyAndBack owedBuy and PriorsLiquidity owedLiq, each transfer tried on its own, and zeroes each one
///            that went through.
///         A share whose transfer fails (a USDG freeze of that engine) stays earmarked for it and is tried again at
///         the next `distribute()`. It is never split again: every arrival is split once, at the `buyBps` of its day,
///         and a frozen engine neither stops the other nor loses its share to it.
///
///         Each transfer runs with a fixed gas budget, and `distribute()` reverts `TransferStarved` unless the caller
///         left that budget, so a caller cannot starve a transfer to make it fail and burn the day's call. Nothing else
///         leaves: no rescue, no withdraw, no reserve step (the reserve rule is the PoolSteward's alone).
contract RevenueRouter is IRevenueRouter, GuardianPause {
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_BUY_BPS = 2_000;
    uint256 public constant MAX_BUY_BPS = 8_000;
    uint256 public constant INTERVAL = 1 days;
    uint256 public constant MIN_BALANCE = 20e6;
    /// @notice Gas given to each USDG transfer, and kept back to finish after it.
    uint256 public constant TRANSFER_GAS = 150_000;
    uint256 public constant TRANSFER_MARGIN = 10_000;

    IERC20 public immutable usdg;
    /// @inheritdoc IRevenueRouter
    address public immutable buyAndBack;
    /// @inheritdoc IRevenueRouter
    address public immutable liquidity;

    /// @inheritdoc IRevenueRouter
    uint256 public buyBps;
    /// @inheritdoc IRevenueRouter
    uint256 public owedBuy;
    /// @inheritdoc IRevenueRouter
    uint256 public owedLiq;
    /// @inheritdoc IRevenueRouter
    uint64 public lastDistributeAt;

    error TooSoon(uint64 next);
    error BalanceTooLow(uint256 balance);
    error BadBuyBps(uint256 buyBps);
    error TransferStarved();

    /// @param usdg_ USDG
    /// @param buyAndBack_ BuyAndBack (engine 2)
    /// @param liquidity_ PriorsLiquidity (engine 3)
    /// @param timelock_ the 48 h TimelockController (`setBuyBps`)
    /// @param guardian_ the Safe (pause of `distribute` only)
    constructor(IERC20 usdg_, address buyAndBack_, address liquidity_, address timelock_, address guardian_)
        GuardianPause(guardian_, timelock_)
    {
        if (address(usdg_) == address(0) || buyAndBack_ == address(0) || liquidity_ == address(0)) {
            revert ZeroAddress();
        }
        usdg = usdg_;
        buyAndBack = buyAndBack_;
        liquidity = liquidity_;
        buyBps = 5_000;
        emit BuyBpsSet(5_000);
    }

    /// @inheritdoc IRevenueRouter
    function distribute() external whenNotPaused {
        uint64 last = lastDistributeAt;
        // safe cast: a constant
        // forge-lint: disable-next-line(unsafe-typecast)
        if (last != 0 && block.timestamp < uint256(last) + INTERVAL) revert TooSoon(last + uint64(INTERVAL));
        uint256 bal = usdg.balanceOf(address(this));
        if (bal < MIN_BALANCE) revert BalanceTooLow(bal);
        lastDistributeAt = uint64(block.timestamp);

        uint256 ob = owedBuy;
        uint256 ol = owedLiq;
        uint256 owed = ob + ol;
        if (bal > owed) {
            uint256 arrived = bal - owed;
            uint256 toBuy = (arrived * buyBps) / BPS;
            ob += toBuy;
            ol += arrived - toBuy;
            emit Split(arrived, toBuy, arrived - toBuy, buyBps);
        }

        uint256 sentBuy = 0;
        uint256 sentLiq = 0;
        if (ob != 0 && _tryTransfer(buyAndBack, ob)) {
            sentBuy = ob;
            ob = 0;
        }
        if (ol != 0 && _tryTransfer(liquidity, ol)) {
            sentLiq = ol;
            ol = 0;
        }
        owedBuy = ob;
        owedLiq = ol;
        emit Distributed(sentBuy, sentLiq);
    }

    /// @inheritdoc IRevenueRouter
    function timelock() public view override(IRevenueRouter, GuardianPause) returns (address) {
        return super.timelock();
    }

    /// @notice The share of each arrival that goes to BuyAndBack: 2,000-8,000 bps (question 10: 5,000 at launch,
    ///         changed only as an owner decision on the keeper's 28-day report). Owed shares already split keep the
    ///         split of their day.
    function setBuyBps(uint256 buyBps_) external onlyTimelock {
        if (buyBps_ < MIN_BUY_BPS || buyBps_ > MAX_BUY_BPS) revert BadBuyBps(buyBps_);
        buyBps = buyBps_;
        emit BuyBpsSet(buyBps_);
    }

    /// @dev `usdg.transfer(to, amount)` with TRANSFER_GAS, true only for a call that succeeded and returned nothing or
    ///      a true word. Copies at most 32 bytes of the reply.
    function _tryTransfer(address to, uint256 amount) internal returns (bool ok) {
        if (gasleft() < (TRANSFER_GAS * 64) / 63 + TRANSFER_MARGIN) revert TransferStarved();
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        address token = address(usdg);
        assembly ("memory-safe") {
            let success := call(TRANSFER_GAS, token, 0, add(data, 32), mload(data), 0, 0)
            switch returndatasize()
            case 0 { ok := success }
            default {
                if and(success, iszero(lt(returndatasize(), 32))) {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, 32)
                    ok := eq(mload(ptr), 1)
                }
            }
        }
    }
}
