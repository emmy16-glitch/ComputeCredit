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
contracts/test/ Base.t.sol (shared fixture)  ComputeCredit.t.sol (24)  WorkEscrow.t.sol (10)
                Fuzz.t.sol (4)  Security.t.sol (8, incl. adversarial-token reentrancy proofs)
                Invariants.t.sol (6 handler-fuzzed stateful invariants)  mocks/ReentrantUSDC.sol
contracts/script/ Deploy.s.sol  DemoLocal.s.sol (two-phase local demo)
contracts/deployments/ 31337-demo.json + phase1/2-txs.json (local demo records)
scripts/demo-local.sh   (anvil lifecycle + time-warp + broadcast + record)
orchestrator/src/ agent.ts  index.ts (CLI)  keeper.ts (penalize monitor)  config.ts
bot/src/ telegram.ts        (/infer /invest /withdraw /position /pool /score /id /history /faucet)
dashboard/public/ index.html            (read-only pool + borrower monitor)
docs/ ARCHITECTURE.md  THREAT_MODEL.md  DEMO.md  DEPLOYMENT.md  V2_CRITIQUE.md
```

## Quickstart

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge build
forge test                      # 47/47 expected (24 core + 10 escrow + 4 fuzz + 8 security + 1 invariant suite)
npm install
npm run typecheck               # tsc clean
cp .env.example .env            # local defaults work as-is; fill keys + addresses for testnet

# local end-to-end demo (anvil): deploy + happy path + partial + default + recovery, all asserted onchain
bash scripts/demo-local.sh

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

Local anvil demo (`bash scripts/demo-local.sh`, chain 31337 — regenerated each run,
see `contracts/deployments/31337-demo.json`):

| Contract | Address |
|---|---|
| USDC / MockUSDC | `0x4A679253410272dd5232B3Ff7cF5dbB88f295319` |
| ComputeCreditVault | `0xc5a5C42992dECbae36851359345FE25997F5C42d` |
| TrustPassport | `0x09635F643e140090A9A8Dcd712eD6285858ceBef` |
| ProviderRegistry | `0x7a2088a1bFc9d81c55368AE168C2C02570cB814F` |
| RevenueRouter | `0x67d269191c92Caf3cD7723F116c85e6E9bf55933` |
| WorkEscrow (stretch) | local `DemoLocal` script does not deploy it (`…` until testnet deploy) |

X Layer testnet (chain 1952 — pending, see `docs/DEPLOYMENT.md` runbook):

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
- **Shipped (core claim):** vault (ERC4626) + passport + registry + router + orchestrator + keeper + bot + dashboard + 47 tests + scripted local end-to-end demo with onchain assertions.
- **Shipped (stretch, outside core claim):** WorkEscrow buyer-escrow module with router-integrated release.
- **Planned (not built):** compute futures, cross-wallet identity, facilitator auto-settlement.

## Attribution
- Base spec: `ComputeCredit_v2.pdf` (Manus AI) — critiqued in `docs/V2_CRITIQUE.md`.
- Draft PR #1 (arena-ai-coding-agent) was reviewed in full: its v2.1 contracts were deliberately
  **not** merged (v3 fixes their economics and share accounting), but four of its ideas were
  ported and are credited in code: adversarial `ReentrantUSDC` mock, handler-based invariant
  suite, two-phase local demo (`DemoLocal` + `demo-local.sh`), and the richer read-only dashboard.
  The PR was closed as superseded.
