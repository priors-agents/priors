// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ScoreLib
/// @notice Credit-backed trust score, v1. A pure function of on-chain repayment records, so anyone can recompute
///         it from events and nobody has to trust the number this contract emits.
///
///         Score is in [0, 1000]. Every input costs real capital held at risk for real time:
///           - dollar-days repaid (principal x actual holding time (capped at term), summed over repaid loans)   -> up to 400 points
///           - qualified loans repaid (term >= minScoreTerm, 7 days by default) -> up to 200 points
///           - backing at risk for this agent (sponsor delegation + own stake)  -> up to 150 points
///           - age since enrollment                                             -> up to 150 points
///           - recourse loans honored (paid a vouched child's debt)             -> up to 100 points
///           - each vouched child that defaulted                                -> -75 points
///           - own default                                                      -> 0, always
///
///         v0 counted loans and volume, which a sponsor could farm with one-day loans for cents in fees. Now the
///         cheapest path to a high score is the honest one: borrow a meaningful amount, hold it for weeks, repay.
library ScoreLib {
    uint256 internal constant USDC = 1e6;

    struct Inputs {
        bool defaulted;
        uint256 qualifiedRepaid; // repaid loans held for at least the minimum scoring term
        uint256 dollarSecondsRepaid; // sum of principal (6 decimals) x term (seconds) over repaid loans
        uint256 backing; // delegatedIn + stake, USDC
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint256 ageSeconds;
    }

    function score(Inputs memory i) internal pure returns (uint256) {
        if (i.defaulted) return 0;

        uint256 dollarDays = i.dollarSecondsRepaid / 1 days; // USDC-days, 6 decimals
        uint256 timePts = _min(400, dollarDays / (10 * USDC)); // 1 pt per $10 held for a day; $4,000-days max
        uint256 countPts = _min(200, i.qualifiedRepaid * 20); // 10 week-long loans max it out
        uint256 backingPts = _min(150, i.backing / (5 * USDC)); // 1 pt per $5 at risk, $750 max
        uint256 agePts = _min(150, (i.ageSeconds / 1 days) * 2); // 75 days max
        uint256 honorPts = _min(100, i.recourseHonored * 50);

        uint256 positive = timePts + countPts + backingPts + agePts + honorPts;
        uint256 penalty = i.childrenDefaulted * 75;
        if (penalty >= positive) return 0;
        uint256 s = positive - penalty;
        return s > 1000 ? 1000 : s;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
