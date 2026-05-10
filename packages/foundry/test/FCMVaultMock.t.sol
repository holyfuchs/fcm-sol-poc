// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FCMVault} from "../contracts/FCMVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-core/contracts/interfaces/IPool.sol";
import {MockYieldToken} from "./mocks/MockYieldToken.sol";
import {V3PoolHelper, IUniswapV3Factory} from "./mocks/V3PoolHelper.sol";

/// @notice Tests the vault against real PunchSwap V3 pools deployed in the
///         fork. Each test creates its own yield token and pools, picks the
///         liquidity it wants to seed, and runs deposit/redeem against a
///         genuine V3 swap path. The Aave pool stays real; only the yield
///         asset's *oracle price* is mocked (it's a freshly-deployed token,
///         the real oracle has no entry for it).
contract FCMVaultRealPoolTest is Test {
    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD        = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant AAVE_POOL    = 0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d;
    address constant AAVE_ORACLE  = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;
    address constant PUNCH_FACTORY = 0xf331959366032a634c7cAcF5852fE01ffdB84Af0;

    uint24 constant POOL_FEE = 3000; // matches FCMVault.POOL_FEE

    FCMVault internal vault;
    MockYieldToken internal yield_;
    V3PoolHelper   internal poolHelper;
    address        internal aWETH;
    address        internal pyusdVariableDebt;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org", 64068000);

        // 1. Test-owned yield token + V3 helper.
        yield_ = new MockYieldToken("Mock Yield", "mYLD", 18);
        poolHelper = new V3PoolHelper(IUniswapV3Factory(PUNCH_FACTORY));

        // 2. Mock the Aave oracle for our freshly-deployed yield token.
        //    Pick 1 mYLD = 0.50 USD (oracle base unit is 1e8).
        vm.mockCall(
            AAVE_ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", address(yield_)),
            abi.encode(uint256(0.50e8))
        );

        // 3. Seed the two pools the vault will route through:
        //    PYUSD↔yield (the deposit-and-redeem leg) and PYUSD↔WETH
        //    (the surplus/deficit settlement leg of redeem).
        //    Pool prices are determined by the amount ratio (after address sort).
        //    PYUSD↔yield: 1 PYUSD = 2 yield  → 1M PYUSD : 2M yield
        //    PYUSD↔WETH:  1 WETH ≈ 2344 PYUSD → 234.4k PYUSD : 100 WETH
        _seedYieldPool(1_000_000e6, 2_000_000e18);
        _seedWethPool (234_400e6, 100e18);

        // 4. Deploy the vault.
        vault = new FCMVault(
            IERC20(WETH),
            IERC20(address(yield_)),
            18,
            "Leveraged WETH",
            "lvWETH"
        );

        // Aave reserve receipt tokens.
        DataTypesLike.ReserveData memory wethR  = _reserve(WETH);
        DataTypesLike.ReserveData memory pyusdR = _reserve(PYUSD);
        aWETH = wethR.aTokenAddress;
        pyusdVariableDebt = pyusdR.variableDebtTokenAddress;

        deal(WETH, alice, 1 ether);
        deal(WETH, bob,   1 ether);
    }

    // =============================================================
    //                            tests
    // =============================================================

    /// Deep, balanced pools → deposit-time swap is essentially frictionless
    /// and contributed NAV ≈ deposit.
    function test_deposit_deepPool() public {
        uint256 deposited = 0.1 ether;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposited);
        vault.deposit(deposited, alice);
        vm.stopPrank();

        uint256 ta = vault.totalAssets();
        console.log("totalAssets:", ta);
        console.log("yield bal:  ", yield_.balanceOf(address(vault)));
        console.log("PYUSD debt: ", IERC20(pyusdVariableDebt).balanceOf(address(vault)));

        assertApproxEqRel(ta, deposited, 0.005e18, "NAV ~= deposit");
    }

    /// Each depositor pays their own slippage. Bob deposits into a pool
    /// already pushed by alice — strictly fewer shares. Alice's NAV-per-share
    /// is unchanged.
    function test_eachDepositorPaysOwnSlippage() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 aShares = vault.deposit(0.1 ether, alice);
        vm.stopPrank();

        uint256 navPerShareAfterAlice =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        vm.startPrank(bob);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 bShares = vault.deposit(0.1 ether, bob);
        vm.stopPrank();

        uint256 navPerShareAfterBob =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        console.log("alice shares:         ", aShares);
        console.log("bob shares:           ", bShares);
        console.log("nav/share after alice:", navPerShareAfterAlice);
        console.log("nav/share after bob:  ", navPerShareAfterBob);

        assertLt(bShares, aShares, "bob pays own slippage = fewer shares");
        assertApproxEqRel(
            navPerShareAfterBob,
            navPerShareAfterAlice,
            0.001e18,
            "alice NAV/share unchanged by bob's deposit"
        );
    }

    /// Single depositor, redeem half. Walks out with ≈ half her contribution.
    function test_redeem_deepPool_halfContribution() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 aShares = vault.deposit(0.1 ether, alice);
        vm.stopPrank();

        uint256 contributedNAV = vault.totalAssets();

        vm.prank(alice);
        uint256 out = vault.redeem(aShares / 2, alice, alice);
        console.log("alice contributedNAV:", contributedNAV);
        console.log("alice redeemed (out):", out);

        assertApproxEqRel(out, contributedNAV / 2, 0.01e18, "alice ~ half contribution");
    }

    /// Stayer is not diluted by a redeemer's unwind.
    function test_redeem_doesNotDiluteStayer() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 aShares = vault.deposit(0.1 ether, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        vault.deposit(0.1 ether, bob);
        vm.stopPrank();

        uint256 navPerShareBefore =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        vm.prank(alice);
        vault.redeem(aShares / 2, alice, alice);

        uint256 navPerShareAfter =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        console.log("nav/share pre-redeem: ", navPerShareBefore);
        console.log("nav/share post-redeem:", navPerShareAfter);

        assertApproxEqRel(
            navPerShareAfter,
            navPerShareBefore,
            0.005e18,
            "stayer NAV/share unchanged by other's redeem"
        );
    }

    // =============================================================
    //                          helpers
    // =============================================================

    /// Create + fund the PYUSD ↔ yield pool on PunchSwap V3.
    /// Deals a 5% buffer above the indicative reserves to absorb any V3
    /// liquidity-rounding overhead on the actual mint amounts.
    function _seedYieldPool(uint256 pyusdAmount, uint256 yieldAmount) internal {
        deal(PYUSD, address(this), IERC20(PYUSD).balanceOf(address(this)) + (pyusdAmount * 105) / 100);
        yield_.mint(address(this), (yieldAmount * 105) / 100);
        IERC20(PYUSD).approve(address(poolHelper), type(uint256).max);
        IERC20(address(yield_)).approve(address(poolHelper), type(uint256).max);
        poolHelper.createAndFundPool(PYUSD, address(yield_), POOL_FEE, pyusdAmount, yieldAmount);
    }

    /// Create + fund the PYUSD ↔ WETH pool on PunchSwap V3.
    function _seedWethPool(uint256 pyusdAmount, uint256 wethAmount) internal {
        deal(PYUSD, address(this), IERC20(PYUSD).balanceOf(address(this)) + (pyusdAmount * 105) / 100);
        deal(WETH,  address(this), IERC20(WETH).balanceOf(address(this))  + (wethAmount  * 105) / 100);
        IERC20(PYUSD).approve(address(poolHelper), type(uint256).max);
        IERC20(WETH).approve(address(poolHelper), type(uint256).max);
        poolHelper.createAndFundPool(PYUSD, WETH, POOL_FEE, pyusdAmount, wethAmount);
    }

    function _reserve(address token)
        internal
        view
        returns (DataTypesLike.ReserveData memory)
    {
        (bool ok, bytes memory ret) = AAVE_POOL.staticcall(
            abi.encodeWithSignature("getReserveData(address)", token)
        );
        require(ok, "getReserveData failed");
        return abi.decode(ret, (DataTypesLike.ReserveData));
    }
}

library DataTypesLike {
    struct ReserveConfigurationMap {
        uint256 data;
    }
    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }
}
