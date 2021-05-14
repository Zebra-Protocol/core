// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IRewardNotifier {
    function notify(uint256 amount) external;
}