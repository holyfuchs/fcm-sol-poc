// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// NOTE: Don't import Morpho.sol — its `=0.8.19` pragma conflicts with OZ V5's
// `^0.8.20+`. We deploy Morpho via `vm.deployCode` (from the pre-built
// artifact, which forge compiles in its own unit) and use the IMorpho
// interface for all calls.
import {IMorpho, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

import {FCMVault, IAllowlist} from "../contracts/FCMVault.sol";
import {Allowlist} from "../contracts/Allowlist.sol";
import {MockPriceSource} from "../contracts/mocks/MockPriceSource.sol";
import {V3PoolPriceSource} from "../contracts/mocks/V3PoolPriceSource.sol";
import {FixedRateIrm} from "../contracts/morpho/FixedRateIrm.sol";
import {SimpleOracle} from "../contracts/morpho/SimpleOracle.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IUniV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IAaveOracleMin {
    function getAssetPrice(address asset) external view returns (uint256);
}

contract MorphoDepositTest is Test {

    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD0       = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant YIELD_TOKEN  = 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D;
    address constant AAVE_ORACLE  = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;
    address constant SWAP_FACTORY = 0xca6d7Bb03334bBf135902e1d919a5feccb461632;
    uint24  constant FEE_YIELD_DEBT = 100;

    FCMVault internal vault;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org");

        // Live oracle prices to seed the mocks.
        uint256 pColl = IAaveOracleMin(AAVE_ORACLE).getAssetPrice(WETH);
        uint256 pDebt = IAaveOracleMin(AAVE_ORACLE).getAssetPrice(PYUSD0);

        MockPriceSource wethSrc  = new MockPriceSource(int256(pColl));
        MockPriceSource pyusdSrc = new MockPriceSource(int256(pDebt));

        // Morpho stack — deploy Morpho via vm.deployCode so we don't import
        // the pragma-incompatible source.
        IMorpho morpho = IMorpho(deployCode(
            "lib/morpho-blue/src/Morpho.sol:Morpho",
            abi.encode(address(this))
        ));
        FixedRateIrm irm = new FixedRateIrm(1585489599); // 5% APR
        SimpleOracle morphoOracle = new SimpleOracle(address(wethSrc), address(pyusdSrc), 6, 18);
        morpho.enableIrm(address(irm));
        morpho.enableLltv(0.86e18);

        MarketParams memory mp = MarketParams({
            loanToken: PYUSD0,
            collateralToken: WETH,
            oracle: address(morphoOracle),
            irm: address(irm),
            lltv: 0.86e18
        });
        morpho.createMarket(mp);

        // Yield oracle from live FlowSwap pool.
        address yieldPool = IUniV3Factory(SWAP_FACTORY).getPool(PYUSD0, YIELD_TOKEN, FEE_YIELD_DEBT);
        require(yieldPool != address(0), "no yield pool");
        V3PoolPriceSource yieldOracle =
            new V3PoolPriceSource(yieldPool, YIELD_TOKEN, PYUSD0, AAVE_ORACLE);

        // Seed Morpho with PYUSD0 liquidity so the vault has something to borrow.
        deal(PYUSD0, address(this), 1_000_000e6);
        IERC20(PYUSD0).approve(address(morpho), type(uint256).max);
        morpho.supply(mp, 1_000_000e6, 0, address(this), "");

        Allowlist allowlist = new Allowlist();
        allowlist.set(alice, true);

        uint8 yieldDecimals = IERC20Decimals(YIELD_TOKEN).decimals();
        vault = new FCMVault(FCMVault.InitParams({
            underlying:            IERC20(WETH),
            yieldAsset:            IERC20(YIELD_TOKEN),
            yieldDecimals:         yieldDecimals,
            yieldOracle:           address(yieldOracle),
            collateralPriceOracle: address(wethSrc),
            debtPriceOracle:       address(pyusdSrc),
            morpho:                morpho,
            marketParams:          mp,
            allowlist:             IAllowlist(address(allowlist)),
            maxSwapSlippageBps:    3000,
            hfLowerThreshold:      1.10e18,
            hfLowerTarget:         1.15e18,
            hfUpperTarget:         1.45e18,
            hfUpperThreshold:      1.50e18,
            name:                  "Leveraged WETH",
            symbol:                "lvWETH"
        }));

        deal(WETH, alice, 1 ether);
    }

    function test_deposit() public {
        uint256 deposited = 0.1 ether;
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposited);
        uint256 shares = vault.deposit(deposited, alice);
        vm.stopPrank();

        console.log("shares minted:    ", shares);
        console.log("total assets:     ", vault.totalAssets());
        console.log("collateral:       ", vault.collateral());
        console.log("debt (PYUSD0):    ", vault.debt());
        console.log("yield bal:        ", IERC20(YIELD_TOKEN).balanceOf(address(vault)));
        console.log("HF (1e18):        ", vault.healthFactor());

        assertGt(shares, 0, "no shares minted");
        assertApproxEqRel(vault.totalAssets(), deposited, 0.05e18, "NAV approx deposit");
    }

    function test_depositRedeem() public {
        uint256 deposited = 0.1 ether;
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposited);
        uint256 shares = vault.deposit(deposited, alice);
        uint256 redeemed = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        console.log("deposited:        ", deposited);
        console.log("redeemed:         ", redeemed);
        console.log("post-redeem collat:", vault.collateral());
        console.log("post-redeem debt: ", vault.debt());

        assertGt(redeemed, 0, "nothing redeemed");
        assertApproxEqRel(redeemed, deposited, 0.05e18, "redeem returns approx deposit");
    }
}
