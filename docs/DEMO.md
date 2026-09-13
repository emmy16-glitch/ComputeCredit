# Demo script (7 min) + rehearsal checklist

Network: X Layer testnet (1952). Token: test USDC (or MockUSDC if no faucet). Explorer: oklink.com/x-layer-testnet.

## 0:00–1:00 — Problem
"Agents can earn per job but must pay compute before their first buyer payment.
ComputeCredit advances one verified compute cost and services it from future routed revenue — nothing more."

## 1:00–2:00 — Lender (`/pool`, invest 10 USDC)
- Show idle 10, outstanding 0, shares minted.
- Say: "proportional claim on pool assets, no guaranteed return."

## 2:00–4:00 — Happy path (`/infer`)
- Nova balance 0, score 300 (tier 5 USDC), provider ceiling 5 USDC.
- Request 2 USDC advance → tx → Nova funded → provider paid exact 2 USDC → result returned.
- Point at `AdvanceRequested` event on explorer.

## 4:00–5:30 — Revenue servicing (buyer pays 10 USDC via router)
- Show 2 USDC → vault (`repaid=2.0`), 8 USDC → Nova.
- Second 1 USDC payment clears 0.01 fee → `Settled`, score 350.
- State: `totalOutstanding=0`. "Serviced exactly once — the old double-decrement is structurally gone."

## 5:30–6:30 — Default OR partial (pick one live, rehearse both)
- Partial: smaller payment → `repaid < repayable`, still Active, no score change yet.
- Default: expired advance → anyone `penalize` → shortfall leaves outstanding once, lien = ×1.10, score −300 → later routed payment splits 50/50 until target, excess forwarded, lien clears.

## 6:30–7:00 — Honest close
"MVP trusts an approved operator and router — both visible onchain and replaceable.
Production: borrower signatures (already in the contract), wallet policy, escrowed receivables, facilitator settlement where supported.
Reliable vault + correct router + honest boundaries beat more half-built modules."

## Rehearsal checklist
- [ ] `forge test` green (47/47). `npm run typecheck` clean.
- [ ] `bash scripts/demo-local.sh` prints ALL LOCAL DEMO ASSERTIONS PASSED.
- [ ] Contracts deployed, addresses in `.env` + README.
- [ ] Lender + buyer wallets funded (test USDC + OKB gas).
- [ ] Provider registered, price confirmed onchain.
- [ ] Nova seeded (score readable).
- [ ] Fallback recording rendered (in case RPC stalls).
- [ ] Never say: guaranteed recovery, universal lien, sybil-proof, "facilitator settles on X Layer".
