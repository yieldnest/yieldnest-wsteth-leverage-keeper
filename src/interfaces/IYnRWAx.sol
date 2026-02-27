// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IYnRWAx is IERC20 {
    /// @notice Returns the underlying asset of the vault.
    function asset() external view returns (address);

    /// @notice Converts a given amount of shares to the equivalent amount of assets.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice Converts a given amount of assets to the equivalent amount of shares.
    function convertToShares(uint256 assets) external view returns (uint256 shares);

    /// @notice Permissioned call to withdraw assets by burning the equivalent shares.
    /// @param asset_ The address of the asset to withdraw.
    /// @param assets The amount of assets to withdraw.
    /// @param receiver The address that receives the withdrawn assets.
    /// @param owner The address whose shares are burned.
    /// @return shares The amount of shares burned.
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
}
