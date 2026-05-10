// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {FCMVault} from "../contracts/FCMVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-core/contracts/interfaces/IPool.sol";

/// @notice Forks Flow mainnet and exercises the same supply→borrow→swap
///         pipeline as `FCM-sol/test/Rebalancer.t.sol`, but driven by an
///         ERC-4626 deposit instead of a curator-driven rebalance.
contract FCMVaultForkTest is Test {
    address constant WETH       = 0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590;
    address constant PYUSD      = 0x99aF3EeA856556646C98c8B9b2548Fe815240750;
    address constant AAVE_POOL  = 0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d;
    /// Yield leg: WFLOW. Strategy = leveraged long FLOW, funded by PYUSD debt
    /// against WETH collateral. WFLOW is oracle-priced via the MORE OracleRegistry.
    address constant YIELD      = 0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e; // WFLOW
    uint8   constant YIELD_DEC  = 18;

    FCMVault internal vault;
    address internal aWETH;
    address internal pyusdVariableDebt;

    address internal alice = makeAddr("alice");
    address internal bob   = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("https://mainnet.evm.nodes.onflow.org", 64068000);

        vault = new FCMVault(
            IERC20(WETH),
            IERC20(YIELD),
            YIELD_DEC,
            "Leveraged WETH",
            "lvWETH"
        );
        console.log("vault:", address(vault));

        // Aave reserve receipt tokens.
        DataTypesLike.ReserveData memory weth = _reserve(WETH);
        DataTypesLike.ReserveData memory pyusd = _reserve(PYUSD);
        aWETH = weth.aTokenAddress;
        pyusdVariableDebt = pyusd.variableDebtTokenAddress;

        deal(WETH, alice, 1 ether);
        deal(WETH, bob,   1 ether);
    }

    /// First deposit triggers the lev-up loop. Vault should end up at
    /// HF ≈ HF_UPPER_TARGET (1.30e18) with a non-zero debt position
    /// and the borrowed PYUSD swapped back into WETH.
    function test_deposit_levsUpToUpperTarget() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 sharesMinted = vault.deposit(0.1 ether, alice);
        vm.stopPrank();

        uint256 freeWeth   = IERC20(WETH).balanceOf(address(vault));
        uint256 aWethBal   = IERC20(aWETH).balanceOf(address(vault));
        uint256 vDebtBal   = IERC20(pyusdVariableDebt).balanceOf(address(vault));
        uint256 pyusdBal   = IERC20(PYUSD).balanceOf(address(vault));
        uint256 yieldBal   = IERC20(YIELD).balanceOf(address(vault));
        (, , , , , uint256 hf) = IPool(AAVE_POOL).getUserAccountData(address(vault));

        console.log("shares minted:", sharesMinted);
        console.log("free WETH:    ", freeWeth);
        console.log("aWETH:        ", aWethBal);
        console.log("PYUSD debt:   ", vDebtBal);
        console.log("PYUSD bal:    ", pyusdBal);
        console.log("yield (WFLOW):", yieldBal);
        console.log("HF (1e18):    ", hf);

        assertGt(aWethBal, 0, "supplied WETH as collateral");
        assertGt(vDebtBal, 0, "borrowed PYUSD recorded as debt");
        assertEq(pyusdBal, 0, "borrowed PYUSD got swapped away");
        assertEq(freeWeth, 0, "no free WETH left in vault");
        assertGt(yieldBal, 0, "swap landed in yield asset (WFLOW)");

        // Band: HF should snap to ~UPPER_TARGET. Tolerance for the
        // discrete share/borrow math.
        assertApproxEqRel(hf, vault.HF_UPPER_TARGET(), 0.001e18, "HF at upper target");
    }

    /// `totalAssets()` accounting: after the lev-up the underlying-equivalent
    /// NAV should be very close to the deposit (some swap slippage / pool
    /// fees expected). Crucially: shares × (totalAssets/totalSupply) ≈ deposit.
    function test_totalAssets_tracksLevPositionFairly() public {
        uint256 deposited = 0.1 ether;

        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), deposited);
        vault.deposit(deposited, alice);
        vm.stopPrank();

        uint256 ta = vault.totalAssets();
        console.log("totalAssets after lev-up:", ta);
        // Within ~6% of the deposit. PYUSD↔WFLOW liquidity on Flow EVM is thin; the
        // round-trip swap on lev-up costs ~5% in practice. Tighten this once a deeper
        // pool / multi-hop route is wired up.
        assertApproxEqRel(ta, deposited, 0.06e18, "NAV ~= deposit after lev-up");
    }

    /// Each depositor pays for their own lev-up slippage. Bob deposits
    /// after alice — his swap pushes the pool further, so he gets
    /// **fewer** shares than alice for the same WETH input. Critically,
    /// alice's per-share NAV is *not* diluted by bob's swap fees: she
    /// doesn't pay for bob's costs.
    function test_eachDepositorPaysOwnSlippage() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 aShares = vault.deposit(0.1 ether, alice);
        vm.stopPrank();

        // Snapshot alice's NAV claim before bob arrives.
        uint256 navPerShareBeforeBob =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        vm.startPrank(bob);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 bShares = vault.deposit(0.1 ether, bob);
        vm.stopPrank();

        uint256 navPerShareAfterBob =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        console.log("alice shares:", aShares);
        console.log("bob shares:  ", bShares);
        console.log("nav/share before bob:", navPerShareBeforeBob);
        console.log("nav/share after  bob:", navPerShareAfterBob);

        // Bob got fewer shares — he paid his own swap fees.
        assertLt(bShares, aShares, "bob pays own slippage = fewer shares");

        // Alice's NAV/share is essentially unchanged — she didn't pay
        // for bob's swap costs.
        assertApproxEqRel(
            navPerShareAfterBob,
            navPerShareBeforeBob,
            0.001e18,
            "alice's NAV/share ~unchanged by bob's deposit"
        );
    }

    /// Proportional redeem: alice deposits, redeems half her shares.
    /// Vault delivers her ~half of her contributed NAV, *less her own
    /// proportional swap cost* on the unwind. Other holders untouched
    /// (none in this test, but the invariant — totalAssets per remaining
    /// share unchanged — must hold).
    function test_redeem_proportionalUnwind() public {
        vm.startPrank(alice);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        uint256 aShares = vault.deposit(0.1 ether, alice);
        vm.stopPrank();

        uint256 navPerShareBefore =
            (vault.totalAssets() * 1e18) / vault.totalSupply();
        uint256 contributedNAV = vault.totalAssets();

        // Add bob as a stayer so we can verify alice's redeem doesn't
        // dilute him.
        vm.startPrank(bob);
        IERC20(WETH).approve(address(vault), 0.1 ether);
        vault.deposit(0.1 ether, bob);
        vm.stopPrank();
        uint256 bobNAVBefore =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        // Alice redeems half her shares.
        uint256 redeemShares = aShares / 2;
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(redeemShares, alice, alice);

        uint256 navPerShareAfter =
            (vault.totalAssets() * 1e18) / vault.totalSupply();

        console.log("alice contributedNAV:", contributedNAV);
        console.log("alice redeemed (out):", aliceOut);
        console.log("nav/share pre-redeem (with bob): ", bobNAVBefore);
        console.log("nav/share post-redeem:           ", navPerShareAfter);
        console.log("nav/share at alice deposit:      ", navPerShareBefore);

        assertGt(aliceOut, 0, "alice received underlying");

        // Approximate fairness check: alice should walk out with roughly half her
        // contributedNAV. The actual amount can differ noticeably (in either
        // direction) because (a) the unwind swap executes at PunchSwap price while
        // NAV is oracle-priced, and (b) when bob deposits he pushes the PYUSD↔WFLOW
        // pool further out of balance, so alice's WFLOW slice unwinds into more
        // PYUSD than oracle says. On a deeper pool / multi-hop route this would
        // tighten back toward 1-2%.
        assertApproxEqRel(aliceOut, contributedNAV / 2, 0.25e18, "alice ~ half contribution");

        // Load-bearing invariant: bob's per-share NAV is unaffected by
        // alice's redemption. Slippage is *not* socialized onto stayers.
        assertApproxEqRel(
            navPerShareAfter,
            bobNAVBefore,
            0.001e18,
            "stayer's NAV/share unchanged by other's redeem"
        );
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    function _reserve(address token)
        internal
        view
        returns (DataTypesLike.ReserveData memory)
    {
        // Aave V3's `getReserveData` returns a packed struct; we mirror
        // its layout via DataTypesLike to avoid pulling in the full
        // protocol-v3 lib.
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
