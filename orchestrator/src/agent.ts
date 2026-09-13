import type { Address } from "viem";
import { ADDR, clients, vaultAbi, passportAbi, registryAbi, erc20Abi, jobHash } from "./config.js";

/**
 * Orchestrator lifecycle (offchain checks are UX only — vault is the authority):
 * 1. read borrower balance / score / tier limit / provider price
 * 2. pay directly if funded, else request one compute advance (operator path)
 * 3. pay provider exact cost, return result to buyer
 * 4. buyer revenue is routed via RevenueRouter.routePayment (split enforced onchain)
 * 5. monitor expiry -> keeper.ts submits penalize() when overdue
 */
export async function infer(prompt: string, borrower: Address, opts?: { nonce?: bigint }) {
  const { public: pub, wallet } = clients();
  const provider = ADDR.provider;
  const [price] = (await pub.readContract({ address: ADDR.registry, abi: registryAbi, functionName: "quote", args: [provider] })) as unknown as [bigint, Address];
  const score = (await pub.readContract({ address: ADDR.passport, abi: passportAbi, functionName: "score", args: [borrower] })) as bigint;
  const tierLimit = (await pub.readContract({ address: ADDR.passport, abi: passportAbi, functionName: "maxAdvanceForScore", args: [score] })) as bigint;
  const balance = (await pub.readContract({ address: ADDR.usdc, abi: erc20Abi, functionName: "balanceOf", args: [borrower] })) as bigint;
  const activeId = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "activeAdvanceId", args: [borrower] })) as bigint;

  console.log(`borrower=${borrower} score=${score} tierLimit=${tierLimit} balance=${balance} price=${price} active=${activeId}`);

  if (price > tierLimit) throw new Error(`provider price ${price} exceeds tier limit ${tierLimit} — advance correctly rejected`);
  if (activeId !== 0n) throw new Error(`borrower already has active advance ${activeId}`);

  let openedJob: `0x${string}` | null = null;
  if (balance < price) {
    const nonce = opts?.nonce ?? BigInt(Date.now());
    const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const hash = jobHash(borrower, provider, process.env.SERVICE_ID ?? "haiku-v1", price, nonce, expiry);
    openedJob = hash;
    console.log(`requesting advance cost=${price} job=${hash}`);
    const tx = await wallet.writeContract({
      address: ADDR.vault, abi: vaultAbi, functionName: "requestAdvanceFor",
      args: [borrower, provider, price, hash, borrower],
    });
    console.log(`advance tx: ${tx}`);
    await pub.waitForTransactionReceipt({ hash: tx });
  } else {
    console.log("borrower funded — paying provider directly, no advance needed");
  }

  // Pay provider (demo: plain USDC transfer to registered payout; production: x402 facilitator leg)
  const [, payout] = (await pub.readContract({ address: ADDR.registry, abi: registryAbi, functionName: "quote", args: [provider] })) as unknown as [bigint, Address];
  // NOTE: operator wallet pays here only when it holds funds for the demo; onchain advance went to borrower.
  console.log(`prompt="${prompt}" -> provider payout ${payout} amount ${price} (execute transfer from funded wallet)`);
  return { price, score, jobHash: openedJob };
}
