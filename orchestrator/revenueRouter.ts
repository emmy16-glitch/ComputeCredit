/**
 * Orchestrator lifecycle (spec §11.1).
 *
 * The 13 steps of the specification, implemented in order:
 *   1.  receive an inference request
 *   2.  identify the borrower, provider, service and job hash
 *   3.  read the borrower balance
 *   4.  read the borrower score and maximum advance
 *   5.  read the provider's registered price
 *   6.  pay directly if the borrower has sufficient funds
 *   7.  otherwise request one compute advance through the approved path
 *   8.  pay the provider
 *   9.  return the result to the buyer
 *   10. watch the registered revenue source
 *   11. route the servicing amount
 *   12. record the payment and work attestation
 *   13. monitor expiry and submit `penalize` when appropriate
 *
 * "The orchestrator should never calculate a permission that the vault does not enforce.
 *  Offchain checks are for user experience; onchain checks are the authority." (spec §11.1)
 */
import { JsonRpcProvider, Wallet } from "ethers";

import { ComputeCredit, signingWallet } from "./chain.ts";
import { formatUnits, parseUnits, explorerLink, type AppConfig } from "./config.ts";

export interface RequestParams {
  /** The agent that will perform the job. */
  borrower: string;
  /** Human-readable prompt forwarded to the provider endpoint. */
  prompt: string;
  /** Offchain reference for the buyer payment (x402 receipt id, invoice id, ...). */
  paymentRef?: string;
  /** Buyer payment amount in USDC, if the buyer already paid (defaults to BUYER_PAYMENT_USDC). */
  buyerPaymentUsdc?: string;
  /**
   * Force the advance branch even when the borrower could pay from its own balance.
   * Used by the demo to exercise the complete advance lifecycle (spec §16 step 3).
   */
  forceAdvance?: boolean;
}

export interface RequestResult {
  borrower: string;
  jobHash: string;
  provider: string;
  serviceId: string;
  computeCost: bigint;
  providerPaid: boolean;
  advanceRequired: boolean;
  requestedAdvance?: string;
  providerPaymentTx?: string;
  providerResult: { serviceId: string; output: string; simulated: boolean };
  preview?: { serviceAmount: bigint; borrowerAmount: bigint; lienActive: boolean };
  notes: string[];
}

export class Orchestrator {
  readonly cfg: AppConfig;
  readonly cc: ComputeCredit;

  constructor(cfg: AppConfig) {
    this.cfg = cfg;
    this.cc = new ComputeCredit(cfg);
  }

  /**
   * Steps 1-9: quote, finance and pay for one provider job.
   */
  async runInference(params: RequestParams): Promise<RequestResult> {
    const notes: string[] = [];
    const borrower = params.borrower;

    // ---- 2. identify provider, service and job hash ------------------
    const provider = this.cfg.service.providerAddress;
    const quote = await this.cc.providerQuote(provider);
    if (!quote.active) {
      throw new Error(`Provider ${provider} is not active in the registry; the vault would reject the advance.`);
    }
    const nonce = Date.now();
    const expiry = Math.floor(Date.now() / 1000) + 3600;
    const jobHash = this.cc.jobHash(borrower, provider, this.cc.hashOf(this.cfg.service.serviceId), quote.pricePerJob, nonce, expiry);

    // ---- 3. read the borrower balance --------------------------------
    const balance = await this.cc.balanceOf(borrower);

    // ---- 4. read the borrower score and maximum advance --------------
    const state = await this.cc.borrowerState(borrower);
    const tierLimit = state.maxAdvance;

    // ---- 5. read the provider's registered price ---------------------
    const computeCost = quote.pricePerJob;
    const maxAdvance = this.cc.units(this.cfg.maxAdvanceUsdc);

    // ---- 6. pay directly when the borrower already has funds ---------
    let advanceRequired = false;
    let requestedAdvance: string | undefined;
    if (balance >= computeCost && !params.forceAdvance) {
      notes.push(
        `Borrower already holds ${this.cc.fmt(balance)}; no advance is needed for a ${this.cc.fmt(computeCost)} job.`,
      );
    } else {
      advanceRequired = true;
      if (params.forceAdvance && balance >= computeCost) {
        notes.push("forceAdvance: the demo requests the advance even though the borrower could pay directly.");
      }

      // Offchain guards mirroring the onchain rules (user experience only).
      if (computeCost > tierLimit) {
        throw new Error(
          `Compute cost ${this.cc.fmt(computeCost)} exceeds the borrower's tier limit ${this.cc.fmt(tierLimit)} ` +
            `(score ${state.score}). The vault would reject this request.`,
        );
      }
      if (computeCost > maxAdvance) {
        throw new Error(`Compute cost exceeds the orchestrator's MAX_ADVANCE_USDC guard (${this.cfg.maxAdvanceUsdc}).`);
      }

      // ---- 7. request exactly one advance through the approved path --
      const tx = await this.cc.requestAdvance(
        this.cfg.operatorPrivateKey,
        borrower,
        provider,
        computeCost,
        jobHash,
        this.cfg.routerAddress,
      );
      const receipt = await tx.wait();
      requestedAdvance = receipt?.hash ?? tx.hash;
      notes.push(
        `Advance requested for the exact provider cost (${this.cc.fmt(computeCost)}). ${explorerLink(this.cfg, requestedAdvance)}`,
      );
    }

    // ---- 8. pay the provider ----------------------------------------
    let providerPaymentTx: string | undefined;
    let providerPaid = false;
    const borrowerKey = this.cfg.borrowerPrivateKey;
    if (borrowerKey) {
      const before = await this.cc.balanceOf(borrower);
      if (before >= computeCost) {
        if (!this.cfg.dryRun) {
          const tx = await this.cc.payProvider(borrowerKey, quote.providerWallet, computeCost);
          const receipt = await tx.wait();
          providerPaymentTx = receipt?.hash ?? tx.hash;
        }
        providerPaid = true;
        notes.push(
          `Provider paid ${this.cc.fmt(computeCost)} to ${quote.providerWallet}. ` +
            (providerPaymentTx ? explorerLink(this.cfg, providerPaymentTx) : "(dry run)"),
        );
      } else {
        notes.push("Borrower still lacks the compute cost: the advance was insufficient.");
      }
    } else {
      notes.push("BORROWER_PRIVATE_KEY not configured: provider payment is left to the caller.");
    }

    // ---- 9. return the result to the buyer ---------------------------
    const providerResult = {
      serviceId: this.cfg.service.serviceId,
      output: this.cfg.service.endpoint.startsWith("http")
        ? `[demo] provider response for prompt: ${params.prompt}`
        : `[local] provider response for prompt: ${params.prompt}`,
      simulated: true,
    };

    // Preview what the router will do with the buyer payment (read-only).
    const buyerPayment = this.cc.units(params.buyerPaymentUsdc ?? process.env.BUYER_PAYMENT_USDC ?? "0.10");
    const preview = await this.cc.previewRouting(borrower, buyerPayment);

    return {
      borrower,
      jobHash,
      provider,
      serviceId: this.cfg.service.serviceId,
      computeCost,
      providerPaid,
      advanceRequired,
      requestedAdvance,
      providerPaymentTx,
      providerResult,
      preview: { serviceAmount: preview.serviceAmount, borrowerAmount: preview.borrowerAmount, lienActive: preview.lienActive },
      notes,
    };
  }

  /**
   * Steps 10-11: route a buyer payment through the registered revenue source.
   */
  async routeBuyerPayment(borrower: string, amountUsdc: string, paymentRef?: string): Promise<Record<string, string>> {
    const amount = this.cc.units(amountUsdc);
    const ref = paymentRef ?? `buyer-payment-${Date.now()}`;

    const preview = await this.cc.previewRouting(borrower, amount);
    if (this.cfg.dryRun) {
      return {
        mode: "dry-run",
        amount: this.cc.fmt(amount),
        serviceAmount: this.cc.fmt(preview.serviceAmount),
        lienCapture: this.cc.fmt(preview.lienCaptureAmount),
        borrowerAmount: this.cc.fmt(preview.borrowerAmount),
      };
    }

    const wallet = signingWallet(this.cfg.buyerPrivateKey ?? this.cfg.operatorPrivateKey, this.cc.provider);
    const router = this.cc.router.connect(wallet) as any;
    const usdc = this.cc.requireUsdc().connect(wallet) as any;

    // The payer must approve the router for the payment amount.
    const allowance: bigint = await this.cc.requireUsdc().allowance(await wallet.getAddress(), this.cfg.routerAddress);
    if (allowance < amount) {
      const approveTx = await usdc.approve(this.cfg.routerAddress, amount);
      await approveTx.wait();
    }

    const tx = await router.routePayment(borrower, amount, this.cc.hashOf(ref));
    const receipt = await tx.wait();
    const hash = receipt?.hash ?? tx.hash;

    return {
      txHash: hash,
      explorer: explorerLink(this.cfg, hash),
      amount: this.cc.fmt(amount),
      serviceAmount: this.cc.fmt(preview.serviceAmount),
      lienCapture: this.cc.fmt(preview.lienCaptureAmount),
      borrowerAmount: this.cc.fmt(preview.borrowerAmount),
    };
  }

  /** Step 12: record a work attestation hash onchain (attester key required). */
  async attestWork(agent: string, workHash: string, paymentTxHash: string, attesterKey: string): Promise<string> {
    const wallet = signingWallet(attesterKey, this.cc.provider);
    const passport = this.cc.passport.connect(wallet) as any;
    const nonce: bigint = await this.cc.passport.attestationNonce(agent);
    const attestation = {
      agent,
      workHash: this.cc.hashOf(workHash),
      paymentTxHash: this.cc.hashOf(paymentTxHash),
      issuedAt: Math.floor(Date.now() / 1000),
      nonce,
    };

    if (this.cfg.dryRun) return "dry-run";
    const tx = await passport.attest(attestation);
    const receipt = await tx.wait();
    return receipt?.hash ?? tx.hash;
  }

  /**
   * Step 13: monitor expiry and penalize when appropriate. Permissionless by design; the keeper
   * key only pays gas.
   */
  async monitorAndPenalize(borrowers: string[], keeperKey?: string): Promise<string[]> {
    const actions: string[] = [];
    for (const borrower of borrowers) {
      const advance = await this.cc.advanceOf(borrower);
      if (!advance.active) continue;

      const now = await this.cc.blockTimestamp(); // the chain clock is the authority for expiry
      if (now <= advance.dueAt) {
        actions.push(
          `${borrower}: advance active, ${advance.dueAt - now}s until dueAt, remaining ${this.cc.fmt(advance.remaining)}`,
        );
        continue;
      }

      if (this.cfg.dryRun) {
        actions.push(`${borrower}: EXPIRED (would call penalize, shortfall ${this.cc.fmt(advance.remaining)})`);
        continue;
      }

      const wallet = signingWallet(keeperKey ?? this.cfg.operatorPrivateKey, this.cc.provider);
      const vault = this.cc.vault.connect(wallet) as any;
      const tx = await vault.penalize(borrower);
      const receipt = await tx.wait();
      actions.push(
        `${borrower}: penalized. shortfall ${this.cc.fmt(advance.remaining)}, lien target ${this.cc.fmt(
          (advance.remaining * 15_000n) / 10_000n,
        )}. ${explorerLink(this.cfg, receipt?.hash ?? tx.hash)}`,
      );
    }
    return actions;
  }

  /** Human-readable pool report used by `/pool` and the dashboard. */
  async poolReport(): Promise<string> {
    const pool = await this.cc.poolState();
    const lines = [
      `idle assets (withdrawable) : ${this.cc.fmt(pool.idleAssets)}`,
      `total pool shares          : ${pool.totalShares}`,
      `total outstanding principal: ${this.cc.fmt(pool.totalOutstanding)}  (receivable, not liquidity)`,
      `active advances            : ${pool.activeAdvanceCount}`,
      `utilisation                : ${Number(pool.utilizationBps) / 100}%`,
      `lifetime issued / serviced : ${this.cc.fmt(pool.totalIssued)} / ${this.cc.fmt(pool.totalServiced)}`,
      `lifetime shortfall         : ${this.cc.fmt(pool.totalShortfall)}  (unrecovered defaults)`,
      `lifetime lien recovered    : ${this.cc.fmt(pool.totalLienCaptured)}  (conditional, not guaranteed)`,
    ];
    return lines.join("\n");
  }

  /** Human-readable borrower report used by `/score` and `/history`. */
  async borrowerReport(borrower: string): Promise<string> {
    const [state, advance] = await Promise.all([this.cc.borrowerState(borrower), this.cc.advanceOf(borrower)]);
    const tierNames = ["", "new / minimal history", "some successful history", "established", "strong history"];
    const lines = [
      `borrower      : ${borrower}`,
      `score         : ${state.score} / 1000 (tier ${state.tier}: ${tierNames[Number(state.tier)]})`,
      `advance limit : ${this.cc.fmt(state.maxAdvance)} (tier ceiling, never a general credit line)`,
      `advance       : ${
        advance.active
          ? `active, remaining ${this.cc.fmt(advance.remaining)} of ${this.cc.fmt(advance.principal)}, due ${new Date(
              advance.dueAt * 1000,
            ).toISOString()}`
          : advance.settled
            ? `settled (serviced ${this.cc.fmt(advance.serviced)})`
            : advance.defaulted
              ? `DEFAULTED (shortfall recorded, lien target ${this.cc.fmt(advance.lienTarget)})`
              : "none"
      }`,
      `lien          : ${
        advance.lienCaptured < advance.lienTarget
          ? `active, captured ${this.cc.fmt(advance.lienCaptured)} of ${this.cc.fmt(
              advance.lienTarget,
            )} (revenue capture ${advance.revenueLienBps} bps)`
          : "none"
      }`,
      `revenue route : ${advance.revenueSource}`,
    ];
    return lines.join("\n");
  }
}

export { formatUnits, parseUnits };
