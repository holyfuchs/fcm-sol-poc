// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @notice Minimal Chainlink-style price source for AaveOracle. The Aave oracle
///         only reads `latestAnswer()`. Price is publicly settable so the demo
///         frontend can simulate yield-token price moves.
contract MockPriceSource {
    int256 private _price;

    event PriceSet(int256 price);

    constructor(int256 initialPrice) {
        _price = initialPrice;
    }

    function setPrice(int256 newPrice) external {
        _price = newPrice;
        emit PriceSet(newPrice);
    }

    function latestAnswer() external view returns (int256) {
        return _price;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}
