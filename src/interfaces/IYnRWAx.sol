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

    /// @notice Permissioned call to burn shares and withdraw the underlying asset.
    /// @param amount The amount of shares to burn.
    /// @return assets The amount of underlying assets received.
    function withdrawAsset(uint256 amount) external returns (uint256 assets);
}
