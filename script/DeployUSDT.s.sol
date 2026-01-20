// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Script} from "forge-std/Script.sol";
import {USDT} from "../src/USDT.sol";

contract USDTScript is Script {
    USDT public usdt;

    function setUp() public {}

    function run() public {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);
        usdt = new USDT(msg.sender, 1_000_000 * 10 ** 6);
        vm.stopBroadcast();
    }
}
