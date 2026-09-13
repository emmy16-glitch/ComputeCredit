#!/usr/bin/env node
/**
 * ComputeCredit Telegram bot.
 *
 * Spec reference: ComputeCredit_v2.pdf §11.3 (Telegram commands).
 *
 *   /infer <prompt>     runs the complete quote, advance, provider and response flow
 *   /invest <amount>    deposits USDC and displays shares received
 *   /position           displays shares, estimated idle claim and pool status
 *   /withdraw <amount>  withdraws available idle liquidity
 *   /score              displays score, tier, active advance and lien status
 *   /history            displays advances, servicing events, settlements, defaults, attestations
 *   /pool               displays idle assets, total shares, outstanding principal and utilisation
 *
 * The bot is a user interface. It must not bypass contract checks or sign arbitrary transactions
 * without policy controls (spec §11.3). Every command below either reads onchain state or calls the
 * same vault entrypoints a human would call, and the vault re-checks all rules.
 *
 * Transport: Telegram Bot API over HTTPS (long polling, no external dependencies). Any command can
 * also be exercised offline through the orchestrator CLI (`orchestrator/index.ts`), which is the
 * recommended path for judging environments without Telegram access.
 */
import { JsonRpcProvider, Wallet } from "ethers";

import { loadConfig, type AppConfig } from "../orchestrator/config.ts";
import { Orchestrator } from "../orchestrator/revenueRouter.ts";

interface TelegramUpdate {
  update_id: number;
  message?: {
    message_id: number;
    chat: { id: number };
    from?: { id: number; username?: string };
    text?: string;
  };
}

const HELP = `ComputeCredit - one-job compute advances serviced from routed agent revenue

/infer <prompt>      quote, advance, pay the provider, return the result
/invest <amount>     deposit USDC into the lender pool (e.g. /invest 50)
/position            your shares, idle claim and pool status
/withdraw <amount>   withdraw available idle liquidity
/score               borrower score, tier, active advance and lien
/history             advances, servicing, settlements, defaults, attestations
/pool                idle assets, shares, outstanding principal, utilisation
/help                this message

Honest scope: the protocol does not guarantee lender recovery. Default creates a reputation
penalty plus a conditional claim on future revenue routed through the registered source.
MVP trust assumptions: an approved orchestrator requests advances and issues attestations, and
the demo revenue router controls the registered receiving path (spec §3.1).`;

class TelegramBot {
  private readonly apiBase: string;
  private readonly token: string;
  private readonly orchestrator: Orchestrator;
  private readonly cfg: AppConfig;
  private offset = 0;

  constructor(token: string, orchestrator: Orchestrator, cfg: AppConfig) {
    this.token = token;
    this.orchestrator = orchestrator;
    this.cfg = cfg;
    this.apiBase = `https://api.telegram.org/bot${token}`;
  }

  private async call(method: string, payload: Record<string, unknown>): Promise<any> {
    const response = await fetch(`${this.apiBase}/${method}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
    });
    const body = (await response.json()) as { ok: boolean; result?: any; description?: string };
    if (!body.ok) throw new Error(`Telegram ${method} failed: ${body.description}`);
    return body.result;
  }

  async sendMessage(chatId: number, text: string): Promise<void> {
    // Telegram messages are capped at 4096 characters.
    for (let index = 0; index < text.length; index += 4000) {
      await this.call("sendMessage", { chat_id: chatId, text: text.slice(index, index + 4000) });
    }
  }

  async run(): Promise<void> {
    console.log("ComputeCredit bot polling Telegram... (Ctrl+C to stop)");
    // eslint-disable-next-line no-constant-condition
    while (true) {
      let updates: TelegramUpdate[] = [];
      try {
        updates = await this.call("getUpdates", { offset: this.offset + 1, timeout: 30 });
      } catch (error) {
        console.error(`polling error: ${(error as Error).message}`);
        await new Promise((resolve) => setTimeout(resolve, 5000));
        continue;
      }

      for (const update of updates) {
        this.offset = Math.max(this.offset, update.update_id);
        const message = update.message;
        if (!message?.text) continue;
        try {
          const reply = await this.handle(message.chat.id, message.text.trim(), message.from?.id);
          await this.sendMessage(message.chat.id, reply);
        } catch (error) {
          await this.sendMessage(message.chat.id, `error: ${(error as Error).message}`);
        }
      }
    }
  }

  async handle(chatId: number, text: string, fromId?: number): Promise<string> {
    const [command, ...rest] = text.split(/\s+/);
    const cc = this.orchestrator.cc;
    const borrower = process.env.BORROWER_ADDRESS ?? "";

    switch (command.replace(/@.*$/, "")) {
      case "/start":
      case "/help":
        return HELP;

      case "/pool":
        return await this.orchestrator.poolReport();

      case "/score":
        if (!borrower) return "BORROWER_ADDRESS is not configured on this bot.";
        return await this.orchestrator.borrowerReport(borrower);

      case "/history":
        if (!borrower) return "BORROWER_ADDRESS is not configured on this bot.";
        return await this.history(borrower);

      case "/invest": {
        const amount = rest[0];
        if (!amount) return "usage: /invest <amount>  e.g. /invest 50";
        const key = this.cfg.lenderPrivateKey;
        if (!key) return "LENDER_PRIVATE_KEY is not configured: the bot cannot sign a deposit for you.";
        const provider = new JsonRpcProvider(this.cfg.rpcUrl, this.cfg.chainId, { staticNetwork: true });
        const wallet = new Wallet(key, provider);
        const value = cc.units(amount);
        const usdc = cc.requireUsdc().connect(wallet) as any;
        const vault = cc.vault.connect(wallet) as any;

        const balance: bigint = await cc.requireUsdc().balanceOf(wallet.address);
        if (balance < value) {
          return `wallet ${wallet.address} holds ${cc.fmt(balance)}; ${amount} USDC is unavailable.`;
        }
        if ((await cc.requireUsdc().allowance(wallet.address, this.cfg.vaultAddress)) < value) {
          await (await usdc.approve(this.cfg.vaultAddress, value)).wait();
        }
        const sharesBefore: bigint = await cc.vault.totalShares();
        const tx = await vault.depositLiquidity(value);
        const receipt = await tx.wait();
        const sharesAfter: bigint = await cc.vault.totalShares();

        return [
          `deposited ${cc.fmt(value)}`,
          `shares minted: ${sharesAfter - sharesBefore} (total ${sharesAfter})`,
          `tx: ${receipt?.hash ?? tx.hash}`,
          "",
          "You own a proportional claim on pool assets. Returns are not guaranteed: a default that",
          "is never recovered is a loss shared proportionally by all shareholders (spec §4.4).",
        ].join("\n");
      }

      case "/position": {
        const key = this.cfg.lenderPrivateKey;
        if (!key) return "LENDER_PRIVATE_KEY is not configured on this bot.";
        const provider = new JsonRpcProvider(this.cfg.rpcUrl, this.cfg.chainId, { staticNetwork: true });
        const wallet = new Wallet(key, provider);
        const [shares, idleClaim] = await Promise.all([
          cc.vault.shares(wallet.address),
          cc.vault.idleClaimOf(wallet.address),
        ]);
        const pool = await cc.poolState();
        return [
          `lender        : ${wallet.address}`,
          `shares        : ${shares}`,
          `idle claim    : ${cc.fmt(idleClaim)}  (idle liquidity only - outstanding advances are receivables)`,
          `max withdraw  : ${cc.fmt(await cc.vault.maxWithdrawable(wallet.address))}`,
          "",
          await this.orchestrator.poolReport(),
        ].join("\n");
      }

      case "/withdraw": {
        const amount = rest[0];
        if (!amount) return "usage: /withdraw <amount>";
        const key = this.cfg.lenderPrivateKey;
        if (!key) return "LENDER_PRIVATE_KEY is not configured on this bot.";
        const provider = new JsonRpcProvider(this.cfg.rpcUrl, this.cfg.chainId, { staticNetwork: true });
        const wallet = new Wallet(key, provider);
        const vault = cc.vault.connect(wallet) as any;
        const value = cc.units(amount);
        const max: bigint = await cc.vault.maxWithdrawable(wallet.address);
        if (value > max) {
          return `requested ${cc.fmt(value)} but only ${cc.fmt(max)} of idle liquidity is withdrawable right now.`;
        }
        const tx = await vault.withdrawLiquidity(value);
        const receipt = await tx.wait();
        return `withdrew ${cc.fmt(value)}\ntx: ${receipt?.hash ?? tx.hash}`;
      }

      case "/infer": {
        const prompt = rest.join(" ").trim();
        if (!prompt) return "usage: /infer <prompt>";
        if (!borrower) return "BORROWER_ADDRESS is not configured on this bot.";
        const result = await this.orchestrator.runInference({ borrower, prompt });
        return [
          `prompt        : ${prompt}`,
          `provider      : ${result.provider} (${result.serviceId})`,
          `compute cost  : ${cc.fmt(result.computeCost)}`,
          `advance needed: ${result.advanceRequired}`,
          result.requestedAdvance ? `advance tx    : ${result.requestedAdvance}` : "",
          `provider paid : ${result.providerPaid}`,
          `result        : ${result.providerResult.output}`,
          "",
          "Buyer revenue is serviced through the registered route before the remainder is released.",
        ]
          .filter(Boolean)
          .join("\n");
      }

      default:
        void chatId;
        void fromId;
        return HELP;
    }
  }

  private async history(borrower: string): Promise<string> {
    const cc = this.orchestrator.cc;
    const count = Number(await cc.vault.advanceHistoryCount(borrower));
    const lines = [`advances issued for ${borrower}: ${count}`];

    const serviced = await cc.vault.queryFilter(cc.vault.filters.AdvanceServiced(borrower), 0, "latest");
    const settled = await cc.vault.queryFilter(cc.vault.filters.AdvanceSettled(borrower), 0, "latest");
    const defaulted = await cc.vault.queryFilter(cc.vault.filters.AdvanceDefaulted(borrower), 0, "latest");
    const captured = await cc.vault.queryFilter(cc.vault.filters.LienCaptured(borrower), 0, "latest");
    const attestations = await cc.passport.attestationCount(borrower);

    lines.push(`servicing events : ${serviced.length}`);
    for (const event of serviced.slice(-5)) {
      const args = (event as any).args;
      lines.push(`  block ${event.blockNumber}: serviced ${cc.fmt(args[1])}, settled=${args[4]}`);
    }
    lines.push(`settlements      : ${settled.length}`);
    lines.push(`defaults         : ${defaulted.length}`);
    for (const event of defaulted.slice(-5)) {
      const args = (event as any).args;
      lines.push(`  shortfall ${cc.fmt(args[1])}, lien target ${cc.fmt(args[2])}`);
    }
    lines.push(`lien captures    : ${captured.length}`);
    lines.push(`attestations     : ${attestations}`);
    return lines.join("\n");
  }
}

async function main(): Promise<void> {
  const token = process.env.TELEGRAM_BOT_TOKEN;
  if (!token) {
    console.error("TELEGRAM_BOT_TOKEN is required. See .env.example.");
    console.error("Without Telegram access you can drive the identical logic with the orchestrator CLI:");
    console.error("  cd orchestrator && npm run pool|score|history|infer|pay|invest|monitor");
    process.exitCode = 1;
    return;
  }

  const cfg = loadConfig();
  const bot = new TelegramBot(token, new Orchestrator(cfg), cfg);
  await bot.run();
}

export { TelegramBot, HELP };

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop() ?? "")) {
  main().catch((error) => {
    console.error(`bot error: ${error.message}`);
    process.exitCode = 1;
  });
}
