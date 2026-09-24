// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CreditPool} from "./CreditPool.sol";
import {CreditPoolV2} from "./CreditPoolV2.sol";
import {ScoreLib} from "./libraries/ScoreLib.sol";

/// @title CreditLensV2
/// @notice Read-only views over CreditPoolV2, kept out of the pool so it fits the code-size limit. `creditReport`
///         returns v1's layout, so the site, the SDK and backers written for v1 read v2 unchanged: `earned` is
///         always 0, `capacity` is the agent's line (or a root's backing), `stake` is a root's backing.
contract CreditLensV2 {
    CreditPoolV2 public immutable pool;

    constructor(CreditPoolV2 pool_) {
        pool = pool_;
    }

    function available(uint256 id) public view returns (uint256) {
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        if (a.isRoot) return pool.freeBacking(id);
        if (a.defaulted || a.frozen || a.sponsor == 0) return 0;
        return a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0;
    }

    /// The v1 score, computed from the v2 record. Keyed on having a record at all (an imported agent shows its
    /// history before it has a line here).
    function score(uint256 id) public view returns (uint256) {
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        return _score(id, a);
    }

    function _score(uint256 id, CreditPoolV2.Agent memory a) internal view returns (uint256) {
        if (a.enrolledAt == 0) return 0;
        return ScoreLib.score(
            ScoreLib.Inputs({
                defaulted: a.defaulted,
                qualifiedRepaid: a.qualifiedRepaid,
                dollarSecondsRepaid: a.dollarSecondsRepaid,
                backing: a.isRoot ? pool.backing(id) : a.delegatedIn,
                recourseHonored: a.recourseHonored,
                childrenDefaulted: a.childrenDefaulted,
                ageSeconds: block.timestamp - a.enrolledAt
            })
        );
    }

    function creditReport(uint256 id) external view returns (CreditPool.CreditReport memory r) {
        CreditPoolV2.Agent memory a = pool.getAgent(id);
        uint256 b = a.isRoot ? pool.backing(id) : 0;
        r.enrolled = a.enrolledAt != 0;
        r.isRoot = a.isRoot;
        r.defaulted = a.defaulted;
        r.sponsor = a.sponsor;
        r.capacity = a.isRoot ? b : (a.defaulted ? 0 : a.delegatedIn);
        r.available = available(id);
        r.delegatedIn = a.delegatedIn;
        r.delegatedOut = a.delegatedOut;
        r.stake = b;
        r.principalOut = a.principalOut;
        r.activeLoans = a.activeLoans;
        r.loansRepaid = a.loansRepaid;
        r.volumeRepaid = a.volumeRepaid;
        r.feesPaid = a.feesPaid;
        r.recourseHonored = a.recourseHonored;
        r.childrenDefaulted = a.childrenDefaulted;
        r.enrolledAt = a.enrolledAt;
        r.score = _score(id, a);
        r.qualifiedRepaid = a.qualifiedRepaid;
        r.dollarSecondsRepaid = a.dollarSecondsRepaid;
    }
}
