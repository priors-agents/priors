// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {V5Storage as S} from "../../src/v5/V5Storage.sol";
import {V5Lens} from "../../src/v5/V5Lens.sol";

/// @dev SeatVaultV5's getters, which its fallback serves from V5Lens (docs/V5-BUILD.md, "Size").
interface IV5Lens {
    function needed(uint256 id, uint256 tokens, bool asOwner) external view returns (V5Lens.Needed memory);
    function usdgPathOpen(uint256 usdgIn) external view returns (bool, uint8);
    function placeRoom(uint256 id) external view returns (uint256 tokens, bool eligible);
    function lineOf(uint256 id) external view returns (uint256);
    function exitServiceOpen() external view returns (bool);
    function depthGuard() external view returns (bool);
    function spotGuardOn() external view returns (bool);
    function kEff() external view returns (uint8);
    function keeper() external view returns (address);
    function epochOf(uint256 t) external view returns (uint256);
    function paused() external view returns (bool);
    function breakerTripped() external view returns (bool);
    function depthGuardOn() external view returns (bool);
    function priceCache()
        external
        view
        returns (uint160 sqrtMedian, uint64 obsAt, uint160 sqrtWeekLow, uint160 sqrtObservation);
    function price() external view returns (S.Price memory);
    function exitHead()
        external
        view
        returns (uint256 entryId, address holder, uint256 rest, uint160 sqrtPLeave, uint64 joinedAt);
    function bookPoints(uint256 id, uint256 epoch) external view returns (uint256);
    function globalPoints(uint256 epoch) external view returns (uint256);
    function cReturned() external view returns (uint256);
    function claimable(address holder) external view returns (uint256);
    function latestGen(uint256 id) external view returns (uint32);
    function getGen(uint256 id, uint32 gen) external view returns (S.Gen memory);
    function position(uint256 id, uint32 gen, uint8 layer, address holder) external view returns (S.Pos memory);
    function record(uint256 id, uint32 gen, uint8 layer, uint32 day, address holder)
        external
        view
        returns (S.Rec memory);
    function leavingBucket(uint256 id, uint32 gen, uint8 layer, uint32 day) external view returns (S.Leaving memory);
    function pendingBucket(uint256 id, uint32 gen, uint8 layer, uint32 day) external view returns (S.Pending memory);
    function loanRecord(uint256 loanId) external view returns (S.LoanRec memory);
    function entry(uint256 entryId) external view returns (S.Entry memory);
    function totals()
        external
        view
        returns (
            uint256 holdersOwed,
            uint256 bufferOwed,
            uint256 protocolFeesOwed,
            uint256 ledger,
            uint256 carry,
            uint256 burned,
            uint256 recordedDefaults
        );
    function settings()
        external
        view
        returns (
            bool openBacking,
            uint256 premiumCap,
            uint256 maxSwapUsdg,
            uint256 openRoom,
            uint256 raiseRoom,
            uint256 vouchCap,
            uint8 minDrawK,
            bool premiumCheck,
            uint64 pausedUntil
        );
    function rooms() external view returns (uint64 epochPlusOne, uint256 openUsed, uint256 promoUsed, uint256 stakeUsed);
    function delegateOf(uint256 id) external view returns (address who, uint64 at);
    function targetPremiumBps(uint256 id) external view returns (uint256);
    function reopenAt(uint256 id) external view returns (uint64);
    function entryRule() external view returns (uint8 minEntryLoans, uint32 minEntryDays);
}
