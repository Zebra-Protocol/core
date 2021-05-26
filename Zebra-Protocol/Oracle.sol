// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';

// import './lib/Babylonian.sol';
// import './lib/FixedPoint.sol';
// import './utils/Epoch.sol';
import './interfaces/IMdexPair.sol';
import './interfaces/IMdexFactory.sol';
import './access/Operator.sol';

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract Oracle is Operator {
    // using FixedPoint for *;
    using SafeMath for uint256;

    struct PairInfo {
        address pair;
        address token0;
        address token1;
    }

    // mapping (address =>PairInfo) public pairs;
    mapping (address =>address) public tokenCluster;

    address public zbt;
    address public usdt;
    IMdexPair public ZBTUSDTPair;

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address zbt_,
        address usdt_
    ) public {
        zbt = zbt_;
        usdt = usdt_;
    }

    function initPair(address pair_) public onlyOperator {
        ZBTUSDTPair = IMdexPair(pair_);
    }

    function addPair(address pair_) public onlyOperator {
        address token0 = IMdexPair(pair_).token0();
        address token1 = IMdexPair(pair_).token1();

        require(token0 == usdt || token1 == usdt, "token0 or token1 must be USDT");

        if (token0 != usdt) {
            tokenCluster[token0] = pair_;
        }

        if (token1 != usdt) {
            tokenCluster[token1] = pair_;
        }
    }

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function quote(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'Oracle: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'Oracle: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }

    function quote2(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        amountB = amountA.mul(reserveB) / reserveA;
    }

    function R(address token, uint256 amount) public view returns(uint256) {    
        if (token == zbt || amount==0) {
            return amount;
        }

        (uint256 zbtUSDT_reserve0, uint256 zbtUSDT_reserve1,) = ZBTUSDTPair.getReserves();
        address zbtUSDT_token0 = ZBTUSDTPair.token0();

        if (token == usdt) {
            if (token == zbtUSDT_token0) {
                return quote(amount, zbtUSDT_reserve0, zbtUSDT_reserve1);
            } else {
                return quote(amount, zbtUSDT_reserve1, zbtUSDT_reserve0);
            }
        }
        
        if (tokenCluster[token] == address(0)) {
            return 0;
        }

        (uint256 reserve0, uint256 reserve1,) = IMdexPair(tokenCluster[token]).getReserves();
        address token0_ = IMdexPair(tokenCluster[token]).token0();
        uint256 usdtAmount;

        if (token == token0_) {
            usdtAmount = quote(amount, reserve0, reserve1);
        } else {
            usdtAmount = quote(amount, reserve1, reserve0);
        }
        
        if (usdtAmount == 0) {
            return 0;
        }

        if (usdt == zbtUSDT_token0) {
            return quote(usdtAmount, zbtUSDT_reserve0, zbtUSDT_reserve1);
        } else {
            return quote(usdtAmount, zbtUSDT_reserve1, zbtUSDT_reserve0);
        }
    }

    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) external view returns (address lpt) {
        return IMdexFactory(factory).getPair(tokenA, tokenB);
    }
}
