// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {ReferralRewardsDistributor} from "../src/ReferralRewardsDistributor.sol";
import {AccessRoleManager} from "../src/AccessRoleManager.sol";

contract ReferralRewardsDistributorScript is Script {
    AccessRoleManager public accessManager;
    ReferralRewardsDistributor public distributor;

    function setUp() public {}

    function run() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);
        // Deployer becomes the owner/admin of the access manager.
        accessManager = new AccessRoleManager(deployer);
        distributor = new ReferralRewardsDistributor(address(accessManager));
        vm.stopBroadcast();
    }
}
