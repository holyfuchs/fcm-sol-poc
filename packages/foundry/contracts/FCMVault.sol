// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "@aave-v3-core/contracts/interfaces/IPool.sol";
import {IAaveOracle} from "@aave-v3-core/contracts/interfaces/IAaveOracle.sol";
import {DataTypes} from "@aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {ISwapRouter} from "./ISwapRouter.sol";

/// @title FCMVault
/// @notice ERC-4626 vault that operates a three-leg leveraged position:
///         1. Collateral leg: the underlying supplied to Aave V3 (held as aToken).
///         2. Debt leg: the borrow asset borrowed against that collateral.
///         3. Yield leg: a separate yield-bearing token bought with the borrowed debt.
///
///         NAV (denominated in the underlying) =
///             aToken balance
///           + free underlying balance
///           + yield-token balance priced in underlying
///           - debt balance priced in underlying.
contract FCMVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    event Rebalanced(uint256 navBefore, uint256 navAfter, uint256 hfAfter);

    /// @notice Emitted by `exit`: the redeemer pays the debt slice in kind and receives
    ///         their collateral and yield slices in kind, with no swaps.
    event Exit(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 shares,
        uint256 collOut,
        uint256 yieldOut,
        uint256 debtIn
    );

    // ---- Hardcoded mainnet config ---------------------------------------

    address public constant AAVE_POOL = 0xbC92aaC2DBBF42215248B5688eB3D3d2b32F2c8d;
    address public constant AAVE_ORACLE = 0x7287f12c268d7Dff22AAa5c2AA242D7640041cB1;

    address public constant BORROW_ASSET = 0x99aF3EeA856556646C98c8B9b2548Fe815240750; // PYUSD
    uint8   public constant BORROW_DECIMALS = 6;

    /// Vault's underlying (WETH) is assumed to be 18-decimal.
    uint8   public constant COLLATERAL_DECIMALS = 18;

    uint256 public constant INTEREST_RATE_MODE_VARIABLE = 2;

    address public constant SWAP_ROUTER = 0xe10Bd46E8c46d208fDE88B151452f50c2e5bDb07; // PunchSwap V3
    uint24  public constant POOL_FEE = 3000;

    uint256 internal constant BPS_DENOM = 10_000;

    /// Health-factor band. Outside [LOWER_THRESHOLD, UPPER_THRESHOLD] `rebalance()` pulls
    /// the position back to the matching TARGET.
    uint256 public constant HF_LOWER_THRESHOLD = 1.10e18;
    uint256 public constant HF_LOWER_TARGET    = 1.15e18;
    uint256 public constant HF_UPPER_TARGET    = 1.45e18;
    uint256 public constant HF_UPPER_THRESHOLD = 1.50e18;

    /// Per-swap slippage budget (vs. oracle).
    uint256 public constant MAX_SWAP_SLIPPAGE_BPS = 3000; // 30%

    /// Whole-rebalance NAV-loss budget.
    uint256 public constant MAX_REBALANCE_SLIPPAGE_BPS = 50; // 0.5%

    /// Hard cap on vault NAV (denominated in the underlying). `deposit` reverts when
    /// the post-deposit NAV would exceed this. Sized for the depth of the swap routes
    /// the vault uses; raise as the underlying liquidity grows.
    uint256 public constant MAX_TVL = 100e18; // 100 units of underlying

    /// ERC-4626 inflation-attack mitigation: virtual `10**6` shares + 1 virtual asset are
    /// added to all share<>asset conversions so a malicious first-depositor cannot inflate
    /// the share price by donating to the contract.
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// Cached at construction time from Aave's reserve config.
    address public immutable aToken;
    address public immutable variableDebtToken;

    /// The yield-bearing token bought with borrowed debt.
    IERC20 public immutable yieldAsset;
    uint8  public immutable yieldDecimals;

    /// @param underlying_     Collateral / vault asset.
    /// @param yieldAsset_     The yield-bearing token bought with borrowed debt.
    /// @param yieldDecimals_  Decimals of the yield token.
    constructor(
        IERC20 underlying_,
        IERC20 yieldAsset_,
        uint8 yieldDecimals_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC4626(underlying_)
    {
        DataTypes.ReserveData memory collatData =
            IPool(AAVE_POOL).getReserveData(address(underlying_));
        DataTypes.ReserveData memory borrowData =
            IPool(AAVE_POOL).getReserveData(BORROW_ASSET);
        aToken = collatData.aTokenAddress;
        variableDebtToken = borrowData.variableDebtTokenAddress;

        yieldAsset = yieldAsset_;
        yieldDecimals = yieldDecimals_;

        // Pre-approve the protocols this vault interacts with.
        underlying_.forceApprove(AAVE_POOL, type(uint256).max);
        IERC20(BORROW_ASSET).forceApprove(AAVE_POOL, type(uint256).max);
        IERC20(BORROW_ASSET).forceApprove(SWAP_ROUTER, type(uint256).max);
        underlying_.forceApprove(SWAP_ROUTER, type(uint256).max);
        yieldAsset_.forceApprove(SWAP_ROUTER, type(uint256).max);
    }

    /// @inheritdoc ERC4626
    /// @dev Adds virtual shares (10**DECIMALS_OFFSET) for inflation-attack resistance.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @notice Total share claims on the vault: real `totalSupply()` plus the virtual
    ///         shares contributed by `_decimalsOffset()` for inflation-attack resistance.
    /// @dev Use this (not raw `totalSupply()`) as the denominator in any share<>asset
    ///      conversion or pro-rata slice computation, so the virtual shares always own
    ///      their slice and the vault stays solvent.
    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    /// @notice Net asset value of the vault, denominated in the underlying.
    function totalAssets() public view override returns (uint256) {
        uint256 collat = IERC20(aToken).balanceOf(address(this));
        uint256 yieldInColl = _yieldToCollateral(yieldAsset.balanceOf(address(this)));
        uint256 debtInColl = _debtToCollateral(IERC20(variableDebtToken).balanceOf(address(this)));
        uint256 gross = collat + yieldInColl;
        if (gross > debtInColl) {
            return gross - debtInColl;
        }
        return 0;
    }

    /// @notice Disabled: shares minted by `deposit` depend on the realised swap
    ///         slippage when the borrowed debt is swapped into the yield asset, which
    ///         a view function can't observe. A correct preview would require
    ///         simulating the on-chain swap.
    function previewDeposit(uint256 /*assets*/) public pure override returns (uint256) {
        revert("not implemented");
    }

    /// @notice Deposit `assets` of underlying and lever the position up to `HF_UPPER_TARGET`.
    /// @dev Flow:
    ///   1. Pull collateral (now sits in free balance).
    ///   2. Snapshot NAV-before by subtracting the just-pulled assets from `totalAssets()`.
    ///   3. Supply collateral to Aave.
    ///   4. Borrow debt up to HF_UPPER_TARGET against the now-larger collateral pool.
    ///   5. Swap debt → yield asset.
    ///   6. Mint shares pro-rata to the depositor's NAV contribution. The depositor takes
    ///      their own swap-slippage hit on the share count.
    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        require(totalAssets() + assets <= MAX_TVL, "tvl cap exceeded");

        // Snapshot NAV-before with free underlying = 0 (invariant: the vault
        // never holds the underlying outside Aave between external calls).
        uint256 navBefore = totalAssets();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        IPool(AAVE_POOL).supply(asset(), assets, address(this), 0);
        _leverNewCollateral(assets);
        _swapDebtToYield();

        uint256 navAfter = totalAssets();
        uint256 contributed = navAfter - navBefore;
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Disabled: shares are entered exclusively via `deposit`.
    function previewMint(uint256 /*shares*/) public pure override returns (uint256) {
        revert("use deposit");
    }

    /// @notice Disabled: shares are entered exclusively via `deposit`.
    function mint(uint256 /*shares*/, address /*receiver*/)
        public
        pure
        override
        returns (uint256)
    {
        revert("use deposit");
    }

    function maxMint(address /*receiver*/) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Disabled: actual underlying paid by `redeem` depends on realised swap
    ///         slippage in the unwind, which a view function can't observe.
    function previewRedeem(uint256 /*shares*/) public pure override returns (uint256) {
        revert("not implemented");
    }

    /// @notice Burn `shares` and pay the redeemer their NAV-pro-rata share.
    /// @dev Uses an Aave flash loan of `debtSlice` so the unwind can run in this clean
    ///      order without HF concerns:
    ///        (1) flashloan `debtSlice` debt tokens,
    ///        (2) repay our debt position by `debtSlice` (HF rises),
    ///        (3) withdraw `collSlice` from Aave (now safe),
    ///        (4) sell `yieldSlice` for debt tokens,
    ///        (5) reconcile flashloan repayment (`debtSlice + premium`) — surplus debt
    ///            tokens get swapped to underlying as a bonus for the redeemer; deficit
    ///            is covered by spending the redeemer's underlying.
    ///      Steps (2)–(5) happen inside `executeOperation()`. After the flashloan
    ///      returns control here, the redeemer's payout sits in the vault's free
    ///      underlying balance (which is otherwise zero).
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        returns (uint256 assets)
    {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 totalClaims = _totalClaims();
        uint256 collSlice  = IERC20(aToken).balanceOf(address(this))
            .mulDiv(shares, totalClaims);
        uint256 yieldSlice = yieldAsset.balanceOf(address(this))
            .mulDiv(shares, totalClaims);
        // Round debt slice UP so a 100%-redeem fully clears the on-Aave debt
        // (flooring leaves 1 wei of debt against 0 wei of post-withdraw scaled
        // collateral, which trips Aave's HF check with error 35).
        uint256 debtSlice  = IERC20(variableDebtToken).balanceOf(address(this))
            .mulDiv(shares, totalClaims, Math.Rounding.Ceil);

        // No debt to repay (e.g. position was fully liquidated) → take the
        // simple path: no flashloan, no debt repay, just withdraw collat and
        // sell the yield slice for more collat.
        if (debtSlice == 0) {
            return simpleRedeem(shares, receiver, owner, collSlice, yieldSlice);
        }

        IPool(AAVE_POOL).flashLoanSimple(
            address(this),
            BORROW_ASSET,
            debtSlice,
            abi.encode(collSlice, yieldSlice),
            0
        );

        assets = IERC20(asset()).balanceOf(address(this));
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Debt-free redeem path. Withdraws `collSlice` from Aave and
    ///         swaps `yieldSlice` back into the underlying. No flashloan, no
    ///         debt repayment. Used when the vault's on-Aave debt is 0 (post
    ///         full-liquidation), where Aave's `flashLoanSimple(asset, 0)`
    ///         and `withdraw(asset, 0)` would both revert.
    /// @dev Internal — `redeem` dispatches here. Caller has already done the
    ///      allowance check and the share<>slice math.
    function simpleRedeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 collSlice,
        uint256 yieldSlice
    ) internal returns (uint256 assets) {
        if (collSlice > 0) {
            IPool(AAVE_POOL).withdraw(asset(), collSlice, address(this));
        }
        if (yieldSlice > 0) {
            uint256 debtReceived =
                _swapExactIn(address(yieldAsset), BORROW_ASSET, yieldSlice);
            if (debtReceived > 0) {
                _swapExactIn(BORROW_ASSET, asset(), debtReceived);
            }
        }

        assets = IERC20(asset()).balanceOf(address(this));
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Aave V3 flash-loan callback. Used by `redeem` to clear the redeemer's
    ///         debt slice up front so collateral can be withdrawn safely.
    /// @dev Aave pulls `amount + premium` of `flashAsset` from this contract after the
    ///      call returns; the constructor pre-approves `BORROW_ASSET` to the pool, so
    ///      no extra approval is needed here.
    function executeOperation(
        address flashAsset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == AAVE_POOL, "only pool");
        require(initiator == address(this), "only self-initiated");
        require(flashAsset == BORROW_ASSET, "wrong flash asset");

        (uint256 collSlice, uint256 yieldSlice) = abi.decode(params, (uint256, uint256));

        IPool(AAVE_POOL).repay(BORROW_ASSET, amount, INTEREST_RATE_MODE_VARIABLE, address(this));
        IPool(AAVE_POOL).withdraw(asset(), collSlice, address(this));
        uint256 debtReceived = _swapExactIn(address(yieldAsset), BORROW_ASSET, yieldSlice);

        // Reconcile: we owe `amount + premium`, we hold `debtReceived`.
        uint256 owed = amount + premium;
        if (debtReceived > owed) {
            uint256 surplus = debtReceived - owed;
            _swapExactIn(BORROW_ASSET, asset(), surplus);
        } else if (debtReceived < owed) {
            uint256 deficit = owed - debtReceived;
            _swapExactOut(asset(), BORROW_ASSET, deficit, IERC20(asset()).balanceOf(address(this)));
        }

        return true;
    }

    /// @notice In-kind exit: the caller pays the redeemer's pro-rata debt slice up front
    ///         (in the borrow asset), and in exchange receives their collateral slice
    ///         (in the underlying) and yield slice (in the yield token). No swaps.
    /// @dev Useful for sophisticated holders who already hold the borrow asset or want
    ///      to avoid AMM slippage. Caller must approve the vault to pull `debtIn` of
    ///      `BORROW_ASSET` before calling. Returns the realised in-kind amounts.
    /// @param shares    Shares to redeem (burned from `owner`, with allowance if `msg.sender != owner`).
    /// @param receiver  Recipient of the collateral and yield slices.
    /// @param owner     Account whose shares are burned.
    function exit(uint256 shares, address receiver, address owner)
        public
        returns (uint256 collOut, uint256 yieldOut, uint256 debtIn)
    {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 totalClaims = _totalClaims();
        collOut  = IERC20(aToken).balanceOf(address(this)).mulDiv(shares, totalClaims);
        yieldOut = yieldAsset.balanceOf(address(this)).mulDiv(shares, totalClaims);
        debtIn   = IERC20(variableDebtToken).balanceOf(address(this)).mulDiv(shares, totalClaims);

        // Pull the debt slice from the caller and clear it on our position. HF rises,
        // making the upcoming collateral withdrawal safe.
        IERC20(BORROW_ASSET).safeTransferFrom(msg.sender, address(this), debtIn);
        IPool(AAVE_POOL).repay(BORROW_ASSET, debtIn, INTEREST_RATE_MODE_VARIABLE, address(this));

        IPool(AAVE_POOL).withdraw(asset(), collOut, address(this));
        IERC20(asset()).safeTransfer(receiver, collOut);

        yieldAsset.safeTransfer(receiver, yieldOut);

        _burn(owner, shares);

        emit Exit(msg.sender, receiver, owner, shares, collOut, yieldOut, debtIn);
    }

    /// @notice Disabled: actual shares burned by `withdraw` depend on the realised
    ///         swap slippage in the unwind path, which a view function can't observe.
    function previewWithdraw(uint256 /*assets*/) public pure override returns (uint256) {
        revert("not implemented");
    }

    /// @notice Withdraw exactly `assets` of underlying. Burns whatever number of shares
    ///         is required to keep stayers' NAV-per-share invariant given the realised
    ///         unwind cost.
    /// @dev Compute the pro-rata debt that has to be cleared to release `assets` of
    ///      collateral, sell just enough yield to cover it, repay, withdraw the
    ///      collateral, then burn shares proportional to the actual NAV decrease.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        returns (uint256 shares)
    {
        uint256 navBefore = totalAssets();

        // Pro-rata debt repayment needed to free up `assets` of collateral.
        uint256 debtToRepay = IERC20(variableDebtToken).balanceOf(address(this))
            .mulDiv(assets, navBefore);

        // Sell exactly enough yield for that debt, then repay.
        if (debtToRepay > 0) {
            _swapExactOut(address(yieldAsset), BORROW_ASSET, debtToRepay, yieldAsset.balanceOf(address(this)));
            IPool(AAVE_POOL).repay(BORROW_ASSET, debtToRepay, INTEREST_RATE_MODE_VARIABLE, address(this));
        }

        // Pull the requested collateral out of Aave.
        IPool(AAVE_POOL).withdraw(asset(), assets, address(this));

        // Burn shares proportional to the actual NAV delta (the yield-sale slippage
        // is reflected here, so the stayers' NAV-per-share is preserved).
        uint256 navAfter = totalAssets() - assets;
        shares = _totalClaims().mulDiv(navBefore - navAfter, navBefore, Math.Rounding.Ceil);

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @notice Pull the vault's HF back into [LOWER_THRESHOLD, UPPER_THRESHOLD] by levering
    ///         up (HF too high) or deleveraging (HF too low).
    /// @dev Intentionally permissionless: anyone may call this. Manipulation is bounded by
    ///      the per-swap and whole-rebalance slippage checks against the Aave oracle. A
    ///      caller who tries to grief the vault by sandwiching the swap will trip
    ///      `MAX_SWAP_SLIPPAGE_BPS` and revert; if they only nudge prices within budget,
    ///      they cost the vault at most `MAX_REBALANCE_SLIPPAGE_BPS` of NAV per call.
    function rebalance() public {
        uint256 navBefore = totalAssets();
        (,,,,, uint256 hf) = IPool(AAVE_POOL).getUserAccountData(address(this));

        if (hf > HF_UPPER_THRESHOLD) {
            // Under-levered: borrow more debt, swap into yield asset.
            uint256 toBorrow = _debtDeltaToReachHF(HF_UPPER_TARGET);
            IPool(AAVE_POOL).borrow(BORROW_ASSET, toBorrow, INTEREST_RATE_MODE_VARIABLE, 0, address(this));
            uint256 expected = _debtToYield(toBorrow);
            uint256 minOut = expected.mulDiv(BPS_DENOM - MAX_SWAP_SLIPPAGE_BPS, BPS_DENOM);
            uint256 received = _swapExactIn(BORROW_ASSET, address(yieldAsset), toBorrow);
            require(received >= minOut, "rebalance swap slippage");
        } else if (hf < HF_LOWER_THRESHOLD) {
            // Over-levered: sell yield asset for debt, repay debt.
            uint256 toRepay = _debtDeltaToReachHF(HF_LOWER_TARGET);
            uint256 expected = _debtToYield(toRepay);
            uint256 maxIn = expected.mulDiv(BPS_DENOM + MAX_SWAP_SLIPPAGE_BPS, BPS_DENOM);
            _swapExactOut(address(yieldAsset), BORROW_ASSET, toRepay, maxIn);
            IPool(AAVE_POOL).repay(BORROW_ASSET, toRepay, INTEREST_RATE_MODE_VARIABLE, address(this));
        }

        uint256 navAfter = totalAssets();
        require(
            navAfter >= navBefore.mulDiv(BPS_DENOM - MAX_REBALANCE_SLIPPAGE_BPS, BPS_DENOM),
            "rebalance NAV slippage"
        );

        (,,,,, uint256 hfAfter) = IPool(AAVE_POOL).getUserAccountData(address(this));
        emit Rebalanced(navBefore, navAfter, hfAfter);
    }

    // =============================================================
    //                       INTERNAL HELPERS
    // =============================================================

    /// @dev Convert a debt-asset amount into its equivalent value in underlying.
    ///      Aave oracle prices are in the protocol's base currency (8 decimals).
    function _debtToCollateral(uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) {
            return 0;
        }
        uint256 pDebt = IAaveOracle(AAVE_ORACLE).getAssetPrice(BORROW_ASSET);
        uint256 pColl = IAaveOracle(AAVE_ORACLE).getAssetPrice(asset());
        return debtAmount.mulDiv(pDebt * (10 ** (COLLATERAL_DECIMALS - BORROW_DECIMALS)), pColl);
    }

    /// @dev Convert a yield-token amount into its equivalent value in underlying.
    function _yieldToCollateral(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) {
            return 0;
        }
        uint256 pYield = IAaveOracle(AAVE_ORACLE).getAssetPrice(address(yieldAsset));
        uint256 pColl = IAaveOracle(AAVE_ORACLE).getAssetPrice(asset());
        // Rescale yield decimals → collateral decimals.
        if (yieldDecimals <= COLLATERAL_DECIMALS) {
            return yieldAmount.mulDiv(pYield * (10 ** (COLLATERAL_DECIMALS - yieldDecimals)), pColl);
        } else {
            return yieldAmount.mulDiv(pYield, pColl * (10 ** (yieldDecimals - COLLATERAL_DECIMALS)));
        }
    }

    /// @dev Convert a yield-token amount into its equivalent value in the debt asset.
    function _yieldToDebt(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) {
            return 0;
        }
        uint256 pYield = IAaveOracle(AAVE_ORACLE).getAssetPrice(address(yieldAsset));
        uint256 pDebt = IAaveOracle(AAVE_ORACLE).getAssetPrice(BORROW_ASSET);
        if (yieldDecimals <= BORROW_DECIMALS) {
            return yieldAmount.mulDiv(pYield * (10 ** (BORROW_DECIMALS - yieldDecimals)), pDebt);
        } else {
            return yieldAmount.mulDiv(pYield, pDebt * (10 ** (yieldDecimals - BORROW_DECIMALS)));
        }
    }

    /// @dev Convert a debt-asset amount into its equivalent value in yield token.
    function _debtToYield(uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) {
            return 0;
        }
        uint256 pDebt = IAaveOracle(AAVE_ORACLE).getAssetPrice(BORROW_ASSET);
        uint256 pYield = IAaveOracle(AAVE_ORACLE).getAssetPrice(address(yieldAsset));
        if (yieldDecimals >= BORROW_DECIMALS) {
            return debtAmount.mulDiv(pDebt * (10 ** (yieldDecimals - BORROW_DECIMALS)), pYield);
        } else {
            return debtAmount.mulDiv(pDebt, pYield * (10 ** (BORROW_DECIMALS - yieldDecimals)));
        }
    }

    /// @dev Borrow debt asset up to whatever brings overall HF to `targetHf`, but never
    ///      more than `maxBorrow`. No-op if already at-or-below target. Pass
    ///      `type(uint256).max` for `maxBorrow` to disable the cap.
    function _borrowToTargetHF(uint256 targetHf, uint256 maxBorrow) internal returns (uint256 borrowed) {
        (uint256 collatBase, uint256 debtBase,, uint256 ltBps,,) =
            IPool(AAVE_POOL).getUserAccountData(address(this));
        if (collatBase == 0) {
            return 0;
        }

        // HF = collatBase * LT / 10000 / debtBase  =>  targetDebtBase at HF = targetHf:
        uint256 targetDebtBase = collatBase.mulDiv(ltBps * 1e18, BPS_DENOM * targetHf);
        if (targetDebtBase <= debtBase) {
            return 0;
        }

        uint256 deltaBase = targetDebtBase - debtBase;
        uint256 pDebt = IAaveOracle(AAVE_ORACLE).getAssetPrice(BORROW_ASSET);
        borrowed = deltaBase.mulDiv(10 ** BORROW_DECIMALS, pDebt);
        if (borrowed > maxBorrow) {
            borrowed = maxBorrow;
        }
        if (borrowed > 0) {
            IPool(AAVE_POOL).borrow(BORROW_ASSET, borrowed, INTEREST_RATE_MODE_VARIABLE, 0, address(this));
        }
    }

    /// @dev Lever up only the depositor's freshly-supplied collateral: borrow against
    ///      it, capped at what their own collateral would warrant at HF_UPPER_TARGET.
    ///      Without the cap, a depositor arriving when the vault is under-levered would
    ///      pay (via swap slippage) for rebalancing the entire pre-existing position too.
    ///      Borrowed debt sits in the vault as a free balance; the caller is expected to
    ///      follow up with `_swapDebtToYield()` to convert it.
    function _leverNewCollateral(uint256 newCollateral) internal returns (uint256 borrowed) {
        uint256 maxBorrow = _maxBorrowOnNewCollateral(newCollateral, HF_UPPER_TARGET);
        borrowed = _borrowToTargetHF(HF_UPPER_TARGET, maxBorrow);
    }

    /// @dev Sweep the vault's entire borrow-asset balance into the yield asset.
    ///      No min-out: callers (deposit, rebalance lever-up branch) eat their own
    ///      slippage via the downstream NAV math.
    function _swapDebtToYield() internal returns (uint256 yieldReceived) {
        uint256 bal = IERC20(BORROW_ASSET).balanceOf(address(this));
        if (bal == 0) {
            return 0;
        }
        yieldReceived = _swapExactIn(BORROW_ASSET, address(yieldAsset), bal);
    }

    /// @dev Maximum debt that should be borrowed against `newCollateral` alone, sized
    ///      so that — if `newCollateral` were the only collateral in the position — HF
    ///      would land at `targetHf`. Used to cap the borrow on `deposit` so the new
    ///      depositor doesn't pay (via swap slippage) for rebalancing pre-existing
    ///      under-levered collateral.
    function _maxBorrowOnNewCollateral(uint256 newCollateral, uint256 targetHf)
        internal view returns (uint256)
    {
        if (newCollateral == 0) {
            return 0;
        }
        // Use the position's effective LT (from getUserAccountData) so the cap
        // matches whatever LT Aave would actually apply.
        (,,, uint256 ltBps,,) = IPool(AAVE_POOL).getUserAccountData(address(this));
        uint256 pColl = IAaveOracle(AAVE_ORACLE).getAssetPrice(asset());
        uint256 newCollBase = newCollateral.mulDiv(pColl, 10 ** COLLATERAL_DECIMALS);
        uint256 maxDebtBase = newCollBase.mulDiv(ltBps * 1e18, BPS_DENOM * targetHf);
        uint256 pDebt = IAaveOracle(AAVE_ORACLE).getAssetPrice(BORROW_ASSET);
        return maxDebtBase.mulDiv(10 ** BORROW_DECIMALS, pDebt);
    }

    /// @dev Absolute amount of debt needed to move HF to `targetHf`. Caller knows
    ///      the direction from the current HF.
    function _debtDeltaToReachHF(uint256 targetHf) internal view returns (uint256) {
        (uint256 collatBase, uint256 debtBase,, uint256 ltBps,,) =
            IPool(AAVE_POOL).getUserAccountData(address(this));
        uint256 targetDebtBase = collatBase.mulDiv(ltBps * 1e18, BPS_DENOM * targetHf);
        uint256 deltaBase = targetDebtBase > debtBase
            ? targetDebtBase - debtBase
            : debtBase - targetDebtBase;
        uint256 pDebt = IAaveOracle(AAVE_ORACLE).getAssetPrice(BORROW_ASSET);
        return deltaBase.mulDiv(10 ** BORROW_DECIMALS, pDebt);
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        return ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 amountInMax)
        internal
        returns (uint256 amountIn)
    {
        return ISwapRouter(SWAP_ROUTER).exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: POOL_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
