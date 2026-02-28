// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IConversionRateProvider {
    /// @notice Returns the conversion rate for a given asset to debt denomination.
    /// @dev The rate should be expressed as: 1 unit of asset = rate units of debt (scaled by 1e18).
    /// @param asset The asset to get the rate for.
    function getRate(address asset) external view returns (uint256);
}
