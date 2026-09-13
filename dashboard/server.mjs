#!/usr/bin/env node
/**
 * ComputeCredit read-only dashboard server.
 *
 * Spec reference: ComputeCredit_v2.pdf §12 (Dashboard requirements).
 *
 * The dashboard displays:
 *   - idle USDC in the vault (actual, withdrawable liquidity);
 *   - total pool shares;
 *   - total outstanding principal (a receivable, NOT liquidity);
 *   - active advances with serviced and remaining amounts;
 *   - borrower scores;
 *   - defaulted borrowers and lien targets (conditional, NOT guaranteed assets);
 *   - event links to the relevant explorer;
 *   - router and provider configuration;
 *   - an explicit "demo trust assumptions" notice.
 *
 * The three value classes are kept strictly separate in the API and in the UI: they are never
 * combined into a single "guaranteed assets" number, and no lender-return figure is implied.
 *
 * Zero external framework dependencies: Node's HTTP server plus ethers for JSON-RPC reads. All
 * reads use `eth_call`; the server holds no keys and cannot move funds.
 */
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

import { AbiCoder, Contract, JsonRpcProvider, getAddress, formatUnits } from "ethers";

const HERE = dirname(fileURLToPath(import.meta.url));

const ABI = {
  vault: [
    "function idleAssets() view returns (uint256)",
    "function totalShares() view returns (uint256)",
    "function totalOutstanding() view returns (uint256)",
    "function totalIssued() view returns (uint256)",
    "function totalServiced() view returns (uint256)",
    "function totalShortfall() view returns (uint256)",
    "function totalLienCaptured() view returns (uint256)",
    "function utilizationBps() view returns (uint256)",
    "function activeAdvanceCount() view returns (uint256)",
    "function approvedRouters(address) view returns (bool)",
    "function approvedOperators(address) view returns (bool)",
    "function shares(address) view returns (uint256)",
    "function maxWithdrawable(address) view returns (uint256)",
    "function idleClaimOf(address) view returns (uint256)",
    "function hasActiveAdvance(address) view returns (bool)",
    "function remainingPrincipal(address) view returns (uint256)",
    "function advanceHistoryCount(address) view returns (uint256)",
    "function advanceView(address) view returns (uint256 principal, uint256 serviced, uint256 remaining, uint256 issuedAt, uint256 dueAt, uint256 splitBps, bytes32 jobHash, address borrower, address provider, address revenueSource, bool settled, bool defaulted, bool active, bool expired, uint256 lienTarget, uint256 lienCaptured, uint256 revenueLienBps)",
    "event LiquidityDeposited(address indexed lender, uint256 amount, uint256 sharesMinted)",
    "event LiquidityWithdrawn(address indexed lender, uint256 amount, uint256 sharesBurned)",
    "event AdvanceRequested(address indexed borrower, address indexed provider, uint256 principal, bytes32 indexed jobHash, address revenueSource, address payoutDestination, uint256 dueAt, uint256 splitBps)",
    "event AdvanceServiced(address indexed borrower, uint256 amount, uint256 serviced, uint256 remaining, bool settled)",
    "event AdvanceSettled(address indexed borrower, uint256 principal, uint256 scoreAfterwards)",
    "event AdvanceDefaulted(address indexed borrower, uint256 shortfall, uint256 lienTarget, uint256 dueAt)",
    "event LienCaptured(address indexed borrower, uint256 captured, uint256 remainder, uint256 lienCaptured, uint256 lienTarget, bool cleared)",
    "event AdvanceRepaidEarly(address indexed borrower, uint256 amount, uint256 remaining, bool settled)",
  ],
  router: [
    "function totalRoutedVolume() view returns (uint256)",
    "function totalServicedVolume() view returns (uint256)",
    "function totalLienCapturedVolume() view returns (uint256)",
    "function authorizedPayerCount() view returns (uint256)",
    "function vault() view returns (address)",
    "event PaymentRouted(address indexed payer, address indexed borrower, uint256 amount, uint256 serviced, uint256 lienCaptured, uint256 forwardedToBorrower, bytes32 indexed paymentRef)",
  ],
  passport: [
    "function score(address) view returns (uint256)",
    "function tierOf(address) view returns (uint256)",
    "function maxAdvance(address) view returns (uint256)",
    "function lienTarget(address) view returns (uint256)",
    "function lienCaptured(address) view returns (uint256)",
    "function revenueLienBps(address) view returns (uint256)",
    "function attestationCount(address) view returns (uint256)",
  ],
  registry: [
    "event ProviderRegistered(address indexed provider, address indexed providerWallet, uint256 pricePerJob, bytes32 serviceId)",
    "function isActive(address) view returns (bool)",
    "function pricePerJob(address) view returns (uint256)",
    "function providerCount() view returns (uint256)",
    "function quoteOf(address) view returns (bool active, address providerWallet, uint256 pricePerJob, uint256 updatedAt, bytes32 serviceId)",
  ],
  usdc: ["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)"],
};

const CONFIG = {
  rpcUrl: process.env.RPC_URL ?? "http://127.0.0.1:8545",
  chainId: Number(process.env.CHAIN_ID ?? 31337),
  port: Number(process.env.DASHBOARD_PORT ?? 8787),
  host: process.env.DASHBOARD_HOST ?? "0.0.0.0",
  explorerBaseUrl: process.env.EXPLORER_BASE_URL ?? "",
  fromBlock: process.env.DASHBOARD_FROM_BLOCK ? Number(process.env.DASHBOARD_FROM_BLOCK) : 0,
  refreshMs: Number(process.env.DASHBOARD_REFRESH_MS ?? 5000),
  expectedLenders: (process.env.DASHBOARD_LENDERS ?? "").split(",").filter(Boolean),
};

function loadDeployment() {
  const candidates = [
    process.env.DEPLOYMENT_PATH,
    resolve(HERE, "..", "contracts", "deployments", `${CONFIG.chainId}.json`),
  ].filter(Boolean);

  for (const path of candidates) {
    if (path && existsSync(path)) {
      try {
        return JSON.parse(readFileSync(path, "utf8"));
      } catch {
        // fall through to environment variables
      }
    }
  }
  return {};
}

const deployment = loadDeployment();

const ADDRESSES = {
  vault: process.env.VAULT_ADDRESS ?? deployment.vault ?? "",
  router: process.env.ROUTER_ADDRESS ?? deployment.revenueRouter ?? "",
  passport: process.env.PASSPORT_ADDRESS ?? deployment.trustPassport ?? "",
  registry: process.env.REGISTRY_ADDRESS ?? deployment.providerRegistry ?? "",
  usdc: process.env.USDC_ADDRESS ?? deployment.usdc ?? "",
  provider: process.env.PROVIDER_ADDRESS ?? deployment.provider ?? "",
};

const provider = new JsonRpcProvider(CONFIG.rpcUrl, CONFIG.chainId, { staticNetwork: true });
const contracts = {
  vault: ADDRESSES.vault ? new Contract(getAddress(ADDRESSES.vault), ABI.vault, provider) : undefined,
  router: ADDRESSES.router ? new Contract(getAddress(ADDRESSES.router), ABI.router, provider) : undefined,
  passport: ADDRESSES.passport ? new Contract(getAddress(ADDRESSES.passport), ABI.passport, provider) : undefined,
  registry: ADDRESSES.registry ? new Contract(getAddress(ADDRESSES.registry), ABI.registry, provider) : undefined,
  usdc: ADDRESSES.usdc ? new Contract(getAddress(ADDRESSES.usdc), ABI.usdc, provider) : undefined,
};

let decimals = 6;

function fmt(value) {
  return formatUnits(value ?? 0n, decimals);
}

function explorerTx(hash) {
  if (!hash || !CONFIG.explorerBaseUrl) return null;
  return `${CONFIG.explorerBaseUrl.replace(/\/$/, "")}/tx/${hash}`;
}

function explorerAddress(address) {
  if (!address || !CONFIG.explorerBaseUrl) return null;
  return `${CONFIG.explorerBaseUrl.replace(/\/$/, "")}/address/${address}`;
}

/** Collects the borrowers the vault has ever issued an advance to, from event history. */
async function collectBorrowers() {
  if (!contracts.vault) return [];
  const filter = contracts.vault.filters.AdvanceRequested();
  const fromBlock = CONFIG.fromBlock;
  const toBlock = await provider.getBlockNumber();

  // Chunk the log query so public RPCs with narrow ranges still work.
  const chunkSize = 50_000;
  const borrowers = new Set();
  for (let start = fromBlock; start <= toBlock; start += chunkSize) {
    const end = Math.min(start + chunkSize - 1, toBlock);
    const logs = await contracts.vault.queryFilter(filter, start, end).catch(() => []);
    for (const log of logs) borrowers.add(log.args[0]);
  }
  return [...borrowers];
}

/** Collects lender addresses from deposit events. */
async function collectLenders() {
  if (!contracts.vault) return [];
  const filter = contracts.vault.filters.LiquidityDeposited();
  const toBlock = await provider.getBlockNumber();
  const logs = await contracts.vault.queryFilter(filter, CONFIG.fromBlock, toBlock).catch(() => []);
  const lenders = new Set(logs.map((log) => log.args[0]));
  for (const lender of CONFIG.expectedLenders) lenders.add(lender);
  return [...lenders];
}

async function recentEvents(limit = 25) {
  if (!contracts.vault) return [];
  const events = [];
  const toBlock = await provider.getBlockNumber();
  const names = [
    "LiquidityDeposited",
    "LiquidityWithdrawn",
    "AdvanceRequested",
    "AdvanceServiced",
    "AdvanceSettled",
    "AdvanceDefaulted",
    "LienCaptured",
    "AdvanceRepaidEarly",
  ];

  for (const name of names) {
    const logs = await contracts.vault.queryFilter(contracts.vault.filters[name](), CONFIG.fromBlock, toBlock).catch(() => []);
    for (const log of logs) {
      events.push({
        name,
        block: log.blockNumber,
        txHash: log.transactionHash,
        explorer: explorerTx(log.transactionHash),
        args: log.args.map((value) => (typeof value === "bigint" ? value.toString() : value)),
      });
    }
  }

  return events.sort((a, b) => b.block - a.block).slice(0, limit);
}

async function buildState() {
  if (!contracts.vault) {
    return {
      ok: false,
      error:
        "No vault address configured. Set VAULT_ADDRESS or place a deployment record at contracts/deployments/<chainId>.json",
      config: { ...CONFIG, addresses: ADDRESSES },
    };
  }

  decimals = await contracts.usdc.decimals().then(Number).catch(() => 6);

  const [poolRaw, borrowers, lenders, events] = await Promise.all([
    Promise.all([
      contracts.vault.idleAssets(),
      contracts.vault.totalShares(),
      contracts.vault.totalOutstanding(),
      contracts.vault.totalIssued(),
      contracts.vault.totalServiced(),
      contracts.vault.totalShortfall(),
      contracts.vault.totalLienCaptured(),
      contracts.vault.utilizationBps(),
      contracts.vault.activeAdvanceCount(),
    ]),
    collectBorrowers(),
    collectLenders(),
    recentEvents(),
  ]);

  const [idleAssets, totalShares, totalOutstanding, totalIssued, totalServiced, totalShortfall, totalLienCaptured, utilizationBps, activeAdvanceCount] =
    poolRaw;

  const advances = await Promise.all(
    borrowers.map(async (borrower) => {
      const [view, score, tier, maxAdvance] = await Promise.all([
        contracts.vault.advanceView(borrower),
        contracts.passport.score(borrower),
        contracts.passport.tierOf(borrower),
        contracts.passport.maxAdvance(borrower),
      ]);
      const status = view.settled ? "settled" : view.defaulted ? "defaulted" : view.active ? (view.expired ? "expired" : "active") : "none";
      return {
        borrower,
        status,
        principal: fmt(view.principal),
        serviced: fmt(view.serviced),
        remaining: fmt(view.remaining),
        issuedAt: Number(view.issuedAt),
        dueAt: Number(view.dueAt),
        splitBps: Number(view.splitBps),
        jobHash: view.jobHash,
        provider: view.provider,
        revenueSource: view.revenueSource,
        score: score.toString(),
        tier: Number(tier),
        tierLimit: fmt(maxAdvance),
        lienTarget: fmt(view.lienTarget),
        lienCaptured: fmt(view.lienCaptured),
        revenueLienBps: Number(view.revenueLienBps),
        lienActive: view.lienCaptured < view.lienTarget,
      };
    }),
  );

  const lenderStates = await Promise.all(
    lenders.map(async (lender) => {
      const [shares, idleClaim, maxWithdrawable] = await Promise.all([
        contracts.vault.shares(lender),
        contracts.vault.idleClaimOf(lender),
        contracts.vault.maxWithdrawable(lender),
      ]);
      return {
        lender,
        shares: shares.toString(),
        sharePct: totalShares === 0n ? "0" : ((Number(shares) / Number(totalShares)) * 100).toFixed(4),
        idleClaim: fmt(idleClaim),
        maxWithdrawable: fmt(maxWithdrawable),
      };
    }),
  );

  // Provider configuration: explicit address first, otherwise the first ProviderRegistered event.
  let providerAddress = ADDRESSES.provider;
  let registeredEvent;
  if (contracts.registry) {
    const registrations = await contracts.registry
      .queryFilter(contracts.registry.filters.ProviderRegistered(), CONFIG.fromBlock, "latest")
      .catch(() => []);
    if (registrations.length > 0) registeredEvent = registrations[0];
    if (!providerAddress && registeredEvent) providerAddress = registeredEvent.args[0];
  }

  const providerQuote = providerAddress
    ? await contracts.registry.quoteOf(providerAddress).catch(() => undefined)
    : undefined;

  const routerTotals = contracts.router
    ? await Promise.all([
        contracts.router.totalRoutedVolume().catch(() => 0n),
        contracts.router.totalServicedVolume().catch(() => 0n),
        contracts.router.totalLienCapturedVolume().catch(() => 0n),
      ])
    : [0n, 0n, 0n];

  return {
    ok: true,
    generatedAt: new Date().toISOString(),
    config: {
      rpcUrl: CONFIG.rpcUrl,
      chainId: CONFIG.chainId,
      explorerBaseUrl: CONFIG.explorerBaseUrl,
      refreshMs: CONFIG.refreshMs,
      addresses: ADDRESSES,
      addressLinks: Object.fromEntries(Object.entries(ADDRESSES).map(([k, v]) => [k, explorerAddress(v)])),
    },
    pool: {
      // This block is the honest separation required by spec §12.
      actualLiquidityUsdc: fmt(idleAssets),
      outstandingReceivablesUsdc: fmt(totalOutstanding),
      conditionalLienTargetsUsdc: fmt(advances.reduce((sum, a) => (a.lienActive ? sum + BigInt(Math.round(Number(a.lienTarget) * 1e6)) : sum), 0n)),
      totalShares: totalShares.toString(),
      activeAdvanceCount: Number(activeAdvanceCount),
      utilizationPct: (Number(utilizationBps) / 100).toFixed(2),
      lifetime: {
        issuedUsdc: fmt(totalIssued),
        servicedUsdc: fmt(totalServiced),
        shortfallUsdc: fmt(totalShortfall),
        lienRecoveredUsdc: fmt(totalLienCaptured),
      },
      routedVolumeUsdc: fmt(routerTotals[0]),
      routedServicedUsdc: fmt(routerTotals[1]),
      routedLienCapturedUsdc: fmt(routerTotals[2]),
    },
    advances,
    lenders: lenderStates,
    provider: providerQuote
      ? {
          address: providerAddress,
          active: providerQuote.active,
          providerWallet: providerQuote.providerWallet,
          pricePerJobUsdc: fmt(providerQuote.pricePerJob),
          updatedAt: Number(providerQuote.updatedAt),
          serviceId: providerQuote.serviceId,
        }
      : null,
    router: {
      address: ADDRESSES.router,
      vault: ADDRESSES.vault,
    },
    events,
    trustAssumptions: [
      "The orchestrator may submit a request for a borrower if the borrower has authorised that action or the demo wallet is controlled by the orchestrator.",
      "The orchestrator may issue work attestations.",
      "The revenue router controls the registered demo receiving path.",
      "Lien enforcement is conditional on revenue routed through that registered source. Payments outside the route are not captured.",
      "The protocol does not promise that every default is recovered, and lenders are not guaranteed a return.",
    ],
  };
}

// ---------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------

const server = createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);

  try {
    if (url.pathname === "/api/state") {
      const state = await buildState();
      response.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
      response.end(JSON.stringify(state, null, 2));
      return;
    }

    if (url.pathname === "/health") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({ ok: true, chainId: CONFIG.chainId }));
      return;
    }

    const file = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\//, "");
    const path = join(HERE, "public", file);
    if (!path.startsWith(join(HERE, "public")) || !existsSync(path)) {
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
      return;
    }

    const type = path.endsWith(".html") ? "text/html" : path.endsWith(".css") ? "text/css" : "application/javascript";
    response.writeHead(200, { "content-type": `${type}; charset=utf-8`, "cache-control": "no-store" });
    response.end(readFileSync(path));
  } catch (error) {
    response.writeHead(500, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: false, error: error.message }));
  }
});

server.listen(CONFIG.port, CONFIG.host, () => {
  console.log(`ComputeCredit dashboard on http://${CONFIG.host}:${CONFIG.port}`);
  console.log(`  RPC      : ${CONFIG.rpcUrl} (chain ${CONFIG.chainId})`);
  console.log(`  vault    : ${ADDRESSES.vault || "(not configured)"}`);
  console.log(`  router   : ${ADDRESSES.router || "(not configured)"}`);
  console.log(`  passport : ${ADDRESSES.passport || "(not configured)"}`);
  console.log("Read-only: this process holds no keys and sends no transactions.");
});
