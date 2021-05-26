// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import './interfaces/InterestModel.sol';
import './access/Operator.sol';

contract TripleSlopeModel is Operator,InterestModel {
    using SafeMath for uint256;
    uint8 public rateType;
    uint256 public level1Rate;
    uint256 public level2Rate;
    uint256 public level3Rate;
    uint256 public level4Rate;

    function setRateType(uint8 _rateType) public onlyOperator {
        require(_rateType>0&&_rateType<(10 ** 18), 'Illegal value range');
        rateType = _rateType;
    }

    function setLevel1Rate(uint256 _level1Rate) public onlyOperator {
        require(_level1Rate>0&&_level1Rate<(10 ** 18), 'Illegal value range');
        level1Rate = _level1Rate;
    }

    function setLevel2Rate(uint256 _level2Rate) public onlyOperator {
        require(_level2Rate>0&&_level2Rate<(10 ** 18), 'Illegal value range');
        level2Rate = _level2Rate;
    }

    function setLevel3Rate(uint256 _level3Rate) public onlyOperator {
        require(_level3Rate>0&&_level3Rate<(10 ** 18), 'Illegal value range');
        level3Rate = _level3Rate;
    }

    function setLevel4Rate(uint256 _level4Rate) public onlyOperator {
        require(_level4Rate>0&&_level4Rate<(10 ** 18), 'Illegal value range');
        level4Rate = _level4Rate;
    }

    function getInterestRate(uint256 debt, uint256 totalBalance) external override view returns (uint256) {
        uint256 total = debt.add(totalBalance);
        uint256 utilization = total == 0? 0: debt.mul(10000).div(total);
        if (rateType==0) {
            if (utilization < 5000) {
                // Less than 50% utilization - 10% APY
                return uint256(10e16) / 365 days;
            } else if (utilization < 7500) {
                // Between 50% and 75% - 20% APY
                return uint256(2*10e16) / 365 days;
            } else if (utilization < 9500) {
                // Between 75% and 95% - 30% APY
                return uint256(3*10e16) / 365 days;
            } else if (utilization < 10000) {
                // Between 95% and 100% - 40% APY
                return uint256(4*10e16) / 365 days;
            } else {
                // Not possible, but just in case - 100% APY
                return uint256(100e16) / 365 days;
            }
        } else if (rateType==1) {
            if (utilization < 5000) {
                // Less than 50% utilization - 10% APY
                return uint256(10e16) / 365 days;
            } else if (utilization < 9500) {
                // Between 50% and 95% - 10%-25% APY
                return (10e16 + utilization.sub(5000).mul(15e16).div(10000)) / 365 days;
            } else if (utilization < 10000) {
                // Between 95% and 100% - 25%-100% APY
                return (25e16 + utilization.sub(7500).mul(75e16).div(10000)) / 365 days;
            } else {
                // Not possible, but just in case - 100% APY
                return uint256(100e16) / 365 days;
            }
        } else {
            if (utilization < 5000) {
                // Less than 50% utilization - 10% APY
                return level1Rate / 365 days;
            } else if (utilization < 7500) {
                // Between 50% and 75% - 20% APY
                return level2Rate / 365 days;
            } else if (utilization < 9500) {
                // Between 75% and 95% - 30% APY
                return level3Rate / 365 days;
            } else if (utilization < 10000) {
                // Between 95% and 100% - 40% APY
                return level4Rate / 365 days;
            } else {
                // Not possible, but just in case - 100% APY
                return uint256(100e16) / 365 days;
            }
        }
    }
}