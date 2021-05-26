// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IOracle {
    function R(address token, uint256 amount) external view returns (uint256);
}
