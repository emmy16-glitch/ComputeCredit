# ComputeCredit v3 — architecture

One-line: **a lender-funded, one-job compute advance serviced from routed agent revenue.**
`lender deposits → provider price verified → one advance issued → provider paid → buyer revenue arrives → router services advance → vault settles exactly → score changes exactly.`

## Components

```
Buyer ──pays──▶ RevenueRouter ──20%──▶ ComputeCreditVault ──settles──▶ lenders (ERC4626 shares)
                    │                      ▲          ▲
                    └─80%──▶ borrower      │          │
                               ▲           │          │
Orchestrator ──requestAdvance──┘   ProviderRegistry  TrustPassport
(provider, cost≤price, jobHash)    (price ceiling)   (score→tier limit)
```

| Contract | Responsibility | Authority |
|---|---|---|
| `ComputeCreditVault` (ERC4626, USDC) | Custodies idle USDC, issues one-job advances, single-path servicing, default + lien | Onchain authority. `totalAssets()` = idle only |
| `TrustPassport` | Score 0–1000, one-time seed, +50 settle / −300 default, attestation hashes | Vault-only mutation post-seed |
| `ProviderRegistry` | Approved providers, `pricePerJob` ceiling, payout wallet | Owner-managed, evented |
| `RevenueRouter` (allowlisted) | Pulls buyer payment, splits to vault/borrower, lien-capped capture | Cannot mint scores/advances or touch lender funds |
| `Orchestrator` (offchain TS) | Quote → balance check → advance decision → provider pay → monitor | Trusted operator in MVP; checks are UX-only |
| `Keeper` (`orchestrator/src/keeper.ts`) | Watches borrower list, submits permissionless `penalize()` after expiry | Anyone can run; no special authority |
| `Telegram bot` | `/infer /invest /withdraw /position /pool /score /id /history /faucet` — thin wrapper | No policy bypass; invest/withdraw proxy the operator demo wallet |
| `AgentIdentity` (planned→shipped v1) | Cross-wallet linkage: agentId ↔ wallets, attester-linked, self-unlink | Sybil mitigation; passport points at it via `identityRegistry` |
| `ComputeFutures` (planned→shipped v1) | Pre-sold compute tranches; buyer locks USDC; settle always via router | Turns expected revenue into locked receivable; indebted workers auto-service |
| `FacilitatorAdapter` (planned→shipped v1) | Records x402 intent hash, flags facilitator path per chain, settles via router | Never claims facilitator settlement on X Layer (unsupported); auditable fallback |
| `CreditAdmin` | M-of-N multisig + timelock for vault admin calls | Replaces single-EOA Ownable in production; threshold 1 / delay 0 = MVP behavior |
| `WorkEscrow` (stretch, deployed) | Buyer-locked receivable; release always routes via `RevenueRouter` | Separate from core; strengthens underwriting when used |

## Key invariants (all tested in `contracts/test/ComputeCredit.t.sol`)
1. `serviced ≤ repayable` per advance; `remaining = principal + fee − repaid`.
2. `totalOutstanding == Σ remaining` over Active advances (single `_applyService` path — the v2 double-decrement is structurally impossible).
3. One active advance per borrower; job hashes never reused; new advance blocked while lien open.
4. Only approved routers move servicing accounting, and only by pulling real USDC.
5. Withdrawals bounded by idle pro-rata (ERC4626 `maxWithdraw`); receivables never withdrawable.
6. `lienCaptured ≤ lienTarget`; cleared lien forwards 100% to borrower afterwards.

## Money flow (happy path, 6-decimal USDC)
1. Lender deposits 10 USDC → ERC4626 shares.
2. Nova (score 300 → tier 5 USDC) requests 2 USDC; provider ceiling 5 USDC ✓; idle 10 ✓.
3. Fee 0.5% → repayable 2.01 USDC; `totalOutstanding += 2.01`; 2 USDC → Nova.
4. Provider paid exact 2 USDC.
5. Buyer pays 10 USDC via router → 2 USDC to vault (`repaid=2.0`), 8 USDC to Nova.
6. Buyer pays 1 USDC → 0.01 clears fee → `Settled`, score 300→350, `totalOutstanding=0`.

## Default flow
1. No routed revenue before `dueAt` (12h) → anyone (keeper script included) calls `penalize`.
2. `shortfall = repayable − repaid` leaves `totalOutstanding` once; lien target = shortfall × 1.10; score −300.
3. Later routed payments: 50% toward lien (capped), 50% to borrower. Excess over target auto-forwarded. Lien cleared → normal splits resume; new advances unblocked.

## Stretch: WorkEscrow (shipped, not in core claim)
`client fund → worker submitResult → client confirm → release via router`.
- Release **always** passes through `RevenueRouter.routePayment(worker, …)`: an indebted worker's advance is serviced automatically, remainder forwarded; a debt-free worker receives 100%.
- `refundExpired` returns funds when nothing was delivered past deadline; `arbiter.resolve` settles disputes either way.
- 10 dedicated tests in `contracts/test/WorkEscrow.t.sol`. Use it in the demo only to tell the "escrowed receivable" story — the core claim stays vault + router.

## X Layer + x402 note (verified Sep 2026)
- Deploy target: **X Layer testnet, chain 1952** (`https://testrpc.xlayer.tech/terigon`), explorer `oklink.com/x-layer-testnet`. Mainnet 196.
- CDP x402 facilitator supports Base/Polygon/Solana/Arbitrum/World — **not X Layer**. So the split is enforced **onchain by RevenueRouter on X Layer**; x402 HTTP 402 handshake is the provider/buyer payment transport (simulated in demo, facilitator path documented for EVM chains they support). Never claim otherwise.

## Trust assumptions (MVP — also in README + demo narration)
1. Operator may request for a borrower (demo wallets) — production: borrower EIP-712 signatures (already implemented as `requestAdvanceWithSig`) + wallet policy.
2. Router controls the registered receiving path — payments outside it are not captured (documented, tested).
3. Scores are seeded (300 bootstrap) by a trusted attester — production: multi-attester + history proofs.
