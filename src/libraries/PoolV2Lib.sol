// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {CreditPool} from "../CreditPool.sol";

/// @title PoolV2Lib
/// @notice Linked (DELEGATECALLed) helpers for CreditPoolV2, split out only to keep the pool under the 24 KB code
///         limit. Everything runs in the pool's own context: hook calls are made by the pool's address.
library PoolV2Lib {
    uint256 internal constant HOOK_GAS = 300_000;
    uint256 internal constant HOOK_OVERHEAD = 12_000;

    error HookStarved();

    struct V1Record {
        uint64 enrolledAt;
        bool defaulted;
        uint256 activeLoans;
        uint256 loansRepaid;
        uint256 volumeRepaid;
        uint256 feesPaid;
        uint256 recourseHonored;
        uint256 childrenDefaulted;
        uint256 qualifiedRepaid;
        uint256 dollarSecondsRepaid;
    }

    /// An agent with no loan open and no default on v1. True on a chain without a v1.
    function v1Clean(CreditPool v1, uint256 id) external view returns (bool) {
        if (address(v1) == address(0)) return true;
        CreditPool.Agent memory o = v1.getAgent(id);
        return o.activeLoans == 0 && !o.defaulted;
    }

    function v1Record(CreditPool v1, uint256 id) external view returns (V1Record memory r) {
        CreditPool.Agent memory o = v1.getAgent(id);
        r.enrolledAt = o.enrolledAt;
        r.defaulted = o.defaulted;
        r.activeLoans = o.activeLoans;
        r.loansRepaid = o.loansRepaid;
        r.volumeRepaid = o.volumeRepaid;
        r.feesPaid = o.feesPaid;
        r.recourseHonored = o.recourseHonored;
        r.childrenDefaulted = o.childrenDefaulted;
        r.qualifiedRepaid = o.qualifiedRepaid;
        r.dollarSecondsRepaid = o.dollarSecondsRepaid;
    }

    /// ECDSA for an EOA owner, EIP-1271 for a contract owner.
    function validSig(address signer, bytes32 digest, bytes calldata sig) external view returns (bool) {
        return SignatureChecker.isValidSignatureNow(signer, digest, sig);
    }

    /// @dev staticcall with a fixed gas budget; only the first 32 bytes of the reply are read. A hook that reverts,
    ///      runs out of gas, has no code, or replies anything but 1 blocks the borrow. The caller must supply the
    ///      budget: starving the hook reverts the whole call instead of silently failing it.
    function canBorrow(address h, bytes memory data) external view returns (bool) {
        if (h.code.length == 0) return false;
        if (gasleft() < HOOK_GAS * 64 / 63 + HOOK_OVERHEAD) revert HookStarved();
        bool ok;
        uint256 word;
        uint256 g = HOOK_GAS;
        assembly {
            ok := staticcall(g, h, add(data, 0x20), mload(data), 0, 0)
            if and(ok, gt(returndatasize(), 31)) {
                returndatacopy(0, 0, 32)
                word := mload(0)
            }
        }
        if (!ok && gasleft() <= HOOK_GAS / 63) revert HookStarved();
        return ok && word == 1;
    }

    /// @dev A notification: never copies return data, and a failing hook never blocks the pool, unless the caller
    ///      starved it on purpose (then the whole call reverts, so it can be retried with enough gas).
    function notify(address h, bytes memory data) external returns (bool ok) {
        if (h.code.length == 0) return true;
        if (gasleft() < HOOK_GAS * 64 / 63 + HOOK_OVERHEAD) revert HookStarved();
        uint256 g = HOOK_GAS;
        assembly {
            ok := call(g, h, 0, add(data, 0x20), mload(data), 0, 0)
        }
        if (!ok && gasleft() <= HOOK_GAS / 63) revert HookStarved();
    }
}
