/* eslint-disable no-console */
// Post-deploy bootstrapping for the local Flow EVM fork.
//
// `forge script` deploys the contracts but cannot do the things that require
// privileged accounts on the fork: granting the deployer the Aave PoolAdmin
// role, swapping in our MockPriceSource for the yield token, funding the
// deployer with WETH/PYUSD, and seeding the two FlowSwap V3 pools.
// All of that lives here and runs against anvil's RPC via cheatcodes.

import { readFileSync, writeFileSync, existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { ethers } from "ethers";

const __dirname = dirname(fileURLToPath(import.meta.url));

const RPC = process.env.LOCAL_RPC ?? "http://127.0.0.1:8545";
const DEPLOYER_PK =
  "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6";

const WETH  = "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590";
const PYUSD = "0x99aF3EeA856556646C98c8B9b2548Fe815240750";
const YIELD_TOKEN = "0xd069d989e2F44B70c65347d1853C0c67e10a9F8D";
const SWAP_FACTORY = "0xca6d7Bb03334bBf135902e1d919a5feccb461632"; // FlowSwap V3 Core Factory
const POOL_FEE = 100; // 0.01%

const erc20Abi = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
  "function transfer(address,uint256) returns (bool)",
  "function mint(address,uint256)",
];

const poolAbi = [
  "function ADDRESSES_PROVIDER() view returns (address)",
];

const providerAbi = [
  "function getACLAdmin() view returns (address)",
  "function getACLManager() view returns (address)",
  "function getPriceOracle() view returns (address)",
];

const aclAbi = [
  "function addPoolAdmin(address)",
  "function isPoolAdmin(address) view returns (bool)",
];

const oracleAbi = [
  "function setAssetSources(address[],address[])",
  "function getSourceOfAsset(address) view returns (address)",
  "function getAssetPrice(address) view returns (uint256)",
];

const factoryAbi = [
  "function getPool(address,address,uint24) view returns (address)",
];

const v3PoolAbi = [
  "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)",
];

const mockSourceAbi = [
  "function setPrice(int256)",
  "function latestAnswer() view returns (int256)",
];

const helperAbi = [
  "function createAndFundPool(address,address,uint24,uint256,uint256) returns (address)",
];

async function rpc(provider, method, params) {
  return provider.send(method, params);
}

async function impersonate(provider, addr) {
  await rpc(provider, "anvil_impersonateAccount", [addr]);
  await rpc(provider, "anvil_setBalance", [addr, "0x56BC75E2D63100000"]); // 100 ether
}

async function stop(provider, addr) {
  await rpc(provider, "anvil_stopImpersonatingAccount", [addr]);
}

// Probe storage slots to find the ERC20 _balances mapping slot, then write
// `amount` into balances[holder]. Tries slots 0..30 — covers OZ ERC20, OZ-V5,
// Solady, and most bridged tokens.
async function setErc20Balance(provider, token, holder, amount) {
  const erc20 = new ethers.Contract(token, erc20Abi, provider);
  const decimals = await erc20.decimals();
  for (let slot = 0; slot < 30; slot++) {
    const key = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [holder, slot])
    );
    const original = await rpc(provider, "eth_getStorageAt", [token, key, "latest"]);
    const sentinel =
      "0x00000000000000000000000000000000000000000000000000000000deadbeef";
    await rpc(provider, "anvil_setStorageAt", [token, key, sentinel]);
    const probed = await erc20.balanceOf(holder);
    await rpc(provider, "anvil_setStorageAt", [token, key, original]);
    if (probed.eq(0xdeadbeef)) {
      const target = ethers.utils.hexZeroPad(
        ethers.BigNumber.from(amount).toHexString(),
        32
      );
      await rpc(provider, "anvil_setStorageAt", [token, key, target]);
      console.log(
        `  ${token}: balance slot ${slot}, set ${ethers.utils.formatUnits(amount, decimals)}`
      );
      return;
    }
  }
  throw new Error(`could not find balance slot for ${token}`);
}

async function main() {
  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const deployer = new ethers.Wallet(DEPLOYER_PK, provider);

  const deployments = JSON.parse(
    readFileSync(join(__dirname, "..", "deployments", "31337.json"), "utf8")
  );
  const addrs = {};
  for (const [addr, name] of Object.entries(deployments)) {
    if (name !== "networkName") addrs[name] = addr;
  }
  console.log("deployments:", addrs);

  // Sanity-check the live PYUSD0↔YIELD pool we depend on.
  const factory = new ethers.Contract(SWAP_FACTORY, factoryAbi, provider);
  const yieldPoolAddr = await factory.getPool(PYUSD, YIELD_TOKEN, POOL_FEE);
  if (yieldPoolAddr === ethers.constants.AddressZero) {
    throw new Error(
      `PYUSD0↔YIELD pool not found on FlowSwap V3 factory ${SWAP_FACTORY}`
    );
  }
  const slot0 = await new ethers.Contract(yieldPoolAddr, v3PoolAbi, provider).slot0();
  if (slot0.sqrtPriceX96.isZero()) {
    throw new Error(`PYUSD0↔YIELD pool ${yieldPoolAddr} is not initialised`);
  }
  console.log(`yield pool: ${yieldPoolAddr} (read live, never seeded)`);

  console.log("\nfunding deployer with WETH");
  const wethTarget = ethers.utils.parseUnits("10", 18);
  await setErc20Balance(provider, WETH, deployer.address, wethTarget);
  const remainingWeth = await new ethers.Contract(WETH, erc20Abi, provider).balanceOf(deployer.address);
  console.log(`deployer WETH balance: ${ethers.utils.formatEther(remainingWeth)}`);

  // Seed the Morpho market with PYUSD0 supply so the vault has loan-token
  // liquidity to borrow against. Use a dedicated "lender" address so the
  // deployer is only ever a borrower in the demo.
  console.log("\nseeding Morpho market with PYUSD0 supply (1M)");
  const LENDER = "0x000000000000000000000000000000000000d0d0";
  await rpc(provider, "anvil_impersonateAccount", [LENDER]);
  await rpc(provider, "anvil_setBalance", [LENDER, "0x56BC75E2D63100000"]);
  const supplyAmount = ethers.utils.parseUnits("1000000", 6);
  await setErc20Balance(provider, PYUSD, LENDER, supplyAmount);

  // Read marketParams from the vault — single source of truth.
  const vaultC = new ethers.Contract(
    addrs.FCMVault,
    [
      "function marketParams() view returns (tuple(address loanToken, address collateralToken, address oracle, address irm, uint256 lltv))",
    ],
    provider
  );
  const mp = await vaultC.marketParams();

  const lenderSigner = provider.getSigner(LENDER);
  const pyusdAsLender = new ethers.Contract(
    PYUSD,
    ["function approve(address,uint256) returns (bool)"],
    lenderSigner
  );
  await (await pyusdAsLender.approve(addrs.Morpho, ethers.constants.MaxUint256)).wait();

  const morphoAsLender = new ethers.Contract(
    addrs.Morpho,
    [
      "function supply(tuple(address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) marketParams, uint256 assets, uint256 shares, address onBehalf, bytes data) returns (uint256, uint256)",
    ],
    lenderSigner
  );
  await (await morphoAsLender.supply(mp, supplyAmount, 0, LENDER, "0x")).wait();
  await rpc(provider, "anvil_stopImpersonatingAccount", [LENDER]);
  console.log(`  lender ${LENDER} supplied ${ethers.utils.formatUnits(supplyAmount, 6)} PYUSD0`);

  // Yearn router pulls WETH from the depositor into itself, then calls
  // vault.deposit which does `safeTransferFrom(router, vault)`. The router
  // needs a standing allowance to the vault for that to work. `approve` is
  // public on the router — anyone can call it; we just do it once here.
  console.log("\napproving WETH router → vault");
  const routerForApprove = new ethers.Contract(
    addrs.Yearn4626Router,
    ["function approve(address token, address to, uint256 amount) payable"],
    deployer
  );
  await (
    await routerForApprove.approve(WETH, addrs.FCMVault, ethers.constants.MaxUint256)
  ).wait();

  // Snapshot the post-deploy chain state so the frontend's "Reset chain"
  // button can revert here without a full redeploy.
  const finalSnapshotId = await rpc(provider, "evm_snapshot", []);
  const snapshotPath = join(
    __dirname,
    "..",
    "..",
    "nextjs",
    "contracts",
    "snapshot.ts"
  );
  writeFileSync(
    snapshotPath,
    `// Auto-generated by postDeploy.js — id of the post-deploy anvil snapshot.\nexport const SNAPSHOT_ID = "${finalSnapshotId}";\n`
  );
  console.log(`\nsnapshot id: ${finalSnapshotId} (written to ${snapshotPath})`);

  console.log("\npost-deploy bootstrap complete.");
}

if (!existsSync(join(__dirname, "..", "deployments", "31337.json"))) {
  console.error("no deployments/31337.json — run forge deploy first");
  process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
