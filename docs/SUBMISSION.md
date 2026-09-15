# OKX Dev Day 2026 — submission pack (ComputeCredit)

Primary track: **Build a Market** (X Layer). Secondary: **Build a Company** (OKX AI A2MCP).
Participation route: **Remote Build**.

## Project summary
Agents earn per job but pay compute before buyer revenue. ComputeCredit advances one
verified provider cost from a lender pool and services it from future buyer revenue
routed through `RevenueRouter` on X Layer. New for the build period:
1. **RWA leg** — `MockXStock` (tokenized stock) + `RwaCollateral`: lock xStock to boost
   the effective advance limit (`tier + min(value, cap)`). Unlock blocked while an
   advance/lien is open.
2. **OKX AI leg** — `services/mcp-server`: A2MCP tools `get_score/get_pool/get_quote`
   over HTTP + MCP JSON-RPC, with x402 `402 + PAYMENT-REQUIRED` paid mode
   (`eip155:196` mainnet / `eip155:1952` testnet, USDT0) and free mode.

## Links (fill at submit time)
- Repo: https://github.com/emmy16-glitch/ComputeCredit (README with runbook)
- Demo video (2–4 min): <YouTube/unlisted link>
- Live product: dashboard (`dashboard/public`) + MCP (`npm run mcp`) + X Layer testnet addresses below
- Contracts (X Layer testnet 1952 — fill after `forge script ... --broadcast`):
  - USDC/MockUSDC: …
  - ComputeCreditVault: …
  - TrustPassport: …
  - ProviderRegistry: …
  - RevenueRouter: …
  - MockXStock (AAPLx): …
  - RwaCollateral: …
  - WorkEscrow / AgentIdentity / ComputeFutures / FacilitatorAdapter / CreditAdmin: …
- Explorer base: https://www.oklink.com/x-layer-testnet

## New work during build period (evidence)
- `contracts/src/MockXStock.sol`, `contracts/src/RwaCollateral.sol` (new)
- `contracts/src/ComputeCreditVault.sol`: `rwaCollateral`, `rwaBoostCap`, `effectiveLimit()` (additive; tier-only when unset)
- `contracts/script/Deploy.s.sol`: deploys + wires RWA leg
- `contracts/test/Rwa.t.sol`: 5 tests
- `services/mcp-server/src/index.ts`: A2MCP + x402 challenge shape (new)
- `orchestrator/src/agent.ts`: dynamic EIP-712 chainId (was hardcoded 1952) + RWA logging
- `orchestrator/src/config.ts`, `bot/src/telegram.ts` (`/rwa`), `dashboard/public/index.html` (RWA + MCP panels)
- Commit history: `git log --oneline` on this repo.

## Demo flow (matches video)
1. Lender deposits 10 USDC → shares.
2. Borrower locks 1 xStock → effective limit 5 → 15 USDC.
3. Advance 2 USDC → provider paid → infer result.
4. Buyer pays via router → vault serviced → settled, score +50.
5. MCP: `curl localhost:4021/pool`, `/score?wallet=`, `POST /mcp tools/call get_score`.
6. Paid mode: `X402_ENABLED=1 curl -i localhost:4021/pool` → `402 + PAYMENT-REQUIRED`.

## Honesty notes (do not claim otherwise)
- No guaranteed returns; lien only captures routed revenue; scores not sybil-resistant.
- x402 facilitator does not settle on X Layer — split enforced onchain by RevenueRouter;
  x402 HTTP-402 is the payment transport; OKX facilitator path via SDK on supported chains.
- MockXStock price is an owner-set mock oracle for the demo.
