// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockPriceSource} from "./MockPriceSource.sol";

/// @notice Settable Chainlink-style price feed used as the WETH source for
///         the Morpho market oracle + the vault's collateral-price oracle.
///         Named subclass so SE-2's generateTsAbis picks it up as a distinct
///         contract entry (one contract per file with matching filename).
contract WethPriceSource is MockPriceSource {
    constructor(int256 initialPrice) MockPriceSource(initialPrice) {}
}
