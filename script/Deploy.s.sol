// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {YieldNestKeeper} from "../src/YieldNestKeeper.sol";
import {BaseLeverageKeeper} from "../src/BaseLeverageKeeper.sol";
import {StablecoinRateProvider} from "../src/StablecoinRateProvider.sol";
import {LatestAnswerAdapter} from "../src/LatestAnswerAdapter.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {YnRWAxConfig} from "./YnRWAxConfig.sol";

contract DeployScript is Script, YnRWAxConfig {
    function run() public {
        vm.startBroadcast();

        address admin = msg.sender;

        StablecoinRateProvider rateProvider = new StablecoinRateProvider(USDC);

        LatestAnswerAdapter wstethOracle = new LatestAnswerAdapter(WSTETH_USD_ORACLE, 8);

        BaseLeverageKeeper.Config memory config =
            _buildConfig(rateProvider, AggregatorV3Interface(address(wstethOracle)), 9900);

        YieldNestKeeper keeper = new YieldNestKeeper(msg.sender);
        keeper.initialize(admin, config);

        vm.stopBroadcast();
    }
}
