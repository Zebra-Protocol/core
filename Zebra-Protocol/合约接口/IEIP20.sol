// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IEIP20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint value) external returns (bool);
}
