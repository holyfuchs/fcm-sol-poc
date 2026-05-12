// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IIrm} from "@morpho-blue/interfaces/IIrm.sol";
import {MarketParams, Market} from "@morpho-blue/interfaces/IMorpho.sol";

/// @notice Minimal IRM that returns a constant borrow rate. Sufficient for a
///         demo — no curve, no utilisation sensitivity.
contract FixedRateIrm is IIrm {
    /// @notice Per-second rate scaled by 1e18. Default = 5% APR.
    ///         APR / seconds_per_year × 1e18, with seconds_per_year = 365.25*86400.
    uint256 public immutable RATE_PER_SECOND;

    constructor(uint256 ratePerSecond_) {
        RATE_PER_SECOND = ratePerSecond_;
    }

    function borrowRate(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE_PER_SECOND;
    }

    function borrowRateView(MarketParams memory, Market memory) external view returns (uint256) {
        return RATE_PER_SECOND;
    }
}
