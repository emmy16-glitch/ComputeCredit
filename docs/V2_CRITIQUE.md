# v2.1 critique → v3 fixes

Source reviewed: `ComputeCredit_v2.pdf` ("ComputeCredit v2.1, Corrected Architecture", Manus AI).
The v2.1 spec is honest about scope and already fixes a double-decrement bug. v3 keeps
all of its good ideas and fixes the structural weaknesses below. Nothing here criticizes
intent — only engineering choices.

## What v2.1 got right (kept in v3)
- Narrow MVP: vault + passport + one router + one provider + one demo. Correct.
- `totalOutstanding` decremented exactly once; settlement performs no second subtraction. Kept, enforced by a single `_applyService` path.
- Revenue-source binding + job hash binding. Kept, plus EIP-712 consent.
- Explicit trust assumptions in README/demo. Kept and strengthened.
- "Lien is conditional on routed revenue, never guaranteed recovery." Kept verbatim in all user-facing copy.

## Issues found and v3 fixes

| # | v2.1 issue | Why it matters | v3 fix |
|---|------------|----------------|--------|
| 1 | Custom share math (`depositAmount × S / A`) reinvented, rounding rule "documented later" | Inflation attack on first deposit; off-by-one drains lenders | Standard **ERC4626** shares; `totalAssets() = idle USDC only`. Withdrawals physically cannot touch live advances. 24 tests green. |
| 2 | No lender incentive (no fee/interest) | Pool only loses on defaults; nobody rationally deposits | **0.5% origination fee** (`feeBps=50`) added to repayable, accrues to pool on service. Small, explicit, hackathon-fair. |
| 3 | Lien = 1.5× shortfall + 100% seizure | 50% penalty is loan-shark optics; 100% capture removes the agent's reason to ever earn again → recovery fails | **10% surcharge** (`penaltyBps=1000`) + **50% capture** (`lienCaptureBps=5000`). Agent keeps half of every future payment, so earning again is rational. |
| 4 | `mapping(address => Advance)` — no IDs, no history | Cannot audit borrower history; "active" vs "defaulted" collides | `nextAdvanceId` + `advances[id]` + `activeAdvanceId[borrower]` + full `Status` enum. History preserved after settle/default. |
| 5 | Operator can request for *any* borrower, no consent proof | Operator can debt-attack any wallet | **EIP-712 `AdvanceIntent`** path (`requestAdvanceWithSig` + nonces + expiry) alongside the demo operator path. Vault verifies borrower signature. |
| 6 | `serviceAdvance(borrower, amount)` records servicing on a bare call | Router "must transfer before/as part of call" is a comment, not enforcement → fake repayment records | `serviceAdvanceWithTransfer` / `captureLienWithTransfer` **pull** USDC via `transferFrom(router)` before touching accounting. No tokens, no record. |
| 7 | Full slash to 0 on default | One illiquid job wipes established agents; encourages wallet resets (sybil) | Calibrated **−300 slash** (floor 0), **+50** per settlement, cap 1000. Defaults hurt, rehabilitation is possible. |
| 8 | Lien state + score logic tangled across vault/passport | Hard to audit money vs reputation | Lien (`lienTarget/lienCaptured`) lives **only in vault**; passport stores **only score + attestations**. |
| 9 | Revenue source "registered" vaguely; change-mid-advance unspecified | Borrower swaps wallet mid-loan, lien stranded | `revenueSourceOf` locked while advance active; new advance blocked until lien cleared (`RevenueSourceLocked`). |
| 10 | x402/X-Layer integration hand-waved ("confirm SDK before deployment") | Judges will ask; CDP facilitator does **not** support X Layer (Base/Polygon/Solana/Arbitrum/World only, verified Sep 2026) | Honest split: demo router enforces the split **onchain on X Layer (chain 1952)**; facilitator/x402 HTTP leg is the **provider-pay / buyer-pay transport**, documented as simulation with production migration path. Never claim facilitator settles on X Layer. |
| 11 | No pause, no custom errors, events unindexed | Demo-day bug = frozen funds; debugging without indexed events is painful | `Pausable`, custom errors, indexed events on every transition, `Ownable` admin. |
| 12 | Repo was PDF-only | Nothing to run, test, or deploy | This repo: 6 contracts + mock, 47 Foundry tests (24 core + 10 escrow + 4 fuzz + 8 security + 1 invariant suite), deploy script, two-phase local demo, TS orchestrator, Telegram bot, static dashboard, 5 docs. |

## Deliberately NOT changed (out of scope for hackathon)
- Single active advance per borrower (correct risk cap for MVP).
- 12h advance window, 4 score tiers, 20% normal split — sane demo defaults.
- No cross-wallet identity / sybil resistance (documented limitation).
- No WorkEscrow / compute futures in the core claim (stretch only).
