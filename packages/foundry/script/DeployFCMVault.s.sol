// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ScaffoldETHDeploy } from "./DeployHelpers.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, MarketParams, Id} from "@morpho-blue/interfaces/IMorpho.sol";

import {FCMVault, IAllowlist} from "../contracts/FCMVault.sol";
import {Allowlist} from "../contracts/Allowlist.sol";
import {V3PoolPriceSource} from "../contracts/mocks/V3PoolPriceSource.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

/// @notice Stage 3: deploys V3PoolPriceSource and FCMVault. Reads previously-
///         deployed Morpho stack addresses from `deployments/<chainId>.json`
///         (written by `DeployMorpho.s.sol`). Compiled with solc ≥0.8.20
///         because of OZ V5 (ERC4626 needs ^0.8.24). Cannot share a compilation
///         unit with Morpho.sol (=0.8.19) or Yearn4626Router (=0.8.18) —
///         that's why those are in separate scripts.
contract DeployFCMVault is ScaffoldETHDeploy {
    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD0       = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant AAVE_ORACLE  = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;
    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    address constant YIELD_TOKEN  = 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D;

    uint24  constant FEE_YIELD_DEBT = 100;
    uint256 constant LLTV = 0.86e18;
    /// 30% max per-swap slippage during rebalance. Plenty of room for the demo.
    uint256 constant MAX_SWAP_SLIPPAGE_BPS = 3000;
    /// Health-factor band: rebalance lower-thresh → lower-target, upper-thresh → upper-target.
    uint256 constant HF_LOWER_THRESHOLD = 1.10e18;
    uint256 constant HF_LOWER_TARGET    = 1.15e18;
    uint256 constant HF_UPPER_TARGET    = 1.45e18;
    uint256 constant HF_UPPER_THRESHOLD = 1.50e18;

    struct Wired {
        address morpho;
        address irm;
        address morphoOracle;
        address wethSource;
        address pyusdSource;
    }

    function run() external scaffoldEthDeployerRunner {
        Wired memory w = _loadMorphoStack();

        Allowlist allowlistContract = new Allowlist();
        allowlistContract.set(deployer, true);

        address yieldPool =
            IUniswapV3Factory(SWAP_FACTORY).getPool(PYUSD0, YIELD_TOKEN, FEE_YIELD_DEBT);
        require(yieldPool != address(0), "PYUSD0/YIELD pool not found");
        V3PoolPriceSource yieldPriceSource =
            new V3PoolPriceSource(yieldPool, YIELD_TOKEN, PYUSD0, AAVE_ORACLE);

        FCMVault vault = _deployVault(w, yieldPriceSource, allowlistContract);

        deployments.push(Deployment({name: "Allowlist",         addr: address(allowlistContract)}));
        deployments.push(Deployment({name: "V3PoolPriceSource", addr: address(yieldPriceSource)}));
        deployments.push(Deployment({name: "FCMVault",          addr: address(vault)}));
    }

    function _loadMorphoStack() internal view returns (Wired memory w) {
        string memory path = string.concat(
            vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"
        );
        require(vm.exists(path), "deployments json missing - run DeployMorpho first");
        string memory j = vm.readFile(path);
        w.morpho       = _findByName(j, "Morpho");
        w.irm          = _findByName(j, "FixedRateIrm");
        w.morphoOracle = _findByName(j, "MorphoOracle");
        w.wethSource   = _findByName(j, "WethPriceSource");
        w.pyusdSource  = _findByName(j, "Pyusd0PriceSource");
    }

    function _deployVault(Wired memory w, V3PoolPriceSource yieldPriceSource, Allowlist allowlistContract)
        internal
        returns (FCMVault)
    {
        MarketParams memory mp = MarketParams({
            loanToken: PYUSD0,
            collateralToken: WETH,
            oracle: w.morphoOracle,
            irm: w.irm,
            lltv: LLTV
        });
        return new FCMVault(FCMVault.InitParams({
            underlying:            IERC20(WETH),
            yieldAsset:            IERC20(YIELD_TOKEN),
            yieldDecimals:         IERC20Decimals(YIELD_TOKEN).decimals(),
            yieldOracle:           address(yieldPriceSource),
            collateralPriceOracle: w.wethSource,
            debtPriceOracle:       w.pyusdSource,
            morpho:                IMorpho(w.morpho),
            marketParams:          mp,
            allowlist:             IAllowlist(address(allowlistContract)),
            maxSwapSlippageBps:    MAX_SWAP_SLIPPAGE_BPS,
            hfLowerThreshold:      HF_LOWER_THRESHOLD,
            hfLowerTarget:         HF_LOWER_TARGET,
            hfUpperTarget:         HF_UPPER_TARGET,
            hfUpperThreshold:      HF_UPPER_THRESHOLD,
            name:                  "Leveraged WETH",
            symbol:                "lvWETH"
        }));
    }

    /// @dev Linear scan over the deployments JSON (flat address→name map) to
    ///      find the address whose value matches `target`. forge-std's JSON
    ///      helpers don't give a reverse lookup directly.
    function _findByName(string memory j, string memory target) internal view returns (address) {
        string[] memory keys = vm.parseJsonKeys(j, "$");
        bytes32 targetH = keccak256(bytes(target));
        for (uint256 i = 0; i < keys.length; i++) {
            string memory v = abi.decode(vm.parseJson(j, string.concat(".", keys[i])), (string));
            if (keccak256(bytes(v)) == targetH) {
                return _parseAddr(keys[i]);
            }
        }
        revert(string.concat("not found in deployments: ", target));
    }

    function _parseAddr(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42 && b[0] == "0" && b[1] == "x", "bad addr");
        uint160 r = 0;
        for (uint256 i = 2; i < 42; i++) {
            r <<= 4;
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) r |= uint160(c - 48);
            else if (c >= 97 && c <= 102) r |= uint160(c - 87);
            else if (c >= 65 && c <= 70) r |= uint160(c - 55);
            else revert("bad hex");
        }
        return address(r);
    }
}
