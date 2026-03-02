// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title IYnVault
/// @notice Minimal interface for a yieldnest-vault instance (https://github.com/yieldnest/yieldnest-vault).
///         The vault is ERC4626-compliant. The keeper uses standard redeem() to burn shares for the
///         default asset, and withdrawAsset() (permissioned, requires ASSET_WITHDRAWER_ROLE) for
///         withdrawing a specific listed asset.
interface IYnVault is IERC4626 {
    /// @notice Permissioned: burn shares from `owner`, send `assets` of `asset_` to `receiver`.
    ///         Requires ASSET_WITHDRAWER_ROLE on the caller.
    /// @param asset_    The listed asset to withdraw (must be in the vault's asset list).
    /// @param assets    The amount of `asset_` to withdraw.
    /// @param receiver  Address that receives the withdrawn assets.
    /// @param owner     Address whose shares are burned.
    /// @return shares   The number of shares burned.
    function withdrawAsset(address asset_, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);
}
