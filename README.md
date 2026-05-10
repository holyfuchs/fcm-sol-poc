# Flow Credit Markets PoC

Leveraged WETH ERC-4626 vault on Flow EVM. Supplies WETH to Aave V3 (MORE Markets), borrows PYUSD against it, swaps the borrow into a yield asset on PunchSwap V3, and rebalances to keep the health factor inside `[1.10, 1.50]`.

Built on Scaffold-ETH 2 (Foundry + Next.js).

## Requirements

- Node ≥ v20.18.3
- Yarn (v1 or v2+)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`anvil`, `forge`, `cast`)

## Quickstart

The vault hardcodes Flow EVM mainnet addresses (Aave Pool, Aave Oracle, PYUSD, PunchSwap V3 router), so local development runs against a fork of Flow EVM mainnet.

```bash
yarn install
```

First-time only — install Foundry libs the contracts depend on:

```bash
cd packages/foundry
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts aave/aave-v3-core
cd ../..
```

### 1. Local fork

```bash
yarn chain
```

This forks `https://mainnet.evm.nodes.onflow.org` via `anvil`. To use a different RPC:

```bash
FLOW_EVM_RPC=https://your-rpc.example yarn chain
```

### 2. Deploy + bootstrap

```bash
yarn deploy
```

Runs the forge deploy script, then `scripts-js/postDeploy.js` does the things that need privileged accounts on the fork:

1. Impersonates the Aave ACL admin and grants the deployer `PoolAdmin`.
2. Points the Aave oracle's source for the mock yield token at our `MockPriceSource` (settable from the UI).
3. Funds the deployer with WETH + PYUSD via `anvil_setStorageAt` (storage-slot probing).
4. Mints mYLD and seeds two PunchSwap V3 pools (`PYUSD↔mYLD` and `PYUSD↔WETH`) via `V3PoolHelper`.
5. Deploys `FCMVault` with WETH as underlying and mYLD as the yield asset.

### 3. Frontend

```bash
yarn start
```

Open <http://localhost:3000>. The home page has:

- **Deposit**: approves WETH and calls `deposit()`. Vault levers up to HF target via Aave + PunchSwap.
- **Set Yield Token Price**: writes a USD price into `MockPriceSource`. Moves the vault's HF without any swaps.
- **Rebalance**: permissionless `rebalance()`. Pulls HF back into `[1.10, 1.50]`.
- Plus the standard SE-2 **Debug Contracts** and **Block Explorer** tabs.

The default deployer (anvil's account `#9` keystore) ends up with ~99 WETH after pool seeding — connect with that account or import its key (`0x2a871d…d409c6`) into your wallet.

## Tests

```bash
cd packages/foundry
forge test
```

The fork test suite (`test/FCMVaultMock.t.sol`) creates its own fork at a pinned block, seeds pools, mocks the oracle via `vm.mockCall`, and exercises deposit / redeem / slippage invariants.

## Layout

- `packages/foundry/contracts/FCMVault.sol` — the vault.
- `packages/foundry/contracts/mocks/` — `MockYieldToken`, `MockPriceSource`, `V3PoolHelper`.
- `packages/foundry/script/DeployFCMVault.s.sol` — on-chain deploy.
- `packages/foundry/scripts-js/postDeploy.js` — fork bootstrapping.
- `packages/nextjs/app/page.tsx` — homepage UI.


## Documentation

Visit our [docs](https://docs.scaffoldeth.io) to learn how to start building with Scaffold-ETH 2.

To know more about its features, check out our [website](https://scaffoldeth.io).

## Contributing to Scaffold-ETH 2

We welcome contributions to Scaffold-ETH 2!

Please see [CONTRIBUTING.MD](https://github.com/scaffold-eth/scaffold-eth-2/blob/main/CONTRIBUTING.md) for more information and guidelines for contributing to Scaffold-ETH 2.