//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import { DeployFCMVault } from "./DeployFCMVault.s.sol";

contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        DeployFCMVault d = new DeployFCMVault();
        d.run();
    }
}
