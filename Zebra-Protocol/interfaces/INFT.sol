// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface INFT is IERC721 {
    function mintTo(address _to) external;
    function getCurrentTokenId() external view returns (uint256);
}
