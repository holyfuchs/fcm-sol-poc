// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal Uniswap-V3-style SwapRouter02 surface used by the vault.
///         Compatible with FlowSwap V3's SwapRouter02 on Flow EVM.
///         Note: SwapRouter02 drops the `deadline` field that SwapRouter v1 had.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}
