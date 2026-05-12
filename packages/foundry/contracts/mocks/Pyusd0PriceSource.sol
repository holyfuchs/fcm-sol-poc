// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {MockPriceSource} from "./MockPriceSource.sol";

/// @notice Settable Chainlink-style price feed for PYUSD0.
contract Pyusd0PriceSource is MockPriceSource {
    constructor(int256 initialPrice) MockPriceSource(initialPrice) {}
}
