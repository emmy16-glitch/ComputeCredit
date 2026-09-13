import { Bot } from "grammy";
import { formatUnits, parseUnits, type Address } from "viem";
import { ADDR, clients, vaultAbi, passportAbi } from "../../orchestrator/src/config.js";
import { infer } from "../../orchestrator/src/agent.js";
import "dotenv/config";

/**
 * ComputeCredit Telegram bot — thin UI wrapper around the orchestrator + contracts.
 * - /invest /withdraw act from the OPERATOR demo wallet (clearly labelled proxy).
 * - Never bypasses contract checks; every rejection surfaces the revert reason.
 */
const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) { console.error("Set TELEGRAM_BOT_TOKEN in .env"); process.exit(1); }
const bot = new Bot(token);

const botVaultAbi = [
  ...vaultAbi,
  { name: "deposit", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "withdraw", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }, { name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "maxWithdraw", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

const usdcAbi = [
  { name: "approve", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "spender", type: "address" }, { name: "amount", type: "uint256" }], outputs: [{ type: "bool" }] },
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "mint", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [] },
] as const;

const historyEvents = [
  { name: "AdvanceRequested", type: "event",
    inputs: [{ name: "id", type: "uint256", indexed: true }, { name: "borrower", type: "address", indexed: true },
      { name: "provider", type: "address", indexed: true }, { name: "principal", type: "uint256" },
      { name: "fee", type: "uint256" }, { name: "jobHash", type: "bytes32" },
      { name: "revenueSource", type: "address" }, { name: "dueAt", type: "uint256" }] },
  { name: "AdvanceServiced", type: "event",
    inputs: [{ name: "id", type: "uint256", indexed: true }, { name: "borrower", type: "address", indexed: true },
      { name: "amount", type: "uint256" }, { name: "repaid", type: "uint256" }, { name: "remaining", type: "uint256" }] },
  { name: "AdvanceSettled", type: "event",
    inputs: [{ name: "id", type: "uint256", indexed: true }, { name: "borrower", type: "address", indexed: true }] },
  { name: "AdvanceDefaulted", type: "event",
    inputs: [{ name: "id", type: "uint256", indexed: true }, { name: "borrower", type: "address", indexed: true },
      { name: "shortfall", type: "uint256" }, { name: "lienTarget", type: "uint256" }] },
] as const;

const u = (v: bigint) => formatUnits(v, 6);
const arg = (text: string | undefined, i: number) => text?.split(/\s+/)[i];

bot.command("start", (ctx) => ctx.reply(
  "ComputeCredit v3 — one-job compute advances.\n" +
  "/infer <prompt> <borrower> — quote → advance → provider flow\n" +
  "/invest <usdc> — deposit from operator demo wallet\n" +
  "/withdraw <usdc> — withdraw idle share value\n" +
  "/position — operator shares + pool status\n" +
  "/pool — vault idle / outstanding\n" +
  "/score <addr> — score, tier, max advance\n" +
  "/id <addr> — active advance id\n" +
  "/history <addr> — advances, servicing, settlements, defaults\n" +
  "/faucet <addr> — mint demo MockUSDC (testnet only)"
));

bot.command("infer", async (ctx) => {
  const parts = (ctx.message?.text ?? "").split(/\s+/);
  const prompt = parts[1], borrower = parts[2] as Address;
  if (!prompt || !borrower) return ctx.reply("usage: /infer <prompt> <borrowerAddress>");
  try {
    const r = await infer(prompt, borrower);
    await ctx.reply(`advance ok. price=${u(r.price as bigint)} USDC score=${r.score}\njob=${r.jobHash}`);
  } catch (e: any) { await ctx.reply(`rejected: ${e.shortMessage ?? e.message}`); }
});

bot.command("invest", async (ctx) => {
  const amt = arg(ctx.message?.text, 1);
  if (!amt) return ctx.reply("usage: /invest <usdc_amount>  (e.g. /invest 10)");
  try {
    const { public: pub, wallet, account } = clients();
    const assets = parseUnits(amt, 6);
    const approveTx = await wallet.writeContract({ address: ADDR.usdc, abi: usdcAbi, functionName: "approve", args: [ADDR.vault, assets] });
    await pub.waitForTransactionReceipt({ hash: approveTx });
    const tx = await wallet.writeContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "deposit", args: [assets, account.address] });
    await pub.waitForTransactionReceipt({ hash: tx });
    const shares = (await pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "balanceOf", args: [account.address] })) as bigint;
    await ctx.reply(`deposited ${amt} USDC from operator demo wallet.\ntx=${tx}\noperator shares=${shares.toString()}\n(no guaranteed return — proportional claim on pool assets)`);
  } catch (e: any) { await ctx.reply(`deposit failed: ${e.shortMessage ?? e.message}`); }
});

bot.command("withdraw", async (ctx) => {
  const amt = arg(ctx.message?.text, 1);
  if (!amt) return ctx.reply("usage: /withdraw <usdc_amount>");
  try {
    const { public: pub, wallet, account } = clients();
    const assets = parseUnits(amt, 6);
    const max = (await pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "maxWithdraw", args: [account.address] })) as bigint;
    if (assets > max) return ctx.reply(`only ${u(max)} USDC withdrawable (rest backs live advances).`);
    const tx = await wallet.writeContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "withdraw", args: [assets, account.address, account.address] });
    await pub.waitForTransactionReceipt({ hash: tx });
    await ctx.reply(`withdrew ${amt} USDC. tx=${tx}`);
  } catch (e: any) { await ctx.reply(`withdraw failed: ${e.shortMessage ?? e.message}`); }
});

bot.command("position", async (ctx) => {
  const { public: pub, account } = clients();
  const [shares, max, idle, out] = await Promise.all([
    pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "balanceOf", args: [account.address] }),
    pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "maxWithdraw", args: [account.address] }),
    pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalAssets" }),
    pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalOutstanding" }),
  ]) as [bigint, bigint, bigint, bigint];
  await ctx.reply(`operator shares=${shares.toString()}\nwithdrawable=${u(max)} USDC\npool idle=${u(idle)} outstanding=${u(out)}`);
});

bot.command("pool", async (ctx) => {
  const { public: pub } = clients();
  const idle = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalAssets" })) as bigint;
  const out = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalOutstanding" })) as bigint;
  const util = idle + out === 0n ? 0 : Number((out * 10_000n) / (idle + out)) / 100;
  await ctx.reply(`idle=${u(idle)} USDC\noutstanding=${u(out)} USDC\nutilization=${util}%`);
});

bot.command("score", async (ctx) => {
  const addr = arg(ctx.message?.text, 1) as Address;
  if (!addr) return ctx.reply("usage: /score <address>");
  const { public: pub } = clients();
  const s = (await pub.readContract({ address: ADDR.passport, abi: passportAbi, functionName: "score", args: [addr] })) as bigint;
  const lim = (await pub.readContract({ address: ADDR.passport, abi: passportAbi, functionName: "maxAdvanceForScore", args: [s] })) as bigint;
  const id = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "activeAdvanceId", args: [addr] })) as bigint;
  await ctx.reply(`score=${s} maxAdvance=${u(lim)} USDC activeAdvance=${id.toString()}`);
});

bot.command("id", async (ctx) => {
  const addr = arg(ctx.message?.text, 1) as Address;
  if (!addr) return ctx.reply("usage: /id <address>");
  const { public: pub } = clients();
  const id = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "activeAdvanceId", args: [addr] })) as bigint;
  await ctx.reply(`activeAdvanceId=${id.toString()}`);
});

bot.command("history", async (ctx) => {
  const addr = arg(ctx.message?.text, 1) as Address;
  if (!addr) return ctx.reply("usage: /history <borrowerAddress>");
  try {
    const { public: pub } = clients();
    const from = process.env.DEPLOY_BLOCK ? BigInt(process.env.DEPLOY_BLOCK) : "earliest" as const;
    const lines: string[] = [];
    for (const ev of historyEvents as unknown as any[]) {
      const logs = await pub.getLogs({ address: ADDR.vault, event: ev, args: { borrower: addr }, fromBlock: from as any });
      for (const l of logs as any[]) {
        if (l.eventName === "AdvanceRequested") lines.push(`#${l.args.id} requested ${u(l.args.principal)} USDC (+${u(l.args.fee)} fee)`);
        if (l.eventName === "AdvanceServiced") lines.push(`#${l.args.id} serviced ${u(l.args.amount)} (remaining ${u(l.args.remaining)})`);
        if (l.eventName === "AdvanceSettled") lines.push(`#${l.args.id} SETTLED`);
        if (l.eventName === "AdvanceDefaulted") lines.push(`#${l.args.id} DEFAULTED shortfall ${u(l.args.shortfall)} lien ${u(l.args.lienTarget)}`);
      }
    }
    await ctx.reply(lines.length ? lines.slice(-20).join("\n") : "no vault events for this borrower yet.");
  } catch (e: any) { await ctx.reply(`history failed: ${e.shortMessage ?? e.message}`); }
});

bot.command("faucet", async (ctx) => {
  const addr = arg(ctx.message?.text, 1) as Address;
  if (!addr) return ctx.reply("usage: /faucet <address>  (demo MockUSDC, testnet only)");
  try {
    const { public: pub, wallet } = clients();
    const tx = await wallet.writeContract({ address: ADDR.usdc, abi: usdcAbi, functionName: "mint", args: [addr, parseUnits("100", 6)] });
    await pub.waitForTransactionReceipt({ hash: tx });
    await ctx.reply(`minted 100 demo USDC to ${addr}.\nTestnet only — MockUSDC.mint is permissionless by design for the demo.`);
  } catch (e: any) { await ctx.reply(`faucet failed (real USDC has no mint): ${e.shortMessage ?? e.message}`); }
});

bot.start();
console.log("bot started");
