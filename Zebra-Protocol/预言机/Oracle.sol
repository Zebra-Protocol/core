// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/math/SafeMath.sol';

// import './lib/Babylonian.sol';
// import './lib/FixedPoint.sol';
// import './lib/UniswapV2OracleLibrary.sol';
// import './utils/Epoch.sol';
import './uniswap/IUniswapV2Pair.sol';
import './uniswap/IUniswapV2Factory.sol';
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
    IUniswapV2Pair public ZBTUSDTPair;

    /* ========== CONSTRUCTOR ========== */
    constructor(
        address _factory,
        address zbt_,
        address usdt_
    ) public {
        ZBTUSDTPair = IUniswapV2Pair(
            IUniswapV2Factory(_factory).getPair(zbt_, usdt_)
        );

        zbt = zbt_;
        usdt = usdt_;
    }

    function addPair(address pair_) public onlyOperator {
        address token0 = IUniswapV2Pair(pair_).token0();
        address token1 = IUniswapV2Pair(pair_).token1();

        require(token0 == usdt || token1 == usdt, "token0 or token1 must be USDT");

        if (token0 != usdt) {
            tokenCluster[token0] = pair_;
        }

        if (token1 != usdt) {
            tokenCluster[token1] = pair_;
        }
    }

    function quote(uint amountA, uint reserveA, uint reserveB) internal pure returns (uint amountB) {
        amountB = amountA.mul(reserveB) / reserveA;
    }

    function R(address token, uint256 amount) public view returns(uint256) {
        if (token == zbt) {
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

        (uint256 reserve0, uint256 reserve1,) = IUniswapV2Pair(tokenCluster[token]).getReserves();
        address token0_ = IUniswapV2Pair(tokenCluster[token]).token0();
        uint256 usdtAmount;
        if (token == token0_) {
            usdtAmount = quote(amount, reserve0, reserve1);
        } else {
            usdtAmount = quote(amount, reserve1, reserve0);
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
        return IUniswapV2Factory(factory).getPair(tokenA, tokenB);
    }

    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);
}
