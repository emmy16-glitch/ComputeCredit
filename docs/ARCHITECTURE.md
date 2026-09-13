# ComputeCredit — Architecture

> Spec reference: `ComputeCredit_v2.pdf` v2.1 (Corrected Architecture and Implementation
> Specification — Agent Revenue Factoring for the Agent Economy), §2–§8.
> This document describes **what is actually implemented**; planned modules are labelled.

## 1. One-paragraph product explanation

Agents can earn per job, but they may need to pay for compute **before** the first buyer
payment arrives. ComputeCredit advances one verified compute cost to a borrower agent and
services that advance from the agent's future revenue that arrives through a registered
revenue route. Lenders fund a pooled vault and hold proportional pool shares; the vault
enforces a single principal obligation per agent at a time, an exact outstanding-principal
ledger, and a conditional recovery lien that only captures revenue that actually flows
through the registered route.

## 2. Components

| Component | File | Responsibility |
| --- | --- | --- |
| **ComputeCreditVault** | `contracts/src/ComputeCreditVault.sol` | Custodies USDC, mints/burns pool shares, enforces the single active advance per borrower, keeps exact `totalOutstanding`, pays the provider, settles on exact servicing, records defaults, executes lien capture. |
| **TrustPassport** | `contracts/src/TrustPassport.sol` | Bounded trust score (0–1000, tier caps), one-time bootstrap seeding by a trusted attester, score bumps on settlement, score slash on default, lien bookkeeping, EIP-712 work attestations. |
| **ProviderRegistry** | `contracts/src/ProviderRegistry.sol` | The single authoritative price source (`providerWallet`, `pricePerJob`, `serviceId`); the vault never trusts a caller-supplied quote. Also hosts the canonical `jobHash` formula. |
| **RevenueRouter** | `contracts/src/RevenueRouter.sol` | Explicitly allowlisted receiving path. Receives the buyer payment, pulls it in one atomic step, splits it into the servicing amount (into the vault) and the remainder (to the borrower), and captures routed revenue against an active default lien. |
| **WorkEscrow** *(stretch)* | `contracts/src/WorkEscrow.sol` | Optional pre-funded buyer escrow; release can pass through the router to service an advance. **Not on the critical path** — the core proof runs without it. |

Offchain (spec §11–§12):

| Component | File | Responsibility |
| --- | --- | --- |
| Orchestrator | `orchestrator/revenueRouter.ts`, `orchestrator/chain.ts`, `orchestrator/index.ts` | Quotes the provider, binds the job hash, decides direct-pay vs. advance, pays the provider, routes revenue, attests work, monitors expiry and calls the permissionless `penalize`. |
| Configuration | `orchestrator/config.ts`, `orchestrator/providerRegistry.json` | Everything environment-driven; deployment records are read from `contracts/deployments/<chainId>.json`. |
| Telegram bot | `bot/telegram.ts` | §11.3 command surface: `/infer /invest /position /withdraw /score /history /pool`. A thin UI over the same calls — it never bypasses a contract check. |
| Dashboard | `dashboard/server.mjs`, `dashboard/public/index.html` | Read-only state surface; keeps actual liquidity, outstanding receivables and conditional lien targets visually separate. |

## 3. Data flow

```
                deposit USDC                        ┌───────────────────────┐
  Lender ─────────────────────────────────────────► │  ComputeCreditVault   │
     ▲   pool shares (proportional claim)           │  • idleAssets()       │
     │                                              │  • totalShares        │
     │  withdraw ≤ idle claim                       │  • totalOutstanding   │
     └──────────────────────────────────────────────┤  • advances[borrower] │
                                                    └────┬──────────┬───────┘
         request advance (operator, borrower-authorized) │          │ price read
                                                         │          ▼
   Borrower agent ───────────────────────────────────────┘   ┌───────────────┐
     ▲  compute paid directly to provider wallet             │ProviderRegistry│
     │                                                       │ pricePerJob   │
     │  remainder (1 − split)                                └───────────────┘
     │                                                               ▲
     │        ┌──────────────────────┐   servicing amount            │
     └────────┤   RevenueRouter      ├───────────────────────────────┘
              │  (allowlisted path)  │   • serviceAdvanceWithTransfer()
   Buyer ────►│  routePayment()      │   • captureLien()
   (0.10 USDC)└──────────────────────┘
```

Servicing rule for a routed payment `P` with registered split `b = 2 000 bps`:

```
baseSplit       = P × b / 10 000
servicingAmount = min(baseSplit, residualPrincipal)
transferToBorrower = P − servicingAmount
```

If the borrower is **defaulted with an active lien**, routed revenue is captured against the
lien target instead: `captured = min(P, lienTarget − lienCaptured)`, the remainder goes to the
borrower, and the lien clears automatically the moment the target is reached.

## 4. Accounting model (single principal, no double decrement)

The corrected v2.1 rules are implemented literally:

* `totalOutstanding` is the sum of **residual principal** (`principal − serviced`) of every
  active advance. It is incremented once when an advance is issued, decremented by exactly the
  serviced amount, and decremented by the shortfall **once** when an advance is penalized.
* Settlement does **not** touch `totalOutstanding` again — the principal was already reduced to
  zero by servicing. A settled advance is skipped by both servicing and penalization.
* Idle liquidity is simply `usdc.balanceOf(vault)`; the vault never moves tokens to itself, so
  idle assets and outstanding receivables stay separate by construction.
* Score changes are exact: `+20` once on exact settlement, slashed to zero once on default.
* The lien target is `shortfall × 15 000 / 10 000` (1.5× the shortfall), recorded on default and
  capped in capture at exactly `lienTarget`; it is **conditional** on routed revenue.

Lien lifecycle: created on `penalize` → captures only routed revenue → clears automatically when
`lienCaptured == lienTarget` → a new advance is rejected while a lien is outstanding (§5.9).

## 5. Advance lifecycle

1. **Provider registration** (`ProviderRegistry.registerProvider`) — price, payout wallet and
   service id are registered by an administrator; the vault caps every advance at this price.
2. **Bootstrap score** (`TrustPassport.seedScore`) — one-time seeding by the trusted attester,
   clamped to 200 (spec §7.4). Default demo value: 150 → tier 1 → 1 USDC ceiling.
3. **Advance request** (`requestComputeAdvanceFor`) — validated onchain against eleven rules:
   a single active advance, no outstanding lien, active provider, `computeCost ≤ registered
   price`, `computeCost ≤ tier ceiling`, non-zero cost, an approved revenue source, sufficient
   idle liquidity, an unused `jobHash`, and an authorised caller (borrower, approved operator, or
   a requester the borrower authorised).
4. **Provider payment** — the vault transfers the compute cost to the provider wallet the
   registry holds for the borrower's spend destination (the borrower's isolated spending wallet
   when configured).
5. **Revenue arrives** — the buyer pays through the registered route. The router pulls the USDC
   **first**, then calls the vault, so accounting can never move ahead of the token transfer.
6. **Servicing** — partial servicing reduces residual principal; exact servicing settles the
   advance and bumps the score once.
7. **Expiry** — after `dueAt`, anyone may call the permissionless `penalize`, which records the
   shortfall, slashes the score and creates the conditional lien.
8. **Recovery** — later routed revenue is captured against the lien until the exact target is
   reached; the excess always reaches the borrower.

## 6. Trust score (spec §7)

| Tier | Score band | Advance ceiling |
| --- | --- | --- |
| 1 | 0–200 | 1 USDC |
| 2 | 201–500 | 5 USDC |
| 3 | 501–800 | 25 USDC |
| 4 | 801–1 000 | 50 USDC |

Tier ceilings are eligibility gates, never a general credit line. Scores only change through
`increaseScore` / `slashToZero` (vault-only, bounded, event-logged) or the one-time seed.

## 7. Repository map

```
computecredit/
├── README.md                     # product, addresses, trust assumptions, limitations
├── contracts/                    # Foundry project
│   ├── src/                      # 5 contracts (WorkEscrow = stretch)
│   ├── test/                     # 6 suites: Vault, Passport, Registry, Router, Invariants, Escrow
│   ├── script/Deploy.s.sol       # environment-driven deploy
│   ├── script/DemoLocal.s.sol    # two-phase local end-to-end demo
│   └── deployments/<chainId>.json
├── orchestrator/                 # quote → advance → pay → route → attest → penalize
├── bot/telegram.ts               # §11.3 command UI
├── dashboard/                    # read-only state surface
├── scripts/{demo-local,dashboard}.sh
└── docs/{ARCHITECTURE,THREAT_MODEL,DEMO}.md
```

## 8. Invariants enforced onchain

Asserted in `contracts/test/Invariants.t.sol` after every handler call:

1. `totalOutstanding == Σ (principal − serviced)` over active advances.
2. `usdc.balanceOf(vault) == Σ lender deposits − Σ advances + Σ serviced + Σ lien captures`
   (idle liquidity never includes receivables).
3. `totalShares == Σ balances` and `totalShares > 0 ⇒ idleAssets ≥ 0` (no negative accounting).
4. No advance is both settled and defaulted; `serviced ≤ principal`.
5. `lienCaptured ≤ lienTarget`; a settled advance has no lien.
6. Score stays within `[0, 1 000]`.
7. A lender can never withdraw more than `idleAssets × shares / totalShares`.
8. Deposits and withdrawals never reduce the per-share value of remaining lenders.

## 9. Explicit non-goals (Post-MVP, spec §1.2)

Futures/forward contracts, cross-wallet identity and sybil resistance, automatic
facilitator-level settlement, and multi-provider routing are **not implemented**. They are
listed in `README.md` and `docs/THREAT_MODEL.md` as planned work, not as shipped features.
