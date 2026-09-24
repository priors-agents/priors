// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditPoolV2} from "../src/CreditPoolV2.sol";
import {CreditLensV2} from "../src/CreditLensV2.sol";
import {TreasurySponsorV4} from "../src/TreasurySponsorV4.sol";
import {SeatVaultV2} from "../src/SeatVaultV2.sol";
import {IERC8004Identity} from "../src/interfaces/IERC8004Identity.sol";
import {IPonsFeeEscrow, IPonsFactoryCreator} from "../src/interfaces/IPonsFeeEscrow.sol";

/// @notice Deploys the v2 set in the order of docs/MIGRATION-v2-RUNBOOK.md §2, §6.1 and §7.1:
///         a 48 h TimelockController (proposer = executor = SAFE, no admin) as the pool's owner, CreditPoolV2
///         (PoolV2Lib is linked by forge) with params copied from v1 and keeperBounty 0, treasury v4 with the
///         real Pons escrow and factory, and the seat vault. The deployer owns nothing: every owner is the
///         timelock or the Safe. It also deploys CreditLensV2 (views only). The Safe steps that follow (seat gates,
///         roots, invites, funding) are the
///         runbook's, not this script's.
///
///   V1=0x…  USDG=0x…  REGISTRY=0x…  PRIORS=0x…  SAFE=0x…  PONS_ESCROW=0x…  PONS_FACTORY=0x…  FEE_SINK=0x…
///   SEAT_SIZE (18dp, default 1_000_000e18)  SEAT_LINE (6dp, default 5e6)  OUT (default deployments/<chainId>.v2.json)
///
///   forge script script/DeployV2.s.sol --rpc-url <rpc> --broadcast --private-key <deployer>
contract DeployV2 is Script {
    function run() external {
        CreditPool v1 = CreditPool(vm.envAddress("V1"));
        IERC20 usdg = IERC20(vm.envAddress("USDG"));
        address registry = vm.envAddress("REGISTRY");
        address priors = vm.envAddress("PRIORS");
        address safe = vm.envAddress("SAFE");
        address escrow = vm.envOr("PONS_ESCROW", address(0));
        address factory = vm.envOr("PONS_FACTORY", address(0));
        address sink = vm.envOr("FEE_SINK", safe);

        // Every owner and role below is SAFE: an EOA there (a typo, the deployer's own address) would hand one key
        // the pool's timelock, treasury v4 and the seat vault.
        require(safe.code.length > 0, "SAFE must be the multisig contract, not an EOA");
        require(sink != address(0), "FEE_SINK is zero");

        CreditPool.Params memory p = v1.getParams();
        CreditPoolV2.Params memory params = CreditPoolV2.Params({
            minLoan: p.minLoan,
            maxLoan: p.maxLoan,
            minTerm: p.minTerm,
            maxTerm: p.maxTerm,
            grace: p.grace,
            minScoreTerm: p.minScoreTerm,
            feeBps: p.feeBps,
            sponsorFeeBps: p.sponsorFeeBps,
            protocolFeeBps: p.protocolFeeBps,
            minStake: p.minStake,
            // final audit N-2: every loan is fully backed, so a cap below 100% protects nobody and lets a self-loan
            // pinned at the cap freeze honest borrowing; at 10_000 lenders' cash is never lent past its own backers.
            maxUtilizationBps: 10_000,
            keeperBounty: 0 // exploit audit F-1: a non-zero bounty is farmable until it is charged to the backer
        });

        address[] memory safeOnly = new address[](1);
        safeOnly[0] = safe;

        vm.startBroadcast();
        TimelockController timelock = new TimelockController(48 hours, safeOnly, safeOnly, address(0));
        CreditPoolV2 pool = new CreditPoolV2(usdg, IERC8004Identity(registry), v1, address(timelock), safe, params);
        // Read-only views in v1's layout for the site, the SDK and the keeper (no owner, no state).
        CreditLensV2 lens = new CreditLensV2(pool);
        TreasurySponsorV4 t4 =
            new TreasurySponsorV4(pool, IPonsFeeEscrow(escrow), IPonsFactoryCreator(factory), safe, sink);
        SeatVaultV2 vault = new SeatVaultV2(
            pool,
            IERC20(priors),
            safe,
            sink,
            SeatVaultV2.Params({
                seatSize: vm.envOr("SEAT_SIZE", uint256(1_000_000e18)),
                line: vm.envOr("SEAT_LINE", uint256(5e6)),
                burnBps: 5000,
                maxOpenSeats: 10,
                epochCap: 50e6,
                epochLength: 7 days
            })
        );
        vm.stopBroadcast();

        require(pool.owner() == address(timelock), "pool owner must be the timelock");
        require(pool.getParams().keeperBounty == 0, "keeperBounty must be 0");

        string memory k = "v2";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployBlock", block.number);
        vm.serializeAddress(k, "v1", address(v1));
        vm.serializeAddress(k, "usdg", address(usdg));
        vm.serializeAddress(k, "registry", registry);
        vm.serializeAddress(k, "priors", priors);
        vm.serializeAddress(k, "safe", safe);
        vm.serializeAddress(k, "timelock", address(timelock));
        vm.serializeAddress(k, "pool", address(pool));
        vm.serializeAddress(k, "lens", address(lens));
        vm.serializeAddress(k, "treasuryV4", address(t4));
        string memory out = vm.serializeAddress(k, "seatVault", address(vault));
        string memory path = vm.envOr("OUT", string.concat("deployments/", vm.toString(block.chainid), ".v2.json"));
        vm.writeJson(out, path);
        console.log("timelock  ", address(timelock));
        console.log("pool v2   ", address(pool));
        console.log("lens      ", address(lens));
        console.log("treasury4 ", address(t4));
        console.log("seat vault", address(vault));
        console.log("written to", path);
    }
}
