/* eslint-disable no-console */
// Post-deploy bootstrapping for the local Flow EVM fork.
//
// `forge script` deploys the contracts but cannot do the things that require
// privileged accounts on the fork: granting the deployer the Aave PoolAdmin
// role, swapping in our MockPriceSource for the yield token, funding the
// deployer with WETH/PYUSD, and seeding the two PunchSwap V3 pools.
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
const PUNCH_FACTORY = "0xf331959366032a634c7cAcF5852fE01ffdB84Af0";
const POOL_FEE = 3000;

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

  const vault = new ethers.Contract(
    addrs.FCMVault,
    [
      ...poolAbi,
      "function AAVE_POOL() view returns (address)",
      "function AAVE_ORACLE() view returns (address)",
    ],
    provider
  );
  const aavePool = await vault.AAVE_POOL();
  const aaveOracle = await vault.AAVE_ORACLE();
  const poolC = new ethers.Contract(aavePool, poolAbi, provider);
  const addrProviderAddr = await poolC.ADDRESSES_PROVIDER();
  const addrProvider = new ethers.Contract(addrProviderAddr, providerAbi, provider);
  const aclManagerAddr = await addrProvider.getACLManager();
  const aclAdminAddr = await addrProvider.getACLAdmin();

  console.log("aave pool:    ", aavePool);
  console.log("aave oracle:  ", aaveOracle);
  console.log("acl admin:    ", aclAdminAddr);
  console.log("acl manager:  ", aclManagerAddr);

  // 1. Impersonate the Aave ACL admin and grant the deployer PoolAdmin so the
  //    deployer can call `setAssetSources` on the oracle.
  console.log("\n[1/5] granting deployer PoolAdmin role");
  await impersonate(provider, aclAdminAddr);
  const adminSigner = provider.getSigner(aclAdminAddr);
  const aclAsAdmin = new ethers.Contract(aclManagerAddr, aclAbi, adminSigner);
  const isAdmin = await aclAsAdmin.isPoolAdmin(deployer.address);
  if (!isAdmin) {
    const tx = await aclAsAdmin.addPoolAdmin(deployer.address);
    await tx.wait();
  }
  await stop(provider, aclAdminAddr);

  // 2. Fund deployer with WETH and PYUSD via storage overwrite.
  console.log("\n[2/5] funding deployer with WETH + PYUSD");
  const wethTarget  = ethers.utils.parseUnits("200", 18);   // covers pool seed + buffer
  const pyusdTarget = ethers.utils.parseUnits("1300000", 6); // ~1.3M PYUSD
  await setErc20Balance(provider, WETH,  deployer.address, wethTarget);
  await setErc20Balance(provider, PYUSD, deployer.address, pyusdTarget);

  // 3. Mint mYLD, approve V3PoolHelper, seed the two pools.
  console.log("\n[3/5] seeding PunchSwap V3 pools");
  const yieldToken = new ethers.Contract(addrs.MockYieldToken, erc20Abi, deployer);
  const weth       = new ethers.Contract(WETH,  erc20Abi, deployer);
  const pyusd      = new ethers.Contract(PYUSD, erc20Abi, deployer);
  const yieldMint  = ethers.utils.parseUnits("1100000", 18); // 1.1M mYLD (with buffer)
  await (await yieldToken.mint(deployer.address, yieldMint)).wait();

  const max = ethers.constants.MaxUint256;
  await (await yieldToken.approve(addrs.V3PoolHelper, max)).wait();
  await (await weth.approve(addrs.V3PoolHelper, max)).wait();
  await (await pyusd.approve(addrs.V3PoolHelper, max)).wait();

  const helper = new ethers.Contract(addrs.V3PoolHelper, helperAbi, deployer);

  //   PYUSD ↔ mYLD: 1 PYUSD = 1 mYLD  → 1M PYUSD : 1M mYLD (initial yield price = $1).
  console.log("  seeding PYUSD↔mYLD");
  await (
    await helper.createAndFundPool(
      PYUSD,
      addrs.MockYieldToken,
      POOL_FEE,
      ethers.utils.parseUnits("1000000", 6),
      ethers.utils.parseUnits("1000000", 18)
    )
  ).wait();

  //   PYUSD ↔ WETH: 1 WETH ≈ 2344 PYUSD → 234.4k PYUSD : 100 WETH
  console.log("  seeding PYUSD↔WETH");
  await (
    await helper.createAndFundPool(
      PYUSD,
      WETH,
      POOL_FEE,
      ethers.utils.parseUnits("234400", 6),
      ethers.utils.parseUnits("100", 18)
    )
  ).wait();

  // 4. Deploy V3PoolPriceSource for the yield token (reads PYUSD↔mYLD pool).
  console.log("\n[4/5] deploying V3PoolPriceSource for yield token");
  const factory = new ethers.Contract(PUNCH_FACTORY, factoryAbi, provider);
  const yieldPoolAddr = await factory.getPool(
    PYUSD,
    addrs.MockYieldToken,
    POOL_FEE
  );
  console.log("  PYUSD↔mYLD pool:", yieldPoolAddr);

  const v3SrcArtifact = JSON.parse(
    readFileSync(
      join(__dirname, "..", "out", "V3PoolPriceSource.sol", "V3PoolPriceSource.json"),
      "utf8"
    )
  );
  const v3SrcFactory = new ethers.ContractFactory(
    v3SrcArtifact.abi,
    v3SrcArtifact.bytecode.object,
    deployer
  );
  const v3Source = await v3SrcFactory.deploy(
    yieldPoolAddr,
    addrs.MockYieldToken,
    PYUSD,
    aaveOracle
  );
  await v3Source.deployed();
  console.log("  V3PoolPriceSource:", v3Source.address);

  // 5. Seed MockPriceSource with the current Aave WETH price, then override
  //    the AaveOracle sources: WETH → MockPriceSource (settable),
  //    mYLD → V3PoolPriceSource (derived from pool).
  console.log("\n[5/5] overriding AaveOracle sources");
  const oracle = new ethers.Contract(aaveOracle, oracleAbi, deployer);
  const wethPriceNow = await oracle.getAssetPrice(WETH);
  console.log(`  current WETH price: $${(Number(wethPriceNow) / 1e8).toFixed(2)}`);

  const mockSource = new ethers.Contract(addrs.MockPriceSource, mockSourceAbi, deployer);
  await (await mockSource.setPrice(wethPriceNow)).wait();

  await (
    await oracle.setAssetSources(
      [WETH, addrs.MockYieldToken],
      [addrs.MockPriceSource, v3Source.address]
    )
  ).wait();

  const yieldPriceNow = await oracle.getAssetPrice(addrs.MockYieldToken);
  console.log(`  yield price (from pool): $${(Number(yieldPriceNow) / 1e8).toFixed(4)}`);

  const remainingWeth = await weth.balanceOf(deployer.address);
  console.log(`\ndeployer WETH balance: ${ethers.utils.formatEther(remainingWeth)}`);

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
