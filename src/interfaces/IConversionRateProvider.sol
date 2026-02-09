// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IConversionRateProvider {
    /// @notice Returns the conversion rate from asset to debt denomination.
    /// @dev The rate should be expressed as: 1 unit of asset = rate units of debt (scaled by 1e18).
    function getRate() external view returns (uint256);
}
