// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV3PoolMin {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IPriceOracleGetter {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Chainlink-style oracle source for AaveOracle that derives the yield
///         token's USD price from a Uniswap-V3-style pool against a quote token
///         (here PYUSD), then anchors to PYUSD's USD price from AaveOracle.
contract V3PoolPriceSource {
    using Math for uint256;

    address public immutable pool;
    address public immutable yieldToken;
    address public immutable quoteToken;
    address public immutable aaveOracle;
    bool    public immutable yieldIsToken0;
    uint256 public immutable yieldDecScale;
    uint256 public immutable quoteDecScale;

    constructor(address pool_, address yieldToken_, address quoteToken_, address aaveOracle_) {
        pool = pool_;
        yieldToken = yieldToken_;
        quoteToken = quoteToken_;
        aaveOracle = aaveOracle_;
        yieldIsToken0 = IUniswapV3PoolMin(pool_).token0() == yieldToken_;
        yieldDecScale = 10 ** IERC20Decimals(yieldToken_).decimals();
        quoteDecScale = 10 ** IERC20Decimals(quoteToken_).decimals();
    }

    /// @notice Yield token's USD price in Aave's 1e8 base.
    function latestAnswer() external view returns (int256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMin(pool).slot0();
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 Q192 = 1 << 192;

        // quotePerYield_human × 1e8 — i.e. how many quote-tokens (human units)
        // equal 1 yield-token (human units), scaled into 1e8 base.
        uint256 quotePerYieldScaled;
        if (yieldIsToken0) {
            // priceX192 / 2^192 = quote_wei / yield_wei
            // quote_human / yield_human = (quote_wei / yield_wei) × yieldDecScale / quoteDecScale
            quotePerYieldScaled = Math.mulDiv(
                priceX192,
                yieldDecScale * 1e8,
                Q192 * quoteDecScale
            );
        } else {
            // token0 = quote, token1 = yield
            // priceX192 / 2^192 = yield_wei / quote_wei
            // quote_human / yield_human = (quote_wei / yield_wei)^-1 × yieldDecScale / quoteDecScale
            //                           = 2^192 / priceX192 × yieldDecScale / quoteDecScale
            quotePerYieldScaled = Math.mulDiv(
                Q192,
                yieldDecScale * 1e8,
                priceX192 * quoteDecScale
            );
        }

        uint256 quoteUsd = IPriceOracleGetter(aaveOracle).getAssetPrice(quoteToken); // 1e8
        // yieldUsd (1e8) = quotePerYieldScaled (1e8) × quoteUsd (1e8) / 1e8
        return int256((quotePerYieldScaled * quoteUsd) / 1e8);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
