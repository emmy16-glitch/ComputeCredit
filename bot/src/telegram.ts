import { Bot, InlineKeyboard } from "grammy";
import { formatUnits, isAddress, parseUnits, type Address } from "viem";
import { ADDR, clients, vaultAbi, passportAbi, rwaAbi, vaultRwaAbi } from "../../orchestrator/src/config.js";
import { infer } from "../../orchestrator/src/agent.js";
import "dotenv/config";

/**
 * ComputeCredit Telegram bot — ZERO-KNOWLEDGE UX.
 *
 * Design goal: anybody understands it in 2 seconds.
 * - No typing commands. Everything is a button.
 * - /start answers: WHAT is this + WHAT can I do (2 choices).
 * - Guided wizards: preset amounts, demo wallet, one question at a time.
 * - Plain English everywhere. Jargon hidden behind "Advanced".
 *
 * Old slash commands still work for power users.
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
const EXPLORER = "https://www.oklink.com/x-layer-testnet";
const txLink = (tx: string) => `${EXPLORER}/tx/${tx}`;

// ---------------------------------------------------------------- wizard state
type Step =
  | { name: "idle" }
  | { name: "await_deposit_amount" }
  | { name: "await_withdraw_amount" }
  | { name: "await_task_text" }
  | { name: "await_borrower_address"; task: string }
  | { name: "await_score_address" }
  | { name: "await_history_address" };

const sessions = new Map<number, Step>();
const setStep = (chatId: number, s: Step) => sessions.set(chatId, s);
const getStep = (chatId: number): Step => sessions.get(chatId) ?? { name: "idle" };

// ---------------------------------------------------------------- keyboards
const mainMenuKb = () =>
  new InlineKeyboard()
    .text("💰 I want to EARN", "earn_home").text("🤖 I need COMPUTE", "borrow_home").row()
    .text("👀 Show me an example", "how").text("❓ What is this?", "what").row()
    .text("🎁 Free demo money", "faucet_home");

const earnKb = () =>
  new InlineKeyboard()
    .text("💰 Pool status", "earn_pool").text("➕ Put money in", "earn_deposit").row()
    .text("➖ Take money out", "earn_withdraw").row()
    .text("◀️ Back", "menu");

const borrowKb = () =>
  new InlineKeyboard()
    .text("🚀 New AI task", "borrow_new").text("⭐ My trust score", "borrow_score").row()
    .text("📜 My jobs", "borrow_history").text("🎁 Free demo money", "faucet_home").row()
    .text("◀️ Back", "menu");

const backKb = () => new InlineKeyboard().text("◀️ Back to menu", "menu");
const earnAmountsKb = () =>
  new InlineKeyboard()
    .text("10 USDC", "amt_10").text("50 USDC", "amt_50").text("100 USDC", "amt_100").row()
    .text("✏️ Other amount…", "amt_custom").row()
    .text("◀️ Back", "earn_home");
const taskPresetsKb = () =>
  new InlineKeyboard()
    .text("📝 Summarize this", "task_summarize").text("💻 Help me code", "task_code").row()
    .text("🌍 Translate this", "task_translate").row()
    .text("✏️ I'll type my own…", "task_custom").row()
    .text("◀️ Back", "borrow_home");

// ---------------------------------------------------------------- copy (2-second rule)
const START_TEXT =
  "🤖 *ComputeCredit*\n\n" +
  "AI agents need compute BEFORE they get paid\\. We front the cost — lenders earn a fee\\.\n\n" +
  "*You are here to…?*\n" +
  "👇 Tap one — no typing needed:";

const WHAT_TEXT =
  "❓ *What is this, in 10 seconds*\n\n" +
  "1️⃣ Lenders put demo USDC into one shared pool\\.\n" +
  "2️⃣ An AI agent needs e\\.g\\. 2 USDC of compute to do a job\\.\n" +
  "3️⃣ The pool pays the provider directly \\(agent never touches cash\\)\\.\n" +
  "4️⃣ When the buyer pays, the pool is repaid \\+ a small fee\\.\n\n" +
  "⚠️ Demo on testnet\\. No guaranteed returns — if a job defaults, lenders share the loss\\.\n\n" +
  "👇 Pick a side to try it:";

const HOW_TEXT =
  "👀 *Example — takes 30 seconds*\n\n" +
  "Agent Ana has trust score 350 → can borrow up to 20 USDC\\.\n" +
  "She needs a 2 USDC AI job\\.\n\n" +
  "Pool fronts 2 USDC → provider runs the job → buyer pays 2\\.20 → " +
  "pool gets 2\\.20 back, Ana's score goes up\\.\n\n" +
  "Try it live 👇";

const EARN_TEXT =
  "💰 *EARN — fund AI jobs*\n\n" +
  "You put demo USDC in\\. Each job repays \\+ fee\\. " +
  "You can withdraw idle cash anytime\\.\n\n" +
  "⚠️ Not a bank\\. Value can go down if jobs default\\.\n\n" +
  "👇 What next?";

const BORROW_TEXT =
  "🤖 *COMPUTE — get the job done now*\n\n" +
  "Tell us the task\\. If your trust score allows, we pay the AI provider for you\\. " +
  "You repay automatically from your next buyer payment\\.\n\n" +
  "👇 What next?";

async function show(text: string, kb: InlineKeyboard, ctx: any, keepStep = false) {
  const opts = { parse_mode: "MarkdownV2" as const, reply_markup: kb };
  // If this came from a button, ack FIRST so the spinner stops instantly.
  // (Telegram requires answerCallbackQuery within ~seconds, long before RPC finishes.)
  if (ctx.callbackQuery) {
    await ctx.answerCallbackQuery().catch(() => {});
    try {
      await ctx.editMessageText(text, opts);
    } catch (e: any) {
      // "message is not modified" = user tapped same menu twice: not an error, don't spam a new message.
      if (/not modified/i.test(e?.message ?? String(e))) {
        if (!keepStep) setStep(ctx.chat.id, { name: "idle" });
        return;
      }
      await ctx.reply(text, opts);
    }
  } else {
    await ctx.reply(text, opts);
  }
  if (!keepStep) setStep(ctx.chat.id, { name: "idle" });
}

// ---------------------------------------------------------------- onchain helpers (friendly errors)
function friendlyError(e: any): string {
  const m: string = e?.shortMessage ?? e?.message ?? String(e);
  if (/exceeds (tier|effective) limit/i.test(m)) return "❌ Trust score too low for this job. Get free demo history or ask for a smaller task.";
  if (/already has active/i.test(m)) return "❌ You already have 1 active job. Finish/repay it first (one job at a time in this demo).";
  if (/insufficient|allowance|balance/i.test(m)) return "❌ Pool is short on idle cash right now. Try a smaller amount or later.";
  if (/only .* withdrawable/i.test(m)) return m;
  return `❌ Failed: ${m.slice(0, 300)}`;
}

async function doDeposit(ctx: any, amtStr: string) {
  const amt = Number(amtStr);
  if (!amtStr || isNaN(amt) || amt <= 0 || amt > 10_000) {
    await ctx.reply("✏️ Type an amount like `10` (USDC). Max 10,000 for demo.", { parse_mode: "MarkdownV2" });
    return;
  }
  const wait = await ctx.reply(`⏳ Putting ${amt} USDC in… (2 chain steps, ~10s)`);
  try {
    const { public: pub, wallet, account } = clients();
    const assets = parseUnits(amtStr, 6);
    const aTx = await wallet.writeContract({ address: ADDR.usdc, abi: usdcAbi, functionName: "approve", args: [ADDR.vault, assets] });
    await pub.waitForTransactionReceipt({ hash: aTx });
    const tx = await wallet.writeContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "deposit", args: [assets, account.address] });
    await pub.waitForTransactionReceipt({ hash: tx });
    await ctx.reply(
      `✅ In\\! You put ${amt} USDC into the shared pool\\.\n\n` +
      `🔗 [See transaction](${txLink(tx)})\n\n` +
      `When jobs repay, your share grows a little\\. No guarantee though\\.\n` +
      `👇 Tap below:`,
      { parse_mode: "MarkdownV2", reply_markup: earnKb() },
    );
  } catch (e: any) {
    await ctx.reply(friendlyError(e), { reply_markup: earnKb() });
  } finally {
    await ctx.api.deleteMessage(ctx.chat.id, wait.message_id).catch(() => {});
    setStep(ctx.chat.id, { name: "idle" });
  }
}

async function doWithdraw(ctx: any, amtStr: string) {
  const amt = Number(amtStr);
  if (!amtStr || isNaN(amt) || amt <= 0) {
    await ctx.reply("✏️ Type an amount like `5` (USDC).");
    return;
  }
  const wait = await ctx.reply(`⏳ Taking ${amt} USDC out…`);
  try {
    const { public: pub, wallet, account } = clients();
    const assets = parseUnits(amtStr, 6);
    const max = (await pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "maxWithdraw", args: [account.address] })) as bigint;
    if (assets > max) {
      await ctx.reply(`⚠️ Only ${u(max)} USDC is free right now — the rest is out on live jobs\\. Try a smaller amount\\.`, { reply_markup: earnKb() });
      return;
    }
    const tx = await wallet.writeContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "withdraw", args: [assets, account.address, account.address] });
    await pub.waitForTransactionReceipt({ hash: tx });
    await ctx.reply(`✅ Out\\! ${amt} USDC back in the demo wallet\\.\n🔗 [See transaction](${txLink(tx)})`, { parse_mode: "MarkdownV2", reply_markup: earnKb() });
  } catch (e: any) {
    await ctx.reply(friendlyError(e), { reply_markup: earnKb() });
  } finally {
    await ctx.api.deleteMessage(ctx.chat.id, wait.message_id).catch(() => {});
    setStep(ctx.chat.id, { name: "idle" });
  }
}

async function doPool(ctx: any) {
  try {
    const { public: pub } = clients();
    const [idle, out] = await Promise.all([
      pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalAssets" }),
      pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalOutstanding" }),
    ]) as [bigint, bigint];
    const total = idle + out;
    const pct = total === 0n ? 0 : Number((out * 10_000n) / total) / 100;
    const bar = "🟩".repeat(Math.round(((100 - pct) / 100) * 8)) + "🟧".repeat(Math.round((pct / 100) * 8));
    await ctx.reply(
      `💰 *Pool right now*\n\n${bar}\n` +
      `Free: ${u(idle)} USDC\nOn jobs: ${u(out)} USDC\nBusy: ${pct}%` +
      (pct > 80 ? "\n\n⚠️ Pool is busy — withdrawals may be limited\\." : ""),
      { parse_mode: "MarkdownV2", reply_markup: earnKb() },
    );
  } catch (e: any) {
    await ctx.reply(friendlyError(e), { reply_markup: earnKb() });
  }
}

async function doFaucet(ctx: any, addr: string) {
  if (!isAddress(addr)) {
    await ctx.reply("That doesn't look like a wallet address (must start with 0x…). Tap 🎁 again to use the demo wallet, or paste a valid one.");
    return;
  }
  const wait = await ctx.reply("⏳ Sending 100 free demo USDC…");
  try {
    const { public: pub, wallet } = clients();
    const tx = await wallet.writeContract({ address: ADDR.usdc, abi: usdcAbi, functionName: "mint", args: [addr as Address, parseUnits("100", 6)] });
    await pub.waitForTransactionReceipt({ hash: tx });
    await ctx.reply(
      `🎁 Done\\! 100 demo USDC → \`${addr.slice(0, 6)}…${addr.slice(-4)}\`\n` +
      `Testnet play\\-money only\\.\n🔗 [See transaction](${txLink(tx)})\n\n👇 Now try a task or fund the pool:`,
      { parse_mode: "MarkdownV2", reply_markup: mainMenuKb() },
    );
  } catch {
    await ctx.reply("❌ Free money failed — real USDC has no faucet. This works only with the demo token on testnet.", { reply_markup: backKb() });
  } finally {
    await ctx.api.deleteMessage(ctx.chat.id, wait.message_id).catch(() => {});
    setStep(ctx.chat.id, { name: "idle" });
  }
}

async function doBorrow(ctx: any, task: string, borrowerAddr: string) {
  if (!isAddress(borrowerAddr)) {
    await ctx.reply("That wallet address looks wrong. It must start with 0x… — tap 🚀 again to use the demo wallet.");
    return;
  }
  const wait = await ctx.reply(`⏳ Checking your score and paying the provider for “${task.slice(0, 60)}”…`);
  try {
    const r = await infer(task.replace(/\s+/g, "-").slice(0, 40) || "demo-task", borrowerAddr as Address);
    await ctx.reply(
      `✅ *Job started\\!*\n\nTask: “${task.slice(0, 80)}”\n` +
      `Cost fronted: ${u(r.price as bigint)} USDC\nTrust score: ${r.score}\n` +
      (r.jobHash ? `Receipt: \`${(r.jobHash as string).slice(0, 18)}…\`` : "Paid directly — no loan needed (wallet already had funds)\\.") +
      `\n\nRepay happens automatically from your next buyer payment\\. 👇`,
      { parse_mode: "MarkdownV2", reply_markup: borrowKb() },
    );
  } catch (e: any) {
    await ctx.reply(friendlyError(e) + "\n\n👇 Try free demo money first, or a smaller task:", { reply_markup: borrowKb() });
  } finally {
    await ctx.api.deleteMessage(ctx.chat.id, wait.message_id).catch(() => {});
    setStep(ctx.chat.id, { name: "idle" });
  }
}

async function doScore(ctx: any, addr: string) {
  if (!isAddress(addr)) {
    await ctx.reply("Paste a wallet like 0x… — or tap ⭐ again and choose “Use demo wallet”.");
    return;
  }
  try {
    const { public: pub } = clients();
    // One score read, then parallel dependent reads (was: score fetched twice + sequential).
    const s = (await pub.readContract({ address: ADDR.passport, abi: passportAbi, functionName: "score", args: [addr as Address] })) as bigint;
    const [lim, id] = await Promise.all([
      pub.readContract({ address: ADDR.passport, abi: passportAbi, functionName: "maxAdvanceForScore", args: [s] }),
      pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "activeAdvanceId", args: [addr as Address] }),
    ]) as [bigint, bigint];
    const stars = s >= 500n ? "⭐⭐⭐" : s >= 350n ? "⭐⭐" : s >= 1n ? "⭐" : "🆕";
    let rwaExtra = "";
    if (ADDR.rwa) {
      try {
        const eff = (await pub.readContract({ address: ADDR.vault, abi: vaultRwaAbi, functionName: "effectiveLimit", args: [addr as Address] })) as bigint;
        if (eff !== lim) rwaExtra = `\n📈 With xStock collateral: up to ${u(eff)} USDC`;
      } catch { /* pre-RWA vault */ }
    }
    await ctx.reply(
      `${stars} *Trust score: ${s}*\n\n` +
      `Can borrow up to: ${u(lim)} USDC${rwaExtra}\n` +
      (id === 0n ? "No active job — free to start one ✅" : `Busy on job #${id} — finish it first ⏳`) +
      `\n\nGood scores grow when jobs repay\\. Bad defaults shrink them\\.`,
      { parse_mode: "MarkdownV2", reply_markup: borrowKb() },
    );
  } catch (e: any) {
    await ctx.reply(friendlyError(e), { reply_markup: borrowKb() });
  }
  setStep(ctx.chat.id, { name: "idle" });
}

async function doRwa(ctx: any, addr: string) {
  if (!isAddress(addr)) {
    await ctx.reply("Paste a wallet like 0x… — or tap ⭐ again and choose “Use demo wallet”.");
    return;
  }
  if (!ADDR.rwa) {
    await ctx.reply("RWA module not deployed yet (RWA_COLLATERAL unset).", { reply_markup: borrowKb() });
    return;
  }
  try {
    const { public: pub } = clients();
    const [val, eff] = await Promise.all([
      pub.readContract({ address: ADDR.rwa, abi: rwaAbi, functionName: "collateralValue", args: [addr as Address] }),
      pub.readContract({ address: ADDR.vault, abi: vaultRwaAbi, functionName: "effectiveLimit", args: [addr as Address] }),
    ]) as [bigint, bigint];
    await ctx.reply(
      `📈 *xStock collateral: ${u(val)} USDC value*\nEffective limit: ${u(eff)} USDC\n\nLock via RwaCollateral\\.lock after approving XSTOCK; unlock blocked while advance/lien open\\.`,
      { parse_mode: "MarkdownV2", reply_markup: borrowKb() },
    );
  } catch (e: any) {
    await ctx.reply(friendlyError(e), { reply_markup: borrowKb() });
  }
  setStep(ctx.chat.id, { name: "idle" });
}

async function doHistory(ctx: any, addr: string) {
  if (!isAddress(addr)) {
    await ctx.reply("Paste a wallet like 0x… — or tap 📜 again and choose “Use demo wallet”.");
    return;
  }
  try {
    const { public: pub } = clients();
    const from = process.env.DEPLOY_BLOCK ? BigInt(process.env.DEPLOY_BLOCK) : ("earliest" as const);
    // Parallel log fetches (was: 4 sequential getLogs — slowest button by far).
    // One failing event must not kill the whole history view.
    const settled = await Promise.allSettled(
      (historyEvents as unknown as any[]).map((ev) =>
        pub.getLogs({ address: ADDR.vault, event: ev, args: { borrower: addr as Address }, fromBlock: from as any }),
      ),
    );
    const lines: string[] = [];
    for (const r of settled) {
      if (r.status !== "fulfilled") continue;
      for (const l of r.value as any[]) {
        if (l.eventName === "AdvanceRequested") lines.push(`🆕 Job #${l.args.id}: borrowed ${u(l.args.principal)} USDC`);
        if (l.eventName === "AdvanceServiced") lines.push(`💸 Job #${l.args.id}: repaid ${u(l.args.amount)} (left ${u(l.args.remaining)})`);
        if (l.eventName === "AdvanceSettled") lines.push(`✅ Job #${l.args.id}: DONE`);
        if (l.eventName === "AdvanceDefaulted") lines.push(`❌ Job #${l.args.id}: FAILED`);
      }
    }
    await ctx.reply(lines.length ? `📜 *Your jobs \\(${lines.slice(-10).length} latest\\)*\n\n${lines.slice(-10).join("\n")}` : "📜 No jobs yet for this wallet\\. Tap 🚀 New AI task to start your first\\!",
      { parse_mode: "MarkdownV2", reply_markup: borrowKb() });
  } catch (e: any) {
    await ctx.reply(friendlyError(e), { reply_markup: borrowKb() });
  }
  setStep(ctx.chat.id, { name: "idle" });
}

// ---------------------------------------------------------------- commands (menu-first, slash = shortcut)
bot.command("start", (ctx) => show(START_TEXT, mainMenuKb(), ctx));
bot.command("menu", (ctx) => show(START_TEXT, mainMenuKb(), ctx));
bot.command("help", (ctx) => show(WHAT_TEXT, mainMenuKb(), ctx));

// Power-user shortcuts still work, but reply in friendly style.
bot.command("pool", (ctx) => doPool(ctx));
bot.command("position", async (ctx) => {
  const { public: pub, account } = clients();
  const [max, idle, out] = await Promise.all([
    pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "maxWithdraw", args: [account.address] }),
    pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalAssets" }),
    pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "totalOutstanding" }),
  ]) as [bigint, bigint, bigint];
  await ctx.reply(`💰 Pool: free ${u(idle)} USDC, on jobs ${u(out)}\\. You can take out ${u(max)}\\.\nType /menu for buttons\\.`, { parse_mode: "MarkdownV2", reply_markup: earnKb() });
});
bot.command("invest", (ctx) => {
  const amt = ctx.message?.text?.split(/\s+/)[1];
  if (!amt) { show(EARN_TEXT, earnKb(), ctx); return; }
  doDeposit(ctx, amt);
});
bot.command("withdraw", (ctx) => {
  const amt = ctx.message?.text?.split(/\s+/)[1];
  if (!amt) { show("➖ *Take money out*\n\nHow much? Tap or type a number:", earnAmountsKb(), ctx); return; }
  doWithdraw(ctx, amt);
});
bot.command("score", (ctx) => {
  const addr = ctx.message?.text?.split(/\s+/)[1];
  if (!addr || !isAddress(addr)) {
    ctx.reply("⭐ Whose score? Tap below for the demo wallet, or send me a 0x… address:", {
      reply_markup: new InlineKeyboard().text("Use demo wallet", "score_demo").text("◀️ Menu", "menu"),
    });
    setStep(ctx.chat!.id, { name: "await_score_address" });
    return;
  }
  doScore(ctx, addr);
});
bot.command("rwa", (ctx) => {
  const addr = ctx.message?.text?.split(/\s+/)[1];
  if (!addr) return ctx.reply("usage: /rwa <borrowerAddress>");
  doRwa(ctx, addr);
});
bot.command("history", (ctx) => {
  const addr = ctx.message?.text?.split(/\s+/)[1];
  if (!addr || !isAddress(addr)) {
    ctx.reply("📜 Whose jobs? Tap below for the demo wallet, or send a 0x… address:", {
      reply_markup: new InlineKeyboard().text("Use demo wallet", "history_demo").text("◀️ Menu", "menu"),
    });
    setStep(ctx.chat!.id, { name: "await_history_address" });
    return;
  }
  doHistory(ctx, addr);
});
bot.command("id", async (ctx) => {
  const addr = ctx.message?.text?.split(/\s+/)[1];
  if (!addr || !isAddress(addr)) return ctx.reply("Send /id 0xYourWallet… — or tap 📜 My jobs for buttons.");
  const { public: pub } = clients();
  const id = (await pub.readContract({ address: ADDR.vault, abi: vaultAbi, functionName: "activeAdvanceId", args: [addr as Address] })) as bigint;
  await ctx.reply(id === 0n ? "No active job ✅ — free to start one. Tap /menu." : `Busy on job #${id} ⏳.`);
});
bot.command("faucet", (ctx) => {
  const addr = ctx.message?.text?.split(/\s+/)[1];
  if (!addr) {
    ctx.reply("🎁 Free 100 demo USDC — who gets it?", {
      reply_markup: new InlineKeyboard().text("🎁 Me (demo wallet)", "faucet_demo").text("◀️ Menu", "menu"),
    });
    return;
  }
  doFaucet(ctx, addr);
});
bot.command("infer", async (ctx) => {
  const parts = (ctx.message?.text ?? "").split(/\s+/);
  const prompt = parts[1], borrower = parts[2];
  if (!prompt || !borrower || !isAddress(borrower)) {
    await show("🤖 *New AI task*\n\nWhat should the AI do? Tap one or just type it:", taskPresetsKb(), ctx);
    if (prompt && !borrower) setStep(ctx.chat.id, { name: "await_borrower_address", task: prompt });
    else setStep(ctx.chat.id, { name: "await_task_text" });
    return;
  }
  await doBorrow(ctx, prompt, borrower);
});

// ---------------------------------------------------------------- button router (the whole UX)
bot.on("callback_query:data", async (ctx) => {
  const d = ctx.callbackQuery.data;
  const chatId = ctx.chat?.id ?? ctx.from.id;
  const demoWallet = clients().account.address;

  // Ack IMMEDIATELY so the button spinner stops in <1s.
  // Heavy work (doPool/doDeposit/doBorrow/...) sends its own "working" message after.
  await ctx.answerCallbackQuery().catch(() => {});

  // ask() must preserve the wizard step: show() resets to idle unless keepStep=true.
  const ask = async (text: string, step: Step, kb?: InlineKeyboard) => {
    await show(text, kb ?? backKb(), ctx, true);
    setStep(chatId, step);
  };

  if (d === "menu") return show(START_TEXT, mainMenuKb(), ctx);
  if (d === "what") return show(WHAT_TEXT, mainMenuKb(), ctx);
  if (d === "how") return show(HOW_TEXT + "\n\n👇 Your turn:", new InlineKeyboard().text("🚀 Try a demo task", "borrow_new").text("💰 Try lending", "earn_home").row().text("◀️ Back", "menu"), ctx);

  if (d === "earn_home") return show(EARN_TEXT, earnKb(), ctx);
  if (d === "borrow_home") return show(BORROW_TEXT, borrowKb(), ctx);

  if (d === "earn_pool") return doPool(ctx);
  if (d === "earn_deposit") return show("➕ *Put money in*\n\nHow much demo USDC? Tap or type a number:", earnAmountsKb(), ctx);
  if (d === "earn_withdraw") {
    await show("➖ *Take money out*\n\nHow much? Tap an amount (applies to withdraw) or type a number:", new InlineKeyboard()
      .text("5 USDC", "w_5").text("10 USDC", "w_10").text("Max", "w_max").row().text("◀️ Back", "earn_home"), ctx, true);
    setStep(chatId, { name: "await_withdraw_amount" });
    return;
  }

  if (d.startsWith("amt_")) {
    if (d === "amt_custom") return ask("✏️ Type the amount in USDC (e\\.g\\. `25`):", { name: "await_deposit_amount" });
    return doDeposit(ctx, d.split("_")[1]);
  }
  if (d.startsWith("w_")) {
    if (d === "w_max") {
      const { public: pub, account } = clients();
      const max = (await pub.readContract({ address: ADDR.vault, abi: botVaultAbi, functionName: "maxWithdraw", args: [account.address] })) as bigint;
      return doWithdraw(ctx, u(max));
    }
    return doWithdraw(ctx, d.split("_")[1]);
  }

  if (d === "borrow_new") return show("🤖 *What should the AI do?*\n\nTap one — it runs on the demo wallet, no address needed:", new InlineKeyboard()
    .text("📝 Summarize this", "task_summarize").text("💻 Help me code", "task_code").row()
    .text("🌍 Translate this", "task_translate").row()
    .text("✏️ I'll type my own…", "task_custom").row()
    .text("◀️ Back", "borrow_home"), ctx);

  if (d.startsWith("task_")) {
    const preset: Record<string, string> = { task_summarize: "summarize-this-document", task_code: "help-me-debug-code", task_translate: "translate-this-text" };
    if (d === "task_custom") return ask("✏️ Type your task in plain words \\(e\\.g\\. `summarize my PDF`\\):", { name: "await_task_text" });
    return doBorrow(ctx, preset[d], demoWallet); // 1-tap: no address asked
  }

  if (d === "borrow_score") return show("⭐ *Check trust score*\n\nHigher score = bigger jobs\\. New wallets start low\\.", new InlineKeyboard()
    .text("⭐ Check demo wallet", "score_demo").text("✏️ Other wallet…", "score_custom").row().text("◀️ Back", "borrow_home"), ctx);
  if (d === "score_demo") return doScore(ctx, demoWallet);
  if (d === "score_custom") return ask("✏️ Paste the wallet address \\(0x…\\):", { name: "await_score_address" });

  if (d === "borrow_history") return show("📜 *Your jobs*\n\nSee borrows, repays, done/failed\\.", new InlineKeyboard()
    .text("📜 Demo wallet jobs", "history_demo").text("✏️ Other wallet…", "history_custom").row().text("◀️ Back", "borrow_home"), ctx);
  if (d === "history_demo") return doHistory(ctx, demoWallet);
  if (d === "history_custom") return ask("✏️ Paste the wallet address \\(0x…\\):", { name: "await_history_address" });

  if (d === "faucet_home") return show("🎁 *Free demo money*\n\n100 play USDC on testnet\\. Real money has no faucet — this is only for trying the demo\\.", new InlineKeyboard()
    .text("🎁 Give ME 100 (demo wallet)", "faucet_demo").row().text("◀️ Back", "menu"), ctx);
  if (d === "faucet_demo") return doFaucet(ctx, demoWallet);

  await ctx.answerCallbackQuery().catch(() => {});
});

// ---------------------------------------------------------------- free-text input (wizard steps)
bot.on("message:text", async (ctx) => {
  const chatId = ctx.chat.id;
  const step = getStep(chatId);
  const text = ctx.message.text.trim();
  const demoWallet = clients().account.address;

  // Global shortcuts: plain numbers / addresses even with no step
  if (step.name === "idle") {
    if (/^\/start|^\/menu|^\/help/.test(text)) return; // handled by commands
    if (/^\d+(\.\d+)?$/.test(text)) return doDeposit(ctx, text); // "50" → invest, zero-knowledge
    if (isAddress(text)) return doScore(ctx, text); // pasted address → score
    await show("👋 I work with buttons — no need to type commands\\.\n\nPick one 👇", mainMenuKb(), ctx);
    return;
  }
  if (step.name === "await_deposit_amount") {
    const amt = text.replace(/[^0-9.]/g, "");
    if (!amt || isNaN(Number(amt))) { await ctx.reply("Please type just a number, e.g. `25`."); return; }
    return doDeposit(ctx, amt);
  }
  if (step.name === "await_withdraw_amount") {
    const amt = text.replace(/[^0-9.]/g, "");
    if (!amt || isNaN(Number(amt))) { await ctx.reply("Please type just a number, e.g. `5`."); return; }
    return doWithdraw(ctx, amt);
  }
  if (step.name === "await_task_text") {
    if (text.length < 2) { await ctx.reply("Tell me a little more — e.g. `summarize my report`."); return; }
    // Zero-knowledge: run on demo wallet immediately, offer "use other wallet" after.
    setStep(chatId, { name: "idle" });
    await ctx.reply(`Got it: “${text.slice(0, 100)}” — running on the demo wallet… (advanced: /infer <task> 0xWallet)`);
    return doBorrow(ctx, text, demoWallet);
  }
  if (step.name === "await_borrower_address") {
    if (!isAddress(text)) { await ctx.reply("That doesn't look like 0x… address. Try again or type /menu."); return; }
    return doBorrow(ctx, (step as any).task ?? "demo-task", text);
  }
  if (step.name === "await_score_address") return doScore(ctx, text);
  if (step.name === "await_history_address") return doHistory(ctx, text);
});

// Telegram side menu (the 3 dots) — only 3 items, not 10.
bot.api.setMyCommands([
  { command: "start", description: "🏠 Main menu (start here)" },
  { command: "menu", description: "🏠 Main menu" },
  { command: "help", description: "❓ What is this?" },
]).catch(() => {});

// One failing update must never stall polling for everyone else.
bot.catch((err) => console.error("bot handler error:", err?.message ?? err));

bot.start({ drop_pending_updates: true });
console.log("bot started (zero-knowledge UX)");
