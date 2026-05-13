// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// @title Allowlist
/// @notice Standalone admin-gated allowlist consulted by `FCMVault.deposit`.
///         Deployer is the admin and is the only address that can add or
///         remove entries.
contract Allowlist {
    address public immutable admin;
    mapping(address => bool) public allowed;

    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event Set(address indexed account, bool allowed);

    error NotAdmin();

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    /// @notice Add or remove a single account.
    function set(address account, bool isAllowed) external onlyAdmin {
        allowed[account] = isAllowed;
        emit Set(account, isAllowed);
    }

    /// @notice Batch variant — cheaper for setting up multiple accounts at once.
    function setMany(address[] calldata accounts, bool isAllowed) external onlyAdmin {
        for (uint256 i = 0; i < accounts.length; i++) {
            allowed[accounts[i]] = isAllowed;
            emit Set(accounts[i], isAllowed);
        }
    }

    /// @notice Convenience read for callers that want a boolean back from a
    ///         function call (the public mapping getter works just as well).
    function isAllowed(address account) external view returns (bool) {
        return allowed[account];
    }
}
