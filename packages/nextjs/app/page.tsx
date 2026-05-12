"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { encodeAbiParameters, encodeFunctionData, formatUnits, keccak256, pad, parseUnits, toHex } from "viem";
import { useAccount, usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import { BugAntIcon, MagnifyingGlassIcon } from "@heroicons/react/24/outline";
import deployedContracts from "~~/contracts/deployedContracts";
import { SNAPSHOT_ID } from "~~/contracts/snapshot";
import { useScaffoldReadContract, useScaffoldWriteContract, useTargetNetwork } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

// Aave V3 numeric revert codes (subset most likely to hit during demos).
const AAVE_ERRORS: Record<string, string> = {
  "1": "caller not pool admin",
  "26": "invalid amount",
  "27": "reserve inactive",
  "28": "reserve frozen",
  "29": "reserve paused",
  "30": "borrowing not enabled",
  "31": "stable borrowing not enabled",
  "32": "no debt of selected type",
  "33": "invalid interest rate mode",
  "34": "collateral balance is 0",
  "35": "HF below liquidation threshold",
  "36": "collateral can't cover new borrow",
  "37": "collateral == borrow currency",
  "38": "amount > max loan size stable",
  "39": "no debt of selected type",
  "43": "borrow cap exceeded",
  "44": "supply cap exceeded",
  "45": "HF not below threshold (can't liquidate)",
  "46": "collateral can't be liquidated",
  "47": "user didn't borrow that currency",
};

// Uniswap V3 / PunchSwap V3 short revert codes.
const UNIV3_ERRORS: Record<string, string> = {
  AS: "amountSpecified == 0 (swap with zero amount)",
  AI: "pool already initialized",
  L: "pool not initialized (slot0.sqrtPriceX96 == 0)",
  LO: "tickLower out of range",
  TLU: "tickLower > tickUpper",
  TLM: "tick out of MIN/MAX bounds",
  SPL: "sqrtPriceLimitX96 outside valid range",
  IIA: "invalid input amount",
  M0: "amount0Owed not paid in mint callback",
  M1: "amount1Owed not paid in mint callback",
};

const explainError = (e: any): string => {
  const raw = e?.shortMessage ?? e?.cause?.shortMessage ?? e?.details ?? e?.message ?? String(e);
  const num = raw.match(/reverted with the following reason:\s*(\d+)/);
  if (num && AAVE_ERRORS[num[1]]) return `${raw}\n→ Aave: ${AAVE_ERRORS[num[1]]}`;
  const str = raw.match(/reverted with the following reason:\s*([A-Z0-9]{1,4})\b/);
  if (str && UNIV3_ERRORS[str[1]]) return `${raw}\n→ UniV3: ${UNIV3_ERRORS[str[1]]}`;
  return raw;
};

const WETH = "0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590" as const;
const PYUSD = "0x99aF3EeA856556646C98c8B9b2548Fe815240750" as const;
const SWAP_FACTORY = "0xca6d7Bb03334bBf135902e1d919a5feccb461632" as const;
// FlowSwap V3 fee tiers — different per pair.
const FEE_YIELD_DEBT = 100; // 0.01% — YIELD/PYUSD0
const FEE_DEBT_COLL = 3000; // 0.30% — WETH/PYUSD0

const factoryAbi = [
  {
    type: "function",
    name: "getPool",
    stateMutability: "view",
    inputs: [
      { name: "tokenA", type: "address" },
      { name: "tokenB", type: "address" },
      { name: "fee", type: "uint24" },
    ],
    outputs: [{ name: "pool", type: "address" }],
  },
] as const;

const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

// Integer sqrt for BigInt — Newton's method.
const bigintSqrt = (n: bigint): bigint => {
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
};

// Move a Uniswap-V3-style pool's `slot0` to a new sqrtPriceX96 derived from
// `humanPrice0In1` (= human-units-of-token1 per 1 human-unit-of-token0). Pool
// must have full-range liquidity already (we seeded it that way).
const setPoolPrice = async (
  publicClient: any,
  pool: `0x${string}`,
  dec0: number,
  dec1: number,
  humanPrice0In1: number,
) => {
  const priceE18 = BigInt(Math.round(humanPrice0In1 * 1e18));
  const num = priceE18 * 10n ** BigInt(dec1) * (1n << 192n);
  const denom = 10n ** 18n * 10n ** BigInt(dec0);
  const sqrtPriceX96 = bigintSqrt(num / denom);

  const ratio = humanPrice0In1 * 10 ** (dec1 - dec0);
  const tickNum = Math.floor(Math.log(ratio) / Math.log(1.0001));
  const tick24 = tickNum < 0 ? BigInt(tickNum) + (1n << 24n) : BigInt(tickNum);

  // slot0 layout: [0..160) sqrtPriceX96, [160..184) int24 tick, [184..256) the rest.
  const existingHex = await publicClient.request({
    method: "eth_getStorageAt",
    params: [pool, "0x0", "latest"],
  });
  const existing = BigInt(existingHex);
  const upperMask = ~((1n << 184n) - 1n);
  const newWord = (existing & upperMask) | (tick24 << 160n) | sqrtPriceX96;
  const newHex = "0x" + newWord.toString(16).padStart(64, "0");

  await publicClient.request({
    method: "anvil_setStorageAt",
    params: [pool, "0x0", newHex],
  });
  // anvil_setStorageAt doesn't bump the block — mine one so wagmi refetches.
  await publicClient.request({
    method: "anvil_mine",
    params: ["0x1"],
  });
};

const Stat = ({
  label,
  value,
  sub,
  tone,
}: {
  label: string;
  value: string;
  sub?: string;
  tone?: "ok" | "warn" | "danger";
}) => (
  <div className="flex justify-between items-baseline gap-4 py-1 border-b border-base-300 last:border-0">
    <span className="text-sm opacity-70">{label}</span>
    <span className="text-right">
      <span
        className={`font-mono ${
          tone === "danger" ? "text-error" : tone === "warn" ? "text-warning" : tone === "ok" ? "text-success" : ""
        }`}
      >
        {value}
      </span>
      {sub && <div className="text-xs opacity-60 font-mono">{sub}</div>}
    </span>
  </div>
);

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();
  const { targetNetwork } = useTargetNetwork();

  const [depositAmount, setDepositAmount] = useState("");
  const [redeemShares, setRedeemShares] = useState("");
  const [wethPriceUsd, setWethPriceUsd] = useState("");
  const [targetHf, setTargetHf] = useState("1.20");
  const [yieldPriceUsd, setYieldPriceUsd] = useState("1.00");

  const vaultAddr = deployedContracts[31337].FCMVault.address as `0x${string}`;

  const { data: totalAssets } = useScaffoldReadContract({
    contractName: "FCMVault",
    functionName: "totalAssets",
  });

  const { data: shareBalance } = useScaffoldReadContract({
    contractName: "FCMVault",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: shareValueWeth } = useScaffoldReadContract({
    contractName: "FCMVault",
    functionName: "convertToAssets",
    args: [shareBalance],
  });

  const { data: yieldAssetAddr } = useScaffoldReadContract({
    contractName: "FCMVault",
    functionName: "yieldAsset",
  });

  const wethSrcAddr = deployedContracts[31337].WethPriceSource?.address as `0x${string}` | undefined;
  const pyusdSrcAddr = deployedContracts[31337].Pyusd0PriceSource?.address as `0x${string}` | undefined;
  const v3SrcAddr = deployedContracts[31337].V3PoolPriceSource?.address as `0x${string}` | undefined;

  const aggregatorAbi = [
    {
      type: "function",
      name: "latestAnswer",
      stateMutability: "view",
      inputs: [],
      outputs: [{ type: "int256" }],
    },
  ] as const;

  const { data: stats } = useReadContracts({
    allowFailure: true,
    query: { refetchInterval: 4000 },
    contracts: [
      // 0: WETH balance of user
      { address: WETH, abi: erc20Abi, functionName: "balanceOf", args: [connectedAddress!] },
      // 1: vault collateral (WETH on Morpho)
      { address: vaultAddr, abi: deployedContracts[31337].FCMVault.abi, functionName: "collateral" },
      // 2: vault debt (PYUSD0)
      { address: vaultAddr, abi: deployedContracts[31337].FCMVault.abi, functionName: "debt" },
      // 3: yield bal of vault
      { address: yieldAssetAddr, abi: erc20Abi, functionName: "balanceOf", args: [vaultAddr] },
      // 4: WETH price (1e8 base)
      { address: wethSrcAddr, abi: aggregatorAbi, functionName: "latestAnswer" },
      // 5: PYUSD0 price (1e8)
      { address: pyusdSrcAddr, abi: aggregatorAbi, functionName: "latestAnswer" },
      // 6: yield price (1e8, from V3 pool)
      { address: v3SrcAddr, abi: aggregatorAbi, functionName: "latestAnswer" },
      // 7: vault health factor (1e18, type(uint256).max if no debt)
      { address: vaultAddr, abi: deployedContracts[31337].FCMVault.abi, functionName: "healthFactor" },
      // 8: PYUSD0↔WETH pool address (for slot0-override "Set Price" buttons)
      { address: SWAP_FACTORY, abi: factoryAbi, functionName: "getPool", args: [WETH, PYUSD, FEE_DEBT_COLL] },
      // 9: PYUSD0↔yield pool address
      {
        address: SWAP_FACTORY,
        abi: factoryAbi,
        functionName: "getPool",
        args: [yieldAssetAddr!, PYUSD, FEE_YIELD_DEBT],
      },
      // 10: yield-token decimals
      {
        address: yieldAssetAddr,
        abi: [
          { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
        ] as const,
        functionName: "decimals",
      },
    ],
  });

  const yieldPoolAddrEarly = stats?.[9]?.result as `0x${string}` | undefined;
  const yieldDecimalsRead = stats?.[10]?.result as number | undefined;

  const { data: poolStats } = useReadContracts({
    allowFailure: true,
    query: {
      refetchInterval: 4000,
      enabled: !!yieldPoolAddrEarly && !!yieldAssetAddr,
    },
    contracts: [
      // 0: PYUSD reserve of the yield pool
      { address: PYUSD, abi: erc20Abi, functionName: "balanceOf", args: [yieldPoolAddrEarly!] },
      // 1: yield-token reserve of the pool
      { address: yieldAssetAddr, abi: erc20Abi, functionName: "balanceOf", args: [yieldPoolAddrEarly!] },
    ],
  });

  // disableSimulate so reverting txs are actually broadcast and land on-chain
  // — otherwise SE-2 simulates first and aborts client-side, and the failing
  // tx never appears in the block explorer (no hash to inspect with cast run).
  const { writeContractAsync: writeVault, isPending: depositPending } = useScaffoldWriteContract({
    contractName: "FCMVault",
    disableSimulate: true,
  });
  const { writeContractAsync: writePrice, isPending: pricePending } = useScaffoldWriteContract({
    contractName: "WethPriceSource",
    disableSimulate: true,
  });
  const { writeContractAsync: writeErc20 } = useWriteContract();
  const publicClient = usePublicClient();

  const handleResetChain = async () => {
    if (!publicClient) return;
    if (!confirm("Revert the chain to the post-deploy snapshot? All txs since then will be lost.")) return;
    try {
      // Use the most recent snapshot — the deploy-time one initially, or the
      // one created by the previous Reset.
      const id = (typeof window !== "undefined" && window.localStorage.getItem("snapshotId")) || SNAPSHOT_ID;

      const ok = await publicClient.request({
        method: "evm_revert" as any,
        params: [id] as any,
      });
      if (!ok) throw new Error("evm_revert returned false (snapshot stale?)");

      // evm_revert consumes the snapshot — take a new one of the same state.
      const newId = await publicClient.request({
        method: "evm_snapshot" as any,
        params: [] as any,
      });
      window.localStorage.setItem("snapshotId", newId as string);

      notification.success("chain reverted to post-deploy state");
      // Refresh so wagmi re-reads everything against the reverted state.
      window.location.reload();
    } catch (e: any) {
      notification.error(explainError(e));
    }
  };

  // A second hardcoded EOA, used by the "other user" demo button. Anvil signs
  // for it via anvil_impersonateAccount.
  const OTHER_USER = "0x000000000000000000000000000000000000b0b0" as const;
  const LIQUIDATOR = "0x000000000000000000000000000000000000c0c0" as const;

  const handleOtherUserDeposit = async () => {
    if (!publicClient || !depositAmount) return;
    try {
      const amount = parseUnits(depositAmount, 18);

      await publicClient.request({
        method: "anvil_impersonateAccount" as any,
        params: [OTHER_USER] as any,
      });
      await publicClient.request({
        method: "anvil_setBalance" as any,
        params: [OTHER_USER, "0x56BC75E2D63100000"] as any, // 100 ETH gas
      });

      // Give them `amount` WETH via storage write (slot 1).
      const slot = 1n;
      const key = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [OTHER_USER, slot]));
      const target = pad(toHex(amount), { size: 32 });
      await publicClient.request({
        method: "anvil_setStorageAt" as any,
        params: [WETH, key, target] as any,
      });

      // approve(vault, amount)
      const approveData =
        "0x095ea7b3" + vaultAddr.slice(2).padStart(64, "0").toLowerCase() + amount.toString(16).padStart(64, "0");
      await publicClient.request({
        method: "eth_sendTransaction" as any,
        params: [{ from: OTHER_USER, to: WETH, data: approveData, gas: "0x186a0" }] as any,
      });

      // deposit(amount, OTHER_USER) — selector 6e553f65
      const depositData =
        "0x6e553f65" + amount.toString(16).padStart(64, "0") + OTHER_USER.slice(2).padStart(64, "0").toLowerCase();
      await publicClient.request({
        method: "eth_sendTransaction" as any,
        params: [{ from: OTHER_USER, to: vaultAddr, data: depositData, gas: "0x7a1200" }] as any,
      });

      await publicClient.request({
        method: "anvil_stopImpersonatingAccount" as any,
        params: [OTHER_USER] as any,
      });

      notification.success(`other user deposited ${depositAmount} WETH`);
    } catch (e: any) {
      try {
        await publicClient.request({
          method: "anvil_stopImpersonatingAccount" as any,
          params: [OTHER_USER] as any,
        });
      } catch {}
      notification.error(explainError(e));
    }
  };

  const handleLiquidate = async () => {
    if (!publicClient) return;
    const morphoAddr = deployedContracts[31337].Morpho.address as `0x${string}`;
    try {
      // Impersonate + fund with native gas.
      await publicClient.request({
        method: "anvil_impersonateAccount" as any,
        params: [LIQUIDATOR] as any,
      });
      await publicClient.request({
        method: "anvil_setBalance" as any,
        params: [LIQUIDATOR, "0x56BC75E2D63100000"] as any,
      });

      // Fund liquidator with PYUSD0 via storage write (slot 1, 1M).
      const slot = 1n;
      const key = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [LIQUIDATOR, slot]));
      const target = pad(toHex(parseUnits("1000000", 6)), { size: 32 });
      await publicClient.request({
        method: "anvil_setStorageAt" as any,
        params: [PYUSD, key, target] as any,
      });

      // approve(Morpho, max) on PYUSD0
      const approveData = "0x095ea7b3" + morphoAddr.slice(2).padStart(64, "0").toLowerCase() + "f".repeat(64);
      await publicClient.request({
        method: "eth_sendTransaction" as any,
        params: [{ from: LIQUIDATOR, to: PYUSD, data: approveData, gas: "0x186a0" }] as any,
      });

      // Read the vault's current marketParams + borrowShares so we know what
      // to pass to morpho.liquidate. We seize the full position by passing
      // `repaidShares = position.borrowShares` (and seizedAssets = 0).
      const mp = (await publicClient.readContract({
        address: vaultAddr,
        abi: deployedContracts[31337].FCMVault.abi,
        functionName: "marketParams",
      })) as {
        loanToken: `0x${string}`;
        collateralToken: `0x${string}`;
        oracle: `0x${string}`;
        irm: `0x${string}`;
        lltv: bigint;
      };

      const marketId = (await publicClient.readContract({
        address: vaultAddr,
        abi: deployedContracts[31337].FCMVault.abi,
        functionName: "marketId",
      })) as `0x${string}`;

      const position = (await publicClient.readContract({
        address: morphoAddr,
        abi: deployedContracts[31337].Morpho.abi,
        functionName: "position",
        args: [marketId, vaultAddr],
      })) as readonly [bigint, bigint, bigint]; // (supplyShares, borrowShares, collateral)
      const borrowShares = position[1];

      const liqData = encodeFunctionData({
        abi: deployedContracts[31337].Morpho.abi,
        functionName: "liquidate",
        args: [mp, vaultAddr, 0n, borrowShares, "0x"],
      });
      const txHash = (await publicClient.request({
        method: "eth_sendTransaction" as any,
        params: [{ from: LIQUIDATOR, to: morphoAddr, data: liqData, gas: "0xf42400" }] as any,
      })) as `0x${string}`;

      const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

      await publicClient.request({
        method: "anvil_stopImpersonatingAccount" as any,
        params: [LIQUIDATOR] as any,
      });

      if (receipt.status !== "success") {
        throw new Error("morpho.liquidate reverted (HF likely ≥ 1)");
      }
      notification.success("liquidation succeeded");
    } catch (e: any) {
      try {
        await publicClient.request({
          method: "anvil_stopImpersonatingAccount" as any,
          params: [LIQUIDATOR] as any,
        });
      } catch {}
      notification.error(explainError(e));
    }
  };

  // Devnet faucet: write into the WETH `_balances` mapping via anvil_setStorageAt.
  // Slot 1 is verified by postDeploy.js for the bridged WETH on Flow EVM.
  const handleGetWeth = async () => {
    if (!connectedAddress || !publicClient) return;
    try {
      const slot = 1n;
      const key = keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [connectedAddress, slot]));
      const target = pad(toHex(parseUnits("10", 18)), { size: 32 });
      await publicClient.request({
        method: "anvil_setStorageAt" as any,
        params: [WETH, key, target] as any,
      });
      await publicClient.request({
        method: "anvil_mine" as any,
        params: ["0x1"] as any,
      });
      notification.success("got 10 WETH");
    } catch (e: any) {
      notification.error(explainError(e) ?? "faucet failed");
    }
  };

  const handleDeposit = async () => {
    if (!depositAmount || !connectedAddress) return;
    try {
      const amount = parseUnits(depositAmount, 18);
      notification.info("approving WETH...");
      await writeErc20({
        address: WETH,
        abi: erc20Abi,
        functionName: "approve",
        args: [vaultAddr, amount],
      });
      notification.info("depositing...");
      await writeVault({
        functionName: "deposit",
        args: [amount, connectedAddress],
        gas: 5_000_000n,
      });
      notification.success("deposit complete");
      setDepositAmount("");
    } catch (e: any) {
      notification.error(explainError(e) ?? "deposit failed");
    }
  };

  const handleRedeem = async () => {
    if (!redeemShares || !connectedAddress) return;
    try {
      const shares = parseUnits(redeemShares, 18);
      await writeVault({
        functionName: "redeem",
        args: [shares, connectedAddress, connectedAddress],
        gas: 8_000_000n,
      });
      notification.success("redeem complete");
      setRedeemShares("");
    } catch (e: any) {
      notification.error(explainError(e) ?? "redeem failed");
    }
  };

  const handleSetMaxShares = () => {
    if (shareBalance) setRedeemShares(formatUnits(shareBalance, 18));
  };

  const moveWethPool = async (priceUsd: number) => {
    if (!publicClient || !wethPoolAddr) return;
    // Pool sorts by address: WETH (0x2F..) < PYUSD (0x99..) → token0=WETH, token1=PYUSD.
    // 1 WETH = priceUsd PYUSD (we treat PYUSD ≈ $1).
    await setPoolPrice(publicClient, wethPoolAddr, 18, 6, priceUsd);
  };

  const moveYieldPool = async (priceUsd: number) => {
    if (!publicClient || !yieldPoolAddr || !yieldAssetAddr) return;
    // Determine token order at runtime — mYLD address is dynamic.
    const yieldIsToken0 = yieldAssetAddr.toLowerCase() < PYUSD.toLowerCase();
    if (yieldIsToken0) {
      // token0=mYLD (18), token1=PYUSD (6). 1 mYLD = priceUsd PYUSD.
      await setPoolPrice(publicClient, yieldPoolAddr, 18, 6, priceUsd);
    } else {
      // token0=PYUSD (6), token1=mYLD (18). 1 PYUSD = 1/priceUsd mYLD.
      await setPoolPrice(publicClient, yieldPoolAddr, 6, 18, 1 / priceUsd);
    }
  };

  const handleSetWethPrice = async () => {
    try {
      const priceFloat = parseFloat(wethPriceUsd);
      const priceWith8Decimals = BigInt(Math.round(priceFloat * 1e8));
      await writePrice({
        functionName: "setPrice",
        args: [priceWith8Decimals],
        gas: 200_000n,
      });
      await moveWethPool(priceFloat);
      notification.success(`WETH price → $${wethPriceUsd}`);
    } catch (e: any) {
      notification.error(explainError(e) ?? "setPrice failed");
    }
  };

  const handleSetYieldPrice = async () => {
    try {
      const priceFloat = parseFloat(yieldPriceUsd);
      await moveYieldPool(priceFloat);
      notification.success(`yield price → $${yieldPriceUsd}`);
    } catch (e: any) {
      notification.error(explainError(e) ?? "setPrice failed");
    }
  };

  // HF scales linearly with collateral price (HF = collat × LT / debt). To
  // hit a target HF we set p_target = p_current × HF_target / HF_current.
  const handleSetHealth = async () => {
    if (!hf || !pColl) {
      notification.error("HF/price not loaded yet");
      return;
    }
    try {
      const targetHfBig = parseUnits(targetHf, 18);
      const newPrice = (pColl * targetHfBig) / hf; // 1e8
      await writePrice({
        functionName: "setPrice",
        args: [newPrice],
        gas: 200_000n,
      });
      const newPriceUsd = Number(newPrice) / 1e8;
      await moveWethPool(newPriceUsd);
      setWethPriceUsd(newPriceUsd.toFixed(2));
      notification.success(`HF → ${targetHf} (WETH = $${newPriceUsd.toFixed(2)})`);
    } catch (e: any) {
      notification.error(explainError(e) ?? "setHealth failed");
    }
  };

  const handleRebalance = async () => {
    try {
      await writeVault({ functionName: "rebalance", gas: 5_000_000n });
      notification.success("rebalanced");
    } catch (e: any) {
      notification.error(explainError(e) ?? "rebalance failed");
    }
  };

  const fmtUnits = (v: bigint | undefined, dec: number) => (v === undefined ? "—" : formatUnits(v, dec));

  const userWeth = stats?.[0]?.result as bigint | undefined;
  const collat = stats?.[1]?.result as bigint | undefined; // 18 dec, in WETH
  const debtAmount = stats?.[2]?.result as bigint | undefined; // 6 dec, PYUSD
  const yieldAmount = stats?.[3]?.result as bigint | undefined; // 18 dec, mYLD
  const pColl = stats?.[4]?.result as bigint | undefined; // 1e8
  const pDebt = stats?.[5]?.result as bigint | undefined; // 1e8
  const pYield = stats?.[6]?.result as bigint | undefined; // 1e8
  const hf = stats?.[7]?.result as bigint | undefined;
  const wethPoolAddr = stats?.[8]?.result as `0x${string}` | undefined;
  const yieldPoolAddr = yieldPoolAddrEarly;
  const yieldDecimals = yieldDecimalsRead ?? 18;
  const poolPyusd = poolStats?.[0]?.result as bigint | undefined;
  const poolYield = poolStats?.[1]?.result as bigint | undefined;

  // debt (PYUSD, 6 dec) → WETH (18 dec): debt * pDebt * 1e12 / pColl
  const debtInColl = debtAmount && pDebt && pColl && pColl > 0n ? (debtAmount * pDebt * 10n ** 12n) / pColl : undefined;
  // yield (yieldDecimals) → WETH (18 dec): yield × pYield × 10^(18-yieldDec) / pColl
  const yieldInColl =
    yieldAmount && pYield && pColl && pColl > 0n
      ? (yieldAmount * pYield * 10n ** BigInt(18 - yieldDecimals)) / pColl
      : undefined;

  const yieldPriceUsdFmt = pYield ? (Number(pYield) / 1e8).toFixed(4) : "—";
  const wethPriceUsdFmt = pColl ? (Number(pColl) / 1e8).toFixed(2) : "—";
  // `vault.healthFactor()` returns type(uint256).max when there's no debt — render as "∞".
  const hfInfinite = hf !== undefined && hf > 10n ** 50n;
  const hfFmt = hf === undefined ? "—" : hfInfinite ? "∞" : Number(formatUnits(hf, 18)).toFixed(3);

  // Sync the WETH price input with the on-chain value once we have it.
  useEffect(() => {
    if (pColl && wethPriceUsd === "") {
      setWethPriceUsd((Number(pColl) / 1e8).toFixed(2));
    }
  }, [pColl, wethPriceUsd]);

  return (
    <div className="flex items-center flex-col grow pt-10 pb-16">
      <div className="px-5 w-full max-w-3xl">
        <div className="flex justify-end gap-2 mb-2">
          <button className="btn btn-xs btn-error" onClick={handleResetChain}>
            Reset chain
          </button>
        </div>
        <h1 className="text-center">
          <span className="block text-2xl mb-2">FCM</span>
          <span className="block text-4xl font-bold">Leveraged WETH Vault</span>
        </h1>

        <div className="flex justify-center items-center space-x-2 flex-col mb-6">
          <p className="my-2 font-medium">Connected:</p>
          <Address address={connectedAddress} chain={targetNetwork} />
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h3 className="card-title">Vault</h3>
              <Stat label="TVL" value={`${fmtUnits(totalAssets, 18)} WETH`} />
              <Stat label="WETH Price" value={`$${wethPriceUsdFmt}`} />
              <Stat label="Collateral" value={`${fmtUnits(collat, 18)} WETH`} />
              <Stat
                label="Debt"
                value={`${fmtUnits(debtAmount, 6)} PYUSD`}
                sub={`= ${fmtUnits(debtInColl, 18)} WETH`}
              />
              <Stat
                label="Yield"
                value={`${fmtUnits(yieldAmount, yieldDecimals)} yield`}
                sub={`= ${fmtUnits(yieldInColl, 18)} WETH`}
              />
              <Stat
                label="Health"
                value={hfFmt}
                tone={
                  !hf
                    ? undefined
                    : hfInfinite
                      ? "ok"
                      : hf < parseUnits("1.1", 18)
                        ? "danger"
                        : hf > parseUnits("1.5", 18)
                          ? "warn"
                          : "ok"
                }
              />
              <Stat label="Yield Token Price" value={`$${yieldPriceUsdFmt}`} />
            </div>
          </div>
          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h3 className="card-title">User Data</h3>
              <Stat label="WETH Balance" value={`${fmtUnits(userWeth, 18)} WETH`} />
              <Stat label="Your Shares" value={fmtUnits(shareBalance, 18)} />
              <Stat label="Shares Value" value={`${fmtUnits(shareValueWeth, 18)} WETH`} />
            </div>
          </div>
        </div>

        <div className="card bg-base-100 shadow-xl mb-6">
          <div className="card-body">
            <h3 className="card-title">Yield Pool (PYUSD ↔ yield)</h3>
            <Stat
              label="Pool"
              value={yieldPoolAddr ? `${yieldPoolAddr.slice(0, 6)}…${yieldPoolAddr.slice(-4)}` : "—"}
            />
            <Stat label="Price" value={`$${yieldPriceUsdFmt} per yield`} />
            <Stat label="Depth (PYUSD)" value={`${fmtUnits(poolPyusd, 6)} PYUSD`} />
            <Stat label="Depth (yield)" value={`${fmtUnits(poolYield, yieldDecimals)} yield`} />
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h2 className="card-title">Deposit</h2>
              <p className="text-sm opacity-70">
                Approve + deposit WETH. Vault levers it up via Morpho Blue + FlowSwap V3.
              </p>
              <input
                type="text"
                inputMode="decimal"
                className="input input-bordered"
                placeholder="WETH amount (e.g. 0.1)"
                value={depositAmount}
                onChange={e => setDepositAmount(e.target.value)}
              />
              <div className="card-actions justify-between flex-wrap">
                <button className="btn btn-ghost btn-sm" onClick={handleGetWeth}>
                  Get 10 WETH (devnet)
                </button>
                <div className="flex gap-2">
                  <button className="btn btn-secondary" disabled={!depositAmount} onClick={handleOtherUserDeposit}>
                    Other user
                  </button>
                  <button
                    className="btn btn-primary"
                    disabled={!depositAmount || depositPending}
                    onClick={handleDeposit}
                  >
                    {depositPending ? "depositing..." : "Deposit"}
                  </button>
                </div>
              </div>
            </div>
          </div>

          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h2 className="card-title">Redeem</h2>
              <p className="text-sm opacity-70">
                Burn shares via the flash-loan unwind. Pays out WETH net of swap slippage.
              </p>
              <input
                type="text"
                inputMode="decimal"
                className="input input-bordered"
                placeholder="shares to redeem"
                value={redeemShares}
                onChange={e => setRedeemShares(e.target.value)}
              />
              <div className="card-actions justify-between">
                <button className="btn btn-ghost btn-sm" onClick={handleSetMaxShares} disabled={!shareBalance}>
                  Max
                </button>
                <button className="btn btn-primary" disabled={!redeemShares || depositPending} onClick={handleRedeem}>
                  {depositPending ? "redeeming..." : "Redeem"}
                </button>
              </div>
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h2 className="card-title">Set Collateral (WETH) Price</h2>
              <p className="text-sm opacity-70">
                Writes a new WETH/USD price into the WethPriceSource. Moves the vault&apos;s health factor directly
                (Morpho market reads this same source).
              </p>
              <input
                type="text"
                inputMode="decimal"
                className="input input-bordered"
                value={wethPriceUsd}
                onChange={e => setWethPriceUsd(e.target.value)}
              />
              <div className="card-actions justify-end">
                <button
                  className="btn btn-secondary"
                  disabled={pricePending || !wethPriceUsd}
                  onClick={handleSetWethPrice}
                >
                  {pricePending ? "setting..." : "Set Price"}
                </button>
              </div>
            </div>
          </div>

          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h2 className="card-title">Set Health</h2>
              <p className="text-sm opacity-70">
                Computes the WETH price needed to hit a target HF (linear in collateral price) and sets it.
              </p>
              <input
                type="text"
                inputMode="decimal"
                className="input input-bordered"
                placeholder="target HF (e.g. 1.20)"
                value={targetHf}
                onChange={e => setTargetHf(e.target.value)}
              />
              <div className="card-actions justify-end">
                <button
                  className="btn btn-secondary"
                  disabled={pricePending || !targetHf || !hf}
                  onClick={handleSetHealth}
                >
                  Set Health
                </button>
              </div>
            </div>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-4 mb-4">
          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h2 className="card-title">Set Yield Token Price</h2>
              <p className="text-sm opacity-70">
                Pushes the PYUSD↔mYLD pool to a new price (slot0 override). V3PoolPriceSource picks it up
                automatically.
              </p>
              <input
                type="text"
                inputMode="decimal"
                className="input input-bordered"
                value={yieldPriceUsd}
                onChange={e => setYieldPriceUsd(e.target.value)}
              />
              <div className="card-actions justify-end">
                <button
                  className="btn btn-secondary"
                  disabled={!yieldPriceUsd || !yieldPoolAddr}
                  onClick={handleSetYieldPrice}
                >
                  Set Price
                </button>
              </div>
            </div>
          </div>

          <div className="card bg-base-100 shadow-xl">
            <div className="card-body">
              <h2 className="card-title">Rebalance / Liquidate</h2>
              <p className="text-sm opacity-70">
                Rebalance is permissionless and pulls HF back into [1.10, 1.50]. Liquidate impersonates a 3rd-party that
                calls Morpho&apos;s liquidate — only succeeds if HF &lt; 1.
              </p>
              <div className="card-actions justify-end">
                <button className="btn btn-error" onClick={handleLiquidate}>
                  Liquidate
                </button>
                <button className="btn btn-accent" disabled={depositPending} onClick={handleRebalance}>
                  Rebalance
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div className="grow bg-base-300 w-full mt-10 px-8 py-8">
        <div className="flex justify-center items-center gap-12 flex-col md:flex-row">
          <div className="flex flex-col bg-base-100 px-10 py-6 text-center items-center max-w-xs rounded-3xl">
            <BugAntIcon className="h-8 w-8 fill-secondary" />
            <p>
              Tinker with the vault using the{" "}
              <Link href="/debug" passHref className="link">
                Debug Contracts
              </Link>{" "}
              tab.
            </p>
          </div>
          <div className="flex flex-col bg-base-100 px-10 py-6 text-center items-center max-w-xs rounded-3xl">
            <MagnifyingGlassIcon className="h-8 w-8 fill-secondary" />
            <p>
              Explore local transactions with the{" "}
              <Link href="/blockexplorer" passHref className="link">
                Block Explorer
              </Link>{" "}
              tab.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
};

export default Home;
