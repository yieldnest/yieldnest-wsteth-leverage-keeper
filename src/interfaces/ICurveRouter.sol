// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICurveRouter {
    function exchange(
        address[11] calldata route,
        uint256[5][5] calldata swapParams,
        uint256 amount,
        uint256 minDy,
        address[5] calldata pools
    ) external returns (uint256);
}
