// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, MarketParams, Id, Position, Market} from "@morpho-blue/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "@morpho-blue/interfaces/IMorphoCallbacks.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";

import {ISwapRouter} from "./ISwapRouter.sol";

interface IChainlinkAggregator {
    function latestAnswer() external view returns (int256);
}

interface IAllowlist {
    function isAllowed(address account) external view returns (bool);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    struct QuoteExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @title FCMVault
/// @notice ERC-4626 vault on Morpho Blue. Three-leg leveraged position:
///         1. Collateral leg: WETH supplied to a Morpho market.
///         2. Debt leg: PYUSD0 borrowed from that market.
///         3. Yield leg: ERC-4626 yield token bought with the borrowed PYUSD0.
contract FCMVault is ERC4626, IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    event Rebalanced(uint256 navBefore, uint256 navAfter, uint256 hfAfter);

    // ---- Hardcoded Flow EVM config -------------------------------------

    address public constant SWAP_ROUTER = 0xeEDC6Ff75e1b10B903D9013c358e446a73d35341; // FlowSwap V3 SwapRouter02
    address public constant QUOTER      = 0x370A8DF17742867a44e56223EC20D82092242C85; // FlowSwap V3 QuoterV2
    uint24  public constant FEE_YIELD_DEBT = 100;    // PYUSD0/YIELD pool
    uint24  public constant FEE_DEBT_COLL  = 3000;   // WETH/PYUSD0 pool

    uint8 public constant LOAN_DECIMALS = 6;
    uint8 public constant COLLATERAL_DECIMALS = 18;

    uint256 internal constant BPS_DENOM = 10_000;

    /// Health-factor band, all 1e18-scaled. Set at construction. `rebalance()`
    /// pulls the position back to the matching target when the current HF
    /// crosses a threshold.
    uint256 public immutable hfLowerThreshold;
    uint256 public immutable hfLowerTarget;
    uint256 public immutable hfUpperTarget;
    uint256 public immutable hfUpperThreshold;

    /// Per-swap price-impact budget during `rebalance()`, vs the oracle-derived
    ///       expected amount. Set at construction (immutable). 1e4-scaled bps.
    uint256 public immutable maxSwapSlippageBps;

    uint256 public constant MAX_REBALANCE_SLIPPAGE_BPS = 50;   // 0.5%
    // ---- Admin-settable parameters -------------------------------------

    /// @notice Admin EOA. Set to the deployer at construction. Can adjust
    ///         `maxTvl` and transfer ownership.
    address public owner;

    /// @notice TVL cap, denominated in the underlying (WETH). Deposits revert
    ///         if `totalAssets() + assets > maxTvl`. Default 0 → no deposits
    ///         until admin raises it.
    uint256 public maxTvl;

    event OwnerSet(address indexed previousOwner, address indexed newOwner);
    event MaxTvlSet(uint256 previousMaxTvl, uint256 newMaxTvl);

    error NotOwner();

    uint8 internal constant DECIMALS_OFFSET = 6;

    // ---- Morpho market config (immutable) ------------------------------

    IMorpho public immutable morpho;
    Id      public immutable marketId;
    address public immutable loanToken;
    address public immutable marketOracle;
    address public immutable marketIrm;
    uint256 public immutable marketLltv;

    // ---- Vault oracles (Chainlink-style, 1e8 base) ---------------------

    address public immutable collateralPriceOracle;
    address public immutable debtPriceOracle;
    address public immutable yieldOracle;

    /// External allowlist contract gating `deposit`. Anyone not in the
    /// allowlist gets reverted with `NotAllowed()`.
    IAllowlist public immutable allowlist;

    // ---- Yield leg -----------------------------------------------------

    IERC20 public immutable yieldAsset;
    uint8  public immutable yieldDecimals;

    error NotAllowed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Set the TVL cap. Default at deploy time is 0 (no deposits).
    function setMaxTvl(uint256 newMaxTvl) external onlyOwner {
        emit MaxTvlSet(maxTvl, newMaxTvl);
        maxTvl = newMaxTvl;
    }

    /// @notice Hand ownership to another address. Pass `address(0)` to renounce.
    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnerSet(owner, newOwner);
        owner = newOwner;
    }

    struct InitParams {
        IERC20 underlying;
        IERC20 yieldAsset;
        uint8 yieldDecimals;
        address yieldOracle;
        address collateralPriceOracle;
        address debtPriceOracle;
        IMorpho morpho;
        MarketParams marketParams;
        IAllowlist allowlist;
        uint256 maxSwapSlippageBps;
        uint256 hfLowerThreshold;
        uint256 hfLowerTarget;
        uint256 hfUpperTarget;
        uint256 hfUpperThreshold;
        string name;
        string symbol;
    }

    constructor(InitParams memory p)
        ERC20(p.name, p.symbol)
        ERC4626(p.underlying)
    {
        require(p.marketParams.collateralToken == address(p.underlying), "underlying != collateral");
        require(p.maxSwapSlippageBps <= BPS_DENOM, "slippage > 100%");
        require(
            p.hfLowerThreshold < p.hfLowerTarget
                && p.hfLowerTarget < p.hfUpperTarget
                && p.hfUpperTarget < p.hfUpperThreshold,
            "bad HF band"
        );
        maxSwapSlippageBps = p.maxSwapSlippageBps;
        hfLowerThreshold   = p.hfLowerThreshold;
        hfLowerTarget      = p.hfLowerTarget;
        hfUpperTarget      = p.hfUpperTarget;
        hfUpperThreshold   = p.hfUpperThreshold;

        morpho       = p.morpho;
        marketId     = p.marketParams.id();
        loanToken    = p.marketParams.loanToken;
        marketOracle = p.marketParams.oracle;
        marketIrm    = p.marketParams.irm;
        marketLltv   = p.marketParams.lltv;

        allowlist             = p.allowlist;
        owner                 = msg.sender;
        emit OwnerSet(address(0), msg.sender);
        // maxTvl defaults to 0 — admin must call setMaxTvl before any deposits.

        yieldAsset            = p.yieldAsset;
        yieldDecimals         = p.yieldDecimals;
        yieldOracle           = p.yieldOracle;
        collateralPriceOracle = p.collateralPriceOracle;
        debtPriceOracle       = p.debtPriceOracle;

        uint256 m = type(uint256).max;
        p.underlying.forceApprove(address(p.morpho), m);
        IERC20(loanToken).forceApprove(address(p.morpho), m);
        IERC20(loanToken).forceApprove(SWAP_ROUTER, m);
        p.underlying.forceApprove(SWAP_ROUTER, m);
        p.yieldAsset.forceApprove(SWAP_ROUTER, m);
    }

    // ======================== ERC4626 plumbing ========================

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function _totalClaims() internal view returns (uint256) {
        return totalSupply() + 10 ** _decimalsOffset();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 collat = _collateral();
        uint256 yieldInColl = _yieldToCollateral(yieldAsset.balanceOf(address(this)));
        uint256 debtInColl = _debtToCollateral(_debtAssets());
        uint256 gross = collat + yieldInColl;
        if (gross > debtInColl) {
            return gross - debtInColl;
        }
        return 0;
    }

    /// @notice ERC-4626 previews are disabled — they cannot model the swap
    ///         slippage that actual `deposit` / `redeem` incur. Use the
    ///         non-view `simulateDeposit` / `simulateRedeem` below for an
    ///         accurate quote via the QuoterV2 (callable via eth_call).
    function previewDeposit(uint256)  public pure override returns (uint256) { revert("use simulateDeposit"); }
    function previewMint(uint256)     public pure override returns (uint256) { revert("use deposit"); }
    function previewRedeem(uint256)   public pure override returns (uint256) { revert("use simulateRedeem"); }
    function previewWithdraw(uint256) public pure override returns (uint256) { revert("not implemented"); }

    /// @notice Slippage-accurate preview of how many shares a `deposit(assets)`
    ///         would mint. Calls QuoterV2 to price the debt→yield swap that
    ///         happens internally during deposit. Non-view (Quoter is non-view)
    ///         — call via eth_call (no broadcast).
    function simulateDeposit(uint256 assets) external returns (uint256 shares) {
        uint256 navBefore = totalAssets();
        (uint256 borrowed, uint256 currentDebt) = _simulateBorrow(assets);
        uint256 quotedYield = _quoteDebtToYield(borrowed);
        uint256 navAfter = _projectedNav(assets, currentDebt + borrowed, quotedYield);
        if (navAfter <= navBefore) return 0;
        shares = (navAfter - navBefore).mulDiv(_totalClaims(), navBefore + 1);
    }

    /// @dev Borrow-sizing math from `_leverNewCollateral`. Returns the borrow
    ///      amount and the current debt (for use in the projected NAV calc).
    function _simulateBorrow(uint256 assets) internal view returns (uint256 borrowed, uint256 currentDebt) {
        uint256 capByNew =
            _collateralToDebt(assets).mulDiv(marketLltv, 1e18).mulDiv(1e18, hfUpperTarget);
        uint256 targetDebt =
            _collateralToDebt(_collateral() + assets).mulDiv(marketLltv, 1e18).mulDiv(1e18, hfUpperTarget);
        currentDebt = _debtAssets();
        uint256 deltaCap = targetDebt > currentDebt ? targetDebt - currentDebt : 0;
        borrowed = capByNew < deltaCap ? capByNew : deltaCap;
    }

    function _quoteDebtToYield(uint256 debtIn) internal returns (uint256) {
        if (debtIn == 0) return 0;
        (uint256 out,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: loanToken,
            tokenOut: address(yieldAsset),
            amountIn: debtIn,
            fee: FEE_YIELD_DEBT,
            sqrtPriceLimitX96: 0
        }));
        return out;
    }

    /// @dev Post-deposit NAV at oracle prices given the new collateral, total
    ///      projected debt, and the quoted yield added to the existing yield bal.
    function _projectedNav(uint256 newAssets, uint256 newDebt, uint256 quotedYield) internal view returns (uint256) {
        uint256 newCollat = _collateral() + newAssets;
        uint256 newYield  = yieldAsset.balanceOf(address(this)) + quotedYield;
        uint256 gross     = newCollat + _yieldToCollateral(newYield);
        uint256 debtColl  = _debtToCollateral(newDebt);
        return gross > debtColl ? gross - debtColl : 0;
    }

    /// @notice Slippage-accurate preview of how much underlying a
    ///         `redeem(shares)` would pay out. Calls QuoterV2 for the
    ///         yield→debt and any debt↔underlying reconcile leg. Non-view —
    ///         call via eth_call.
    function simulateRedeem(uint256 shares) external returns (uint256 assets) {
        uint256 totalClaims = _totalClaims();
        Position memory pos = morpho.position(marketId, address(this));
        Market memory mkt   = morpho.market(marketId);

        uint256 collSlice  = uint256(pos.collateral).mulDiv(shares, totalClaims);
        uint256 yieldSlice = yieldAsset.balanceOf(address(this)).mulDiv(shares, totalClaims);
        uint256 debtSliceShares = uint256(pos.borrowShares).mulDiv(shares, totalClaims, Math.Rounding.Ceil);
        if (debtSliceShares > pos.borrowShares) debtSliceShares = pos.borrowShares;

        // Price the yield → loanToken sell (used in both paths).
        uint256 debtReceived;
        if (yieldSlice > 0) {
            (debtReceived,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: address(yieldAsset),
                tokenOut: loanToken,
                amountIn: yieldSlice,
                fee: FEE_YIELD_DEBT,
                sqrtPriceLimitX96: 0
            }));
        }

        if (debtSliceShares == 0) {
            // simpleRedeem path: yield → loanToken → asset, plus collSlice.
            uint256 wethOut;
            if (debtReceived > 0) {
                (wethOut,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: loanToken,
                    tokenOut: asset(),
                    amountIn: debtReceived,
                    fee: FEE_DEBT_COLL,
                    sqrtPriceLimitX96: 0
                }));
            }
            return collSlice + wethOut;
        }

        // Flashloan path. flashAssets = what we need to repay.
        uint256 flashAssets = debtSliceShares.toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);

        if (debtReceived > flashAssets) {
            uint256 surplus = debtReceived - flashAssets;
            uint256 wethBonus;
            (wethBonus,,,) = IQuoterV2(QUOTER).quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: loanToken,
                tokenOut: asset(),
                amountIn: surplus,
                fee: FEE_DEBT_COLL,
                sqrtPriceLimitX96: 0
            }));
            return collSlice + wethBonus;
        } else if (debtReceived < flashAssets) {
            uint256 deficit = flashAssets - debtReceived;
            uint256 wethCost;
            (wethCost,,,) = IQuoterV2(QUOTER).quoteExactOutputSingle(IQuoterV2.QuoteExactOutputSingleParams({
                tokenIn: asset(),
                tokenOut: loanToken,
                amount: deficit,
                fee: FEE_DEBT_COLL,
                sqrtPriceLimitX96: 0
            }));
            return collSlice > wethCost ? collSlice - wethCost : 0;
        }
        return collSlice;
    }
    function mint(uint256, address)  public pure override returns (uint256) { revert("use deposit"); }
    function maxMint(address)        public pure override returns (uint256) { return 0; }
    function withdraw(uint256, address, address) public pure override returns (uint256) { revert("use redeem"); }

    // ============================= deposit =============================

    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        // Gate on the share recipient (router-friendly: receiver is the user
        // even when msg.sender is the Yearn router).
        if (!allowlist.isAllowed(receiver)) revert NotAllowed();
        require(totalAssets() + assets <= maxTvl, "tvl cap exceeded");

        // Snapshot NAV-before with free underlying = 0 (the vault never holds
        // underlying outside Morpho between external calls).
        uint256 navBefore = totalAssets();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        morpho.supplyCollateral(_marketParams(), assets, address(this), "");
        _leverNewCollateral(assets);
        _swapDebtToYield();

        uint256 navAfter = totalAssets();
        uint256 contributed = navAfter - navBefore;
        shares = contributed.mulDiv(_totalClaims(), navBefore + 1);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ============================= redeem ==============================

    /// @dev Flash-loan unwind: borrow `flashAssets` PYUSD0 from Morpho, repay
    ///      the debt slice (in shares), withdraw the collateral slice, sell
    ///      the yield slice, reconcile, return the flash loan.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        returns (uint256 assets)
    {
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Accrue first so position + market state are exact for this tx.
        morpho.accrueInterest(_marketParams());

        uint256 totalClaims = _totalClaims();
        Position memory pos = morpho.position(marketId, address(this));
        Market memory mkt = morpho.market(marketId);

        uint256 collSlice  = uint256(pos.collateral).mulDiv(shares, totalClaims);
        uint256 yieldSlice = yieldAsset.balanceOf(address(this)).mulDiv(shares, totalClaims);

        // Round shares to clear UP, but never exceed our actual position.
        uint256 debtSliceShares = uint256(pos.borrowShares).mulDiv(shares, totalClaims, Math.Rounding.Ceil);
        if (debtSliceShares > pos.borrowShares) debtSliceShares = pos.borrowShares;

        if (debtSliceShares == 0) {
            return simpleRedeem(shares, receiver, owner, collSlice, yieldSlice);
        }

        uint256 flashAssets =
            debtSliceShares.toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);

        morpho.flashLoan(loanToken, flashAssets, abi.encode(collSlice, yieldSlice, debtSliceShares));

        assets = IERC20(asset()).balanceOf(address(this));
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Debt-free unwind path (e.g. position fully liquidated).
    function simpleRedeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 collSlice,
        uint256 yieldSlice
    ) internal returns (uint256 assets) {
        if (collSlice > 0) {
            morpho.withdrawCollateral(_marketParams(), collSlice, address(this), address(this));
        }
        if (yieldSlice > 0) {
            uint256 debtReceived = _swapExactIn(address(yieldAsset), loanToken, yieldSlice);
            if (debtReceived > 0) {
                _swapExactIn(loanToken, asset(), debtReceived);
            }
        }
        assets = IERC20(asset()).balanceOf(address(this));
        _burn(owner, shares);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @inheritdoc IMorphoFlashLoanCallback
    function onMorphoFlashLoan(uint256 flashAssets, bytes calldata data) external {
        require(msg.sender == address(morpho), "only morpho");

        (uint256 collSlice, uint256 yieldSlice, uint256 debtSliceShares) =
            abi.decode(data, (uint256, uint256, uint256));

        // 1. Clear the debt slice. Morpho will pull exactly `flashAssets` worth
        //    (it computes that internally as toAssetsUp of debtSliceShares,
        //    matching what we pre-computed above).
        morpho.repay(_marketParams(), 0, debtSliceShares, address(this), "");

        // 2. Withdraw collateral slice.
        if (collSlice > 0) {
            morpho.withdrawCollateral(_marketParams(), collSlice, address(this), address(this));
        }

        // 3. Sell yield slice for loan token.
        if (yieldSlice > 0) {
            _swapExactIn(address(yieldAsset), loanToken, yieldSlice);
        }

        // 4. Reconcile loan-token balance to `flashAssets` (Morpho will pull
        //    that exact amount back — no premium).
        uint256 loanBal = IERC20(loanToken).balanceOf(address(this));
        if (loanBal > flashAssets) {
            _swapExactIn(loanToken, asset(), loanBal - flashAssets);
        } else if (loanBal < flashAssets) {
            uint256 deficit = flashAssets - loanBal;
            _swapExactOut(asset(), loanToken, deficit, IERC20(asset()).balanceOf(address(this)));
        }
    }

    // ============================ rebalance ============================

    function rebalance() public {
        morpho.accrueInterest(_marketParams());
        uint256 navBefore = totalAssets();
        uint256 hf = _healthFactor();

        if (hf > hfUpperThreshold) {
            uint256 toBorrow = _debtDeltaToReachHf(hfUpperTarget);
            morpho.borrow(_marketParams(), toBorrow, 0, address(this), address(this));
            uint256 expected = _debtToYield(toBorrow);
            uint256 minOut = expected.mulDiv(BPS_DENOM - maxSwapSlippageBps, BPS_DENOM);
            uint256 received = _swapExactIn(loanToken, address(yieldAsset), toBorrow);
            require(received >= minOut, "rebalance swap slippage");
        } else if (hf < hfLowerThreshold) {
            uint256 toRepay = _debtDeltaToReachHf(hfLowerTarget);
            uint256 expected = _debtToYield(toRepay);
            uint256 maxIn = expected.mulDiv(BPS_DENOM + maxSwapSlippageBps, BPS_DENOM);
            _swapExactOut(address(yieldAsset), loanToken, toRepay, maxIn);
            morpho.repay(_marketParams(), toRepay, 0, address(this), "");
        }

        uint256 navAfter = totalAssets();
        require(
            navAfter >= navBefore.mulDiv(BPS_DENOM - MAX_REBALANCE_SLIPPAGE_BPS, BPS_DENOM),
            "rebalance NAV slippage"
        );

        emit Rebalanced(navBefore, navAfter, _healthFactor());
    }

    // ============================= views ===============================

    function collateral() public view returns (uint256) { return _collateral(); }
    function debt() public view returns (uint256) { return _debtAssets(); }
    function healthFactor() public view returns (uint256) { return _healthFactor(); }
    function marketParams() public view returns (MarketParams memory) { return _marketParams(); }

    // ========================= internal helpers ========================

    function _marketParams() internal view returns (MarketParams memory) {
        return MarketParams({
            loanToken: loanToken,
            collateralToken: asset(),
            oracle: marketOracle,
            irm: marketIrm,
            lltv: marketLltv
        });
    }

    function _collateral() internal view returns (uint256) {
        return uint256(morpho.position(marketId, address(this)).collateral);
    }

    function _debtAssets() internal view returns (uint256) {
        Position memory p = morpho.position(marketId, address(this));
        if (p.borrowShares == 0) return 0;
        Market memory m = morpho.market(marketId);
        if (m.totalBorrowShares == 0) return 0;
        return uint256(p.borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _pColl() internal view returns (uint256) {
        return uint256(IChainlinkAggregator(collateralPriceOracle).latestAnswer());
    }
    function _pDebt() internal view returns (uint256) {
        return uint256(IChainlinkAggregator(debtPriceOracle).latestAnswer());
    }
    function _pYield() internal view returns (uint256) {
        return uint256(IChainlinkAggregator(yieldOracle).latestAnswer());
    }

    function _healthFactor() internal view returns (uint256) {
        uint256 d = _debtAssets();
        if (d == 0) return type(uint256).max;
        uint256 collValInDebt = _collateralToDebt(_collateral());
        uint256 maxBorrow = collValInDebt.mulDiv(marketLltv, 1e18);
        return maxBorrow.mulDiv(1e18, d);
    }

    function _debtDeltaToReachHf(uint256 targetHf) internal view returns (uint256) {
        uint256 collValInDebt = _collateralToDebt(_collateral());
        uint256 maxBorrow = collValInDebt.mulDiv(marketLltv, 1e18);
        uint256 targetDebt = maxBorrow.mulDiv(1e18, targetHf);
        uint256 currentDebt = _debtAssets();
        return targetDebt > currentDebt ? targetDebt - currentDebt : currentDebt - targetDebt;
    }

    function _leverNewCollateral(uint256 newCollateral) internal returns (uint256 borrowed) {
        if (newCollateral == 0) return 0;

        uint256 newCollValInDebt = _collateralToDebt(newCollateral);
        uint256 capByNew = newCollValInDebt.mulDiv(marketLltv, 1e18).mulDiv(1e18, hfUpperTarget);

        uint256 collValInDebt = _collateralToDebt(_collateral());
        uint256 targetDebt = collValInDebt.mulDiv(marketLltv, 1e18).mulDiv(1e18, hfUpperTarget);
        uint256 currentDebt = _debtAssets();
        uint256 deltaCap = targetDebt > currentDebt ? targetDebt - currentDebt : 0;

        borrowed = capByNew < deltaCap ? capByNew : deltaCap;
        if (borrowed > 0) {
            morpho.borrow(_marketParams(), borrowed, 0, address(this), address(this));
        }
    }

    function _swapDebtToYield() internal returns (uint256) {
        uint256 bal = IERC20(loanToken).balanceOf(address(this));
        if (bal == 0) return 0;
        return _swapExactIn(loanToken, address(yieldAsset), bal);
    }

    function _collateralToDebt(uint256 collatAmount) internal view returns (uint256) {
        if (collatAmount == 0) return 0;
        return collatAmount.mulDiv(_pColl() * (10 ** LOAN_DECIMALS), _pDebt() * (10 ** COLLATERAL_DECIMALS));
    }

    function _debtToCollateral(uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) return 0;
        return debtAmount.mulDiv(_pDebt() * (10 ** COLLATERAL_DECIMALS), _pColl() * (10 ** LOAN_DECIMALS));
    }

    function _yieldToCollateral(uint256 yieldAmount) internal view returns (uint256) {
        if (yieldAmount == 0) return 0;
        if (yieldDecimals <= COLLATERAL_DECIMALS) {
            return yieldAmount.mulDiv(_pYield() * (10 ** (COLLATERAL_DECIMALS - yieldDecimals)), _pColl());
        } else {
            return yieldAmount.mulDiv(_pYield(), _pColl() * (10 ** (yieldDecimals - COLLATERAL_DECIMALS)));
        }
    }

    function _debtToYield(uint256 debtAmount) internal view returns (uint256) {
        if (debtAmount == 0) return 0;
        if (yieldDecimals >= LOAN_DECIMALS) {
            return debtAmount.mulDiv(_pDebt() * (10 ** (yieldDecimals - LOAN_DECIMALS)), _pYield());
        } else {
            return debtAmount.mulDiv(_pDebt(), _pYield() * (10 ** (LOAN_DECIMALS - yieldDecimals)));
        }
    }

    function _feeFor(address tokenA, address tokenB) internal view returns (uint24) {
        address y = address(yieldAsset);
        if ((tokenA == y && tokenB == loanToken) || (tokenA == loanToken && tokenB == y)) {
            return FEE_YIELD_DEBT;
        }
        return FEE_DEBT_COLL;
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        return ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: _feeFor(tokenIn, tokenOut),
                recipient: address(this),
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
                fee: _feeFor(tokenIn, tokenOut),
                recipient: address(this),
                amountOut: amountOut,
                amountInMaximum: amountInMax,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
