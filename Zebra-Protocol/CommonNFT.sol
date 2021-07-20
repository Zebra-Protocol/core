// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';

import './access/Operator.sol';
import "./interfaces/INFT.sol";

import '@nomiclabs/buidler/console.sol';
/**
 * @title 普通NFT
 */
contract CommonNFT is INFT, ERC721, Operator {
    using SafeERC20 for IERC20;

    IERC20 private rewardToken;
    uint256 private _currentTokenId = 0;

    uint256 private starttime;
    uint256 public rewardBase;//How much should be awarded in the first cycle
    //nft token id->zbt rewards
    mapping(uint256 => uint256) private rewards;
    event RewardPaid(address indexed user, uint256 reward);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _starttime,
        uint256 _rewardBase,
        address _rewardToken
    ) public ERC721(_name, _symbol) {
        starttime = _starttime;
        rewardBase = _rewardBase;
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

    function withdraw() public checkStart {
        uint256[] memory nfts  = tokensOfOwner(msg.sender);
        require(nfts.length > 0,"There is no NFT on your account");
        if(nfts.length==1&&rewards[nfts[0]] > 0) {
            require(2 < 1,"You have withdrawn the reward");
        }
        for(uint i = 0;i < nfts.length;i++) {
            if(rewards[nfts[i]] == 0) {
                require(rewardBase <= rewardToken.balanceOf(address(this)),"The balance of the ZBT is not enough");
                rewards[nfts[i]] = rewardBase;
                rewardToken.safeTransfer(msg.sender, rewardBase);
                emit RewardPaid(msg.sender, rewardBase);
            }
        }
    }

    function getReward(address user) public view returns(uint256) { 
        uint256[] memory nfts  = tokensOfOwner(user);
        if(nfts.length == 0) {
            return 0;
        }

        uint256 sumReward = 0;
        for(uint i = 0;i < nfts.length;i++) {
            if(rewards[nfts[i]] == 0) {
                sumReward = sumReward.add(rewardBase);
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
