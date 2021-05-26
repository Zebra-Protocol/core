// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/access/Ownable.sol';
import './interfaces/IBankConfig.sol';
import './interfaces/InterestModel.sol';

contract BankConfig is IBankConfig, Ownable {

    uint256 public override getReserveBps;
    uint256 public override getLiquidateBps;
    uint256 public override getBoardroomBps;
    uint256 public override getPlatformBps;

    address public interestModel;

    constructor() public {}

    function setParams(
        uint256 _getReserveBps, 
        uint256 _getBoardroomBps, 
        uint256 _getPlatformBps, 
        uint256 _getLiquidateBps, 
        address _interestModel) public onlyOwner {
        
        require(_getReserveBps>0&&_getReserveBps<10000, 'The value must be between 0 and 10000');
        require(_getBoardroomBps>0&&_getBoardroomBps<10000, 'The value must be between 0 and 10000');
        require(_getPlatformBps>0&&_getPlatformBps<10000, 'The value must be between 0 and 10000');
        require(_getLiquidateBps>0&&_getLiquidateBps<10000, 'The value must be between 0 and 10000');

        getReserveBps = _getReserveBps;
        getBoardroomBps = _getBoardroomBps;
        getPlatformBps = _getPlatformBps;
        getLiquidateBps = _getLiquidateBps;
        interestModel = _interestModel;
    }

    function getInterestRate(uint256 debt, uint256 floating) external override view returns (uint256) {
        return InterestModel(interestModel).getInterestRate(debt, floating);
    }
}