// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import './access/Operator.sol';
import "./lib/ExtStrings.sol";
import "./interfaces/INFT.sol";

import '@nomiclabs/buidler/console.sol';
/**
 * @title 稀有NFT
 */
contract RareNFT is INFT, ERC721, Operator {
    using ExtStrings for string;
    using SafeERC20 for IERC20;

    struct RewardInfo {
        uint256 periods;//已领取的周期数
        uint256 amount;//已领取ZBT的数量
        uint256 latestRewardTime;//最近一次领取时间
    }

    IERC20 private rewardToken;
    uint256 private _currentTokenId = 0;

    uint256 private starttime;//解锁的开始时间

    uint256 public DURATION = 2 minutes; //每个周期持续的时长(可调整)
    uint256 public TOTAL_PERIODS = 25; //总周期(可调整)
    uint256 public FIRST_RATIO = 15000; //15% 需要除以100000(可调整)
    uint256 public LATER_RATIO = 3540; //3.54% 需要除以100000(可调整)

    uint256 public firstAmount;//首个周期的释放数量
    uint256 public laterAmount;//后面每个周期的释放数量

    //nft token id->zbt reward info
    mapping(uint256 => RewardInfo) private rewards;

    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _starttime,
        uint256 _total,
        address _rewardToken
    ) public ERC721(_name, _symbol) {
        starttime = _starttime;
        firstAmount = _total.mul(FIRST_RATIO).div(100000);
        laterAmount = _total.mul(LATER_RATIO).div(100000);
        rewardToken = IERC20(_rewardToken);
    }

    //检查解锁时间是否到了
    modifier checkStart() {
        require(starttime > 0, "not start");
        require(block.timestamp >= starttime, 'not start');
        _;
    }

    function getStartTime() public view returns(uint256) {
        return starttime;
    }

    function getRewardInfo(uint256 tokenId) public view returns(uint256, uint256, uint256) {
        return (rewards[tokenId].periods,rewards[tokenId].amount,rewards[tokenId].latestRewardTime);
    }

    function withdraw() public checkStart {
        uint256[] memory nfts  = tokensOfOwner(msg.sender);
        require(nfts.length > 0,"There is no NFT on your account");
        
        uint256 periodNum = (block.timestamp.sub(starttime)).div(DURATION);
        if(periodNum > TOTAL_PERIODS) {
            periodNum = TOTAL_PERIODS;
        }
        console.log("*******getReward periodNum:%s nfts:%s",periodNum, nfts.length);
        require(periodNum > 0 ,"It's not time to get rewards");
        
        if(nfts.length==1) {
            if(periodNum <= rewards[nfts[0]].periods) {
                require(2 < 1 ,"It's not time to get rewards");
            }
        }
        
        for(uint i = 0;i < nfts.length; i++) {
            RewardInfo memory info = rewards[nfts[i]];
            if(periodNum > info.periods) {
                uint256 reward = 0;
                if(info.periods == 0) {//首个周期
                    reward = firstAmount.add((periodNum.sub(1)).mul(laterAmount));
                } else {
                    reward = (periodNum.sub(info.periods)).mul(laterAmount);
                }
                require(reward <= rewardToken.balanceOf(address(this)),"The balance of the ZBT is not enough");
                
                rewards[nfts[i]].periods = periodNum;
                rewards[nfts[i]].amount = rewards[nfts[i]].amount.add(reward);
                rewards[nfts[i]].latestRewardTime = block.timestamp;

                rewardToken.safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, reward);
            }
        }
    }

    function getReward(address user) public view returns(uint256) {
        uint256[] memory nfts  = tokensOfOwner(user);
        if(nfts.length == 0) {
            return 0;
        }
        
        uint256 periodNum = (block.timestamp.sub(starttime)).div(DURATION);
        if(periodNum > TOTAL_PERIODS) {
            periodNum = TOTAL_PERIODS;
        }
        if(periodNum == 0) {
            return 0;
        }
        uint256 sumReward = 0;
        for(uint i = 0;i < nfts.length; i++) {
            RewardInfo memory info = rewards[nfts[i]];
            if(periodNum > info.periods) {
                uint256 reward = 0;
                if(info.periods == 0) {//首个周期
                    reward = firstAmount.add((periodNum.sub(1)).mul(laterAmount));
                } else {
                    reward = (periodNum.sub(info.periods)).mul(laterAmount);
                }
                sumReward = sumReward.add(reward);
            }
        }
        return sumReward;
    }
    /**
     * @dev Mints a token to an address with a tokenURI.
     * @param _to address of the future owner of the token
     */
    function mintTo(address _to) public override onlyOwner {
        //console.log("aaaaaaaaaa","");
        uint256 newTokenId = _getNextTokenId();
        _mint(_to, newTokenId);
        //console.log("bbbbbbbbbb","");
        _incrementTokenId();
    }

    /**
     * @dev calculates the next token ID based on value of _currentTokenId
     * @return uint256 for the next token ID
     */
    function _getNextTokenId() private view returns (uint256) {
        return _currentTokenId.add(1);
    }

    function getCurrentTokenId() public view override returns (uint256) {
        return _currentTokenId;
    }

    function tokensOfOwner(address user) public view returns (uint256[] memory) {
        console.log("***********tokensOfOwner:%s",user);
        uint256 count = super.balanceOf(user);
        uint256[] memory tokenIds = new uint256[](count);
        for(uint i = 0;i < count;i++) {
            tokenIds[i] = super.tokenOfOwnerByIndex(user,i);
        }
        return tokenIds;
    }

    /**
     * @dev increments the value of _currentTokenId
     */
    function _incrementTokenId() private {
        _currentTokenId++;
    }

    function baseTokenURI() public pure returns (string memory) {
        return "";
    }
}
