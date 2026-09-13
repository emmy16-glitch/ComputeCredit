/**
 * ComputeCredit orchestrator configuration.
 *
 * Spec reference: ComputeCredit_v2.pdf §11.2 (Provider registry configuration), §11.1
 * (Orchestrator lifecycle), §18 (Repository structure).
 *
 * Everything is environment driven: "The actual endpoint and addresses must be stored in
 * environment variables or deployment configuration, not hardcoded in source code."
 *
 * Chain and token parameters must be confirmed against current official documentation before
 * any deployment (spec, References note). See .env.example and docs/ARCHITECTURE.md.
 */
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

export interface ServiceConfig {
  providerAddress: string;
  serviceId: string;
  pricePerJobUsdc: string;
  endpoint: string;
  active: boolean;
}

export interface AppConfig {
  rpcUrl: string;
  chainId: number;
  explorerBaseUrl: string;
  usdcAddress: string;
  usdcDecimals: number;
  vaultAddress: string;
  routerAddress: string;
  passportAddress: string;
  registryAddress: string;
  operatorPrivateKey: string;
  lenderPrivateKey?: string;
  borrowerPrivateKey?: string;
  buyerPrivateKey?: string;
  service: ServiceConfig;
  /** Maximum advance the orchestrator will ever request, in USDC (belt-and-braces guard). */
  maxAdvanceUsdc: string;
  /** How much of a buyer payment is routed to the vault through the registered route, in bps. */
  splitBps: number;
  /** Trusted bootstrap score used when a borrower wallet has no history (spec §7.4). */
  bootstrapScore: number;
  dryRun: boolean;
}

const DEFAULTS = {
  rpcUrl: "http://127.0.0.1:8545",
  chainId: 31337,
  explorerBaseUrl: "",
  usdcDecimals: 6,
  splitBps: 2000,
  bootstrapScore: 150,
  maxAdvanceUsdc: "1.0",
};

function env(name: string, fallback?: string): string {
  const value = process.env[name];
  if (value === undefined || value === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function envOptional(name: string): string | undefined {
  const value = process.env[name];
  return value === undefined || value === "" ? undefined : value;
}

/**
 * Loads the deployment record produced by `forge script script/Deploy.s.sol` (or DemoLocal).
 * Addresses may also be supplied explicitly through the environment.
 */
export function loadDeployment(
  chainId: number,
  deploymentsDir = resolve(import.meta.dirname ?? ".", "../contracts/deployments"),
): Record<string, string> | undefined {
  const path = resolve(deploymentsDir, `${chainId}.json`);
  if (!existsSync(path)) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf8")) as Record<string, string>;
  } catch (error) {
    throw new Error(`Failed to parse deployment record at ${path}: ${(error as Error).message}`);
  }
}

export function loadConfig(): AppConfig {
  const chainId = Number(env("CHAIN_ID", String(DEFAULTS.chainId)));
  const deployment = loadDeployment(chainId) ?? {};

  const providerPath = envOptional("PROVIDER_CONFIG_PATH") ?? resolve(import.meta.dirname ?? ".", "providerRegistry.json");
  const providerConfig = JSON.parse(readFileSync(providerPath, "utf8")) as ServiceConfig;

  return {
    rpcUrl: env("RPC_URL", DEFAULTS.rpcUrl),
    chainId,
    explorerBaseUrl: env("EXPLORER_BASE_URL", DEFAULTS.explorerBaseUrl),
    usdcAddress: env("USDC_ADDRESS", deployment.usdc ?? ""),
    usdcDecimals: Number(env("USDC_DECIMALS", String(DEFAULTS.usdcDecimals))),
    vaultAddress: env("VAULT_ADDRESS", deployment.vault ?? ""),
    routerAddress: env("ROUTER_ADDRESS", deployment.revenueRouter ?? ""),
    passportAddress: env("PASSPORT_ADDRESS", deployment.trustPassport ?? ""),
    registryAddress: env("REGISTRY_ADDRESS", deployment.providerRegistry ?? ""),
    operatorPrivateKey: env("OPERATOR_PRIVATE_KEY"),
    lenderPrivateKey: envOptional("LENDER_PRIVATE_KEY"),
    borrowerPrivateKey: envOptional("BORROWER_PRIVATE_KEY"),
    buyerPrivateKey: envOptional("BUYER_PRIVATE_KEY"),
    service: {
      providerAddress: envOptional("PROVIDER_ADDRESS") ?? providerConfig.providerAddress,
      serviceId: envOptional("PROVIDER_SERVICE_ID") ?? providerConfig.serviceId,
      pricePerJobUsdc: envOptional("PROVIDER_PRICE_PER_JOB_USDC") ?? providerConfig.pricePerJobUsdc,
      endpoint: envOptional("PROVIDER_ENDPOINT") ?? providerConfig.endpoint,
      active: providerConfig.active,
    },
    maxAdvanceUsdc: env("MAX_ADVANCE_USDC", DEFAULTS.maxAdvanceUsdc),
    splitBps: Number(env("SPLIT_BPS", String(DEFAULTS.splitBps))),
    bootstrapScore: Number(env("BOOTSTRAP_SCORE", String(DEFAULTS.bootstrapScore))),
    dryRun: env("DRY_RUN", "false") === "true",
  };
}

/** Formats a 6-decimal token amount without floating point drift. */
export function formatUnits(value: bigint, decimals = 6): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const fraction = (abs % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${fraction ? "." + fraction : ""}`;
}

/** Parses a decimal string into 6-decimal token units without floating point drift. */
export function parseUnits(value: string, decimals = 6): bigint {
  const [whole, fraction = ""] = value.trim().split(".");
  const padded = (fraction + "0".repeat(decimals)).slice(0, decimals);
  return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(padded === "" ? "0" : padded);
}

export function explorerLink(cfg: AppConfig, txHash: string): string {
  return cfg.explorerBaseUrl ? `${cfg.explorerBaseUrl.replace(/\/$/, "")}/tx/${txHash}` : txHash;
}
