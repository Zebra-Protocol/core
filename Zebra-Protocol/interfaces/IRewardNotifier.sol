// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IRewardNotifier {
    function notify(address token, uint256 amount) external;
}