# ComputeCredit — Demo Runbook

> Spec reference: `ComputeCredit_v2.pdf` v2.1 §9 (end-to-end flows), §14 (deployment plan),
> §16 (demo script), §19 (release criteria 10–13).

Everything below is reproducible from a clean checkout. The demo runs against a local anvil
chain so that expiry (`dueAt`) can be reached by advancing the *chain's* clock — a cheatcode
`vm.warp` only moves a script's simulation and cannot expire an already-broadcast advance.

## 0. Prerequisites

```bash
# Foundry (forge / cast / anvil). Any recent version; the repo pins solc 0.8.26 via foundry.toml
forge --version

# Node.js 20+ (the offchain code runs with node --experimental-strip-types)
node --version

# Dependencies (OpenZeppelin + forge-std are vendored under contracts/lib)
npm install            # root: orchestrator, bot, dashboard workspaces
```

## 1. One-command onchain demo (spec §9.1–§9.3)

```bash
bash scripts/demo-local.sh
```

What it does:

1. starts `anvil` on `http://127.0.0.1:8545` (chain id 31337) if nothing is listening;
2. **phase 1** — deploys the four core contracts, deposits 50 USDC of lender liquidity, seeds
   Nova's bootstrap score of 150, registers the provider at 0.02 USDC/job, then runs
   - §9.1 happy path: one 0.02 USDC advance, a 0.10 USDC buyer payment → 0.02 serviced,
     advance settled, score 150 → 170;
   - §9.2 partial servicing: a fresh 0.02 advance, a 0.05 payment → 0.01 serviced (10 000 of
     20 000 units); a second 0.05 payment settles it, score 190;
   - opens a third advance that deliberately receives **no** revenue before its deadline;
3. advances the real chain clock by 43 201 s (`cast rpc evm_increaseTime` + `evm_mine`) so that
   third advance is now past `dueAt`;
4. **phase 2** — anyone calls the permissionless `penalize`, then the buyer routes two payments
   through the registered router to demonstrate conditional lien capture.

Expected outcome (read back from contract state):

| Item | Value |
| --- | --- |
| Vault idle assets | 50 010 000 units (50.01 USDC) — recovered, **not guaranteed** |
| Total pool shares | 50 000 000 |
| Total outstanding principal | 0 |
| Lifetime issued / serviced | 60 000 / 40 000 units |
| Lifetime shortfall | 20 000 units |
| Lifetime lien recovered | 30 000 units |
| Utilisation | 0 % |
| Nova's score | 0 (slashed on default) |

Phase 2 narration (the honest part):

```
permissionless penalize → shortfall 20 000, lien target 30 000 (1.5×), score 0
routed payment 10 000  → captured 10 000, forwarded 0,          lien remaining 20 000
routed payment 50 000  → captured 20 000 (stops at the target), forwarded 30 000
lien cleared automatically, capture bps back to 0
```

Snapshots: `contracts/deployments/31337.json`, `contracts/deployments/31337-demo.json`, and the
broadcast records under `contracts/broadcast/DemoLocal.s.sol/31337/`.

## 2. Offchain orchestration

```bash
set -a && . ./.env && set +a            # or export the variables directly

# pool / borrower reporting
node --experimental-strip-types orchestrator/index.ts pool
node --experimental-strip-types orchestrator/index.ts score --borrower $BORROWER_ADDRESS
node --experimental-strip-types orchestrator/index.ts history --borrower $BORROWER_ADDRESS

# §11.1 lifecycle: quote → job hash → balance → tier limit → advance vs direct pay → provider
node --experimental-strip-types orchestrator/index.ts infer --prompt "write a haiku about ledgers"

# buyer revenue through the registered route
node --experimental-strip-types orchestrator/index.ts pay --amount 0.10 --payment-ref x402-receipt-001

# keeper path (after the deadline)
node --experimental-strip-types orchestrator/index.ts monitor

# the complete lifecycle in one command (deposit → advance → provider → servicing →
# partial servicing → expiry → penalize → conditional lien recovery)
node --experimental-strip-types orchestrator/index.ts demo
```

`index.ts demo` moves real tokens, so it preflights the demo actors and stops with an actionable
message when they are unfunded. On a fresh chain, fund the lender and the buyer with the demo
token first (it is a local `MockUSDC` with a permissionless `mint`):

```bash
cast send $USDC_ADDRESS "mint(address,uint256)" $(cast wallet address --private-key $LENDER_PRIVATE_KEY) 100000000 --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
cast send $USDC_ADDRESS "mint(address,uint256)" $(cast wallet address --private-key $BUYER_PRIVATE_KEY)  10000000  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
```

The orchestrator enforces the same order the vault does, but the vault remains the authority:
offchain checks are UX only. `DRY_RUN=1` keeps it read-only.

## 3. Telegram bot (optional, Recommended capability — spec §11.3)

```bash
export TELEGRAM_BOT_TOKEN=...           # from @BotFather
node --experimental-strip-types bot/telegram.ts
```

Commands: `/infer <prompt>`, `/invest <amount>`, `/position`, `/withdraw <amount>`, `/score`,
`/history`, `/pool`. Without a token the bot exits with a message pointing at the CLI, so the
demo never depends on Telegram availability.

## 4. Dashboard (optional — spec §12)

```bash
bash scripts/dashboard.sh               # http://localhost:8787
```

Read-only: the process holds no keys and sends no transactions. It keeps the three value classes
separate — **actual vault liquidity**, **outstanding receivables**, **conditional lien targets** —
and never sums them into a single "assets" number. Badges list the demo trust assumptions.

## 5. Test commands

```bash
cd contracts
forge test                  # 161 tests, 6 suites (vault, passport, registry, router, invariants, escrow)
forge test --match-path "test/Invariants.t.sol" -vvv
forge coverage              # optional
```

Deployment (environment-driven, spec §14 Day 7):

```bash
cd contracts
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
```

## 6. Demo script for judges (spec §16 — 4 minutes)

| Time | Beat | What to show |
| --- | --- | --- |
| 0:00–0:20 | Problem | Agents earn per job but must pay for compute before the first buyer payment arrives. ComputeCredit advances one verified compute cost and services it from future routed revenue. |
| 0:20–0:50 | Lender | `/invest 50` → vault idle liquidity and the lender's pool shares. Say explicitly: the lender owns a proportional claim on pool assets and has **no guaranteed return**. |
| 0:50–1:50 | Happy path | Nova has a zero balance; the provider's registered price is 0.02 USDC. Request the advance, show the provider payment and the result returned to the buyer. |
| 1:50–2:40 | Revenue servicing | 0.10 USDC buyer payment through the registered route → 0.02 services the advance, 0.08 reaches Nova; `serviced == principal`, settlement, score +20. |
| 2:40–3:20 | Default path | Expired advance → `penalize` → score slash, shortfall 0.02, conditional lien target 0.03; a later routed payment is captured until the target is reached, then the lien clears. |
| 3:20–4:00 | Honest close | The MVP relies on an approved orchestrator and a registered revenue router. Production replaces these with agent signatures, wallet policies, escrowed receivables and facilitator-level split settlement. Recovery is conditional on routed revenue — never described as guaranteed. |

## 7. Failure modes and recovery

| Symptom | Cause | Fix |
| --- | --- | --- |
| `NotExpired` when penalizing | The advance's `dueAt` is still in the future on the **node's** clock. | Advance real chain time (`cast rpc evm_increaseTime`/`evm_mine`) — never `vm.warp` for broadcast steps. |
| `Missing contract addresses` | No deployment record for `CHAIN_ID` and no `VAULT_ADDRESS`/… in the environment. | Run `scripts/demo-local.sh`, or point `CHAIN_ID`/`DEPLOYMENT_PATH` at an existing record. |
| `PoolInsolvent` on deposit | Shares exist but idle assets are zero (every unit is out on advances). | Wait for servicing/recovery; the vault refuses to price shares against a zero denominator. |
| Dashboard shows no provider | No `PROVIDER_ADDRESS` configured. | The dashboard also falls back to the first `ProviderRegistered` event; set the variable for a fixed view. |
