// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {YieldNestKeeper} from "../src/YieldNestKeeper.sol";
import {StablecoinRateProvider} from "../src/StablecoinRateProvider.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {YnRWAxConfig} from "./YnRWAxConfig.sol";

contract DeployScript is Script, YnRWAxConfig {
    function run() public {
        vm.startBroadcast();

        address admin = msg.sender;

        StablecoinRateProvider rateProvider = new StablecoinRateProvider(USDC);

        YieldNestKeeper.Config memory config =
            _buildConfig(rateProvider, AggregatorV3Interface(WSTETH_USD_ORACLE), 9900);

        new YieldNestKeeper(admin, config);

        vm.stopBroadcast();
    }
}
