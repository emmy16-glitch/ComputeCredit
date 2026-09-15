import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createPublicClient, http, formatUnits, type Address } from "viem";
import "dotenv/config";

/**
 * ComputeCredit A2MCP service (OKX AI "Build a Company" leg).
 * GET /health, GET /score?wallet=, GET /pool, GET /quote, POST /mcp
 * x402: X402_ENABLED=1 -> 402 + PAYMENT-REQUIRED header (v2 challenge shape).
 * Free mode (default): 200 directly. Both are A2MCP-compliant.
 * Run: npm run mcp  (MCP_PORT default 4021)
 */

const PORT = Number(process.env.MCP_PORT ?? 4021);
const X402_ENABLED = process.env.X402_ENABLED === "1";
const NETWORK = process.env.X402_NETWORK ?? "eip155:1952";
const PAY_TO = process.env.PAY_TO_ADDRESS ?? "0x0000000000000000000000000000000000000000";
const PRICE = process.env.X402_PRICE ?? "$0.01";
const RPC = process.env.RPC_URL ?? "https://testrpc.xlayer.tech/terigon";

const VAULT = process.env.VAULT as Address | undefined;
const PASSPORT = process.env.PASSPORT as Address | undefined;
const REGISTRY = process.env.REGISTRY as Address | undefined;
const RWA = (process.env.RWA_COLLATERAL ?? process.env.RWA) as Address | undefined;
const PROVIDER = process.env.PROVIDER as Address | undefined;

const vaultAbi = [
  { name: "totalAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "totalOutstanding", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "activeAdvanceId", type: "function", stateMutability: "view", inputs: [{ name: "b", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "effectiveLimit", type: "function", stateMutability: "view", inputs: [{ name: "borrower", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;
const passportAbi = [
  { name: "score", type: "function", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "maxAdvanceForScore", type: "function", stateMutability: "view", inputs: [{ name: "s", type: "uint256" }], outputs: [{ type: "uint256" }] },
] as const;
const registryAbi = [
  { name: "quote", type: "function", stateMutability: "view", inputs: [{ name: "p", type: "address" }], outputs: [{ name: "pricePerJob", type: "uint256" }, { name: "payout", type: "address" }] },
] as const;
const rwaAbi = [
  { name: "collateralValue", type: "function", stateMutability: "view", inputs: [{ name: "b", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

function pub() {
  return createPublicClient({ transport: http(RPC) });
}

function challenge(resourceUrl: string, description: string): string {
  const payload = {
    x402Version: 2,
    resource: { url: resourceUrl, description, mimeType: "application/json" },
    accepts: [
      {
        scheme: "exact",
        network: NETWORK,
        asset: "0x779ded0c9e1022225f8e0630b35a9b54be713736",
        amount: "10000",
        payTo: PAY_TO,
        maxTimeoutSeconds: 300,
        extra: { name: "USD₮0", version: "1" },
      },
    ],
  };
  return Buffer.from(JSON.stringify(payload)).toString("base64");
}

function send(res: ServerResponse, status: number, body: unknown, extraHeaders: Record<string, string> = {}) {
  res.writeHead(status, { "content-type": "application/json", ...extraHeaders });
  res.end(JSON.stringify(body));
}

function needsPayment(req: IncomingMessage): boolean {
  if (!X402_ENABLED) return false;
  const h = req.headers;
  return h["payment-sig"] === undefined && h["payment-signature"] === undefined;
}

async function getScore(wallet: Address) {
  const c = pub();
  if (!PASSPORT || !VAULT) throw new Error("PASSPORT/VAULT not configured");
  const score = (await c.readContract({ address: PASSPORT, abi: passportAbi, functionName: "score", args: [wallet] })) as bigint;
  const tier = (await c.readContract({ address: PASSPORT, abi: passportAbi, functionName: "maxAdvanceForScore", args: [score] })) as bigint;
  let effective = tier;
  try {
    effective = (await c.readContract({ address: VAULT, abi: vaultAbi, functionName: "effectiveLimit", args: [wallet] })) as bigint;
  } catch { /* pre-RWA vault */ }
  let rwa: string | null = null;
  if (RWA) {
    try {
      const v = (await c.readContract({ address: RWA, abi: rwaAbi, functionName: "collateralValue", args: [wallet] })) as bigint;
      rwa = formatUnits(v, 6);
    } catch { /* ignore */ }
  }
  const active = (await c.readContract({ address: VAULT, abi: vaultAbi, functionName: "activeAdvanceId", args: [wallet] })) as bigint;
  return { wallet, score: score.toString(), maxAdvanceUSDC: formatUnits(tier, 6), effectiveLimitUSDC: formatUnits(effective, 6), rwaCollateralUSDC: rwa, activeAdvanceId: active.toString() };
}

async function getPool() {
  const c = pub();
  if (!VAULT) throw new Error("VAULT not configured");
  const [idle, out] = (await Promise.all([
    c.readContract({ address: VAULT, abi: vaultAbi, functionName: "totalAssets" }),
    c.readContract({ address: VAULT, abi: vaultAbi, functionName: "totalOutstanding" }),
  ])) as [bigint, bigint];
  const denom = idle + out;
  return { idleUSDC: formatUnits(idle, 6), outstandingUSDC: formatUnits(out, 6), utilizationPct: denom === 0n ? 0 : Number((out * 10_000n) / denom) / 100, chain: "X Layer (1952 testnet / 196 mainnet)" };
}

async function getQuote() {
  const c = pub();
  if (!REGISTRY || !PROVIDER) throw new Error("REGISTRY/PROVIDER not configured");
  const [price, payout] = (await c.readContract({ address: REGISTRY, abi: registryAbi, functionName: "quote", args: [PROVIDER] })) as unknown as [bigint, Address];
  return { priceUSDC: formatUnits(price, 6), payout, provider: PROVIDER };
}

function readBody(req: IncomingMessage): Promise<any> {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (d) => (data += d));
    req.on("end", () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch { resolve({}); }
    });
  });
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  try {
    if (url.pathname === "/health") return send(res, 200, { ok: true, x402: X402_ENABLED ? "paid" : "free", network: NETWORK });
    if (url.pathname === "/score") {
      const wallet = url.searchParams.get("wallet") as Address | null;
      if (!wallet) return send(res, 400, { error: "usage: /score?wallet=0x..." });
      if (needsPayment(req!)) return send(res, 402, { error: "payment required", price: PRICE, network: NETWORK }, { "PAYMENT-REQUIRED": challenge(url.toString(), "ComputeCredit credit-score lookup") });
      return send(res, 200, await getScore(wallet));
    }
    if (url.pathname === "/pool") {
      if (needsPayment(req!)) return send(res, 402, { error: "payment required", price: PRICE, network: NETWORK }, { "PAYMENT-REQUIRED": challenge(url.toString(), "ComputeCredit pool state") });
      return send(res, 200, await getPool());
    }
    if (url.pathname === "/quote") {
      if (needsPayment(req!)) return send(res, 402, { error: "payment required", price: PRICE, network: NETWORK }, { "PAYMENT-REQUIRED": challenge(url.toString(), "ComputeCredit provider quote") });
      return send(res, 200, await getQuote());
    }
    if (url.pathname === "/mcp" && req.method === "POST") {
      if (needsPayment(req!)) return send(res, 402, { error: "payment required", price: PRICE, network: NETWORK }, { "PAYMENT-REQUIRED": challenge(url.toString(), "ComputeCredit MCP call") });
      const body = await readBody(req);
      if (body.method === "tools/list") {
        return send(res, 200, { tools: [
          { name: "get_score", description: "Borrower score, tier limit, RWA collateral and active advance", inputSchema: { wallet: "0x..." } },
          { name: "get_pool", description: "Pool idle, outstanding, utilization", inputSchema: {} },
          { name: "get_quote", description: "Provider price per job", inputSchema: {} },
        ] });
      }
      if (body.method === "tools/call") {
        const { tool, args } = body.params ?? {};
        if (tool === "get_score") return send(res, 200, await getScore(args.wallet));
        if (tool === "get_pool") return send(res, 200, await getPool());
        if (tool === "get_quote") return send(res, 200, await getQuote());
        return send(res, 400, { error: `unknown tool ${tool}` });
      }
      return send(res, 400, { error: "unknown MCP method (tools/list, tools/call)" });
    }
    return send(res, 404, { error: "not found", routes: ["GET /health", "GET /score?wallet=", "GET /pool", "GET /quote", "POST /mcp"] });
  } catch (e: any) {
    return send(res, 500, { error: e.message });
  }
});

server.listen(PORT, () => console.log(`[mcp] listening on :${PORT} mode=${X402_ENABLED ? `x402-paid ${NETWORK} ${PRICE}` : "free"}`));
