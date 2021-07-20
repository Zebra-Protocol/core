// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './access/Operator.sol';
import "./NFTFactory.sol";
import "./interfaces/INFT.sol";
import "./lib/ExtStrings.sol";

//import '@nomiclabs/buidler/console.sol';

contract NFTManage is Operator,ReentrancyGuard {
    using SafeMath for uint256;
    using ExtStrings for string;

    struct CreateInfo {
        uint256 createId;
        uint256 startTokenId;
        uint256 nftNum;
        uint256 createTime;
    }

    struct DistributeInfo {
        uint256 nftType;
        uint256 distributeId;
        uint256 tokenId;
        address fristAddress;
        uint256 distTime;
    }

    uint256 public currNftType = 0;
    mapping(address => uint256) private nftTypes;
    mapping(uint256 => address) private typeNfts;

    //nft address->sequence
    mapping(address => uint256) private latestNftCreateSeq;
    mapping(address => mapping(uint256 => CreateInfo)) private nftCreateInfos;
    
    uint256 public currDistId = 0;
    //seq id->dist info
    mapping(uint256 => DistributeInfo) private nftDistInfos;
    
    //nft address->user->tokenId
    mapping(address => mapping(address => uint256)) private userNfts;
    
    uint256 public maxNftNum = 50;//一次性铸造NFT的最大数量

    uint256 public maxTransNum = 50;//批量分配NFT的最大数量

    //nft address->count
    mapping(address => uint256) public latestNftTokenID;//对应每一种类型的NFT最近一次分发出去的tokenId

    NFTFactory public nftFactory;

    constructor(address _nftFactory) public {
        nftFactory = NFTFactory(_nftFactory);
    }

    function setMaxNftNum(uint256 _maxNftNum) external onlyOperator {
        maxNftNum = _maxNftNum;
    }

    function setMaxTransNum(uint256 _maxTransNum) external onlyOperator {
        maxTransNum = _maxTransNum;
    }

    //铸造NFT
    function createNFT(address nftAddress, uint256 nftAmount) external onlyOperator nonReentrant {
        require(nftAmount <= maxNftNum, "The number of NFT exceeds the limit");
        uint256 seqID = latestNftCreateSeq[nftAddress].add(1);
        latestNftCreateSeq[nftAddress] = seqID;
        CreateInfo memory info = CreateInfo({
            createId: seqID,
            startTokenId: nftFactory.getCurrentTokenId(nftAddress),
            nftNum: nftAmount,
            createTime: now
        });
        nftCreateInfos[nftAddress][seqID] = info;

        if(nftTypes[nftAddress]==0) {
            currNftType = currNftType.add(1);
            nftTypes[nftAddress] = currNftType;
            typeNfts[currNftType] = nftAddress;
        }

        nftFactory.mint(nftAddress, nftAmount, address(this));
    }

    //分配NFT
    function distributeNFT(address nftAddress, address[] calldata addresses) external onlyOperator nonReentrant {
        require(addresses.length <= maxTransNum, "The number of address exceeds the limit");
        require(addresses.length <= INFT(nftAddress).balanceOf(address(this)), 'Your balance of NFT is not enough.');
        
        for(uint i = 0;i < addresses.length;i++) {
            require(userNfts[nftAddress][addresses[i]] == 0,ExtStrings.strConcat("The ",ExtStrings.toString(addresses[i])," has been distributed"));

            uint256 tokenId = latestNftTokenID[nftAddress].add(1);
            latestNftTokenID[nftAddress] = tokenId;

            currDistId = currDistId.add(1);
            DistributeInfo memory info = DistributeInfo({
                nftType: nftTypes[nftAddress],
                distributeId: currDistId,
                tokenId: tokenId,
                fristAddress: addresses[i],
                distTime: now
            });
            nftDistInfos[currDistId] = info;
            userNfts[nftAddress][addresses[i]] = tokenId;

            INFT(nftAddress).transferFrom(address(this), addresses[i], tokenId);
        }
    }

    //铸造记录的最大ID
    function getCreateMaxId(address nftAddress) external view  returns (uint256) {
        return latestNftCreateSeq[nftAddress];
    }

    function getCreateInfo(address nftAddress) external view  
    returns (uint256, uint256, uint256) {
        uint256 createMaxId = latestNftCreateSeq[nftAddress];
        CreateInfo memory info = nftCreateInfos[nftAddress][createMaxId];
        return (nftFactory.getCurrentTokenId(nftAddress),INFT(nftAddress).balanceOf(address(this)),info.createTime);
    }

    function getDistInfo(uint256 distId) external view  
    returns (address,address, address, uint256, uint256) {
        DistributeInfo memory info = nftDistInfos[distId];
        address nftAddress = typeNfts[info.nftType];

        address currOwner = nftFactory.ownerOf(nftAddress,info.tokenId);
        return (nftAddress,info.fristAddress,currOwner,INFT(nftAddress).balanceOf(currOwner),info.distTime);
    }

    receive() external payable {}
}