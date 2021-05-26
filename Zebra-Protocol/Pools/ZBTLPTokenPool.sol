// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import '../access/Operator.sol';
import '../interfaces/IMdexPair.sol';
import '../interfaces/IMdexFactory.sol';
import '../interfaces/IMdexRouter.sol';
import '../interfaces/IWHT.sol';
import '../lib/Math.sol';
import '../lib/TokenSwapUtil.sol';

contract ZBTLPTokenPool is Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //交易对(A-B)
    address public WETH;
    address public tokenA;
    address public tokenB;
    IMdexPair public lpToken;
    address public rewardToken;

    IMdexFactory public factory;
    IMdexRouter public router;

    uint256 public duration; //周期长度
    uint256 public duration1 = 7 days; //第1阶段周期（1周）
    uint256 public duration2 = 7 days; //第2阶段周期（1周）持续6周
    uint256 public duration3 = 90 days; //第2阶段周期（3个月）
    uint256 public period; //周期数

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
        IMdexFactory factory_,
        IMdexRouter router_,
        address tokenA_,
        address tokenB_,
        address WETH_,
        IMdexPair lpToken_,
        address rewardToken_,
        uint256 rewardBase_
    ) public {
        require(rewardBase_ > 0, "rewardBase must > 0");

        factory = factory_;
        router  = router_;
        
        WETH        = WETH_;
        tokenA      = tokenA_;
        tokenB      = tokenB_;
        lpToken     = lpToken_;
        rewardToken = rewardToken_;

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

    function stake2(address token0, address token1,  uint256 token0Amount,  uint256 token1Amount)
        public
        payable
        updateReward(msg.sender)
        checkhalve
        checkStart
    {
        uint256 token0Before = token0 == address(0)? address(this).balance.sub(msg.value): IERC20(token0).balanceOf(address(this));
        uint256 token1Before = token1 == address(0)? address(this).balance.sub(msg.value): IERC20(token1).balanceOf(address(this));

        if (token0Amount > 0 && token0 != address(0)) {
            IERC20(token0).safeTransferFrom(msg.sender, address(this), token0Amount);
        }
        if (token1Amount > 0 && token1 != address(0)) {
            IERC20(token1).safeTransferFrom(msg.sender, address(this), token1Amount);
        }
        address htRelative = address(0);
        {
            if (token0 == address(0)){
                token0 = WETH;
                htRelative = token1;
                token0Amount = msg.value;
            }
            if (token1 == address(0)){
                token1 = WETH;
                htRelative = token0;
                token1Amount = msg.value;
            }
            // change all ht to WHT if need.
            uint256 htBalance = address(this).balance;
            if (htBalance > 0) {
                IWHT(WETH).deposit{value:htBalance}();
            }
        }

        IERC20(token0).safeApprove(address(router), 0);
        IERC20(token0).safeApprove(address(router), uint256(-1));
        IERC20(token1).safeApprove(address(router), 0);
        IERC20(token1).safeApprove(address(router), uint256(-1));

        //swap and mint LP tokens.
        calAndSwap(IMdexPair(lpToken), token0, token1, token0Amount, token1Amount);

        uint256 token0After = IERC20(token0).balanceOf(address(this));
        uint256 token1After = IERC20(token1).balanceOf(address(this));
        
        (,, uint256 lpAmount) = router.addLiquidity(token0, token1, token0After.sub(token0Before), token1After.sub(token1Before), 0, 0, address(this), now);
        require(lpAmount > 0, 'LPPool: Cannot stake 0');

        uint256 token0After1 = IERC20(token0).balanceOf(address(this));
        uint256 token1After1 = IERC20(token1).balanceOf(address(this));
  
        //剩余的返回给用户
        if (htRelative == address(0)) {
            if(token0After1.sub(token0Before)>0) {
                IERC20(token0).safeTransfer(msg.sender, token0After1.sub(token0Before));
            }
            if(token1After1.sub(token1Before)>0) {
                IERC20(token1).safeTransfer(msg.sender, token1After1.sub(token1Before));
            }
        } else {
            safeUnWrapperAndAllSend(token0, msg.sender,token0After1.sub(token0Before));
            safeUnWrapperAndAllSend(token1, msg.sender,token1After1.sub(token1Before));
        }
        
        //抵押
        _totalSupply = _totalSupply.add(lpAmount);
        _balances[msg.sender] = _balances[msg.sender].add(lpAmount);
        
        emit Staked(msg.sender, lpAmount);
    }

    function withdraw2(address token_)
        public
        updateReward(msg.sender)
        checkhalve
    {
        uint256 liquidity = _balances[msg.sender];
        
        _totalSupply = _totalSupply.sub(liquidity);
        _balances[msg.sender] = _balances[msg.sender].sub(liquidity);

        require(liquidity > 0, 'LPPool: Cannot withdraw 0');
        require(token_ == address(0) || token_ == tokenA || token_ == tokenB, 'LPPool: invalid token');

        //授权
        {
            lpToken.approve(address(router), uint(0));
            lpToken.approve(address(router), ~uint(0));
            
            IERC20(tokenA).safeApprove(address(router), 0);
            IERC20(tokenA).safeApprove(address(router), uint256(-1));
            IERC20(tokenB).safeApprove(address(router), 0);
            IERC20(tokenB).safeApprove(address(router), uint256(-1));
        }

        address[] memory path = new address[](2);

        if (tokenA == WETH || tokenB == WETH) {
            address token1 = tokenA;
            address token2 = tokenB;
            if (tokenA == WETH) {
                token1 = tokenB;
                token2 = tokenA;
            }
            //移除流动性
            (uint amountToken, uint amountETH) = router.removeLiquidityETH(token1, liquidity, 0, 0, address(this), now);

            //赎回两种币
            if (token_ == address(0)) {
                IERC20(token1).safeTransfer(msg.sender, amountToken);
                safeTransferETH(msg.sender, amountETH);
                return;
            }

            uint256 total;
            if (token_ == WETH) {
                if (tokenA == WETH) {
                    (path[0], path[1]) = (tokenB, tokenA);
                } else {
                    (path[0], path[1]) = (tokenA, tokenB);
                }
                uint256[] memory amounts = router.swapExactTokensForETH(amountToken, 0, path, address(this), now);

                total = total.add(amountETH);
                total = total.add(amounts[1]);
                safeTransferETH(msg.sender, total);
            } else {
                if (tokenA == WETH) {
                    (path[0], path[1]) = (tokenA, tokenB);
                } else {
                    (path[0], path[1]) = (tokenB, tokenA);
                }

                uint256[] memory amounts = router.swapExactETHForTokens{value: amountETH}(0, path, address(this), now);

                total = total.add(amountToken);
                total = total.add(amounts[1]);
                IERC20(token_).safeTransfer(msg.sender, total); 
            }
        } else {
            //移除流动性
            (uint amountA, uint amountB) = router.removeLiquidity(tokenA, tokenB, liquidity, 0, 0, address(this), now);
            
            //赎回两种币
            if (token_ == address(0)) {
                IERC20(tokenA).safeTransfer(msg.sender, amountA);
                IERC20(tokenB).safeTransfer(msg.sender, amountB);
                return;
            }

            uint256 total;
            if (token_ == tokenA) {
                (path[0], path[1]) = (tokenB, tokenA);
                //购买代币
                uint256[] memory amounts = router.swapExactTokensForTokens(amountB, 0, path, address(this), now);
                total = total.add(amountA);
                total = total.add(amounts[1]);
            } else {
                (path[0], path[1]) = (tokenA, tokenB);
                //购买代币
                uint256[] memory amounts = router.swapExactTokensForTokens(amountA, 0, path, address(this), now);
                total = total.add(amountB);
                total = total.add(amounts[1]);
            }

            IERC20(token_).safeTransfer(msg.sender, total);          
        }
        

        emit Withdrawn(msg.sender, liquidity);
    }

    // function exit() external {
    //     withdraw(balanceOf(msg.sender));
    //     getReward();
    // }

    function getReward() public updateReward(msg.sender) checkhalve {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            IERC20(rewardToken).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// get token balance, if is WHT un wrapper to HT and send to 'to'
    function safeUnWrapperAndAllSend(address token, address to,uint256 restAmount) internal {
        if (restAmount > 0) {
            if (token == WETH) {
                IWHT(WETH).withdraw(restAmount);
                safeTransferETH(to, restAmount);
            } else {
                IERC20(token).safeTransfer(to, restAmount);
            }
        }
    }

    /// Compute amount and swap between borrowToken and tokenRelative.
    function calAndSwap(IMdexPair pair, 
    address token0, 
    address token1, 
    uint256 token0Amount,  
    uint256 token1Amount) internal {

        (uint256 token0Reserve, uint256 token1Reserve,) = pair.getReserves();
        (uint256 debtReserve, uint256 relativeReserve) = token0 ==
            lpToken.token0() ? (token0Reserve, token1Reserve) : (token1Reserve, token0Reserve);
        
        (uint256 swapAmt, bool isReversed) = TokenSwapUtil.optimalDeposit(token0Amount, token1Amount,
            debtReserve, relativeReserve);
        if (swapAmt > 0){
            address[] memory path = new address[](2);
            (path[0], path[1]) = isReversed ? (token1, token0) : (token0, token1);
            router.swapExactTokensForTokens(swapAmt, 0, path, address(this), now);
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

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    receive() external payable {}
}
