# ComputeCredit v3 — one-job compute advances, serviced from routed revenue

> Agents can earn per job but must pay for compute before their first buyer payment.
> ComputeCredit advances **one verified provider cost** from a lender-funded pool and services it
> from **future buyer revenue routed through an authorized split router**. Not a lending protocol,
> not a faucet, no guaranteed returns.

Flow: `lender deposits → provider price verified → one advance issued → provider paid → buyer revenue arrives → router services advance → vault settles exactly → score changes exactly.`

This is a clean-room v3 rewrite of the `ComputeCredit_v2.pdf` (Manus AI) spec. What changed and why: [`docs/V2_CRITIQUE.md`](docs/V2_CRITIQUE.md).

## Repo layout

```
contracts/src/  ComputeCreditVault.sol  TrustPassport.sol  ProviderRegistry.sol
                RevenueRouter.sol  WorkEscrow.sol (stretch)  MockUSDC.sol
contracts/test/ Base.t.sol (shared fixture)  ComputeCredit.t.sol (24)  WorkEscrow.t.sol (10)  Fuzz.t.sol (4)
contracts/script/ Deploy.s.sol
orchestrator/src/ agent.ts  index.ts (CLI)  keeper.ts (penalize monitor)  config.ts
bot/src/ telegram.ts        (/infer /invest /withdraw /position /pool /score /id /history /faucet)
dashboard/public/ index.html            (read-only pool monitor)
docs/ ARCHITECTURE.md  THREAT_MODEL.md  DEMO.md  DEPLOYMENT.md  V2_CRITIQUE.md
```

## Quickstart

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build
forge test                      # 38/38 expected (24 core + 10 escrow + 4 fuzz)
npm install
npm run typecheck               # tsc clean
cp .env.example .env            # fill keys + addresses

# deploy (X Layer testnet 1952) — full runbook: docs/DEPLOYMENT.md
forge script contracts/script/Deploy.s.sol \
  --rpc-url https://testrpc.xlayer.tech/terigon --broadcast

npm run orchestrator -- "summarize this" 0xBorrower
KEEPER_BORROWERS=0xBorrower npm run keeper
npm run bot
npm run dashboard                 # http://localhost:3000
```

## Network config (verified Sep 2026)

| | X Layer testnet | X Layer mainnet |
|---|---|---|
| Chain ID | **1952** (0x7a0) | 196 (0xC4) |
| RPC | `https://testrpc.xlayer.tech/terigon` / `https://xlayertestrpc.okx.com/terigon` | `https://rpc.xlayer.tech` |
| Explorer | `https://www.oklink.com/x-layer-testnet` | `https://www.oklink.com/x-layer` |
| Gas token | OKB | OKB |

**Faucet:** official faucet at `https://web3.okx.com/xlayer/faucet` dispenses **0.2 OKB/day** for gas plus USDG/test ERC20s — there is **no native testnet USDC**, so the deploy script deploys a 6-decimal `MockUSDC` (permissionless mint, testnet only) unless `USDC=` points at your own stable.

**x402 honesty note:** the CDP x402 facilitator supports Base/Polygon/Solana/Arbitrum/World — **not X Layer**.
So the revenue split is enforced **onchain by `RevenueRouter` on X Layer**; x402's HTTP-402 handshake is the
provider/buyer payment transport (simulated in the demo). We never claim facilitator settlement on X Layer.

## Deployed addresses (fill after deploy)

| Contract | Address |
|---|---|
| USDC / MockUSDC | `…` |
| ComputeCreditVault | `…` |
| TrustPassport | `…` |
| ProviderRegistry | `…` |
| RevenueRouter | `…` |
| WorkEscrow (stretch) | `…` |

## Trust assumptions (MVP — also narrated in demo)
1. **Operator** may request advances for demo borrowers (production: borrower EIP-712 signatures — already implemented as `requestAdvanceWithSig` — plus wallet policy).
2. **Router** controls the registered receiving path; payments sent elsewhere are not captured.
3. **Scores** start from a trusted bootstrap seed (300); attesters are trusted in MVP.

## Known limitations
- One active advance per borrower; tier caps ≤ 20 USDC — intentionally small.
- Lien is conditional on routed revenue; defaults can still lose lenders money.
- Scores are wallet-linked, not sybil-resistant; new wallets restart at bootstrap.
- Not regulated factoring; no guaranteed recovery; pool shares float with defaults/repayments.

## Shipped vs planned
- **Shipped (core claim):** vault (ERC4626) + passport + registry + router + orchestrator + keeper + bot + dashboard + 38 tests.
- **Shipped (stretch, outside core claim):** WorkEscrow buyer-escrow module with router-integrated release.
- **Planned (not built):** compute futures, cross-wallet identity, facilitator auto-settlement.
