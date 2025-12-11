// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {ReferalRewardsDistributor} from "../src/ReferalRewardsDistributor.sol";

contract ReferalRewardsDistributorScript is Script {
    ReferalRewardsDistributor public distributor;

    function setUp() public {}

    function run() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        distributor = new ReferalRewardsDistributor();
        vm.stopBroadcast();
    }
}
