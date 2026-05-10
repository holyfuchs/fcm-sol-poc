// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FCMVault} from "../contracts/FCMVault.sol";
import {MockYieldToken} from "../contracts/mocks/MockYieldToken.sol";
import {MockPriceSource} from "../contracts/mocks/MockPriceSource.sol";
import {V3PoolHelper, IUniswapV3Factory} from "../contracts/mocks/V3PoolHelper.sol";

/// @notice Deploys the on-chain pieces of the FCM demo. The remaining setup
///         (whale impersonation, Aave oracle source override, pool seeding) is
///         performed by `scripts-js/postDeploy.js`.
contract DeployFCMVault is ScaffoldETHDeploy {
    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PUNCH_FACTORY = 0xf331959366032a634c7cAcF5852fE01ffdB84Af0;

    function run() external ScaffoldEthDeployerRunner {
        MockYieldToken yieldToken =
            new MockYieldToken("Mock Yield", "mYLD", 18);

        // Initial price: 0.50 USD (Aave oracle base unit is 1e8).
        MockPriceSource priceSource = new MockPriceSource(0.50e8);

        V3PoolHelper poolHelper =
            new V3PoolHelper(IUniswapV3Factory(PUNCH_FACTORY));

        FCMVault vault = new FCMVault(
            IERC20(WETH),
            IERC20(address(yieldToken)),
            18,
            "Leveraged WETH",
            "lvWETH"
        );

        deployments.push(Deployment("FCMVault", address(vault)));
        deployments.push(Deployment("MockYieldToken", address(yieldToken)));
        deployments.push(Deployment("MockPriceSource", address(priceSource)));
        deployments.push(Deployment("V3PoolHelper", address(poolHelper)));
    }
}
