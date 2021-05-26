// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';

import './interfaces/IAsset.sol';
import './interfaces/IBankConfig.sol';
import './interfaces/Goblin.sol';
import './interfaces/IEIP20.sol';
import './interfaces/IRewardNotifier.sol';
import './access/Operator.sol';

contract Bank is Operator, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    event OpPosition(uint256 indexed id, uint256 debt, uint back);
    event Liquidate(uint256 indexed id, address indexed killer, uint256 prize, uint256 left);
    event Harvest(uint256 indexed id, address indexed user, uint256 back, uint256 left);

    struct TokenBank {
        address tokenAddr;
        address zTokenAddr;
        bool isOpen;
        bool canDeposit;
        bool canWithdraw;
        uint256 totalVal;//deposit存入
        uint256 totalDebt;
        uint256 totalDebtShare;
        uint256 totalInterest;
        uint256 totalReserve;
        uint256 totalBoardroom;
        uint256 totalPlatform;
        uint256 lastInterestTime;
    }

    struct TokenInterest {
        uint256 canReserveInterest;
        uint256 canBoardroomInterest;
        uint256 canPlatformInterest;
    }

    struct Production {
        address borrowToken;
        bool isOpen;
        bool canBorrow;
        address goblin;
        uint256 minDebt;
        uint256 openFactor;
        uint256 liquidateFactor;
    }

    struct Position {
        address owner;
        uint256 productionId;
        uint256 debtShare;
        uint256 lptAmount;
        uint256 loanAmount;
    }

    IBankConfig config;

    address public wht;
    address public boardroom;

    mapping(address => TokenBank) public banks;

    mapping(uint256 => Production) public productions;
    uint256 public currentPid = 1;

    mapping(uint256 => Position) public positions;
    uint256 public currentPos = 1;

    mapping(address => TokenInterest) public tokenInterests;

    //token->user
    mapping(address => address[]) public tokenUsers;

    mapping(address=>uint256[]) myPositionIDList; 

    modifier onlyEOA() {
        require(msg.sender == tx.origin, "not eoa");
        _;
    }

    constructor(
        address _wht,
        address boardroom_) public {

        wht = _wht;
        boardroom = boardroom_;
    }

    //view
    function getMyPositionIDList(address account) public view returns(uint256[] memory) {
        return myPositionIDList[account];
    }

    function setBoardroom(address boardroom_) public onlyOperator {
        boardroom = boardroom_;
    }

    function positionInfo(uint256 posId) public view returns (uint256, uint256, uint256, uint256, uint256, address) {
        require((posId>=0&&posId<currentPos), 'Illegal position ID');

        Position memory pos = positions[posId];
        Production memory prod = productions[pos.productionId];
        
        uint256 lptAmount = pos.lptAmount;
        uint256 totalBalance = prod.borrowToken == address(0)? address(this).balance: myBalance(prod.borrowToken);
        uint256 posDebt = debtShareToVal(prod.borrowToken, pos.debtShare);
        uint256 totalAsset = banks[prod.borrowToken].totalDebt.add(totalBalance);

        return (pos.productionId, Goblin(prod.goblin).health(posId, prod.borrowToken),
            posDebt, totalAsset, lptAmount, pos.owner);
    }

    function tokenInfo(address token) public view returns (uint256, uint256, uint256) {
        TokenBank storage bank = banks[token];
        uint256 totalBalance = token == address(0)? address(this).balance: myBalance(token);

        return (bank.totalDebt, totalBalance.add(bank.totalDebt),
            config.getInterestRate(bank.totalDebt, totalBalance));
    }

    function myBalance(address token) internal view returns (uint) {
        return IERC20(token).balanceOf(address(this));
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    function totalToken(address token) public view returns (uint256) {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        uint balance = token == address(0)? address(this).balance: myBalance(token);
        /*这里有可能直接向银行转帐（不会影响bank.totalVal的变化），而不是通过合成资产存入的资产,
        所以要取balance与bank.totalVal中的最小值*/
        balance = bank.totalVal < balance? bank.totalVal: balance;

        return balance.add(bank.totalDebt).sub(bank.totalReserve).sub(bank.totalBoardroom).sub(bank.totalPlatform);
    }

    function debtShareToVal(address token, uint256 debtShare) public view returns (uint256) {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        if (bank.totalDebtShare == 0) return debtShare;
        return debtShare.mul(bank.totalDebt).div(bank.totalDebtShare);
    }

    function debtValToShare(address token, uint256 debtVal) public view returns (uint256) {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        if (bank.totalDebt == 0) return debtVal;
        return debtVal.mul(bank.totalDebtShare).div(bank.totalDebt);
    }

    function deposit(address token, uint256 amount) external payable nonReentrant {
        TokenBank storage bank = banks[token];
        require(bank.isOpen && bank.canDeposit, 'Token not exist or cannot deposit');

        calInterest(token);
        
        if (token == address(0)) {//HT
            amount = msg.value;
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        }
        bank.totalVal = bank.totalVal.add(amount);
        uint256 total = totalToken(token).sub(amount);
        uint256 zTotal = IAsset(bank.zTokenAddr).totalSupply();

        uint256 tokenDecimal = uint256(IEIP20(token==address(0)?wht:token).decimals());
        uint256 zTokenDecimal = uint256(IEIP20(bank.zTokenAddr).decimals());
    
        //require covner unit
        uint256 rAmount = amount.mul(10**zTokenDecimal).div(10**tokenDecimal);
        uint256 rTotal = total.mul(10**zTokenDecimal).div(10**tokenDecimal);

        uint256 pAmount = (rTotal == 0 || zTotal == 0) ? rAmount: rAmount.mul(zTotal).div(rTotal);

        IAsset(bank.zTokenAddr).mint(msg.sender, pAmount);
    }

    function withdraw(address token, uint256 zAmount) external nonReentrant {
        TokenBank storage bank = banks[token];
        require(IAsset(bank.zTokenAddr).balanceOf(msg.sender) >= zAmount, 'zToken: withdraw execced balance');

        calInterest(token);

        uint256 tokenDecimal = uint256(IEIP20(token==address(0)?wht:token).decimals());
        uint256 zTokenDecimal = uint256(IEIP20(bank.zTokenAddr).decimals());
        uint256 total = totalToken(token);

        //require covner unit
        uint256 rTotal = total.mul(10**zTokenDecimal).div(10**tokenDecimal);

        uint256 amount = zAmount.mul(rTotal).div(IAsset(bank.zTokenAddr).totalSupply());
        
        //require covner unit
        uint256 tAmount = amount.mul(10**tokenDecimal).div(10**zTokenDecimal);

        bank.totalVal = bank.totalVal.sub(tAmount);

         IAsset(bank.zTokenAddr).burnFrom(msg.sender, zAmount);

        if (token == address(0)) {//HT
            safeTransferETH(msg.sender, tAmount);
        } else {
            IERC20(token).safeTransfer(msg.sender, tAmount);
        }
    }

    function opPosition(uint256 posId, uint256 pid, uint256 borrow, bytes calldata data)
    external payable onlyEOA nonReentrant {

        if (posId == 0) {
            posId = currentPos;
            currentPos ++;
            positions[posId].owner = msg.sender;
            positions[posId].productionId = pid;
            myPositionIDList[msg.sender].push(posId);
        } else {
            require(posId < currentPos, "bad position id");
            require(positions[posId].owner == msg.sender, "not position owner");
            require(pid == positions[posId].productionId, "Each position can only borrow the same token");

            pid = positions[posId].productionId;
        }
        Production storage production = productions[pid];
        require(production.isOpen, 'Production not exists');

        require(borrow == 0 || production.canBorrow, "Production can not borrow");
    
        calInterest(production.borrowToken);

        uint256 debt = _removeDebt(positions[posId], production).add(borrow);
        bool isBorrowHt = production.borrowToken == address(0);

        uint256 sendHT = msg.value;
        uint256 beforeToken = 0;
        if (isBorrowHt) {
            sendHT = sendHT.add(borrow);
            require(sendHT <= address(this).balance && debt <= banks[production.borrowToken].totalVal, "insufficient HT in the bank");
            beforeToken = address(this).balance.sub(sendHT);
        } else {
            beforeToken = myBalance(production.borrowToken);
            require(borrow <= beforeToken && debt <= banks[production.borrowToken].totalVal, "insufficient borrowToken in the bank");
            beforeToken = beforeToken.sub(borrow);
            IERC20(production.borrowToken).safeApprove(production.goblin, borrow);
        }
        
        {
            uint256 lptAmount = Goblin(production.goblin).work{value:sendHT}(posId, msg.sender, production.borrowToken, borrow, debt, data);
            positions[posId].lptAmount = lptAmount;
        }
        
        uint256 backToken = isBorrowHt? (address(this).balance.sub(beforeToken)) :
            myBalance(production.borrowToken).sub(beforeToken);

        if(backToken > debt) { //There is no loan, there is a refund left
            backToken = backToken.sub(debt);
            debt = 0;

            isBorrowHt? safeTransferETH(msg.sender, backToken):
                IERC20(production.borrowToken).safeTransfer(msg.sender, backToken);

        } else if (debt > backToken) { //have loan
            debt = debt.sub(backToken);
            if(borrow > 0) {
                positions[posId].loanAmount = positions[posId].loanAmount.add(borrow.sub(backToken));
            }
            backToken = 0;

            require(debt >= production.minDebt, "too small debt size");
            uint256 health = Goblin(production.goblin).health(posId, production.borrowToken);
            //70% of openFactor
            require(health.mul(production.openFactor) >= debt.mul(10000), "bad work factor");

            _addDebt(positions[posId], production, debt);
        }
        emit OpPosition(posId, debt, backToken);
    }

    function updateConfig(IBankConfig _config) external onlyOperator {
        config = _config;
    }

    function addToken(address token, address zToken) external onlyOperator {
        TokenBank storage bank = banks[token];
        require(!bank.isOpen, 'token already exists');

        bank.isOpen = true;
        bank.tokenAddr = token;
        bank.zTokenAddr = zToken;
        bank.canDeposit = true;
        bank.canWithdraw = true;
        bank.totalVal = 0;
        bank.totalDebt = 0;
        bank.totalDebtShare = 0;
        bank.totalInterest = 0;
        bank.totalReserve = 0;
        bank.totalBoardroom = 0;
        bank.totalPlatform = 0;
        bank.lastInterestTime = now;
    }

    function updateToken(address token, bool canDeposit, bool canWithdraw) external onlyOperator {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        bank.canDeposit = canDeposit;
        bank.canWithdraw = canWithdraw;
    }

    function opProduction(uint256 pid, bool isOpen, bool canBorrow,
        address borrowToken, address goblin,
        uint256 minDebt, uint256 openFactor, uint256 liquidateFactor) external onlyOperator {

        if(pid == 0){
            pid = currentPid;
            currentPid ++;
        } else {
            require(pid < currentPid, "bad production id");
        }

        Production storage production = productions[pid];
        production.isOpen = isOpen;
        production.canBorrow = canBorrow;
        
        production.borrowToken = borrowToken;
        production.goblin = goblin;

        production.minDebt = minDebt;
        production.openFactor = openFactor;
        production.liquidateFactor = liquidateFactor;
    }

    function calInterest(address token) public {
        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');

        if (now > bank.lastInterestTime) {
            uint256 timePast = now.sub(bank.lastInterestTime);
            uint256 totalDebt = bank.totalDebt;
            //uint256 totalBalance = totalToken(token);
            uint totalBalance = token == address(0)? address(this).balance: myBalance(token);

            uint256 ratePerSec = config.getInterestRate(totalDebt, totalBalance);
            uint256 interest = ratePerSec.mul(timePast).mul(totalDebt).div(1e18);
            
            uint256 toReserve = interest.mul(config.getReserveBps()).div(10000);
            uint256 toBoardroom = interest.mul(config.getBoardroomBps()).div(10000);
            uint256 toPlatform = interest.mul(config.getPlatformBps()).div(10000);
            
            _rewardToBoardroom(token, toBoardroom);

            uint256 restInterest = interest.sub(toReserve).sub(toBoardroom).sub(toPlatform);
            bank.totalInterest = bank.totalInterest.add(restInterest);
            bank.totalReserve = bank.totalReserve.add(toReserve);
            bank.totalBoardroom = bank.totalBoardroom.add(toBoardroom);
            bank.totalPlatform = bank.totalPlatform.add(toPlatform);
            bank.totalDebt = bank.totalDebt.add(interest);
            bank.lastInterestTime = now;
        }
    }

    function withdrawalFunds(address token, address to, uint256 value, uint drawType) external onlyOperator nonReentrant {
        require(drawType >= 0&&drawType < 3, 'Incorrect draw type');

        TokenBank storage bank = banks[token];
        require(bank.isOpen, 'token not exists');
 
        if(drawType==0) {//Reserve
            require(value <= tokenInterests[token].canReserveInterest, 'There are not enough reserve balance');
            bank.totalReserve = bank.totalReserve.sub(value);
            tokenInterests[token].canReserveInterest = tokenInterests[token].canReserveInterest.sub(value);
        } else if(drawType==1) {//Boardroom
            require(value <= tokenInterests[token].canBoardroomInterest, 'There are not enough boardroom balance');
            bank.totalBoardroom = bank.totalBoardroom.sub(value);
            tokenInterests[token].canBoardroomInterest = tokenInterests[token].canBoardroomInterest.sub(value);
        } else if(drawType==2) {//Platform
            require(value <= tokenInterests[token].canPlatformInterest, 'There are not enough platform balance');
            bank.totalPlatform = bank.totalPlatform.sub(value); 
            tokenInterests[token].canPlatformInterest = tokenInterests[token].canPlatformInterest.sub(value);
        }

        uint balance = token == address(0)? address(this).balance: myBalance(token);
        //非deposit存入,这里有可能直接向银行转帐（不会影响bank.totalVal的变化），而不是通过合成资产存入的资产
        if(balance < bank.totalVal.add(value)) {
            bank.totalVal = bank.totalVal.sub(value);
        }

        if (token == address(0)) {
            safeTransferETH(to, value);
        } else {
            IERC20(token).safeTransfer(to, value);
        }
    }

    function liquidate(uint256 posId) external payable onlyEOA nonReentrant {
        Position storage pos = positions[posId];
        require(pos.debtShare > 0, "liquidate:no debt");
        Production storage production = productions[pos.productionId];

        calInterest(production.borrowToken);

        uint256 debt = _removeDebt(pos, production);
        
        uint256 health = Goblin(production.goblin).health(posId, production.borrowToken);
        //require modify
        require(health.mul(production.liquidateFactor) < debt.mul(10000), "can't liquidate");

        bool isHT = production.borrowToken == address(0);
        uint256 before = isHT? address(this).balance: myBalance(production.borrowToken);

        Goblin(production.goblin).liquidate(posId, pos.owner, production.borrowToken);
        
        uint256 back = isHT? address(this).balance: myBalance(production.borrowToken);

        back = back.sub(before);

        uint256 prize = back.mul(config.getLiquidateBps()).div(10000);//10% kill prize
        uint256 rest = back.sub(prize);
        uint256 left = 0;

        if (prize > 0) {
            isHT? safeTransferETH(msg.sender, prize): IERC20(production.borrowToken).safeTransfer(msg.sender, prize);
        }
        
        positions[posId].lptAmount = 0;//清除仓位
        positions[posId].loanAmount = 0;

        if (rest > debt) {
            left = rest.sub(debt);

            _calEnabledInterest(production.borrowToken, debt.sub(positions[posId].loanAmount));

            isHT? safeTransferETH(pos.owner, left): IERC20(production.borrowToken).safeTransfer(pos.owner, left);
        } else {
            banks[production.borrowToken].totalVal = banks[production.borrowToken].totalVal.sub(debt).add(rest);
        }
    
        emit Liquidate(posId, msg.sender, prize, left);
    }

    function harvest(uint256 posId, bytes calldata data) external onlyEOA nonReentrant {
        Position storage pos = positions[posId];

        Production storage production = productions[pos.productionId];

        calInterest(production.borrowToken);

        uint256 debt = _removeDebt(pos, production);

        bool isHT = production.borrowToken == address(0);
        uint256 before = isHT? address(this).balance: myBalance(production.borrowToken);

        positions[posId].lptAmount = 0;
        positions[posId].loanAmount = 0;

        Goblin(production.goblin).work(posId, msg.sender, production.borrowToken, uint256(0), debt, data);
        
        uint256 back = isHT? address(this).balance: myBalance(production.borrowToken);

        back = back.sub(before);

        uint256 left = 0;
        if (back > debt) {
            left = back.sub(debt);
            
            _calEnabledInterest(production.borrowToken, debt.sub(positions[posId].loanAmount));
            
            isHT? safeTransferETH(pos.owner, left): IERC20(production.borrowToken).safeTransfer(pos.owner, left);
        } else {
            banks[production.borrowToken].totalVal = banks[production.borrowToken].totalVal.sub(debt).add(back);
        }
        emit Harvest(posId, msg.sender, back, left);
    }

    function _addDebt(Position storage pos, Production storage production, uint256 debtVal) internal {
        if (debtVal == 0) {
            return;
        }

        TokenBank storage bank = banks[production.borrowToken];

        uint256 debtShare = debtValToShare(production.borrowToken, debtVal);
        pos.debtShare = pos.debtShare.add(debtShare);

        bank.totalVal = bank.totalVal.sub(debtVal);
        bank.totalDebtShare = bank.totalDebtShare.add(debtShare);
        bank.totalDebt = bank.totalDebt.add(debtVal);
    }

    function _removeDebt(Position storage pos, Production storage production) internal returns (uint256) {
        TokenBank storage bank = banks[production.borrowToken];

        uint256 debtShare = pos.debtShare;
        if (debtShare > 0) {
            uint256 debtVal = debtShareToVal(production.borrowToken, debtShare);
            pos.debtShare = 0;

            bank.totalVal = bank.totalVal.add(debtVal);
            bank.totalDebtShare = bank.totalDebtShare.sub(debtShare);
            bank.totalDebt = bank.totalDebt.sub(debtVal);

            return debtVal;
        } else {
            return 0;
        }
    }

    function _calEnabledInterest(address borrowToken, uint256 interest) internal {
        uint256 toReserve = interest.mul(config.getReserveBps()).div(10000);
        uint256 toBoardroom = interest.mul(config.getBoardroomBps()).div(10000);
        uint256 toPlatform = interest.mul(config.getPlatformBps()).div(10000);
        
        tokenInterests[borrowToken].canReserveInterest = tokenInterests[borrowToken].canReserveInterest.add(toReserve);
        tokenInterests[borrowToken].canBoardroomInterest = tokenInterests[borrowToken].canReserveInterest.add(toBoardroom);
        tokenInterests[borrowToken].canPlatformInterest = tokenInterests[borrowToken].canReserveInterest.add(toPlatform);
    }


    function _rewardToBoardroom(address token, uint256 fee) internal {
        if(fee > 0) {
            token = token == address(0) ? wht : token;
            IRewardNotifier(boardroom).notify(token, fee);
        }
    }

    receive() external payable {}
}