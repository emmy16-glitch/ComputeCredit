#!/usr/bin/env node
/**
 * ComputeCredit orchestrator CLI.
 *
 * Spec reference: ComputeCredit_v2.pdf §11.1 (Orchestrator lifecycle), §11.3 (Telegram commands -
 * the same operations are exposed here as a CLI so the demo is not dependent on a chat platform),
 * §16 (Demo script).
 *
 *   npm run infer   -- --prompt "write a haiku" --borrower 0x...
 *   npm run pay     -- --amount 0.10 --borrower 0x...
 *   npm run pool
 *   npm run score   -- --borrower 0x...
 *   npm run history -- --borrower 0x...
 *   npm run monitor -- --borrower 0x...
 *   npm run demo                         # full local lifecycle incl. default + recovery
 *
 * Offchain checks are for user experience only; the vault re-checks every rule onchain.
 */
import { JsonRpcProvider, Wallet, Contract, parseUnits } from "ethers";

import { loadConfig, explorerLink, formatUnits } from "./config.ts";
import { Orchestrator } from "./revenueRouter.ts";
import { signingWallet } from "./chain.ts";

function arg(name: string, fallback?: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`);
  if (index !== -1 && process.argv[index + 1] && !process.argv[index + 1].startsWith("--")) {
    return process.argv[index + 1];
  }
  const inline = process.argv.find((value) => value.startsWith(`--${name}=`));
  if (inline) return inline.split("=").slice(1).join("=");
  return fallback;
}

function flag(name: string): boolean {
  return process.argv.includes(`--${name}`);
}

async function main(): Promise<void> {
  const cfg = loadConfig();
  const orchestrator = new Orchestrator(cfg);

  const command = process.argv[2] ?? "help";
  const borrower = arg("borrower") ?? process.env.BORROWER_ADDRESS ?? "";
  const pretty = (value: string) => value.replace(/\n\s*$/g, "");

  switch (command) {
    case "infer": {
      const prompt = arg("prompt", "write a haiku about compute credit")!;
      if (!borrower) throw new Error("--borrower (or BORROWER_ADDRESS) is required");
      const result = await orchestrator.runInference({
        borrower,
        prompt,
        paymentRef: arg("payment-ref"),
        buyerPaymentUsdc: arg("buyer-payment"),
      });
      console.log("=== ComputeCredit inference run ===");
      console.log(`borrower         : ${result.borrower}`);
      console.log(`provider         : ${result.provider} (${result.serviceId})`);
      console.log(`job hash         : ${result.jobHash}`);
      console.log(`compute cost     : ${orchestrator.cc.fmt(result.computeCost)}`);
      console.log(`advance needed   : ${result.advanceRequired}`);
      if (result.requestedAdvance) console.log(`advance tx       : ${explorerLink(cfg, result.requestedAdvance)}`);
      console.log(`provider paid    : ${result.providerPaid}`);
      if (result.providerPaymentTx) console.log(`provider tx      : ${explorerLink(cfg, result.providerPaymentTx)}`);
      console.log(`provider result  : ${result.providerResult.output}`);
      if (result.preview) {
        console.log(`buyer payment    : services ${orchestrator.cc.fmt(result.preview.serviceAmount)}, ` +
          `borrower keeps ${orchestrator.cc.fmt(result.preview.borrowerAmount)}` +
          (result.preview.lienActive ? " (lien active: captured toward the lien target)" : ""));
      }
      console.log("notes:");
      for (const note of result.notes) console.log(`  - ${note}`);
      break;
    }

    case "pay": {
      if (!borrower) throw new Error("--borrower (or BORROWER_ADDRESS) is required");
      const amount = arg("amount", "0.10")!;
      const result = await orchestrator.routeBuyerPayment(borrower, amount, arg("payment-ref"));
      console.log("=== routed buyer payment ===");
      for (const [key, value] of Object.entries(result)) console.log(`${key.padEnd(15)}: ${value}`);
      break;
    }

    case "pool": {
      console.log(pretty(await orchestrator.poolReport()));
      break;
    }

    case "score": {
      if (!borrower) throw new Error("--borrower (or BORROWER_ADDRESS) is required");
      console.log(pretty(await orchestrator.borrowerReport(borrower)));
      break;
    }

    case "history": {
      if (!borrower) throw new Error("--borrower (or BORROWER_ADDRESS) is required");
      console.log(await historyReport(orchestrator, borrower));
      break;
    }

    case "monitor": {
      const targets = borrower ? [borrower] : (process.env.BORROWERS ?? "").split(",").filter(Boolean);
      if (targets.length === 0) throw new Error("--borrower or BORROWERS is required");
      const actions = await orchestrator.monitorAndPenalize(targets, arg("keeper-key"));
      for (const action of actions) console.log(`- ${action}`);
      break;
    }

    case "demo": {
      await runDemo(orchestrator, flag("skip-provider-payment"));
      break;
    }

    default:
      console.log(`ComputeCredit orchestrator

Usage: node --experimental-strip-types index.ts <command> [--flags]

Commands
  infer    --prompt <text> [--borrower <addr>] [--buyer-payment 0.10]  quote, finance, pay the provider
  pay      --amount <usdc> [--borrower <addr>] [--payment-ref <ref>]    route a buyer payment
  pool                                                                  idle assets, shares, outstanding, utilisation
  score    --borrower <addr>                                            score, tier, advance, lien
  history  --borrower <addr>                                            advances, servicing, settlement, default
  monitor  --borrower <addr>                                            expiry watch and permissionless penalize
  demo                                                                  full local lifecycle (requires DRY_RUN=false)

Configuration comes from the environment: see .env.example.
MVP trust assumptions (spec §3.1): the orchestrator is a trusted operator in this prototype.`);
  }
}

async function historyReport(orchestrator: Orchestrator, borrower: string): Promise<string> {
  const count = Number(await orchestrator.cc.vault.advanceHistoryCount(borrower));
  const lines = [`advances issued for ${borrower}: ${count}`];
  for (let index = 0; index < count; index += 1) {
    const a = await orchestrator.cc.vault.advanceHistoryAt(borrower, index);
    // `advanceHistoryAt` is the issuance record (an immutable snapshot). Current status comes from
    // the servicing / settlement / default events below and from the live advance view.
    lines.push(
      `  issued #${index}: principal=${orchestrator.cc.fmt(a.principal)} at ${new Date(
        Number(a.issuedAt) * 1000,
      ).toISOString()} job=${String(a.jobHash).slice(0, 14)}...`,
    );
  }

  // Onchain event history: servicing, settlement and default records.
  const filter = orchestrator.cc.vault.filters.AdvanceServiced(borrower);
  const events = await orchestrator.cc.vault.queryFilter(filter, 0, "latest");
  lines.push(`servicing events: ${events.length}`);
  for (const event of events.slice(-10)) {
    const args = (event as any).args;
    lines.push(
      `  block ${event.blockNumber}: serviced=${orchestrator.cc.fmt(args[1])} remaining=${orchestrator.cc.fmt(
        args[3],
      )} settled=${args[4]}`,
    );
  }
  return lines.join("\n");
}

/**
 * Full local lifecycle used by the Quickstart: deposit, advance, provider payment, buyer revenue,
 * settlement, a partial servicing case, then a default with conditional recovery.
 * Time travel uses the node's evm RPCs, which only exist on development chains.
 */
async function runDemo(orchestrator: Orchestrator, skipProviderPayment: boolean): Promise<void> {
  const cfg = orchestrator.cfg;
  const cc = orchestrator.cc;
  const borrower = process.env.BORROWER_ADDRESS ?? "";
  const lenderKey = cfg.lenderPrivateKey;
  if (!borrower || !lenderKey) throw new Error("BORROWER_ADDRESS and LENDER_PRIVATE_KEY are required for demo");

  const provider = new JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
  const borrowerWallet = new Wallet(cfg.borrowerPrivateKey ?? cfg.operatorPrivateKey, provider);

  const lender = signingWallet(lenderKey, provider);
  const deposit = cc.units(process.env.DEMO_DEPOSIT_USDC ?? "50");
  const buyer = signingWallet(cfg.buyerPrivateKey ?? cfg.operatorPrivateKey, provider);
  const buyerPayment = cc.units(process.env.BUYER_PAYMENT_USDC ?? "0.10");

  // Preflight: the demo moves real tokens. Fail with an actionable message instead of a raw
  // ERC20 revert halfway through the sequence.
  const lenderBalance = await cc.balanceOf(await lender.getAddress());
  if (lenderBalance < deposit) {
    throw new Error(
      `lender ${await lender.getAddress()} holds ${cc.fmt(lenderBalance)} but the demo deposits ${cc.fmt(deposit)}. ` +
        "Fund the demo actors first (scripts/demo-local.sh funds all of them) or point LENDER_PRIVATE_KEY at a funded account.",
    );
  }
  const buyerBalance = await cc.balanceOf(await buyer.getAddress());
  if (buyerBalance < buyerPayment) {
    throw new Error(
      `buyer ${await buyer.getAddress()} holds ${cc.fmt(buyerBalance)} but the demo routes ${cc.fmt(buyerPayment)} of revenue. ` +
        "Fund the buyer first (scripts/demo-local.sh funds all demo actors).",
    );
  }

  console.log("== step 1: lender deposit ==");
  const vaultAsLender = cc.vault.connect(lender) as any;
  const usdcAsLender = cc.requireUsdc().connect(lender) as any;
  if ((await cc.requireUsdc().allowance(await lender.getAddress(), cfg.vaultAddress)) < deposit) {
    await (await usdcAsLender.approve(cfg.vaultAddress, deposit)).wait();
  }
  const depositTx = await vaultAsLender.depositLiquidity(deposit);
  await depositTx.wait();
  console.log(`  deposited ${cc.fmt(deposit)} -> shares ${await cc.vault.totalShares()}`);

  console.log("== steps 2-8: advance + provider payment ==");
  const run = await orchestrator.runInference({ borrower, prompt: "write a haiku about liquidity" });
  console.log(`  advance required: ${run.advanceRequired}; provider paid: ${run.providerPaid}`);

  console.log("== steps 10-11: buyer revenue serviced through the registered route ==");
  const routed = await orchestrator.routeBuyerPayment(borrower, process.env.BUYER_PAYMENT_USDC ?? "0.10");
  for (const [key, value] of Object.entries(routed)) console.log(`  ${key.padEnd(14)}: ${value}`);

  console.log("== partial servicing: a smaller payment services only part of the principal ==");
  let advance = await cc.advanceOf(borrower);
  if (!advance.active) {
    // The first advance settled exactly; open a fresh one so the partial rule can be shown.
    await orchestrator.runInference({ borrower, prompt: "second job (partial servicing demo)", forceAdvance: true });
    advance = await cc.advanceOf(borrower);
  }
  if (advance.active) {
    const partial = await orchestrator.routeBuyerPayment(borrower, "0.05");
    for (const [key, value] of Object.entries(partial)) console.log(`  ${key.padEnd(14)}: ${value}`);
  } else {
    console.log("  no active advance; skipping the partial case");
  }

  console.log("== default and conditional recovery ==");
  // The partially serviced advance is deliberately left to expire without further revenue.
  const advanceToDefault = await cc.advanceOf(borrower);
  if (!advanceToDefault.active) {
    console.log("  no active advance to default; skipping");
  } else {
    const windowSeconds = Number(process.env.ADVANCE_WINDOW ?? 43_200) + 1;
    try {
      await provider.send("evm_increaseTime", [windowSeconds]);
      await provider.send("evm_mine", []);
      console.log(`  chain clock advanced by ${windowSeconds}s`);
    } catch (error) {
      console.log(`  this RPC does not allow time travel (${(error as Error).message.split("\n")[0]})`);
      console.log("  on a testnet the default path must wait for the real deadline");
    }

    const actions = await orchestrator.monitorAndPenalize([borrower]);
    for (const action of actions) console.log(`  - ${action}`);

    // A payment smaller than the remaining target: part is captured, the rest reaches the agent.
    const recovery = await orchestrator.routeBuyerPayment(borrower, "0.01");
    console.log(`  recovery payment captured ${recovery.lienCapture}, forwarded ${recovery.borrowerAmount}`);
    // A payment larger than the remaining target: capture stops at exactly the target.
    const clearing = await orchestrator.routeBuyerPayment(borrower, "0.05");
    console.log(`  clearing payment captured ${clearing.lienCapture}, forwarded ${clearing.borrowerAmount}`);
  }

  console.log("== final pool state ==");
  console.log((await orchestrator.poolReport()).replace(/^/gm, "  "));
  if (!skipProviderPayment) {
    console.log(`\nBorrower wallet: ${borrowerWallet.address}`);
  }
}

main().catch((error) => {
  console.error(`orchestrator error: ${error.message}`);
  process.exitCode = 1;
});
