import type { Address } from "viem";
import { ADDR, clients, vaultAbi } from "./config.js";

/**
 * Keeper: permissionless default monitor. Anyone may call penalize() after expiry;
 * run on a cron (e.g. every 10 min) with borrower addresses in KEEPER_BORROWERS.
 *
 *   KEEPER_BORROWERS=0xabc,0xdef npx tsx orchestrator/src/keeper.ts
 *   npx tsx orchestrator/src/keeper.ts --watch 600   # loop every 600s
 */

const advanceAbi = [
  ...vaultAbi,
  { name: "advances", type: "function", stateMutability: "view",
    inputs: [{ name: "id", type: "uint256" }],
    outputs: [
      { name: "id", type: "uint256" }, { name: "borrower", type: "address" },
      { name: "provider", type: "address" }, { name: "principal", type: "uint256" },
      { name: "fee", type: "uint256" }, { name: "repaid", type: "uint256" },
      { name: "issuedAt", type: "uint256" }, { name: "dueAt", type: "uint256" },
      { name: "splitBps", type: "uint256" }, { name: "jobHash", type: "bytes32" },
      { name: "revenueSource", type: "address" }, { name: "status", type: "uint8" },
    ] },
] as const;

async function sweep(borrowers: Address[]) {
  const { public: pub, wallet } = clients();
  const now = BigInt(Math.floor(Date.now() / 1000));
  for (const b of borrowers) {
    const id = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "activeAdvanceId", args: [b] })) as bigint;
    if (id === 0n) { console.log(`${b}: no active advance`); continue; }
    const adv = (await pub.readContract({ address: ADDR.vault, abi: advanceAbi, functionName: "advances", args: [id] })) as unknown as { dueAt: bigint; status: number; principal: bigint; repaid: bigint };
    if (now <= adv.dueAt) { console.log(`${b}: advance ${id} due in ${adv.dueAt - now}s`); continue; }
    console.log(`${b}: advance ${id} OVERDUE — submitting penalize`);
    const tx = await wallet.writeContract({ address: ADDR.vault, abi: vaultAbi, functionName: "penalize", args: [b] });
    console.log(`penalize tx: ${tx}`);
    await pub.waitForTransactionReceipt({ hash: tx });
  }
}

const borrowers = (process.env.KEEPER_BORROWERS ?? "").split(",").filter(Boolean) as Address[];
if (borrowers.length === 0 && !process.argv.includes("--watch")) {
  console.error("Set KEEPER_BORROWERS=0x..,0x.. (comma-separated borrower addresses)");
  process.exit(1);
}
const watchIdx = process.argv.indexOf("--watch");
if (watchIdx >= 0) {
  const every = Number(process.argv[watchIdx + 1] ?? 600) * 1000;
  console.log(`keeper watching every ${every / 1000}s`);
  for (;;) { await sweep(borrowers).catch((e) => console.error("sweep failed:", e.message)); await new Promise((r) => setTimeout(r, every)); }
} else {
  await sweep(borrowers).catch((e) => { console.error(e.message); process.exit(1); });
}
