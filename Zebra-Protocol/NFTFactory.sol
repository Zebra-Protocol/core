// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import './access/Operator.sol';
import "./interfaces/INFT.sol";

import '@nomiclabs/buidler/console.sol';

contract NFTFactory is Operator {

    constructor() public {
    }

    function mint(address _nftAddress, uint256 nftNum, address _toAddress) public onlyOwner {
        assert(owner() == msg.sender);
        //console.log("***********nftAddress:%s",nftAddress);
        INFT openSeaNft = INFT(_nftAddress);
        for (uint256 i = 0;i < nftNum;i++) {
            openSeaNft.mintTo(_toAddress);
        }
    }

    function ownerOf(address _nftAddress, uint256 _tokenId) public view returns (address _owner) {
        INFT openSeaNft = INFT(_nftAddress);
        return openSeaNft.ownerOf(_tokenId);
    }

    function getCurrentTokenId(address _nftAddress) public view returns (uint256) {
        INFT openSeaNft = INFT(_nftAddress);
        return openSeaNft.getCurrentTokenId();
    }
}
