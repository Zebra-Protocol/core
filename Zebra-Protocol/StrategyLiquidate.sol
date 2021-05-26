// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './lib/Math.sol';
import './interfaces/Strategy.sol';
import './interfaces/IMdexFactory.sol';
import './interfaces/IMdexRouter.sol';
import './interfaces/IMdexPair.sol';
import './interfaces/IWHT.sol';
import './access/Operator.sol';


contract StrategyLiquidate is Operator, ReentrancyGuard, Strategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IMdexFactory public factory;
    IMdexRouter public router;
    address public wht;
    mapping(address => bool) private goblins;

    /// @dev Create a new withdraw minimize trading strategy instance for mdx.
    /// @param _router The mdx router smart contract.
    constructor(IMdexRouter _router) public {
        factory = IMdexFactory(_router.factory());
        router = _router;
        wht = _router.WHT();
    }

    modifier onlyGoblin() {
        require(
            goblins[msg.sender] == true,
            'operator: caller is not the goblin'
        );
        _;
    }

    function setGoblin(address goblin) public onlyOperator {
        goblins[goblin] = true;
    }
    
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    function myBalance(address token) internal view returns (uint) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Execute worker strategy. Take LP tokens + ETH. Return LP tokens + ETH.
    /// @param data Extra calldata information passed along to this strategy.
    function execute(address /*user*/, address borrowToken, uint256 /*borrow*/, uint256 /*debt*/, bytes calldata data)
        external
        override
        payable
        onlyGoblin
        nonReentrant
    {
        (address lpAddress) = abi.decode(data, (address));
        IMdexPair lpToken = IMdexPair(lpAddress);

        address token0 = lpToken.token0();
        address token1 = lpToken.token1();

        // is borrowToken is ht.
        bool isBorrowHt = borrowToken == address(0);
        require(borrowToken == token0 || borrowToken == token1 || isBorrowHt, "borrowToken not token0 and token1");
        // the relative token when token0 or token1 is ht.
        address htRelative = address(0);
        {
            if (token0 == address(0)){
                token0 = wht;
                htRelative = token1;
            }
            if (token1 == address(0)){
                token1 = wht;
                htRelative = token0;
            }
        }
        lpToken.approve(address(router), uint256(-1));
        router.removeLiquidity(token0, token1, lpToken.balanceOf(address(this)), 0, 0, address(this), now);
        {
            borrowToken = isBorrowHt ? wht : borrowToken;
            address tokenRelative = borrowToken == token0 ? token1 : token0;

            //convert all token to borrow token
            swapIfNeed(borrowToken, tokenRelative);

            uint whtBalance = myBalance(borrowToken);
            if (isBorrowHt) {
                IWHT(wht).withdraw(whtBalance);
                safeTransferETH(msg.sender, whtBalance);
            } else {
                IERC20(borrowToken).safeTransfer(msg.sender, whtBalance);
            }
        }
    }

    /// swap if need.
    function swapIfNeed(address borrowToken, address tokenRelative) internal {
        uint256 anotherAmount = IERC20(tokenRelative).balanceOf(address(this));
        if(anotherAmount > 0){
            IERC20(tokenRelative).safeApprove(address(router), 0);
            IERC20(tokenRelative).safeApprove(address(router), uint256(-1));

            address[] memory path = new address[](2);
            path[0] = tokenRelative;
            path[1] = borrowToken;
            router.swapExactTokensForTokens(anotherAmount, 0, path, address(this), now);
        }
    }

    /// @dev Recover ERC20 tokens that were accidentally sent to this smart contract.
    /// @param token The token contract. Can be anything. This contract should not hold ERC20 tokens.
    /// @param to The address to send the tokens to.
    /// @param value The number of tokens to transfer to `to`.
    function recover(address token, address to, uint256 value) external onlyOperator nonReentrant {
        IERC20(token).safeTransfer(to, value);
    }

    receive() external payable {}
}