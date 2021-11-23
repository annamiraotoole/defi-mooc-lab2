//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    address target_address = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F; // loan of USDT collateralized with WBTC
    address loaner_address = 0xa61e59faC455EED933405ecDde9928982B478CE7;
    address me = address(this);

    ILendingPool lending_pool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV2Factory uni_factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapV2Factory sushi_factory = IUniswapV2Factory(0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac);
    IUniswapV2Pair weth_usdt_uniswap = IUniswapV2Pair(uni_factory.getPair(WETH, USDT));
    IUniswapV2Pair weth_wbtc_sushiswap = IUniswapV2Pair(sushi_factory.getPair(WETH, WBTC));

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // add a `receive` function so that you can withdraw your WETH
    receive() external payable {}

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***

        // 1. get the target user account data & make sure it is liquidatable

        // totalCollateralETH is equivalent to WBTC borrowed
        // totalDebtETH is equivalent to USDT owed by loan

        // address user_account = address(0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F);
        // position = ILendingPool.getUserAccountData(user_account);

        // bool liquitable = (position.healthFactor < 1);

        uint256 totalCollateralETH;
        uint256 totalDebtETH;
        uint256 availableBorrowsETH;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
        
        (totalCollateralETH, totalDebtETH, availableBorrowsETH, currentLiquidationThreshold, ltv, healthFactor) = lending_pool.getUserAccountData(target_address);
        assert (healthFactor < 1e18);

        // we know that the target user borrowed USDT with WBTC as collateral
        // so we should borrow USDT using Uniswap, 

        uint256 usdt_amount_in_eth = 2916378221684; // getAmountIn(totalCollateralETH, IERC20(WETH).balanceOf(address(this)), IERC20(USDT).balanceOf(address(this)));
        IWETH(WETH).approve(address(weth_usdt_uniswap), usdt_amount_in_eth);
        bool success = IWETH(WETH).transfer(address(weth_usdt_uniswap), usdt_amount_in_eth);
        weth_usdt_uniswap.swap(0, usdt_amount_in_eth, me, "not null for flash swap");

        // 2. call flash swap to liquidate the target user VIA uniswapV2Call
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        
        // weth_usdt_uniswap.uniswapV2Call(me, 0, usdt_amount_in_eth, "not null for flash swap");
        
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***

        
        // 3. Convert the profit into ETH and send back to sender
        //    convert WETH to ETH
        //    *** Your code here ***

        uint256 weth_balance = IWETH(WETH).balanceOf(me);
        IWETH(WETH).withdraw(weth_balance);
        msg.sender.call{value: weth_balance}("");

        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0, // should be 0 = amount in WETH to be given to pool
        uint256 amount1, // should be usdt_amount_in_weth = amout of USDT to be taken from pool
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***

        // console.log tool edstem

        // 2.1 liquidate the target user
        //    *** Your code here ***

        // then liquidate the target user on Aave and get the WBTC collateral back

        uint256 balance_in_usdt = IERC20(USDT).balanceOf(sender);
        IERC20(USDT).approve(address(lending_pool), balance_in_usdt);
        bool success = IERC20(USDT).transfer(address(lending_pool), balance_in_usdt);
        lending_pool.liquidationCall(USDT, WBTC, target_address, balance_in_usdt, false);
        
        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***

        // 2.3 repay
        //    *** Your code here ***

        // then swap WBTC for WETH to repay uniswap
        uint256 balance_in_wbtc = IERC20(WBTC).balanceOf(sender);
        IERC20(WBTC).approve(address(weth_wbtc_sushiswap), balance_in_wbtc);
        success = IERC20(WBTC).transfer(address(weth_wbtc_sushiswap), balance_in_wbtc);
        weth_wbtc_sushiswap.swap(0, balance_in_wbtc, sender, "");

        
        // END TODO
    }
}
