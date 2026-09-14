import type { Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ADDR, clients, vaultAbi, passportAbi, registryAbi, erc20Abi, jobHash } from "./config.js";

/**
 * Orchestrator lifecycle (offchain checks are UX only — vault is the authority):
 * 1. read borrower balance / score / tier limit / provider price
 * 2. pay directly if funded, else request one compute advance:
 *    - production path (preferred): borrower EIP-712 signature via BORROWER_PRIVATE_KEY
 *      submitted with requestAdvanceWithSig (works even in sigOnlyMode)
 *    - demo path: operator requestAdvanceFor (disabled when vault sigOnlyMode is on)
 * 3. pay provider exact cost, return result to buyer
 * 4. buyer revenue is routed via RevenueRouter.routePayment (split enforced onchain;
 *    on facilitator-supported chains the FacilitatorAdapter records the x402 intent)
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
    const borrowerKey = process.env.BORROWER_PRIVATE_KEY as `0x${string}` | undefined;
    let tx: `0x${string}`;
    if (borrowerKey) {
      // Trust-minimized path: borrower signs the EIP-712 intent; anyone submits.
      const borrowerAccount = privateKeyToAccount(borrowerKey);
      if (borrowerAccount.address.toLowerCase() !== borrower.toLowerCase()) {
        throw new Error(`BORROWER_PRIVATE_KEY does not match borrower ${borrower}`);
      }
      const onchainNonce = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "nonces", args: [borrower] })) as bigint;
      const domain = { name: "ComputeCreditVault", version: "3", chainId: 1952, verifyingContract: ADDR.vault } as const;
      const types = {
        AdvanceIntent: [
          { name: "borrower", type: "address" },
          { name: "provider", type: "address" },
          { name: "cost", type: "uint256" },
          { name: "jobHash", type: "bytes32" },
          { name: "revenueSource", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "expiry", type: "uint256" },
        ],
      } as const;
      const sig = await (borrowerAccount as any).signTypedData({
        domain, types,
        primaryType: "AdvanceIntent",
        message: { borrower, provider, cost: price, jobHash: hash, revenueSource: borrower, nonce: onchainNonce, expiry },
      });
      tx = await wallet.writeContract({
        address: ADDR.vault, abi: vaultAbi, functionName: "requestAdvanceWithSig",
        args: [borrower, provider, price, hash, borrower, onchainNonce, expiry, sig],
      });
      console.log(`advance (sig) tx: ${tx}`);
    } else {
      tx = await wallet.writeContract({
        address: ADDR.vault, abi: vaultAbi, functionName: "requestAdvanceFor",
        args: [borrower, provider, price, hash, borrower],
      });
      console.log(`advance tx: ${tx}`);
    }
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
