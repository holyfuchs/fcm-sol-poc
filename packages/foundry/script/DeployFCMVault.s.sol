// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Morpho} from "@morpho-blue/Morpho.sol";
import {IMorpho, MarketParams, Id} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";

import {FCMVault} from "../contracts/FCMVault.sol";
import {WethPriceSource} from "../contracts/mocks/WethPriceSource.sol";
import {Pyusd0PriceSource} from "../contracts/mocks/Pyusd0PriceSource.sol";
import {V3PoolPriceSource} from "../contracts/mocks/V3PoolPriceSource.sol";
import {FixedRateIrm} from "../contracts/morpho/FixedRateIrm.sol";
import {SimpleOracle} from "../contracts/morpho/SimpleOracle.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IAaveOracleMin {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @notice One-shot deploy of the full FCM stack on a Flow EVM fork:
///   - Morpho Blue singleton (owner = deployer)
///   - FixedRateIrm at ~5% APR
///   - MockPriceSources for WETH + PYUSD0 (settable; seeded with live Aave prices)
///   - SimpleOracle for Morpho's market (wraps the two MockPriceSources)
///   - WETH/PYUSD0 market on Morpho at 86% LLTV
///   - V3PoolPriceSource for the yield token (reads FlowSwap V3 PYUSD0/YIELD)
///   - FCMVault wired to all the above
contract DeployFCMVault is ScaffoldETHDeploy {
    using MarketParamsLib for MarketParams;

    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD0       = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant AAVE_ORACLE  = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;
    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    address constant YIELD_TOKEN  = 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D;

    uint8  constant WETH_DECIMALS   = 18;
    uint8  constant PYUSD0_DECIMALS = 6;
    uint24 constant FEE_YIELD_DEBT  = 100;

    /// 86% LLTV (1e18-scaled).
    uint256 constant LLTV = 0.86e18;
    /// 5% APR ≈ 5e16 / (365.25*86400) ≈ 1.585e9 per second, 1e18-scaled.
    uint256 constant FIXED_RATE_PER_SECOND = 1585489599;

    function run() external ScaffoldEthDeployerRunner {
        // --- 1. WETH + PYUSD0 price sources (settable). Seed with live Aave prices.
        uint256 livePColl = IAaveOracleMin(AAVE_ORACLE).getAssetPrice(WETH);
        uint256 livePDebt = IAaveOracleMin(AAVE_ORACLE).getAssetPrice(PYUSD0);
        WethPriceSource wethSource   = new WethPriceSource(int256(livePColl));
        Pyusd0PriceSource pyusdSource = new Pyusd0PriceSource(int256(livePDebt));

        // --- 2. Morpho stack.
        Morpho morpho = new Morpho(deployer);
        FixedRateIrm irm = new FixedRateIrm(FIXED_RATE_PER_SECOND);
        SimpleOracle morphoOracle = new SimpleOracle(
            address(wethSource), address(pyusdSource), PYUSD0_DECIMALS, WETH_DECIMALS
        );
        morpho.enableIrm(address(irm));
        morpho.enableLltv(LLTV);

        MarketParams memory mp = MarketParams({
            loanToken: PYUSD0,
            collateralToken: WETH,
            oracle: address(morphoOracle),
            irm: address(irm),
            lltv: LLTV
        });
        morpho.createMarket(mp);

        // --- 3. Yield token oracle from the live FlowSwap V3 pool.
        address yieldPool =
            IUniswapV3Factory(SWAP_FACTORY).getPool(PYUSD0, YIELD_TOKEN, FEE_YIELD_DEBT);
        require(yieldPool != address(0), "PYUSD0/YIELD pool not found");
        V3PoolPriceSource yieldPriceSource =
            new V3PoolPriceSource(yieldPool, YIELD_TOKEN, PYUSD0, AAVE_ORACLE);

        // --- 4. Vault.
        uint8 yieldDecimals = IERC20Decimals(YIELD_TOKEN).decimals();
        FCMVault vault = new FCMVault(
            IERC20(WETH),
            IERC20(YIELD_TOKEN),
            yieldDecimals,
            address(yieldPriceSource),
            address(wethSource),
            address(pyusdSource),
            IMorpho(address(morpho)),
            mp,
            "Leveraged WETH",
            "lvWETH"
        );

        deployments.push(Deployment("Morpho",            address(morpho)));
        deployments.push(Deployment("FixedRateIrm",      address(irm)));
        deployments.push(Deployment("MorphoOracle",      address(morphoOracle)));
        deployments.push(Deployment("WethPriceSource",   address(wethSource)));
        deployments.push(Deployment("Pyusd0PriceSource", address(pyusdSource)));
        deployments.push(Deployment("V3PoolPriceSource", address(yieldPriceSource)));
        deployments.push(Deployment("FCMVault",          address(vault)));
        // Market id (bytes32 → packed into an address slot for serialisation).
        deployments.push(Deployment(
            "MorphoMarketId",
            address(uint160(uint256(Id.unwrap(mp.id()))))
        ));
    }
}
