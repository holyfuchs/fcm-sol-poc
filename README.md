# Flow Credit Markets PoC

Leveraged WETH ERC-4626 vault on Flow EVM. Supplies WETH to Aave V3 (MORE Markets), borrows PYUSD against it, swaps the borrow into a yield asset on PunchSwap V3, and rebalances to keep the health factor inside `[1.10, 1.50]`.

Built on Scaffold-ETH 2 (Foundry + Next.js).

## Deployments

PYUSD0 - 0x99af3eea856556646c98c8b9b2548fe815240750

### Swap

https://flowswap.io/

V3 Core Factory:
0xca6d7Bb03334bBf135902e1d919a5feccb461632
Universal Router:
0x5fE87847fe20a6C30921620F52B06a4A3740aa61
Tick Lens:
0x513A58591c8E502543D629748076857a71C6079D
Nonfungible Token Position Manager:
0xf7F20a346E3097C7d38afDDA65c7C802950195C7
V3 Migrator:
0x5C65D5C7E0154f519B7dC4558915A7016F41aa50
Quoter:
0x370A8DF17742867a44e56223EC20D82092242C85
Swap Router 02:
0xeEDC6Ff75e1b10B903D9013c358e446a73d35341
Permit2:
0x000000000022D473030F116dDEE9F6B43aC78BA3
Multicall2:
0x8B5eB800B8d9cF702ff3DD0047ac31bBD411B82a


0x9196e243b7562b0866309013f2f9eb63f83a690f -- MOET / FUSDEV - 0.01

### Yield

FUSDEV - 0xd069d989e2F44B70c65347d1853C0c67e10a9F8D - PYUSD0 - sync
0xcbf9a7753f9d2d0e8141ebb36d99f87acef98597 - FLOW - async

## Requirements

- Node ≥ v20.18.3
- Yarn (v1 or v2+)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`anvil`, `forge`, `cast`)

## Quickstart

The vault interacts with on-chain Flow EVM addresses (FlowSwap V3 router, PYUSD0, the yield ERC-4626) — so local dev runs against a **fork** of Flow EVM mainnet. **Morpho Blue is not deployed on Flow EVM**, so `yarn deploy` deploys it (the lending primitive, an IRM, an oracle adapter, and a WETH/PYUSD0 market) into the fork as part of the bootstrap.

```bash
yarn install
git submodule update --init --recursive   # pulls forge-std, openzeppelin, aave-v3-core, morpho-blue
```

(If you don't already have Foundry: <https://book.getfoundry.sh/getting-started/installation>.)

### 1. Local fork

```bash
yarn chain
```

Forks `https://mainnet.evm.nodes.onflow.org` via `anvil`. Override the RPC:

```bash
FLOW_EVM_RPC=https://your-rpc.example yarn chain
```

### 2. Deploy + bootstrap

```bash
yarn deploy
```

Pipeline:

1. **`DeployMorphoStack.s.sol`** — deploys Morpho Blue (owner = deployer), a `FixedRateIrm` at ~5% APR, two `MockPriceSource`s (WETH + PYUSD0, both seeded with the live Aave oracle prices so initial HF math matches mainnet), a `SimpleOracle` that wraps them for Morpho's `IOracle` (1e36 scale), and creates the WETH/PYUSD0 market at 86% LLTV.
2. **`DeployFCMVault.s.sol`** — deploys `MockPriceSource` (WETH price for the demo), `V3PoolPriceSource` (yield-token oracle reading FlowSwap V3 `slot0`), and `FCMVault` with the yield oracle baked in.
3. **`scripts-js/postDeploy.js`** —
   - Impersonates the Aave ACL admin → grants the deployer `PoolAdmin` so we can override Aave's WETH source (the vault still consults Aave for WETH/PYUSD0 HF math).
   - Funds the deployer with WETH + PYUSD0 via `anvil_setStorageAt` (storage-slot probing).
   - Confirms the live PYUSD0↔YIELD FlowSwap V3 pool exists.
   - Points Aave's WETH source at our settable `MockPriceSource`.
   - Snapshots the post-deploy chain state for the "Reset chain" button.

### 3. Frontend

```bash
yarn start
```

Open <http://localhost:3000>. Cards on the home page:

- **Deposit / Redeem** — approves WETH and runs vault entry/exit. "Other user" button impersonates a second EOA and deposits the same amount.
- **Set Collateral (WETH) Price / Set Health** — writes a USD price (or computes one from a target HF) into the WETH `MockPriceSource`, then nudges the WETH↔PYUSD0 FlowSwap pool to match via `anvil_setStorageAt` on `slot0`.
- **Set Yield Token Price** — nudges the PYUSD0↔YIELD FlowSwap pool's `slot0`; the V3PoolPriceSource derives the new yield USD price automatically.
- **Rebalance / Liquidate** — `rebalance()` is permissionless; **Liquidate** impersonates a 3rd party that calls Aave's `liquidationCall` (only succeeds if HF < 1).
- **Reset chain** (top-right) — `evm_revert` to the post-deploy snapshot.

The default deployer is anvil's keystore-default account; private key `0x2a871d…d409c6`. Import it into your wallet or use the SE-2 burner.

## Tests

```bash
cd packages/foundry
forge test
```

`test/RealDeposit.t.sol` forks Flow EVM mainnet at the latest block, deploys a fresh `FCMVault` against the live FlowSwap V3 pools, and exercises a 0.1 WETH deposit end-to-end (real swap, real Aave supply/borrow).

## Layout

- `packages/foundry/contracts/FCMVault.sol` — the vault.
- `packages/foundry/contracts/morpho/` — `FixedRateIrm`, `SimpleOracle` (Morpho Blue glue).
- `packages/foundry/contracts/mocks/` — `MockPriceSource`, `V3PoolPriceSource`, `V3PoolHelper`.
- `packages/foundry/script/Deploy.s.sol` — orchestrator.
- `packages/foundry/script/DeployMorphoStack.s.sol` — Morpho Blue + IRM + oracle + market.
- `packages/foundry/script/DeployFCMVault.s.sol` — FCMVault + its yield oracle.
- `packages/foundry/scripts-js/postDeploy.js` — fork bootstrapping (impersonation, funding, oracle override, snapshot).
- `packages/nextjs/app/page.tsx` — homepage UI.

> Note: `FCMVault` currently uses **Aave V3** for the WETH/PYUSD0 leg. Morpho Blue is deployed on the fork via `DeployMorphoStack` but the vault doesn't yet route through it — porting that is the next change. Phase 2.


## Documentation

Visit our [docs](https://docs.scaffoldeth.io) to learn how to start building with Scaffold-ETH 2.

To know more about its features, check out our [website](https://scaffoldeth.io).

## Contributing to Scaffold-ETH 2

We welcome contributions to Scaffold-ETH 2!

Please see [CONTRIBUTING.MD](https://github.com/scaffold-eth/scaffold-eth-2/blob/main/CONTRIBUTING.md) for more information and guidelines for contributing to Scaffold-ETH 2.
