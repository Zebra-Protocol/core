// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
/**
 *Single token mining
 */

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '../interfaces/IRewardDistributionRecipient.sol';
import '../access/Operator.sol';
import '../lib/Math.sol';
import '../interfaces/IStakingRewards.sol';

contract StakingRewardsRule is
    Operator,
    IStakingRewards,
    IRewardDistributionRecipient
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public lpt;

    uint256 private _totalSupply;
    
    mapping(address => uint256) private _balances;

    IERC20 public rewardToken;
    //require modify
    uint256 public constant DURATION = 1 minutes;

    uint256 public constant TOTAL_PERIOD = 6;//It lasts for 6 weeks

    uint256 public rewardBase;//How much should be awarded in the first cycle
    
    uint256 public starttime; // starttime TBD
    uint256 public periodFinish = 0;//The deadline for the current cycle
    uint256 public periodCount = 0;
    uint256 public rewardRate = 0;//release　tokens of per second
    uint256 public lastUpdateTime;//Latest time to update Award

    //Rewards for each token stored
    uint256 public rewardPerTokenStored;
    //Rewards paid to users
    mapping(address => uint256) public userRewardPerTokenPaid;
    
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        address rewardToken_,//Tokens from mining
        address stakingToken_,//Pledged token
        uint256 rewardBase_,
        uint256 starttime_
    ) public {
        rewardToken = IERC20(rewardToken_);
        lpt = IERC20(stakingToken_);
        rewardBase = rewardBase_;
        starttime = starttime_;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function totalSupply() public override view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public override view returns (uint256) {
        return _balances[account];
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    function setStartTime(uint256 starttime_) public onlyOperator {
        starttime = starttime_;
    }

    function lastTimeRewardApplicable() public override view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function lastUpdateTimeOK() public view returns (uint256) {
        return Math.max(lastUpdateTime, periodFinish - DURATION);
    }

    function rewardPerToken() public override view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTimeOK())
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public override view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount, address user)
        public
        override
        updateReward(user)
        checkhalve
        checkStart
    {
        require(amount > 0, 'Cannot stake 0');
        require(periodCount < TOTAL_PERIOD, 'Mining has stopped');

        _totalSupply = _totalSupply.add(amount);
        _balances[user] = _balances[user].add(amount);
        if(address(lpt) != address(0)) {
            lpt.safeTransferFrom(msg.sender, address(this), amount);
        }
        emit Staked(user, amount);
    }

    function withdraw(uint256 amount, address user)
        public
        override
        updateReward(user)
        checkhalve
    {
        require(amount > 0, 'Cannot withdraw 0');

        //1. get rewards
        uint256 reward = earned(user);
        if (reward > 0) {
            rewards[user] = 0;
            rewardToken.safeTransfer(user, reward);
        }
        //2. return lp token to user
        _totalSupply = _totalSupply.sub(amount);
        _balances[user] = _balances[user].sub(amount);

        if(address(lpt) == address(0)) {
            safeTransferETH(msg.sender, amount);
        } else {
            lpt.safeTransfer(msg.sender, amount);
        }
        emit Withdrawn(user, amount);
    }

    function exit(address user) external override {
        withdraw(balanceOf(user),user);
        getReward(user);
    }

    function getRewardForDuration() external override view returns (uint256) {
        return rewardRate.mul(DURATION);
    }
    
    function getReward(address user) public override updateReward(user) checkhalve {
        uint256 reward = earned(user);
        if (reward > 0) {
            rewards[user] = 0;
            rewardToken.safeTransfer(user, reward);
            emit RewardPaid(user, reward);
        }
    }

    modifier checkhalve() {
        if (block.timestamp >= starttime && block.timestamp >= periodFinish && periodCount < TOTAL_PERIOD) {
            periodCount = periodCount.add(1);//into next period

            if(periodCount < TOTAL_PERIOD) {
                rewardBase = rewardBase.mul(80).div(100);

                rewardRate = rewardBase.div(DURATION);
                periodFinish = block.timestamp.add(DURATION);
                emit RewardAdded(rewardBase);
            }
        }
        _;
    }

    modifier checkStart() {
        require(block.timestamp >= starttime, 'not start');
        _;
    }

    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyRewardDistribution
        updateReward(address(0))
    {
        if (block.timestamp > starttime) {
            if (block.timestamp >= periodFinish) {//之前的周期已结束
                rewardRate = reward.div(DURATION);
            } else {//之前的周期未结束
                //A new cycle will start at the current time point
                uint256 remaining = periodFinish.sub(block.timestamp);
                uint256 leftover = remaining.mul(rewardRate);
                rewardRate = reward.add(leftover).div(DURATION);
            }
            lastUpdateTime = block.timestamp;
            periodFinish = block.timestamp.add(DURATION);
            emit RewardAdded(reward);
        } else {
            rewardRate = rewardBase.div(DURATION);
            lastUpdateTime = starttime;
            periodFinish = starttime.add(DURATION);
            emit RewardAdded(reward);
        }
    }
}
