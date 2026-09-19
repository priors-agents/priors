// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CreditPool} from "./CreditPool.sol";
import {IERC8004Identity} from "./interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "./interfaces/IPonsFeeEscrow.sol";

/// @title TreasurySponsor
/// @notice The token is a sponsor. Creator fees the project token earns on Pons land here; a sweep sends a share
///         to the pool's first-loss reserve and stakes the rest under the treasury's own ERC-8004 identity as a
///         root sponsor. From that stake it vouches by rule, not by judgement:
///
///           firstLine(agent)  any ERC-8004 identity that has never been enrolled gets a small first line
///           raise(agent)      an agent it sponsors that has repaid enough qualified loans, is seasoned and
///                             clean, gets its line raised to the second tier
///
///         Everything it vouches is capped per epoch, so the most a sybil attack can cost the treasury is one
///         epoch's cap, in public. The sponsor fees its agents pay (25% of every loan fee) are collected to the
///         fee sink, which is the buyback wallet. Losses show up as slashed stake and burnt branches on the
///         treasury's own tree. Every call here is permissionless except the owner's parameter changes.
contract TreasurySponsor is Ownable2Step, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct Rules {
        uint256 reserveBps; // share of each sweep that goes to the reserve; the rest is staked
        uint256 firstLine; // USDC, line for a brand-new identity
        uint256 secondLine; // USDC, line after a clean record
        uint256 epochCap; // USDC vouched per epoch, all agents combined
        uint64 epochLength; // seconds
        uint64 minSeasoning; // seconds enrolled before a raise
        uint256 minQualified; // qualified loans repaid before a raise
        uint256 minScore; // score before a raise
    }

    CreditPool public immutable pool;
    IERC20 public immutable asset;
    IERC8004Identity public immutable registry;
    IPonsFeeEscrow public immutable escrow; // may be zero on chains without Pons
    IPonsFactoryCreator public immutable factory;

    uint256 public agentId; // the treasury's own ERC-8004 identity, once adopted
    address public feeSink; // where collected sponsor fees go (the buyback wallet)
    Rules public rules;

    uint64 public epochStart;
    uint256 public vouchedThisEpoch;
    mapping(uint256 => bool) public firstLined;

    uint256 public totalToReserve;
    uint256 public totalStaked;
    uint256 public totalCollected;

    event Adopted(uint256 indexed agentId);
    event Swept(address indexed caller, uint256 claimed, uint256 toReserve, uint256 toStake);
    event FirstLine(uint256 indexed agentId, uint256 amount, address indexed caller);
    event Raised(uint256 indexed agentId, uint256 added, uint256 lineNow);
    event Collected(uint256 amount, address indexed to);
    event RulesUpdated(Rules rules);
    event FeeSinkUpdated(address indexed feeSink);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error NotAdopted();
    error NotOurs(uint256 agentId);
    error AlreadyLined(uint256 agentId);
    error AlreadyEnrolled(uint256 agentId);
    error NotEligible(uint256 agentId);
    error EpochCapReached(uint256 wanted, uint256 left);
    error InvalidRules();

    constructor(
        CreditPool pool_,
        IPonsFeeEscrow escrow_,
        IPonsFactoryCreator factory_,
        address owner_,
        address feeSink_
    ) Ownable(owner_) {
        pool = pool_;
        asset = pool_.usdc();
        registry = pool_.registry();
        escrow = escrow_;
        factory = factory_;
        feeSink = feeSink_ == address(0) ? owner_ : feeSink_;
        rules = Rules({
            reserveBps: 5000,
            firstLine: 5e6,
            secondLine: 50e6,
            epochCap: 100e6,
            epochLength: 7 days,
            minSeasoning: 14 days,
            minQualified: 3,
            minScore: 100
        });
        epochStart = uint64(block.timestamp);
        asset.approve(address(pool_), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Identity
    // ------------------------------------------------------------------

    /// @notice Bind the treasury to an ERC-8004 identity it owns. Register one, transfer it here, then adopt.
    function adopt(uint256 id) external onlyOwner {
        if (registry.ownerOf(id) != address(this)) revert NotOurs(id);
        agentId = id;
        emit Adopted(id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------
    // Money in: creator fees -> reserve + stake
    // ------------------------------------------------------------------

    /// @notice Claim what the Pons escrow owes in the pool asset, then split everything held here: a share to
    ///         the reserve, the rest staked as this sponsor's capacity. Permissionless.
    function sweep() external returns (uint256 toReserve, uint256 toStake) {
        uint256 claimed;
        if (address(escrow) != address(0)) {
            claimed = escrow.balanceOfToken(address(this), address(asset));
            if (claimed > 0) escrow.claimToken(address(asset));
        }
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) {
            emit Swept(msg.sender, claimed, 0, 0);
            return (0, 0);
        }
        toReserve = bal * rules.reserveBps / 10_000;
        toStake = bal - toReserve;
        if (toReserve > 0) {
            pool.fundReserve(toReserve);
            totalToReserve += toReserve;
        }
        if (toStake > 0) {
            if (agentId == 0) {
                toStake = 0; // nothing to stake under yet; held until adopted
            } else if (!pool.creditReport(agentId).enrolled) {
                if (toStake >= pool.getParams().minStake) pool.enrollRoot(agentId, toStake);
                else toStake = 0;
            } else {
                pool.addStake(agentId, toStake);
            }
            totalStaked += toStake;
        }
        emit Swept(msg.sender, claimed, toReserve, toStake);
    }

    /// @notice What a sweep would move right now.
    function sweepable() external view returns (uint256) {
        uint256 c = address(escrow) != address(0) ? escrow.balanceOfToken(address(this), address(asset)) : 0;
        return c + asset.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Vouching by rule
    // ------------------------------------------------------------------

    /// @notice Give a never-enrolled ERC-8004 identity its first line. Anyone can call it for any agent.
    function firstLine(uint256 id) external {
        if (agentId == 0) revert NotAdopted();
        if (firstLined[id]) revert AlreadyLined(id);
        if (pool.creditReport(id).enrolled) revert AlreadyEnrolled(id);
        _spend(rules.firstLine);
        firstLined[id] = true;
        pool.vouch(agentId, id, rules.firstLine);
        emit FirstLine(id, rules.firstLine, msg.sender);
    }

    /// @notice Raise the line of an agent this treasury sponsors, once its record qualifies. Anyone can call it.
    function raise(uint256 id) external {
        if (agentId == 0) revert NotAdopted();
        CreditPool.CreditReport memory r = pool.creditReport(id);
        if (!eligibleForRaise(r)) revert NotEligible(id);
        uint256 add = rules.secondLine - r.delegatedIn;
        _spend(add);
        pool.vouch(agentId, id, add);
        emit Raised(id, add, r.delegatedIn + add);
    }

    function eligibleForRaise(CreditPool.CreditReport memory r) public view returns (bool) {
        return r.enrolled && !r.defaulted && r.sponsor == agentId && r.childrenDefaulted == 0
            && r.qualifiedRepaid >= rules.minQualified && r.score >= rules.minScore
            && block.timestamp >= uint256(r.enrolledAt) + rules.minSeasoning && r.delegatedIn < rules.secondLine;
    }

    /// @notice How much the treasury may still vouch this epoch.
    function epochRoom() public view returns (uint256) {
        uint256 used = block.timestamp >= epochStart + rules.epochLength ? 0 : vouchedThisEpoch;
        return rules.epochCap > used ? rules.epochCap - used : 0;
    }

    function _spend(uint256 amount) internal {
        if (block.timestamp >= epochStart + rules.epochLength) {
            epochStart = uint64(block.timestamp);
            vouchedThisEpoch = 0;
        }
        uint256 left = rules.epochCap > vouchedThisEpoch ? rules.epochCap - vouchedThisEpoch : 0;
        if (amount > left) revert EpochCapReached(amount, left);
        vouchedThisEpoch += amount;
    }

    // ------------------------------------------------------------------
    // Money out: sponsor fees -> buyback wallet
    // ------------------------------------------------------------------

    /// @notice Collect the sponsor fees the treasury's agents have paid and send them to the fee sink.
    function collect() external returns (uint256 amount) {
        if (agentId == 0) revert NotAdopted();
        amount = pool.claimSponsorFees(agentId, feeSink);
        totalCollected += amount;
        emit Collected(amount, feeSink);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

    function setRules(Rules calldata r) external onlyOwner {
        if (r.reserveBps > 10_000 || r.epochLength == 0 || r.firstLine == 0 || r.secondLine < r.firstLine) {
            revert InvalidRules();
        }
        rules = r;
        emit RulesUpdated(r);
    }

    function setFeeSink(address sink) external onlyOwner {
        feeSink = sink;
        emit FeeSinkUpdated(sink);
    }

    /// @notice Pull back stake that is not backing anything.
    function retire(uint256 amount, address to) external onlyOwner {
        pool.withdrawStake(agentId, amount, to);
    }

    /// @notice Redirect the launch token's future creator fees elsewhere. Claim first.
    function transferCreatorFeeRecipient(address launchToken, address newRecipient) external onlyOwner {
        factory.transferCreatorFeeRecipient(launchToken, newRecipient);
    }

    /// @notice Withdraw any other asset the escrow credited here (ETH, vested launch tokens).
    function rescue(address token, address to) external onlyOwner {
        if (token == address(0)) {
            if (address(escrow) != address(0) && escrow.balanceOf(address(this)) > 0) escrow.claim();
            uint256 bal = address(this).balance;
            (bool ok,) = to.call{value: bal}("");
            require(ok, "eth transfer failed");
            emit Rescued(address(0), to, bal);
        } else {
            require(token != address(asset), "use sweep");
            if (address(escrow) != address(0) && escrow.balanceOfToken(address(this), token) > 0) {
                escrow.claimToken(token);
            }
            uint256 bal = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, bal);
            emit Rescued(token, to, bal);
        }
    }

    receive() external payable {}
}
