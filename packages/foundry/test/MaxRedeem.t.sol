// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-core/contracts/interfaces/IPool.sol";
import {FCMVault} from "../contracts/FCMVault.sol";
import {MockYieldToken} from "../contracts/mocks/MockYieldToken.sol";
import {V3PoolHelper, IUniswapV3Factory} from "../contracts/mocks/V3PoolHelper.sol";

contract MaxRedeemDebug is Test {
    address constant WETH         = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD        = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant AAVE_POOL    = 0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d;
    address constant AAVE_ORACLE  = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;
    address constant PUNCH_FACTORY = 0xf331959366032a634c7cAcF5852fE01ffdB84Af0;
    uint24 constant POOL_FEE = 3000;

    FCMVault internal vault;
    MockYieldToken internal yield_;
    V3PoolHelper internal poolHelper;

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org", 64068000);

        yield_ = new MockYieldToken("Mock Yield", "mYLD", 18);
        poolHelper = new V3PoolHelper(IUniswapV3Factory(PUNCH_FACTORY));

        // Mock yield-token oracle price at $1 — matches our pool seed.
        vm.mockCall(
            AAVE_ORACLE,
            abi.encodeWithSignature("getAssetPrice(address)", address(yield_)),
            abi.encode(uint256(1e8))
        );

        // 1:1 PYUSD↔mYLD pool, plus the WETH↔PYUSD route pool.
        _seedYieldPool(1_000_000e6, 1_000_000e18);
        _seedWethPool(234_400e6, 100e18);

        vault = new FCMVault(IERC20(WETH), IERC20(address(yield_)), 18, "lvWETH", "lvWETH");

        deal(WETH, alice, 1 ether);
    }

    function test_maxRedeem() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 shares = vault.deposit(0.1 ether, alice);
        console.log("shares minted:", shares);

        (,,,,, uint256 hfBefore) = IPool(AAVE_POOL).getUserAccountData(address(vault));
        console.log("HF before redeem:", hfBefore);

        uint256 out = vault.redeem(shares, alice, alice);
        console.log("redeemed:", out);
        vm.stopPrank();
    }

    function _seedYieldPool(uint256 pyusdAmount, uint256 yieldAmount) internal {
        deal(PYUSD, address(this), (pyusdAmount * 105) / 100);
        yield_.mint(address(this), (yieldAmount * 105) / 100);
        IERC20(PYUSD).approve(address(poolHelper), type(uint256).max);
        IERC20(address(yield_)).approve(address(poolHelper), type(uint256).max);
        poolHelper.createAndFundPool(PYUSD, address(yield_), POOL_FEE, pyusdAmount, yieldAmount);
    }

    function _seedWethPool(uint256 pyusdAmount, uint256 wethAmount) internal {
        deal(PYUSD, address(this), IERC20(PYUSD).balanceOf(address(this)) + (pyusdAmount * 105) / 100);
        deal(WETH, address(this), IERC20(WETH).balanceOf(address(this)) + (wethAmount * 105) / 100);
        IERC20(PYUSD).approve(address(poolHelper), type(uint256).max);
        IERC20(WETH).approve(address(poolHelper), type(uint256).max);
        poolHelper.createAndFundPool(PYUSD, WETH, POOL_FEE, pyusdAmount, wethAmount);
    }
}
