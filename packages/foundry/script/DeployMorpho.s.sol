// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import {Morpho} from "@morpho-blue/Morpho.sol";
import {IMorpho, MarketParams, Id} from "@morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {WethPriceSource} from "../contracts/mocks/WethPriceSource.sol";
import {Pyusd0PriceSource} from "../contracts/mocks/Pyusd0PriceSource.sol";
import {FixedRateIrm} from "../contracts/morpho/FixedRateIrm.sol";
import {SimpleOracle} from "../contracts/morpho/SimpleOracle.sol";

interface IAaveOracleMin {
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @notice Stage 1: Morpho Blue + IRM + market oracle + price sources + the
///         WETH/PYUSD0 market. Compiled with solc 0.8.19 (Morpho's exact
///         pinned pragma). Writes addresses to `deployments/<chainId>.json`
///         for `DeployFCMVault.s.sol` (stage 3) to read.
contract DeployMorpho is ScaffoldETHDeploy {
    using MarketParamsLib for MarketParams;

    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD0       = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant AAVE_ORACLE  = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;

    uint8  constant WETH_DECIMALS   = 18;
    uint8  constant PYUSD0_DECIMALS = 6;

    uint256 constant LLTV = 0.86e18;
    uint256 constant FIXED_RATE_PER_SECOND = 1585489599; // ~5% APR / sec, 1e18-scaled

    function run() external scaffoldEthDeployerRunner {
        // Seed price sources with live Aave prices so initial HF math matches mainnet.
        uint256 livePColl = IAaveOracleMin(AAVE_ORACLE).getAssetPrice(WETH);
        uint256 livePDebt = IAaveOracleMin(AAVE_ORACLE).getAssetPrice(PYUSD0);
        WethPriceSource wethSource    = new WethPriceSource(int256(livePColl));
        Pyusd0PriceSource pyusdSource = new Pyusd0PriceSource(int256(livePDebt));

        Morpho morpho     = new Morpho(deployer);
        FixedRateIrm irm  = new FixedRateIrm(FIXED_RATE_PER_SECOND);
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

        deployments.push(Deployment({name: "Morpho",            addr: address(morpho)}));
        deployments.push(Deployment({name: "FixedRateIrm",      addr: address(irm)}));
        deployments.push(Deployment({name: "MorphoOracle",      addr: address(morphoOracle)}));
        deployments.push(Deployment({name: "WethPriceSource",   addr: address(wethSource)}));
        deployments.push(Deployment({name: "Pyusd0PriceSource", addr: address(pyusdSource)}));
        // Market id packed into an address slot for downstream JS to read.
        deployments.push(Deployment({
            name: "MorphoMarketId",
            addr: address(uint160(uint256(Id.unwrap(mp.id()))))
        }));
    }
}
