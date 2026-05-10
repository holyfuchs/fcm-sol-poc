// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IUniswapV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);
    function tickSpacing() external view returns (int24);
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
}

/// @notice Test-only helper that deploys real Uniswap-V3-style pools on a
///         live factory (e.g. PunchSwap V3 on Flow EVM) and seeds them with
///         full-range liquidity. Implements the V3 mint callback so the
///         pool can pull funds from this helper directly.
///
///         Per-test usage:
///           helper = new V3PoolHelper(factory);
///           IERC20(tokenA).approve(address(helper), amountA);
///           IERC20(tokenB).approve(address(helper), amountB);
///           helper.createAndFundPool(tokenA, tokenB, fee, amountA, amountB);
///
///         The implied price is `amountB / amountA` (after sorting by
///         address). The pool is initialised at that price and full-range
///         liquidity is added; whichever side is the binding constraint is
///         consumed entirely, the other has small dust remaining in the
///         helper (negligible for tests).
contract V3PoolHelper {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant Q96 = 1 << 96;
    int24   internal constant MIN_TICK = -887272;
    int24   internal constant MAX_TICK =  887272;

    IUniswapV3Factory public immutable factory;

    constructor(IUniswapV3Factory factory_) {
        factory = factory_;
    }

    /// @param amountA      Indicative reserve for `tokenA` — used together with
    ///                     `amountB` to determine the pool's initial price
    ///                     (`amountB / amountA` after address sort). Actual
    ///                     amounts the pool pulls may differ slightly from
    ///                     these due to V3 liquidity rounding, so the caller
    ///                     should hold a small buffer above the inputs and
    ///                     approve this helper for at least that much.
    function createAndFundPool(
        address tokenA,
        address tokenB,
        uint24 fee,
        uint256 amountA,
        uint256 amountB
    ) external returns (address pool) {
        (address token0, address token1, uint256 amount0, uint256 amount1) =
            tokenA < tokenB
                ? (tokenA, tokenB, amountA, amountB)
                : (tokenB, tokenA, amountB, amountA);

        pool = factory.getPool(token0, token1, fee);
        if (pool == address(0)) {
            pool = factory.createPool(token0, token1, fee);
        }

        // sqrtPriceX96 = sqrt(amount1 / amount0) * 2^96
        uint256 ratioX192 = Math.mulDiv(amount1, 1 << 192, amount0);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(ratioX192));

        // Only initialise if the pool isn't already live.
        (uint160 existing,,,,,,) = IUniswapV3Pool(pool).slot0();
        if (existing == 0) {
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        int24 spacing = IUniswapV3Pool(pool).tickSpacing();
        int24 tickLower = (MIN_TICK / spacing) * spacing;
        int24 tickUpper = (MAX_TICK / spacing) * spacing;

        // Full-range liquidity: L0 = amount0 * sqrtP / Q96, L1 = amount1 * Q96 / sqrtP.
        // The pool will recompute exact amounts owed in the callback.
        uint256 L0 = Math.mulDiv(amount0, sqrtPriceX96, Q96);
        uint256 L1 = Math.mulDiv(amount1, Q96, sqrtPriceX96);
        uint128 liquidity = uint128(L0 < L1 ? L0 : L1);
        require(liquidity > 0, "zero liquidity");

        IUniswapV3Pool(pool).mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(token0, token1, msg.sender)
        );
    }

    /// V3 pool mint callback — `msg.sender` is the pool. We pay it what it's
    /// owed by transferring from the original caller of `createAndFundPool`,
    /// who must have approved this helper for at least the owed amounts.
    /// PunchSwap forked Uniswap V3 with a renamed callback selector.
    function punchSwapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        (address token0, address token1, address payer) =
            abi.decode(data, (address, address, address));
        if (amount0Owed > 0) {
            IERC20(token0).safeTransferFrom(payer, msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            IERC20(token1).safeTransferFrom(payer, msg.sender, amount1Owed);
        }
    }
}
