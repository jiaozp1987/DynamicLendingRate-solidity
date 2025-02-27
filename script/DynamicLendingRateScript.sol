// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {DynamicLendingRate} from "../src/DynamicLendingRate.sol";

contract DynamicLendingRateScript is Script {
    DynamicLendingRate public dynamicLendingRate;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        dynamicLendingRate = new DynamicLendingRate();

        vm.stopBroadcast();
    }
}
