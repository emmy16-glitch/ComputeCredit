/**
 * Chain access layer for the ComputeCredit orchestrator.
 *
 * Spec reference: ComputeCredit_v2.pdf §11.1 (Orchestrator lifecycle: read balance, read score,
 * read provider price, request an advance, pay the provider, route revenue, monitor expiry).
 *
 * Contract reads are the authority. Every offchain check in this file is a user-experience
 * convenience that mirrors an onchain rule; the vault re-checks all of them.
 */
import { AbiCoder, Contract, JsonRpcProvider, NonceManager, Wallet, getAddress, keccak256, toUtf8Bytes, type ContractTransactionResponse } from "ethers";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { formatUnits, parseUnits, type AppConfig } from "./config.ts";

const ABI_DIR = resolve(import.meta.dirname ?? ".", "abi");

function loadAbi(name: string): any[] {
  return JSON.parse(readFileSync(resolve(ABI_DIR, `${name}.json`), "utf8"));
}

export interface AdvanceState {
  principal: bigint;
  serviced: bigint;
  remaining: bigint;
  dueAt: number;
  splitBps: bigint;
  jobHash: string;
  provider: string;
  revenueSource: string;
  settled: boolean;
  defaulted: boolean;
  active: boolean;
  expired: boolean;
  lienTarget: bigint;
  lienCaptured: bigint;
  revenueLienBps: bigint;
}

export interface PoolState {
  idleAssets: bigint;
  totalShares: bigint;
  totalOutstanding: bigint;
  totalIssued: bigint;
  totalServiced: bigint;
  totalShortfall: bigint;
  totalLienCaptured: bigint;
  utilizationBps: bigint;
  activeAdvanceCount: bigint;
}

export interface BorrowerState {
  address: string;
  score: bigint;
  tier: bigint;
  maxAdvance: bigint;
  idleClaim: bigint;
}

/**
 * A signer that tracks nonces locally.
 *
 * Several flows send two transactions back to back from the same account (approve + route,
 * request + pay). Relying on a fresh `eth_getTransactionCount` for the second one races with the
 * node's pending state and can produce `NONCE_EXPIRED`; the nonce manager removes that race.
 */
export function signingWallet(privateKey: string, provider: JsonRpcProvider): NonceManager {
  return new NonceManager(new Wallet(privateKey, provider));
}

export class ComputeCredit {
  readonly provider: JsonRpcProvider;
  readonly vault: Contract;
  readonly router: Contract;
  readonly passport: Contract;
  readonly registry: Contract;
  readonly usdc: Contract | undefined;

  readonly cfg: AppConfig;

  constructor(cfg: AppConfig) {
    this.cfg = cfg;
    if (!cfg.vaultAddress || !cfg.routerAddress || !cfg.passportAddress || !cfg.registryAddress) {
      throw new Error(
        "Missing contract addresses. Set VAULT_ADDRESS/ROUTER_ADDRESS/PASSPORT_ADDRESS/REGISTRY_ADDRESS " +
          "or point CHAIN_ID at a deployment record in contracts/deployments/<chainId>.json",
      );
    }

    this.provider = new JsonRpcProvider(cfg.rpcUrl, cfg.chainId, { staticNetwork: true });
    this.vault = new Contract(getAddress(cfg.vaultAddress), loadAbi("ComputeCreditVault"), this.provider);
    this.router = new Contract(getAddress(cfg.routerAddress), loadAbi("RevenueRouter"), this.provider);
    this.passport = new Contract(getAddress(cfg.passportAddress), loadAbi("TrustPassport"), this.provider);
    this.registry = new Contract(getAddress(cfg.registryAddress), loadAbi("ProviderRegistry"), this.provider);
    if (cfg.usdcAddress) {
      this.usdc = new Contract(getAddress(cfg.usdcAddress), loadAbi("MockUSDC"), this.provider);
    }
  }

  // ---------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------

  async poolState(): Promise<PoolState> {
    const [idle, shares, outstanding, issued, serviced, shortfall, lienRecovered, utilization, activeCount] =
      await Promise.all([
        this.vault.idleAssets(),
        this.vault.totalShares(),
        this.vault.totalOutstanding(),
        this.vault.totalIssued(),
        this.vault.totalServiced(),
        this.vault.totalShortfall(),
        this.vault.totalLienCaptured(),
        this.vault.utilizationBps(),
        this.vault.activeAdvanceCount(),
      ]);

    return {
      idleAssets: idle,
      totalShares: shares,
      totalOutstanding: outstanding,
      totalIssued: issued,
      totalServiced: serviced,
      totalShortfall: shortfall,
      totalLienCaptured: lienRecovered,
      utilizationBps: utilization,
      activeAdvanceCount: activeCount,
    };
  }

  async advanceOf(borrower: string): Promise<AdvanceState> {
    const view = await this.vault.advanceView(borrower);
    return {
      principal: view[0],
      serviced: view[1],
      remaining: view[2],
      dueAt: Number(view[4]),
      splitBps: view[5],
      jobHash: view[6],
      provider: view[8],
      revenueSource: view[9],
      settled: view[10],
      defaulted: view[11],
      active: view[12],
      expired: view[13],
      lienTarget: view[14],
      lienCaptured: view[15],
      revenueLienBps: view[16],
    };
  }

  async borrowerState(borrower: string): Promise<BorrowerState> {
    const [score, tier, maxAdvance, idleClaim] = await Promise.all([
      this.passport.score(borrower),
      this.passport.tierOf(borrower),
      this.passport.maxAdvance(borrower),
      this.vault.idleClaimOf(borrower),
    ]);
    return { address: borrower, score, tier, maxAdvance, idleClaim };
  }

  async balanceOf(account: string): Promise<bigint> {
    if (!this.usdc) return 0n;
    return this.usdc.balanceOf(account);
  }

  /**
   * The chain clock. Expiry decisions (dueAt) must use this, never the local wall clock: after
   * a local time jump or on a network with a different clock the two disagree.
   */
  async blockTimestamp(): Promise<number> {
    const block = await this.provider.getBlock("latest");
    return block?.timestamp ?? Math.floor(Date.now() / 1000);
  }

  /** The settlement asset, or a clear error when USDC_ADDRESS is not configured. */
  requireUsdc(): Contract {
    if (!this.usdc) throw new Error("USDC_ADDRESS is not configured in the environment");
    return this.usdc;
  }

  async providerQuote(provider: string) {
    const quote = await this.registry.quoteOf(provider);
    return {
      active: quote[0],
      providerWallet: quote[1],
      pricePerJob: quote[2],
      updatedAt: Number(quote[3]),
      serviceId: quote[4],
    };
  }

  async previewRouting(borrower: string, amount: bigint) {
    const preview = await this.router.previewRouting(borrower, amount);
    return {
      serviceAmount: preview[0],
      lienCaptureAmount: preview[1],
      borrowerAmount: preview[2],
      lienActive: preview[3],
      advanceActive: preview[4],
      destination: preview[5],
    };
  }

  /**
   * Canonical job hash (spec §6):
   *   jobHash = keccak256(abi.encode(borrower, provider, serviceId, quotedPrice, nonce, expiry))
   *
   * The hash binds the advance to one borrower, one provider, one service, one price and one
   * offchain authorisation. The vault stores it onchain; a reused hash is rejected.
   */
  jobHash(
    borrower: string,
    provider: string,
    serviceId: string,
    quotedPrice: bigint,
    nonce: number | bigint,
    expiry: number,
  ): string {
    const encoded = AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "bytes32", "uint256", "uint256", "uint256"],
      [getAddress(borrower), getAddress(provider), serviceId, quotedPrice, nonce, expiry],
    );
    return keccak256(encoded);
  }

  // ---------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------

  async requestAdvance(
    operatorKey: string,
    borrower: string,
    provider: string,
    computeCost: bigint,
    jobHash: string,
    revenueSource: string,
  ): Promise<ContractTransactionResponse> {
    const wallet = new Wallet(operatorKey, this.provider);
    const vault = this.vault.connect(wallet) as Contract;
    return vault.requestComputeAdvanceFor(borrower, provider, computeCost, jobHash, revenueSource);
  }

  async serviceAdvance(routerKey: string, borrower: string, amount: bigint): Promise<ContractTransactionResponse> {
    const wallet = new Wallet(routerKey, this.provider);
    const vault = this.vault.connect(wallet) as Contract;
    return vault.serviceAdvanceWithTransfer(borrower, amount);
  }

  async captureLien(routerKey: string, borrower: string, amount: bigint): Promise<ContractTransactionResponse> {
    const wallet = new Wallet(routerKey, this.provider);
    const vault = this.vault.connect(wallet) as Contract;
    return vault.captureLien(borrower, amount);
  }

  async repayEarly(borrowerKey: string, borrower: string, amount: bigint): Promise<ContractTransactionResponse> {
    const wallet = new Wallet(borrowerKey, this.provider);
    const vault = this.vault.connect(wallet) as Contract;
    return vault.repayEarly(borrower, amount);
  }

  async payProvider(borrowerKey: string, providerWallet: string, amount: bigint): Promise<ContractTransactionResponse> {
    if (!this.usdc) throw new Error("USDC_ADDRESS is not configured - cannot pay the provider");
    const wallet = new Wallet(borrowerKey, this.provider);
    const usdc = this.usdc.connect(wallet) as Contract;
    return usdc.transfer(providerWallet, amount);
  }

  // ---------------------------------------------------------------------
  // Formatting helpers
  // ---------------------------------------------------------------------

  fmt(value: bigint): string {
    return `${formatUnits(value, this.cfg.usdcDecimals)} USDC`;
  }

  units(value: string): bigint {
    return parseUnits(value, this.cfg.usdcDecimals);
  }

  hashOf(value: string): string {
    return keccak256(toUtf8Bytes(value));
  }
}
