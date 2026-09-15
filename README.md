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
                AgentIdentity.sol  ComputeFutures.sol  FacilitatorAdapter.sol  CreditAdmin.sol
                MockXStock.sol  RwaCollateral.sol (OKX Build-a-Market RWA leg)
contracts/test/ Base.t.sol (shared fixture)  ComputeCredit.t.sol (24)  WorkEscrow.t.sol (10)
                Fuzz.t.sol (4)  Security.t.sol (8, incl. adversarial-token reentrancy proofs)
                Invariants.t.sol (6 handler-fuzzed stateful invariants)  Production.t.sol (9)  Rwa.t.sol (5)  mocks/ReentrantUSDC.sol
contracts/script/ Deploy.s.sol  DemoLocal.s.sol (two-phase local demo)
contracts/deployments/ 31337-demo.json + phase1/2-txs.json (local demo records)
services/mcp-server/src/index.ts  (OKX AI A2MCP leg: get_score/get_pool/get_quote + x402 paid mode)
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
forge test                      # 61/61 expected (24 core + 10 escrow + 4 fuzz + 8 security + 1 invariant suite + 9 production + 5 RWA)
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
npm run mcp                     # A2MCP service on :4021 (free mode; X402_ENABLED=1 for paid)
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
| USDC / MockUSDC | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| ComputeCreditVault | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` |
| TrustPassport | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| ProviderRegistry | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| RevenueRouter | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9` |
| WorkEscrow (stretch) | local `DemoLocal` script does not deploy it (`…` until testnet deploy) |

X Layer testnet (chain 1952 — live 2026-09-14, see `contracts/deployments/1952-testnet.json`):

| Contract | Address |
|---|---|
| USDC / MockUSDC | `0xb9865fB7b45C60256C068079b04f2dFE8FAbBEEA` |
| ComputeCreditVault | `0x279F99B70DaEc1a300A93cB0C5260C755EB2F07C` |
| TrustPassport | `0x7633e910FFF76B80BD08f0Ea2B66CE9ce6c91324` |
| ProviderRegistry | `0xE16485066fF785d7DB536B36C0fBa1F3eaf902A8` |
| RevenueRouter | `0xB449320134A01C7b8Bd7F781399fF7562c11dbc9` |
| WorkEscrow (stretch) | `0x0D0993fd1Ea64Bc2Fbaf0aFB88cD0eb60eA159D9` |
| AgentIdentity | `0x660e3023245C37e15611E6aBa9Adf5686a29F538` |
| ComputeFutures | `0x0b60c951862D1206F0d8b17913297027fe5FA263` |
| FacilitatorAdapter | `0xa1cAB0d72766779d499A6d37Ea2d471a7Aad45c6` |
| CreditAdmin | `0x4aaFD149b08092943AB992c3FD459F284b8DEe79` |

Testnet happy path (operator/borrower `0xBB9f4e86eA090F592e3757db0d4aa60c5FFEeA37`): deposit `0x94d14000f345f882f72c430169dd8f9949274248dfe8590719c06156d2759acd` → advance `0xcb168831130dc06b1ad346d43558966c41b3b6b593e85bf117fd52ddc83eb72e` → route `0x6e9deb865a646c80ac592ecacedcfc86f0faabdf07dffbabaf9c3499d8eed2d1` → settle `0x396eefb38694a773ff8584f517e4687cae7488a7b650f055313fe658e617593f` (score 300→350, remaining 0). Explorer: `https://www.oklink.com/x-layer-testnet`.

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
- **Shipped (core claim):** vault (ERC4626) + passport + registry + router + orchestrator + keeper + bot + dashboard + 61 tests + scripted local end-to-end demo with onchain assertions.
- **Shipped (OKX Dev Day Build-a-Market):** `MockXStock` + `RwaCollateral` — lock tokenized stock to boost effective advance limit (`tier + min(value, cap)`); unlock blocked while advance/lien open. See `docs/SUBMISSION.md`.
- **Shipped (OKX AI Build-a-Company):** `services/mcp-server` A2MCP tools `get_score/get_pool/get_quote` over HTTP + MCP JSON-RPC with x402 paid/free modes.
- **Shipped (stretch, outside core claim):** WorkEscrow buyer-escrow module with router-integrated release.
- **Shipped (production hardening):** vault sig-only mode + 6-decimal assertion + global outstanding cap + risk timelock; passport multi-attester quorum + identity-registry hook; `CreditAdmin` multisig-timelock; orchestrator EIP-712 sig path (`BORROWER_PRIVATE_KEY`).
- **Shipped (planned modules, v1):** `AgentIdentity` (cross-wallet linkage), `ComputeFutures` (pre-sold tranches settled via router), `FacilitatorAdapter` (x402 intent record + router fallback; never claims facilitator settlement on X Layer).
- **Still not done (needs humans):** OKLink verification, keeper/bot live run, fallback recording, third-party audit. (X Layer testnet deploy done 2026-09-14 — see addresses + happy-path txs above.)

## Attribution
- Base spec: `ComputeCredit_v2.pdf` (Manus AI) — critiqued in `docs/V2_CRITIQUE.md`.
- Draft PR #1 (arena-ai-coding-agent) was reviewed in full: its v2.1 contracts were deliberately
  **not** merged (v3 fixes their economics and share accounting), but four of its ideas were
  ported and are credited in code: adversarial `ReentrantUSDC` mock, handler-based invariant
  suite, two-phase local demo (`DemoLocal` + `demo-local.sh`), and the richer read-only dashboard.
  The PR was closed as superseded.
