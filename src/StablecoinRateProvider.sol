// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IConversionRateProvider} from "./interfaces/IConversionRateProvider.sol";

/// @title StablecoinRateProvider
/// @notice Returns a fixed 1:1 conversion rate between two stablecoins.
///         Decimal normalization is handled by the consumer (YieldNestKeeper._debtToAsset).
contract StablecoinRateProvider is IConversionRateProvider {
    address public immutable BASE_ASSET;

    constructor(address _baseAsset) {
        BASE_ASSET = _baseAsset;
    }

    /// @notice Returns 1e18, representing a 1:1 peg between BASE_ASSET and QUOTE_ASSET.
    function getRate(address) external pure override returns (uint256) {
        return 1e18;
    }
}
