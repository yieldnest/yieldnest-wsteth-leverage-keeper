// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title LatestAnswerAdapter
/// @notice Wraps an oracle that only exposes latestAnswer() (e.g. Aave's
///         WstETHSynchronicityPriceAdapter) into the full AggregatorV3Interface
///         expected by FlexStrategyLeverageKeeper.
contract LatestAnswerAdapter is AggregatorV3Interface {
    address public immutable SOURCE;
    uint8 private immutable _decimals;

    constructor(address source, uint8 decimals_) {
        SOURCE = source;
        _decimals = decimals_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (bool ok, bytes memory data) = SOURCE.staticcall(abi.encodeWithSignature("latestAnswer()"));
        require(ok, "latestAnswer() failed");
        answer = abi.decode(data, (int256));
        roundId = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
        answeredInRound = 1;
    }
}
