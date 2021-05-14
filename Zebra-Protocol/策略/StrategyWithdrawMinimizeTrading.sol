// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './lib/Math.sol';
import './interfaces/Strategy.sol';
import './interfaces/IMdexFactory.sol';
import './interfaces/IMdexRouter.sol';
import './interfaces/IMdexPair.sol';
import './interfaces/IWHT.sol';

contract StrategyWithdrawMinimizeTrading is Ownable, ReentrancyGuard, Strategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IMdexFactory public factory;
    IMdexRouter public router;
    address public wht;

    /// @dev Create a new withdraw minimize trading strategy instance for mdx.
    /// @param _router The mdx router smart contract.
    constructor(IMdexRouter _router) public {
        factory = IMdexFactory(_router.factory());
        router = _router;
        wht = _router.WHT();
    }
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }
    function myBalance(address token) internal view returns (uint) {
        return IERC20(token).balanceOf(address(this));
    }
    /// @dev Execute worker strategy. Take LP tokens. Return debt token + token want back.
    /// @param user User address to withdraw liquidity.
    /// @param borrowToken The token user borrow from bank.
    /// @param debt User's debt amount.
    /// @param data Extra calldata information passed along to this strategy.
    function execute(address user, address borrowToken, uint256 /* borrow */, uint256 debt, bytes calldata data)
        external
        override
        payable
        nonReentrant
    {
        // 1. Find out lpToken and liquidity.
        // whichWantBack: 0:token0; 1:token1; 2:token what surplus.
        (address token0, address token1, uint whichWantBack) = abi.decode(data, (address, address, uint));

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
        address tokenUserWant = whichWantBack == uint(0) ? token0 : token1;

        IMdexPair lpToken = IMdexPair(factory.getPair(token0, token1));
        token0 = lpToken.token0();
        token1 = lpToken.token1();

        {
            lpToken.approve(address(router), uint256(-1));
            router.removeLiquidity(token0, token1, lpToken.balanceOf(address(this)), 0, 0, address(this), now);
        }
        {
            borrowToken = isBorrowHt ? wht : borrowToken;
            address tokenRelative = borrowToken == token0 ? token1 : token0;

            swapIfNeed(borrowToken, tokenRelative, debt);

            if (isBorrowHt) {
                IWHT(wht).withdraw(debt);
                safeTransferETH(msg.sender, debt);
            } else {
                IERC20(borrowToken).safeTransfer(msg.sender, debt);
            }
        }

        // 2. swap remaining token to what user want.
        if (whichWantBack != uint(2)) {
            address tokenAnother = tokenUserWant == token0 ? token1 : token0;
            uint256 anotherAmount = myBalance(tokenAnother);

            if(anotherAmount > 0){
                IERC20(tokenAnother).safeApprove(address(router), 0);
                IERC20(tokenAnother).safeApprove(address(router), uint256(-1));

                address[] memory path = new address[](2);
                path[0] = tokenAnother;
                path[1] = tokenUserWant;
                router.swapExactTokensForTokens(anotherAmount, 0, path, address(this), now);
            }
        }
        // 3. send all tokens back.
        if (htRelative == address(0)) {
            IERC20(token0).safeTransfer(user, myBalance(token0));
            IERC20(token1).safeTransfer(user, myBalance(token1));
        } else {
            safeUnWrapperAndAllSend(wht, user);
            safeUnWrapperAndAllSend(htRelative, user);
        }
    }

    /// swap if need.
    function swapIfNeed(address borrowToken, address tokenRelative, uint256 debt) internal {
        uint256 borrowTokenAmount = myBalance(borrowToken);

        if (debt > borrowTokenAmount) {//5,3
            IERC20(tokenRelative).safeApprove(address(router), 0);
            IERC20(tokenRelative).safeApprove(address(router), uint256(-1));

            uint256 remainingDebt = debt.sub(borrowTokenAmount);
            address[] memory path = new address[](2);
            path[0] = tokenRelative;
            path[1] = borrowToken;
            router.swapTokensForExactTokens(remainingDebt, myBalance(tokenRelative), path, address(this), now);
        }
    }

    /// get token balance, if is WHT un wrapper to HT and send to 'to'
    function safeUnWrapperAndAllSend(address token, address to) internal {
        uint256 total = myBalance(token);

        if (total > 0) {
            if (token == wht) {
                IWHT(wht).withdraw(total);
                safeTransferETH(to, total);
            } else {
                IERC20(token).safeTransfer(to, total);
            }
        }
    }

    /// @dev Recover ERC20 tokens that were accidentally sent to this smart contract.
    /// @param token The token contract. Can be anything. This contract should not hold ERC20 tokens.
    /// @param to The address to send the tokens to.
    /// @param value The number of tokens to transfer to `to`.
    function recover(address token, address to, uint256 value) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(to, value);
    }

    receive() external payable {}
}