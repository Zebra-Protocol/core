// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/Math.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import '../access/Operator.sol';
import '../uniswap/IUniswapV2Pair.sol';
import '../uniswap/IUniswapV2Factory.sol';
import '../uniswap/IUniswapV2Router02.sol';

contract ZBTLPTokenPool is Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    //debug
    address public path0;
    address public path1;
    uint256 public dvalue1;
    uint256 public dvalue2;
    uint256 public dvalue3;
    uint256 public dvalue_total1;
    uint256 public dvalue_total2;
    uint256 public dvalue_total4;
    uint256 public dvalue_liquidity;
    uint public dvalue_amountToken;
    uint public dvalue_amountETH;

    //交易对(A-B)
    address public WETH;
    address public tokenA;
    address public tokenB;
    IUniswapV2Pair public lpToken;
    address public rewardToken;

    IUniswapV2Factory public factory;
    IUniswapV2Router02 public router;

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
        IUniswapV2Factory factory_,
        IUniswapV2Router02 router_,
        address tokenA_,
        address tokenB_,
        address WETH_,
        IUniswapV2Pair lpToken_,
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

    function stake2(address token_, uint256 amount)
        public
        payable
        updateReward(msg.sender)
        checkhalve
        checkStart
    {
        require(token_ == tokenA || token_ == tokenB, 'LPPool: invalid token');
        
        if (tokenA == WETH || tokenB == WETH) {
            if (token_ == WETH) {
                amount = msg.value;
            } else {
                IERC20(token_).safeTransferFrom(msg.sender, address(this), amount);
            }
        } else {
            IERC20(token_).safeTransferFrom(msg.sender, address(this), amount);
        }

        require(amount > 0, 'LPPool: Cannot stake 0');
        

        uint256 half = amount.div(2);//取一半都兑换
        require(half > 0, 'LPPool: half cannot be 0');

        uint256 rAmount = 1;
        address[] memory path = new address[](2);

        // token-token
        {
            IERC20(tokenA).approve(address(router), uint(0));
            IERC20(tokenB).approve(address(router), uint(0));
            IERC20(tokenA).approve(address(router), ~uint(0));
            IERC20(tokenB).approve(address(router), ~uint(0));
        }
    
        if (tokenA == WETH || tokenB == WETH) {
            uint256 amountToken;
            uint256 amountETH;
            if (token_ == WETH) {
                if (tokenA == WETH) {
                    (path[0], path[1]) = (tokenA, tokenB);
                } else {
                    (path[0], path[1]) = (tokenB, tokenA);
                }
                uint256[] memory amounts = router.swapExactETHForTokens{value: half}(0, path, address(this), now);
                amountToken = amounts[1];
                amountETH   = amounts[0];
            } else {
                if (tokenA == WETH) {
                    (path[0], path[1]) = (tokenB, tokenA);
                } else {
                    (path[0], path[1]) = (tokenA, tokenB);
                }
                uint256[] memory amounts = router.swapExactTokensForETH(half, 0, path, address(this), now);
                amountToken = amounts[0];
                amountETH   = amounts[1];
            }

            address token1 = tokenA;
            if (tokenA == WETH) {
                token1 = tokenB;
            }

            path0 = path[0];//TODO delete
            path1 = path[1];//TODO delete

            //注入流动性token-ETH
            (,, uint256 lpAmount) = router.addLiquidityETH{value: amountETH}(token1, amountToken, 0, 0, address(this), now);
            rAmount = lpAmount;
        } else {
            if (token_ == tokenA) {
                (path[0], path[1]) = (tokenA, tokenB);
            } else {
                (path[0], path[1]) = (tokenB, tokenA);
            }

            path0 = path[0];//TODO delete
            path1 = path[1];//TODO delete

            //购买代币
            uint256[] memory amounts = router.swapExactTokensForTokens(half, 0, path, address(this), now);
            
            dvalue1 = amounts[0];//TODO delete
            dvalue2 = amounts[1];//TODO delete
            
            //注入流动性token-token
            (,, uint256 lpAmount) = router.addLiquidity(
                path[0], path[1],
                amounts[0], amounts[1], 0, 0, address(this), now
            );

            rAmount = lpAmount;
            dvalue3 = lpAmount;//TODO delete
        }

        require(rAmount > 0, 'LPPool: Cannot stake 0');

        //抵押
        _totalSupply = _totalSupply.add(rAmount);
        _balances[msg.sender] = _balances[msg.sender].add(rAmount);
        
        emit Staked(msg.sender, rAmount);
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
        }

        address[] memory path = new address[](2);

        if (tokenA == WETH || tokenB == WETH) {
            address token1 = tokenA;
            address token2 = tokenB;
            if (tokenA == WETH) {
                token1 = tokenB;
                token2 = tokenA;
            }

            dvalue_liquidity = liquidity;
            //移除流动性
            (uint amountToken, uint amountETH) = router.removeLiquidityETH(token1, liquidity, 0, 0, address(this), now);

            dvalue_amountToken = amountToken;
            dvalue_amountETH   = amountETH;
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
                dvalue_total1 = amounts[0];//TODO delete
                dvalue_total2 = amounts[1];//TODO delete

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
                dvalue_total1 = amounts[0];//TODO delete
                dvalue_total2 = amounts[1];//TODO delete

                total = total.add(amountToken);
                total = total.add(amounts[1]);
                IERC20(token_).safeTransfer(msg.sender, total); 
            }

            dvalue_total4 = total;
        } else {
            //移除流动性
            (uint amountA, uint amountB) = router.removeLiquidity(tokenA, tokenB, liquidity, 0, 0, address(this), now);
            
            dvalue_total1 = amountA;//TODO delete
            dvalue_total2 = amountB;//TODO delete

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

            dvalue_total4 = total;//TODO delete

            IERC20(token_).safeTransfer(msg.sender, total);          
        }
        

        emit Withdrawn(msg.sender, dvalue_total4);
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

    modifier checkhalve() {
        if (block.timestamp >= starttime && block.timestamp >= periodFinish) {
            period = period.add(1);//进入下一个周期
            if (period >= 2 && period <= 7 ) {
                //持续6周
                duration = duration2; //设置当前周期长度
            } else {
                duration = duration3; //设置当前周期长度
            } 
        
            rewardBase = rewardBase.mul(80).div(100);//减产20%
            rewardRate = rewardBase.div(duration);

            periodFinish = block.timestamp.add(duration);
            emit RewardAdded(rewardBase);
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
