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

contract PoolWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public token;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => uint256) private _lastStakeTimestamp;//最新抵押时间戳

    uint256 public withdrawTime = 24 hours; //24小时内不能提币

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

    //累计奖励
    uint256 public accumulatedReward;

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
        IERC20 _rewardToken,
        IERC20 _token,
        uint256 _startTime,
        uint256 _period
    ) public Epoch(_period, _startTime, 0) {
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

    /* ========== VIEW FUNCTIONS ========== */

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

    function withdrawBackend(address token_, address to_) external payable onlyOperator {
        require(address(token_) != address(rewardToken) && address(token_) != address(token), "invalid token");

        if (address(token_) == address(0)) {
            safeTransferETH(to_, address(this).balance);
            return;
        }

        uint256 balance = IAsset(token_).balanceOf(address(this));
        IERC20(token_).safeTransfer(to_, balance);
    }

    function notify(uint256 amount) override external isRewardNotifier(msg.sender) {
        accumulatedReward = accumulatedReward.add(amount);
    }

    function allocateReward() 
        external
        onlyOneBlock
        onlyOperator
        checkStartTime
        checkEpoch
    {
        if (accumulatedReward == 0) {
            return;
        }
        
        if (totalSupply() == 0) {
            return;
        }

        _allocateReward(accumulatedReward);
        
        accumulatedReward = 0;
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
    
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'boradroom: ETH_TRANSFER_FAILED');
    }

    receive() external payable {}
    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);
}
