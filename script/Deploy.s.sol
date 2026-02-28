// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {YieldNestKeeper} from "../src/YieldNestKeeper.sol";
import {IYnVault} from "../src/interfaces/IYnVault.sol";
import {IConversionRateProvider} from "../src/interfaces/IConversionRateProvider.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployScript is Script {
    function run() public {
        vm.startBroadcast();

        // TODO: Replace with actual mainnet addresses before deployment
        address admin = msg.sender;

        address[] memory positions = new address[](1);
        positions[0] = address(0); // TODO: set managed position address

        address[11] memory route; // TODO: configure Curve route
        uint256[5][5] memory swapParams; // TODO: configure swap params
        address[5] memory pools; // TODO: configure pools

        YieldNestKeeper.Config memory config = YieldNestKeeper.Config({
            vault: IYnVault(address(0)), // TODO
            positions: positions,
            debtToken: IERC20(address(0)), // TODO
            rateProvider: IConversionRateProvider(address(0)), // TODO
            approvedWallet: address(0), // TODO
            rewardAsset: address(0), // TODO
            destinationStrategy: address(0), // TODO
            curveRouter: address(0), // TODO
            route: route,
            swapParams: swapParams,
            pools: pools,
            assetOracle: AggregatorV3Interface(address(0)), // TODO
            rewardOracle: AggregatorV3Interface(address(0)), // TODO
            maxOracleAge: 86400,
            minOutputBps: 9900
        });

        new YieldNestKeeper(admin, config);

        vm.stopBroadcast();
    }
}
