// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAccountingModule {
    function deposit(uint256 amount) external;
}

interface IFlexStrategy {
    function accountingModule() external view returns (IAccountingModule);
    function processor(address[] calldata targets, uint256[] memory values, bytes[] calldata data)
        external
        returns (bytes[] memory);
}
