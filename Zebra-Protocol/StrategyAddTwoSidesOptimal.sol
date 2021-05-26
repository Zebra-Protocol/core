// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

import './lib/Math.sol';
import './lib/TokenSwapUtil.sol';
import './interfaces/Strategy.sol';
import './interfaces/IMdexFactory.sol';
import './interfaces/IMdexRouter.sol';
import './interfaces/IMdexPair.sol';
import './interfaces/IWHT.sol';

contract StrategyAddTwoSidesOptimal is Ownable, ReentrancyGuard, Strategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IMdexFactory public factory;
    IMdexRouter public router;
    address public wht;
    address public goblin;

    /// @dev Create a new add two-side optimal strategy instance for mdx.
    /// @param _router The mdx router smart contract.
    /// @param _goblin The goblin can execute the smart contract.
    constructor(IMdexRouter _router, address _goblin) public {
        factory = IMdexFactory(_router.factory());
        router = _router;

        wht = _router.WHT();
        goblin = _goblin;
    }

    /// @dev Throws if called by any account other than the goblin.
    modifier onlyGoblin() {
        require(isGoblin(), "caller is not the goblin");
        _;
    }

    /// @dev Returns true if the caller is the current goblin.
    function isGoblin() public view returns (bool) {
        return msg.sender == goblin;
    }

    function myBalance(address token) internal view returns (uint) {
        return IERC20(token).balanceOf(address(this));
    }
    
    /// @dev Execute worker strategy. Take LP tokens + debtToken. Return LP tokens.
    /// @param user User address
    /// @param borrowToken The token user borrow from bank.
    /// @param borrow The amount user borrow from bank.
    /// @param data Extra calldata information passed along to this strategy.
    function execute(address user, address borrowToken, uint256 borrow, uint256 /* debt */, bytes calldata data)
        external
        override
        payable
        onlyGoblin
        nonReentrant
    {
        address token0;
        address token1;
        uint256 minLPAmount;
        {
            // 1. decode token and amount info, and transfer to contract.
            (address _token0, address _token1, uint256 token0Amount, uint256 token1Amount, uint256 _minLPAmount) =
                abi.decode(data, (address, address, uint256, uint256, uint256));
            token0 = _token0;
            token1 = _token1;
            minLPAmount = _minLPAmount;

            require(borrowToken == token0 || borrowToken == token1, "borrowToken not token0 and token1");
            if (token0Amount > 0 && _token0 != address(0)) {
                IERC20(token0).safeTransferFrom(user, address(this), token0Amount);
            }
            if (token1Amount > 0 && token1 != address(0)) {
                IERC20(token1).safeTransferFrom(user, address(this), token1Amount);
            }
        }

        address htRelative = address(0);
        {
            if (borrow > 0 && borrowToken != address(0)) {
                IERC20(borrowToken).safeTransferFrom(msg.sender, address(this), borrow);
            }
            if (token0 == address(0)){
                token0 = wht;
                htRelative = token1;
            }
            if (token1 == address(0)){
                token1 = wht;
                htRelative = token0;
            }

            // change all ht to WHT if need.
            uint256 htBalance = address(this).balance;
            if (htBalance > 0) {
                IWHT(wht).deposit{value:htBalance}();
            }
        }
        // tokens are all ERC20 token now.

        IMdexPair lpToken = IMdexPair(factory.getPair(token0, token1));
        // 2. Compute the optimal amount of token0 and token1 to be converted.
        address tokenRelative;
        {
            borrowToken = borrowToken == address(0) ? wht : borrowToken;
            tokenRelative = borrowToken == lpToken.token0() ? lpToken.token1() : lpToken.token0();

            IERC20(borrowToken).safeApprove(address(router), 0);
            IERC20(borrowToken).safeApprove(address(router), uint256(-1));

            IERC20(tokenRelative).safeApprove(address(router), 0);
            IERC20(tokenRelative).safeApprove(address(router), uint256(-1));

            // 3. swap and mint LP tokens.
            calAndSwap(lpToken, borrowToken, tokenRelative);//0.1,0

            (,, uint256 moreLPAmount) = router.addLiquidity(token0, token1, myBalance(token0), myBalance(token1), 0, 0, address(this), now);
            require(moreLPAmount >= minLPAmount, "insufficient LP tokens received");
        }
        // 4. send lpToken and borrowToken back to the sender.
        lpToken.transfer(msg.sender, lpToken.balanceOf(address(this)));

        if (htRelative == address(0)) {
            IERC20(borrowToken).safeTransfer(msg.sender, myBalance(borrowToken));
            IERC20(tokenRelative).safeTransfer(user, myBalance(tokenRelative));
        } else {
            safeUnWrapperAndAllSend(borrowToken, msg.sender);
            safeUnWrapperAndAllSend(tokenRelative, user);
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

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }
    /// Compute amount and swap between borrowToken and tokenRelative.
    function calAndSwap(IMdexPair lpToken, address borrowToken, address tokenRelative) internal {
        (uint256 token0Reserve, uint256 token1Reserve,) = lpToken.getReserves();

        (uint256 debtReserve, uint256 relativeReserve) = borrowToken ==
            lpToken.token0() ? (token0Reserve, token1Reserve) : (token1Reserve, token0Reserve);

        (uint256 swapAmt, bool isReversed) = TokenSwapUtil.optimalDeposit(myBalance(borrowToken), myBalance(tokenRelative),
            debtReserve, relativeReserve);//0.1,0,1,0.1

        if (swapAmt > 0){
            address[] memory path = new address[](2);
            (path[0], path[1]) = isReversed ? (tokenRelative, borrowToken) : (borrowToken, tokenRelative);
           
            router.swapExactTokensForTokens(swapAmt, 0, path, address(this), now);
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