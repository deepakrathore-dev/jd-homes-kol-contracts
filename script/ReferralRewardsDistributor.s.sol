// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {ReferralRewardsDistributor} from "../src/ReferralRewardsDistributor.sol";

contract ReferralRewardsDistributorScript is Script {
    ReferralRewardsDistributor public distributor;

    function setUp() public {}

    function run() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        distributor = new ReferralRewardsDistributor();
        vm.stopBroadcast();
    }
}
