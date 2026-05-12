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
    uint24  public constant FEE_YIELD_DEBT = 100;    // PYUSD0/YIELD pool
    uint24  public constant FEE_DEBT_COLL  = 3000;   // WETH/PYUSD0 pool

    uint8 public constant LOAN_DECIMALS = 6;
    uint8 public constant COLLATERAL_DECIMALS = 18;

    uint256 internal constant BPS_DENOM = 10_000;

    uint256 public constant HF_LOWER_THRESHOLD = 1.10e18;
    uint256 public constant HF_LOWER_TARGET    = 1.15e18;
    uint256 public constant HF_UPPER_TARGET    = 1.45e18;
    uint256 public constant HF_UPPER_THRESHOLD = 1.50e18;

    uint256 public constant MAX_SWAP_SLIPPAGE_BPS      = 3000; // 30%
    uint256 public constant MAX_REBALANCE_SLIPPAGE_BPS = 50;   // 0.5%
    uint256 public constant MAX_TVL = 100e18;

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

    // ---- Yield leg -----------------------------------------------------

    IERC20 public immutable yieldAsset;
    uint8  public immutable yieldDecimals;

    constructor(
        IERC20 underlying_,
        IERC20 yieldAsset_,
        uint8 yieldDecimals_,
        address yieldOracle_,
        address collateralPriceOracle_,
        address debtPriceOracle_,
        IMorpho morpho_,
        MarketParams memory marketParams_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
        ERC4626(underlying_)
    {
        require(marketParams_.collateralToken == address(underlying_), "underlying != collateral");

        morpho       = morpho_;
        marketId     = marketParams_.id();
        loanToken    = marketParams_.loanToken;
        marketOracle = marketParams_.oracle;
        marketIrm    = marketParams_.irm;
        marketLltv   = marketParams_.lltv;

        yieldAsset            = yieldAsset_;
        yieldDecimals         = yieldDecimals_;
        yieldOracle           = yieldOracle_;
        collateralPriceOracle = collateralPriceOracle_;
        debtPriceOracle       = debtPriceOracle_;

        uint256 max = type(uint256).max;
        underlying_.forceApprove(address(morpho_), max);
        IERC20(loanToken).forceApprove(address(morpho_), max);
        IERC20(loanToken).forceApprove(SWAP_ROUTER, max);
        underlying_.forceApprove(SWAP_ROUTER, max);
        yieldAsset_.forceApprove(SWAP_ROUTER, max);
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

    function previewDeposit(uint256) public pure override returns (uint256) { revert("not implemented"); }
    function previewMint(uint256)    public pure override returns (uint256) { revert("use deposit"); }
    function previewRedeem(uint256)  public pure override returns (uint256) { revert("not implemented"); }
    function previewWithdraw(uint256) public pure override returns (uint256) { revert("not implemented"); }
    function mint(uint256, address)  public pure override returns (uint256) { revert("use deposit"); }
    function maxMint(address)        public pure override returns (uint256) { return 0; }
    function withdraw(uint256, address, address) public pure override returns (uint256) { revert("use redeem"); }

    // ============================= deposit =============================

    function deposit(uint256 assets, address receiver)
        public
        override
        returns (uint256 shares)
    {
        require(totalAssets() + assets <= MAX_TVL, "tvl cap exceeded");

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

        if (hf > HF_UPPER_THRESHOLD) {
            uint256 toBorrow = _debtDeltaToReachHF(HF_UPPER_TARGET);
            morpho.borrow(_marketParams(), toBorrow, 0, address(this), address(this));
            uint256 expected = _debtToYield(toBorrow);
            uint256 minOut = expected.mulDiv(BPS_DENOM - MAX_SWAP_SLIPPAGE_BPS, BPS_DENOM);
            uint256 received = _swapExactIn(loanToken, address(yieldAsset), toBorrow);
            require(received >= minOut, "rebalance swap slippage");
        } else if (hf < HF_LOWER_THRESHOLD) {
            uint256 toRepay = _debtDeltaToReachHF(HF_LOWER_TARGET);
            uint256 expected = _debtToYield(toRepay);
            uint256 maxIn = expected.mulDiv(BPS_DENOM + MAX_SWAP_SLIPPAGE_BPS, BPS_DENOM);
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

    function _debtDeltaToReachHF(uint256 targetHf) internal view returns (uint256) {
        uint256 collValInDebt = _collateralToDebt(_collateral());
        uint256 maxBorrow = collValInDebt.mulDiv(marketLltv, 1e18);
        uint256 targetDebt = maxBorrow.mulDiv(1e18, targetHf);
        uint256 currentDebt = _debtAssets();
        return targetDebt > currentDebt ? targetDebt - currentDebt : currentDebt - targetDebt;
    }

    function _leverNewCollateral(uint256 newCollateral) internal returns (uint256 borrowed) {
        if (newCollateral == 0) return 0;

        uint256 newCollValInDebt = _collateralToDebt(newCollateral);
        uint256 capByNew = newCollValInDebt.mulDiv(marketLltv, 1e18).mulDiv(1e18, HF_UPPER_TARGET);

        uint256 collValInDebt = _collateralToDebt(_collateral());
        uint256 targetDebt = collValInDebt.mulDiv(marketLltv, 1e18).mulDiv(1e18, HF_UPPER_TARGET);
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
