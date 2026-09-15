import { createPublicClient, createWalletClient, defineChain, http, keccak256, encodePacked, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import "dotenv/config";

// Minimal ABIs — only what the orchestrator needs.
export const vaultAbi = [
  { name: "requestAdvanceFor", type: "function", stateMutability: "nonpayable",
    inputs: [{name:"borrower",type:"address"},{name:"provider",type:"address"},{name:"cost",type:"uint256"},{name:"jobHash",type:"bytes32"},{name:"revenueSource",type:"address"}],
    outputs: [{type:"uint256"}] },
  { name: "requestAdvanceWithSig", type: "function", stateMutability: "nonpayable",
    inputs: [{name:"borrower",type:"address"},{name:"provider",type:"address"},{name:"cost",type:"uint256"},{name:"jobHash",type:"bytes32"},{name:"revenueSource",type:"address"},{name:"nonce",type:"uint256"},{name:"expiry",type:"uint256"},{name:"sig",type:"bytes"}],
    outputs: [{type:"uint256"}] },
  { name: "nonces", type: "function", stateMutability: "view", inputs: [{name:"borrower",type:"address"}], outputs: [{type:"uint256"}] },
  { name: "sigOnlyMode", type: "function", stateMutability: "view", inputs: [], outputs: [{type:"bool"}] },
  { name: "activeAdvanceId", type: "function", stateMutability: "view", inputs: [{name:"borrower",type:"address"}], outputs: [{type:"uint256"}] },
  { name: "remainingOf", type: "function", stateMutability: "view", inputs: [{name:"id",type:"uint256"}], outputs: [{type:"uint256"}] },
  { name: "penalize", type: "function", stateMutability: "nonpayable", inputs: [{name:"borrower",type:"address"}], outputs: [] },
  { name: "totalAssets", type: "function", stateMutability: "view", inputs: [], outputs: [{type:"uint256"}] },
  { name: "totalOutstanding", type: "function", stateMutability: "view", inputs: [], outputs: [{type:"uint256"}] },
] as const;

export const passportAbi = [
  { name: "score", type: "function", stateMutability: "view", inputs: [{name:"agent",type:"address"}], outputs: [{type:"uint256"}] },
  { name: "maxAdvanceForScore", type: "function", stateMutability: "view", inputs: [{name:"s",type:"uint256"}], outputs: [{type:"uint256"}] },
] as const;

export const registryAbi = [
  { name: "quote", type: "function", stateMutability: "view", inputs: [{name:"provider",type:"address"}], outputs: [{name:"pricePerJob",type:"uint256"},{name:"payout",type:"address"}] },
] as const;

export const routerAbi = [
  { name: "routePayment", type: "function", stateMutability: "nonpayable",
    inputs: [{name:"borrower",type:"address"},{name:"amount",type:"uint256"},{name:"borrowerDestination",type:"address"}],
    outputs: [{name:"toVault",type:"uint256"},{name:"toBorrower",type:"uint256"}] },
] as const;

export const identityAbi = [
  { name: "agentOf", type: "function", stateMutability: "view", inputs: [{name:"wallet",type:"address"}], outputs: [{type:"uint256"}] },
  { name: "walletsOf", type: "function", stateMutability: "view", inputs: [{name:"agentId",type:"uint256"}], outputs: [{type:"address[]"}] },
] as const;

export const adapterAbi = [
  { name: "recordAndRoute", type: "function", stateMutability: "nonpayable",
    inputs: [{name:"borrower",type:"address"},{name:"amount",type:"uint256"},{name:"borrowerDestination",type:"address"},{name:"intentHash",type:"bytes32"},{name:"settlementChainId",type:"uint256"}],
    outputs: [{name:"toVault",type:"uint256"},{name:"toBorrower",type:"uint256"},{name:"facilitatorPath",type:"bool"}] },
] as const;
export const erc20Abi = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{name:"a",type:"address"}], outputs: [{type:"uint256"}] },
  { name: "transfer", type: "function", stateMutability: "nonpayable", inputs: [{name:"to",type:"address"},{name:"amount",type:"uint256"}], outputs: [{type:"bool"}] },
] as const;

export const xlayerTestnet = defineChain({
  id: 1952, name: "X Layer Testnet",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RPC_URL ?? "https://testrpc.xlayer.tech/terigon"] } },
});

export function clients() {
  const account = privateKeyToAccount(process.env.OPERATOR_PRIVATE_KEY as `0x${string}`);
  const transport = http();
  return {
    account,
    public: createPublicClient({ chain: xlayerTestnet, transport }),
    wallet: createWalletClient({ account, chain: xlayerTestnet, transport }),
  };
}

export const ADDR = {
  vault: process.env.VAULT as Address,
  passport: process.env.PASSPORT as Address,
  registry: process.env.REGISTRY as Address,
  router: process.env.ROUTER as Address,
  usdc: process.env.USDC as Address,
  provider: process.env.PROVIDER as Address,
  rwa: (process.env.RWA_COLLATERAL ?? process.env.RWA) as Address | undefined,
  xstock: process.env.XSTOCK as Address | undefined,
};

export const rwaAbi = [
  { name: "collateralValue", type: "function", stateMutability: "view", inputs: [{name:"b",type:"address"}], outputs: [{type:"uint256"}] },
  { name: "locked", type: "function", stateMutability: "view", inputs: [{name:"b",type:"address"}], outputs: [{type:"uint256"}] },
] as const;

export const vaultRwaAbi = [
  { name: "effectiveLimit", type: "function", stateMutability: "view", inputs: [{name:"borrower",type:"address"}], outputs: [{type:"uint256"}] },
] as const;

/** Deterministic job binding: keccak(borrower, provider, serviceId, price, nonce, expiry). */
export function jobHash(borrower: Address, provider: Address, serviceId: string, price: bigint, nonce: bigint, expiry: bigint) {
  return keccak256(encodePacked(
    ["address","address","bytes32","uint256","uint256","uint256"],
    [borrower, provider, keccak256(encodePacked(["string"], [serviceId])), price, nonce, expiry],
  ));
}
