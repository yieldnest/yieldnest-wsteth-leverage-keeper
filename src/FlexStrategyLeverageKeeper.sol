// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseLeverageKeeper} from "./BaseLeverageKeeper.sol";
import {IFlexStrategy, IAccountingModule} from "./interfaces/IFlexStrategy.sol";

/// @title FlexStrategyLeverageKeeper
/// @notice Leverage keeper that deposits harvested rewards into the strategy's accounting module.
contract FlexStrategyLeverageKeeper is BaseLeverageKeeper {
    constructor(address _initializer) BaseLeverageKeeper(_initializer) {}

    /// @dev Uses PROCESSOR_ROLE on the strategy to call accountingModule.deposit(rewardOut).
    function _onPostHarvest(Config memory c, uint256 rewardOut) internal override {
        IFlexStrategy strategy = IFlexStrategy(c.destinationStrategy);
        address accountingModule = address(strategy.accountingModule());

        address[] memory targets = new address[](1);
        targets[0] = accountingModule;

        uint256[] memory values = new uint256[](1);

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(IAccountingModule.deposit, rewardOut);

        strategy.processor(targets, values, data);
    }
}
