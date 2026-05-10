//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { DeployFCMVault } from "./DeployFCMVault.s.sol";

contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        DeployFCMVault deployFCMVault = new DeployFCMVault();
        deployFCMVault.run();
    }
}
