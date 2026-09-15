# Demo video script (2–4 min) — OKX Dev Day 2026

Target: Remote Build, primary track Build a Market, secondary Build a Company.
Record after `bash scripts/demo-local.sh` passes and (if possible) testnet deploy.

## 0:00–0:30 — Problem (show README + architecture)
"Agents earn per job but pay compute before buyer revenue. ComputeCredit advances
one verified provider cost from a lender pool and services it from routed buyer
revenue on X Layer. Not a lending protocol, no guaranteed returns."

## 0:30–1:30 — Market leg on X Layer (show OKLink + terminal)
1. `forge test` — 61/61 green.
2. Lender deposits 10 USDC → shares (show `Deposit` event).
3. Borrower locks 1 AAPLx in `RwaCollateral` → effective limit 5 → 15 USDC.
4. `requestAdvance(2 USDC)` → provider paid exact 2 USDC → inference result.
5. Buyer pays 10 USDC via `RevenueRouter.routePayment` → 2 USDC vault (Settled),
   8 USDC borrower, score +50. Show tx hashes + OKLink links.

## 1:30–2:30 — Default + honesty (show explorer)
1. Expired advance → `penalize` → lien ×1.10, score −300.
2. Next routed payment splits 50/50 until lien target, excess forwarded.
3. Say: "Lien only captures routed revenue. Scores are wallet-linked, not
   sybil-proof. x402 is payment transport; split enforced onchain."

## 2:30–3:30 — Company leg: A2MCP (show curl)
```bash
curl localhost:4021/health
curl localhost:4021/pool
curl "localhost:4021/score?wallet=0xBorrower"
curl -X POST localhost:4021/mcp -d '{"method":"tools/list"}'
X402_ENABLED=1 curl -i localhost:4021/pool  # 402 + PAYMENT-REQUIRED
```
Narrate: "Free mode returns 200. Paid mode returns 402 with base64 v2 challenge
(eip155:1952/196, USDT0 0.01). Compliant with OKX A2MCP guide."

## Shot list
- Terminal: forge test, demo-local.sh ALL LOCAL DEMO ASSERTIONS PASSED
- Explorer: vault, router, RWA txs
- Browser: dashboard/public, MCP responses
- Keep under 4 min. Fallback recording required per docs/DEPLOYMENT.md.
