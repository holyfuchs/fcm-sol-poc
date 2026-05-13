// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {Script} from "forge-std/Script.sol";
import {Yearn4626Router} from "@yearn-router/Yearn4626Router.sol";
import {IWETH9} from "@yearn-router/external/PeripheryPayments.sol";

/// @notice Stage 2: Yearn ERC-4626 Router. Compiled with solc 0.8.18 (Yearn's
///         pinned pragma). Standalone Script — doesn't extend ScaffoldETHDeploy
///         (which is ^0.8.19 and would force solc ≥0.8.19). Appends the
///         deployed address into the shared `deployments/<chainId>.json`.
contract DeployRouter is Script {
    address constant WETH = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;

    function run() external {
        vm.startBroadcast();
        Yearn4626Router router = new Yearn4626Router("FCMRouter", IWETH9(WETH));
        vm.stopBroadcast();

        // Append to deployments/<chainId>.json. The JSON is a flat map of
        // address → name (plus a `networkName` key). We read, add our entry, write.
        string memory path = string.concat(
            vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"
        );

        string memory jsonOut;
        if (vm.exists(path)) {
            string memory existing = vm.readFile(path);
            string[] memory keys = vm.parseJsonKeys(existing, "$");
            for (uint256 i = 0; i < keys.length; i++) {
                string memory v = abi.decode(vm.parseJson(existing, string.concat(".", keys[i])), (string));
                vm.serializeString(jsonOut, keys[i], v);
            }
        }
        jsonOut = vm.serializeString(jsonOut, vm.toString(address(router)), "Yearn4626Router");
        vm.writeJson(jsonOut, path);
    }
}
