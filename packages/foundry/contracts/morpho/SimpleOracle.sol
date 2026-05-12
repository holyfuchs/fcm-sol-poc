// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IChainlinkLike {
    function latestAnswer() external view returns (int256);
}

/// @notice Morpho-Blue-compatible IOracle.
///         Returns: (collateralPrice / loanPrice) × 10^(36 + loanDecimals - collateralDecimals).
///         Sources are Chainlink-style aggregators using `latestAnswer()` with
///         1e8 base (Aave's convention) — works directly with our `MockPriceSource`
///         and Aave's own per-asset sources.
contract SimpleOracle {
    address public immutable collateralSource;
    address public immutable loanSource;
    /// Pre-computed `10^(36 + loanDecimals - collateralDecimals)` for the
    /// configured market.
    uint256 public immutable scaleFactor;

    constructor(
        address collateralSource_,
        address loanSource_,
        uint8 loanDecimals,
        uint8 collateralDecimals
    ) {
        collateralSource = collateralSource_;
        loanSource = loanSource_;
        scaleFactor = 10 ** (uint256(36) + uint256(loanDecimals) - uint256(collateralDecimals));
    }

    /// @notice Price of 1 unit of collateral (in collateral-wei) expressed in
    ///         loan-wei, scaled by `1e36`.
    function price() external view returns (uint256) {
        int256 c = IChainlinkLike(collateralSource).latestAnswer();
        int256 l = IChainlinkLike(loanSource).latestAnswer();
        require(c > 0 && l > 0, "bad oracle");
        // Both sources are 1e8-scaled; the ratio is dimensionless. Multiply by
        // scaleFactor to land in Morpho's expected 1e36 + decimal base.
        return (uint256(c) * scaleFactor) / uint256(l);
    }
}
