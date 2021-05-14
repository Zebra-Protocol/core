// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import '../access/Operator.sol';

contract zTokenPool is Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public zToken;
    IERC20 public rewardToken;

    uint256 public duration; //周期
    uint256 public duration1 = 7 days; //第1阶段周期（1周）持续6周
    uint256 public period; //周期

    uint256 public rewardBase;

    bool public isStarting;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    
    // uint256 public initreward;
    uint256 public starttime;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        address zToken_,
        address rewardToken_,
        uint256 rewardBase_
    ) public {
        require(rewardBase_ > 0, "rewardBase must > 0");

        zToken = IERC20(zToken_);
        rewardToken = IERC20(rewardToken_);

        rewardBase = rewardBase_;
    }

    function getStartTime() public view returns(uint256) {
        return starttime;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
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

    // function setStartTime(uint256 starttime_) public onlyOperator {
    //     starttime = starttime_;
    // }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function lastUpdateTimeOK() public view returns (uint256) {
        return Math.max(lastUpdateTime, periodFinish - duration);
    }

    function rewardPerToken() public view returns (uint256) {
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

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    // stake visibility is public as overriding LPTokenWrapper's stake() function
    function stake(uint256 amount)
        public
        updateReward(msg.sender)
        checkhalve
        checkStart
    {
        require(amount > 0, 'Cannot stake 0');

        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        zToken.safeTransferFrom(msg.sender, address(this), amount);
        
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount)
        public
        updateReward(msg.sender)
        checkhalve
    {
        require(amount > 0, 'Cannot withdraw 0');

        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        zToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
        getReward();
    }

    function getReward() public updateReward(msg.sender) checkhalve {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    modifier checkhalve() {
        if (block.timestamp >= starttime && block.timestamp >= periodFinish) {
            period = period.add(1);//进入下一个周期
            
            //持续6周
            if (period <= 6) {
                rewardBase = rewardBase.mul(80).div(100);//减产20%
                rewardRate = rewardBase.div(duration);

                periodFinish = block.timestamp.add(duration);
                emit RewardAdded(rewardBase);                
            }
        }
        
        _;
    }

    //检查矿池是否开始了
    modifier checkStart() {
        require(starttime > 0, "not start");
        require(block.timestamp >= starttime, 'not start');
        _;
    }

    //启动矿池
    function startPool(uint256 starttime_) external {
        require(starttime_ > block.timestamp, "start time must > now");
        require(isStarting == false, "pool is starting");

        starttime = starttime_;//设置开始时间
        period = period.add(1);//进入第一个周期
        duration = duration1; //设置当前周期长度
        rewardRate = rewardBase.div(duration);//初始化第一周期奖励

        lastUpdateTime = starttime;
        periodFinish = starttime.add(duration);

        isStarting = true;
    }
}
