// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
//pragma experimental ABIEncoderV2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import '../access/Operator.sol';
import '../utils/ContractGuard.sol';
import '../utils/Epoch.sol';
import '../interfaces/IRewardNotifier.sol';
import '../interfaces/IAsset.sol';
import '../interfaces/IOracle.sol';

contract PoolWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public token;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lastStakeTimestamp;//最新抵押时间戳

    //uint256 public withdrawTime = 24 hours; //24小时内不能提币
    uint256 public withdrawTime = 1 hours; //24小时内不能提币

    modifier checkWithdraw(address account) {
        require(_lastStakeTimestamp[msg.sender].add(withdrawTime) < block.timestamp , "boardroom: can not whitdraw");

        _;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function lastStakeTimestamp(address account) public view returns (uint256) {
        return _lastStakeTimestamp[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        _lastStakeTimestamp[msg.sender] = block.timestamp;
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual checkWithdraw(msg.sender) {
        uint256 directorToken = _balances[msg.sender];
        require(
            directorToken >= amount,
            'Pool: withdraw request greater than staked amount'
        );
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = directorToken.sub(amount);
        token.safeTransfer(msg.sender, amount);
    }
}

contract Boardroom is Epoch, PoolWrapper, ContractGuard, IRewardNotifier {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public oracle;

    //累计奖励
    uint256 public accumulatedCount;
    mapping(uint256 => uint256) public accumulatedHistory;
    uint256 public accumulatedTotal;

    address[] public tokenList;
    mapping(address => uint256) public tokenAccumulatedTotal;

    //授权通知者
    mapping (address => bool) _notifier;
    
    /* ========== DATA STRUCTURES ========== */

    struct Boardseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
    }

    struct BoardSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerToken;
    }

    /* ========== STATE VARIABLES ========== */

    IERC20 private rewardToken;

    mapping(address => Boardseat) private directors;
    BoardSnapshot[] private boardHistory;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _oracle,
        IERC20 _rewardToken,
        IERC20 _token,
        uint256 _startTime,
        uint256 _period
    ) public Epoch(_period, _startTime, 0) {
        oracle = _oracle;
        rewardToken = _rewardToken;
        token = _token;

        BoardSnapshot memory genesisSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: 0,
            rewardPerToken: 0
        });
        boardHistory.push(genesisSnapshot);
    }

    /* ========== Modifiers =============== */
    modifier directorExists {
        require(
            balanceOf(msg.sender) > 0,
            'Pool: The director does not exist'
        );
        _;
    }

    modifier updateReward(address director) {
        if (director != address(0)) {
            Boardseat memory seat = directors[director];
            seat.rewardEarned = earned(director);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            directors[director] = seat;
        }
        _;
    }

    modifier isRewardNotifier(address account) {
        require(_notifier[account] == true, "not reward notifier");
        _;
    }

    function accumulatedRewardOfIndex(uint256 index) public view returns(uint256) {
        return accumulatedHistory[index];
    }

    function setWithdrawTime(uint256 _withdrawTime) public onlyOperator {
        withdrawTime = _withdrawTime;
    }

    //token list
    function addToken(address token) public onlyOperator {
        tokenList.push(token);
    }
    
    function tokenListLength() public view returns(uint256) {
        return tokenList.length;
    }

    function getTokenOfIndex(uint256 index_) public view returns(address) {
        return tokenList[index_];
    }

    //set oracle
    function setOracle(address oracle_) public onlyOperator {
        oracle = oracle_;
    }

    // ============ reward notifier 
    function setNotifier(address account) public onlyOperator {
        _notifier[account] = true;
    }
    
    function unsetNotifier(address account) public onlyOperator {
        _notifier[account] = false;
    }

    function getNotifier(address account) public view returns(bool) {
        return _notifier[account];
    }

    // =========== Snapshot getters

    function latestSnapshotIndex() public view returns (uint256) {
        return boardHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (BoardSnapshot memory) {
        return boardHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address director)
        public
        view
        returns (uint256)
    {
        return directors[director].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address director)
        internal
        view
        returns (BoardSnapshot memory)
    {
        return boardHistory[getLastSnapshotIndexOf(director)];
    }

    // =========== Director getters

    function rewardPerToken() public view returns (uint256) {
        return getLatestSnapshot().rewardPerToken;
    }

    function earned(address director) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerToken;
        uint256 storedRPS = getLastSnapshotOf(director).rewardPerToken;

        return
            balanceOf(director).mul(latestRPS.sub(storedRPS)).div(1e18).add(
                directors[director].rewardEarned
            );
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount)
        public
        override
        onlyOneBlock
        checkStartTime
        updateReward(msg.sender)
    {
        require(amount > 0, 'Boardroom: Cannot stake 0');
        super.stake(amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount)
        public
        override
        onlyOneBlock
        directorExists
        updateReward(msg.sender)
    {
        require(amount > 0, 'Boardroom: Cannot withdraw 0');
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
        claimReward();
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = directors[msg.sender].rewardEarned;
        if (reward > 0) {
            directors[msg.sender].rewardEarned = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function notify(address token_, uint256 amount_) override external isRewardNotifier(msg.sender) {
        //每个token累计奖励
        tokenAccumulatedTotal[token_] = tokenAccumulatedTotal[token_].add(amount_);
    }

    function allocateReward() 
        external
        onlyOneBlock
        checkStartTime
        checkEpoch
    {
        if (totalSupply() == 0) {
            return;
        }

        uint256 accumulatedReward = 0;
        for (uint256 i = 0; i < tokenList.length; i++) {
            uint256 fee = tokenAccumulatedTotal[tokenList[i]];
            uint256 amount = IOracle(oracle).R(tokenList[i], fee);
            if (amount != 0) {
                accumulatedReward = accumulatedReward.add(amount);
                tokenAccumulatedTotal[tokenList[i]] = 0;
            }
        }

        if (accumulatedReward == 0) {
            return;
        }
        
        _allocateReward(accumulatedReward);
        
        //统计每次奖励数据
        accumulatedCount = accumulatedCount.add(1);
        accumulatedHistory[accumulatedCount] = accumulatedReward;
        accumulatedTotal = accumulatedTotal.add(accumulatedReward);
    }

    function _allocateReward(uint256 amount) internal {
        require(amount > 0, 'boardroom: Cannot allocate 0');
        require(totalSupply() > 0,'boardroom: Cannot allocate when totalSupply is 0');

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerToken;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        BoardSnapshot memory newSnapshot = BoardSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerToken: nextRPS
        });
        boardHistory.push(newSnapshot);

        emit RewardAdded(msg.sender, amount);
    }

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
}
