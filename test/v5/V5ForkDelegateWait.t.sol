// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ICreditPoolV2} from "../../src/interfaces/ICreditPoolV2.sol";
import {IPoolT} from "./V5Base.sol";

interface ILiveV5 {
    function noteDelegate(uint256 id) external;
    function refresh(uint256 id) external;
    function delegateOf(uint256 id) external view returns (address who, uint64 at);
    function canBorrow(uint256, uint256, uint256, uint64, uint256, address, address, address)
        external
        view
        returns (bool);
}

interface ILiveRegistry {
    function ownerOf(uint256 id) external view returns (address);
}

/// @title The DEPLOYED SeatVaultV5 and CreditPoolV2 on a fork of Robinhood Chain: what the SDK's v5BeforeBorrow relies on
/// @notice Runs only when FORK_RPC is set; everything happens inside the local fork, nothing is broadcast:
///           FORK_RPC=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/v5/V5ForkDelegateWait.t.sol -vv
///         (FORK_AGENT picks the V5 line, default 7651, the first book V5 opened; it must be on V5's root with room.)
///         The pool asks V5's canBorrow with the borrower (msg.sender) as the caller (CreditPoolV2 _askBacker), and V5
///         refuses any caller but the owner until 24 h after it recorded that key (src/v5/V5View.sol), whatever room
///         the line has: so a key V5 records now borrows nothing for 24 h (V5_DELEGATE_WAIT in the x402 package and
///         sdk/float.mjs). And V5 lends for at most 10 days (V5Types MAX_LOAN_TERM): a longer term is refused
///         (GHSA-xccq-5ghg-w7mq, V5_TERM_TOO_LONG). The key borrowing 24 h later is V5LoansTest's
///         test_canBorrow_delegateAfter24h: a day on the fork lets V5's live inputs (its price cache, the swap
///         limiter's depth snapshot) age past what canBorrow takes, for the owner too.
contract V5ForkDelegateWaitTest is Test {
    IPoolT constant POOL = IPoolT(0x281210097f0de7A8FB6F87310AF0f089c9C8DE21);
    ILiveRegistry constant REG = ILiveRegistry(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    ILiveV5 constant V5 = ILiveV5(0xC999014C6218EC41f0aE412d49AE8f2aA4c539fD); // deployments/4663.v2.json seatVaultV5
    uint256 constant V5_ROOT = 8762; // seatVaultV5AgentId

    bool forked;
    uint256 id;
    address owner;
    address key = makeAddr("agentKey");

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        forked = true;
        assertEq(block.chainid, 4663, "Robinhood Chain");
        id = vm.envOr("FORK_AGENT", uint256(7651));
        owner = REG.ownerOf(id);
        ICreditPoolV2.Agent memory a = POOL.getAgent(id);
        assertEq(a.sponsor, V5_ROOT, "a line V5 backs");
        console2.log("fork block", block.number, "agent", id);
    }

    function _minLoan() internal view returns (uint256) {
        return POOL.getParams().minLoan;
    }

    function _room() internal view returns (uint256) {
        ICreditPoolV2.Agent memory a = POOL.getAgent(id);
        return a.delegatedIn > a.principalOut ? a.delegatedIn - a.principalOut : 0;
    }

    function test_fork_aKeyV5RecordsNow_borrowsNothingFor24h_whateverTheRoom() public onFork {
        // the owner names a new pool delegate, and anyone has V5 record it (what v5BeforeBorrow's noteDelegate does)
        vm.prank(owner);
        POOL.setDelegate(id, key);
        assertTrue(POOL.isController(id, key));
        V5.noteDelegate(id);
        (address who, uint64 at) = V5.delegateOf(id);
        assertEq(who, key);
        assertEq(at, block.timestamp);
        // the owner's refresh: the line has room for this loan
        vm.prank(owner);
        V5.refresh(id);
        uint256 amount = _minLoan();
        assertGe(_room(), amount, "the line has room");

        // the recorded key, under 24 h: refused by V5 through the pool, room or not (the client's old "room" branch)
        vm.prank(key);
        vm.expectRevert(abi.encodeWithSignature("BorrowBlockedByBacker(uint256)", V5_ROOT));
        POOL.borrow(id, amount, 7 days, key, type(uint256).max);
        assertFalse(V5.canBorrow(V5_ROOT, id, amount, 7 days, 1, key, owner, key), "the view agrees");

        // the owner, the same loan: lent (V5 refuses the key, not the line)
        vm.prank(owner);
        uint256 loanId = POOL.borrow(id, amount, 7 days, owner, type(uint256).max);
        assertGt(loanId, 0);
        console2.log("owner's loan", loanId);
    }

    function test_fork_aTermOverTenDays_isRefused_tenDaysLends() public onFork {
        vm.prank(owner);
        V5.refresh(id);
        uint256 amount = _minLoan();
        assertGe(_room(), amount, "the line has room");
        assertGe(POOL.getParams().maxTerm, 11 days, "the pool itself takes 11 days");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("BorrowBlockedByBacker(uint256)", V5_ROOT));
        POOL.borrow(id, amount, 10 days + 1, owner, type(uint256).max);
        vm.prank(owner);
        uint256 loanId = POOL.borrow(id, amount, 10 days, owner, type(uint256).max);
        assertGt(loanId, 0, "10 days, V5's longest, lends");
    }
}
