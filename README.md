# ComputeCredit

**A prototype credit primitive for the agent economy: a lender-funded, one-job compute advance
serviced from routed agent revenue.**

Agents can earn per job, but they may need to pay for compute *before* the first buyer payment
arrives. ComputeCredit lets a lender pool fund **one verified compute cost** to a borrower agent,
pays the provider at its registered price, and then services that advance automatically from the
agent's future revenue as it flows through a registered revenue route. The vault keeps an exact
single-principal ledger, the trust passport moves the score by exactly one step per settlement or
default, and default recovery is a *conditional* lien on routed revenue — never a guarantee.

Built for **OKX Dev Day 2026 — OKX AI Track**, settling on **X Layer**.

---

## 1. Architecture

```
                 deposit USDC                       ┌───────────────────────┐
   Lender ────────────────────────────────────────► │  ComputeCreditVault   │
      ▲   pool shares (proportional claim)          │  idleAssets()         │
      │                                             │  totalShares          │
      │   withdraw ≤ proportional idle claim        │  totalOutstanding     │
      └─────────────────────────────────────────────┤  advances[borrower]   │
                                                    └───┬──────────────┬────┘
   request advance (authorised operator) ───────────────┘              │ price read (authority)
                                                                       ▼
   Borrower agent ──── compute paid to provider wallet ─────► ┌──────────────────┐
      ▲                                                      │ ProviderRegistry │
      │  remainder (0.08 of 0.10)                            └──────────────────┘
      │                                                                 ▲
      │      ┌───────────────────────┐  servicing amount (0.02)         │
      └──────┤    RevenueRouter      ├──────────────────────────────────┘
             │  (allowlisted route)  │  • serviceAdvanceWithTransfer()
  Buyer ────►│  routePayment()       │  • captureLien()
             └───────────────────────┘
```

Components: **ComputeCreditVault** (custody, shares, exact principal ledger, default + lien),
**TrustPassport** (bounded score, tiers, attestations, lien bookkeeping), **ProviderRegistry**
(authoritative provider price + job-hash formula), **RevenueRouter** (allowlisted receiving path
that splits routed revenue), **WorkEscrow** (stretch module, not on the critical path).
Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## 2. Deployed addresses

### Local demo chain (chain id 31337) — verified

Written by `scripts/demo-local.sh` to `contracts/deployments/31337.json`:

| Contract | Address |
| --- | --- |
| MockUSDC (settlement asset, demo only) | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| TrustPassport | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| ProviderRegistry | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |
| ComputeCreditVault | `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9` |
| RevenueRouter | `0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9 |
| WorkEscrow (stretch) | deployed on demand from `contracts/src/WorkEscrow.sol` |

### X Layer testnet (chain id 1952) — deployment pending

The X Layer testnet deployment is part of the build-window plan (§14 Day 7) and is **not yet
recorded here**: this repository has been exercised end-to-end on the local chain so far. When it
is deployed, the addresses go in this table together with the recorded transaction hashes, and
`contracts/deployments/1952.json` becomes the source of truth for the orchestrator, bot and
dashboard. Until then, treat any non-local address claim as unverified.

## 3. Network and token configuration

| Setting | Local demo | X Layer testnet | X Layer mainnet |
| --- | --- | --- | --- |
| Chain id | 31337 | **1952** | **196** |
| RPC | `http://127.0.0.1:8545` | `https://testrpc.xlayer.tech/terigon` | `https://rpc.xlayer.tech` |
| Explorer | — | `https://www.okx.com/web3/explorer/xlayer-test` | `https://www.okx.com/web3/explorer/xlayer` |
| Native token | ETH (anvil) | OKB | OKB |
| Settlement asset | `MockUSDC` (6 decimals) | configure the testnet settlement asset; the official token table lists no testnet USDC | USDC `0x74b7F16337b8972027F6196A17a631aC6dE26d22` |

Parameters confirmed against the official X Layer documentation on 2026-09-13
(<https://web3.okx.com/onchainos/dev-docs/xlayer/developer/build-on-xlayer/network-information>).
Per the spec's own instruction, re-confirm chain id, RPC, explorer, token address and faucet
before any deployment. `MockUSDC` is a local/test artifact only and must never be presented as a
real asset. All configuration lives in `.env` (see [`.env.example`](.env.example)) — nothing is
hardcoded in source.

## 4. Run the demo

```bash
# dependencies (root npm workspaces)
npm install

# one-command onchain demo: deploy → happy path → partial servicing → default → lien recovery
bash scripts/demo-local.sh

# optional offchain surfaces
node --experimental-strip-types orchestrator/index.ts pool
node --experimental-strip-types orchestrator/index.ts infer --prompt "write a haiku about ledgers"
node --experimental-strip-types orchestrator/index.ts pay --amount 0.10 --payment-ref x402-receipt-001
bash scripts/dashboard.sh                       # read-only dashboard on :8787
node --experimental-strip-types bot/telegram.ts # needs TELEGRAM_BOT_TOKEN
```

Full runbook, expected numbers, the 4-minute demo script and failure modes:
[`docs/DEMO.md`](docs/DEMO.md).

## 5. Tests

```bash
cd contracts
forge test                  # 161 tests across 6 suites
forge test --match-contract InvariantsTest -vvv
forge build
forge coverage              # line coverage: vault 95.96%, passport 99.06%, registry 100%, router 100%, escrow 100%
```

| Suite | Covers |
| --- | --- |
| `ComputeCreditVault.t.sol` | deposits/shares, idle-only withdrawals, advance validation, exact servicing, settlement, authorization, pause |
| `TrustPassport.t.sol` | bounded scores, one-time seeding, tiers, slashing, EIP-712 attestations |
| `ProviderRegistry.t.sol` | administrator bounds, registration, price/wallet/service updates, canonical job hash |
| `RevenueRouter.t.sol` | atomic split, partial servicing, default servicing, exact lien capture, authorization |
| `Invariants.t.sol` | fuzzed accounting/solvency/share-price invariants |
| `WorkEscrow.t.sol` | the stretch escrow flow, including routed release |

## 6. Shipped vs. planned

**Shipped (core protocol — the first seven capabilities, plus the required score/default/lien):**
lender deposits · lender pool shares · one active advance per agent · provider price registry ·
job binding · revenue servicing · automatic settlement · basic trust score · default + conditional
lien · orchestrator · Telegram bot · read-only dashboard · WorkEscrow (stretch).

**Planned (Post-MVP, explicitly not implemented):** futures / forward contracts,
cross-wallet identity and sybil resistance, automatic facilitator settlement, multi-provider
routing, formal verification. `WorkEscrow` is shipped as a *stretch* module and is not part of the
core proof.

## 7. Trust assumptions (spec §3.1)

The MVP has **three deliberate centralization assumptions**:

1. **The orchestrator may submit a request for a borrower** if the borrower has authorized that
   action, or the demo wallet is controlled by the orchestrator.
2. **The orchestrator may issue work attestations.**
3. **The revenue router controls the registered demo receiving path.**

The vault still enforces every economic rule onchain: it cannot be made to pay more than the
registered provider price, mint unearned shares, settle an advance twice, or record a repayment
without the router's authorisation. Production replaces these assumptions with agent-signed
EIP-712 requests, policy-controlled wallets, multiple attesters and facilitator-level split
settlement.

## 8. Known limitations

* Recovery is **conditional, not guaranteed**. The lien only captures revenue that flows through
  the registered route, and it stops at exactly its target.
* Payments routed outside the registered route are not captured; in the MVP an agent can avoid the
  lien by changing wallets.
* A default is only recovered if the borrower earns again through the registered route.
* The trust score is only weakly sybil resistant — a new wallet restarts at the bootstrap tier.
* Offchain checks are for usability only; the vault is the authority.
* The local settlement asset is a mock token; X Layer settlement must be configured and
  re-verified before deployment.
* Invariants are fuzz-tested, not formally verified.
* Nothing here is a regulated financial product: this is an onchain revenue-based advance
  prototype, and the "factoring" analogy is intentionally limited.

**The demo never claims guaranteed recovery or universal lien enforcement.** See
[`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md) for the full threat model and the production
migration path.

## 9. Repository layout

```
computecredit/
├── contracts/            # Foundry: src/, test/, script/, deployments/, lib/
├── orchestrator/         # index.ts, revenueRouter.ts, chain.ts, config.ts, providerRegistry.json
├── bot/telegram.ts       # §11.3 Telegram command surface
├── dashboard/            # read-only server + static UI
├── scripts/              # demo-local.sh, dashboard.sh
├── docs/                 # ARCHITECTURE.md, THREAT_MODEL.md, DEMO.md
└── .env.example
```

## 10. Built from the specification

This repository implements `ComputeCredit_v2.pdf` v2.1 ("Corrected Architecture and Implementation
Specification — Agent Revenue Factoring for the Agent Economy", OKX Dev Day 2026 Hackathon, OKX AI
Track, X Layer settlement). Spec section references are kept in the source comments; the corrected
v2.1 rules — single principal accounting with no double-decrement, proportional pool shares,
bounded orchestrator authority, a lien conditional on routed revenue, and the reduced MVP scope —
are implemented as written, and the stretch/planned modules are labelled as such.

## 11. Release criteria status (spec §19)

| # | Criterion | Status |
| --- | --- | --- |
| 1 | Lender can deposit and receive pool shares | ✅ tested + demoed |
| 2 | Lender cannot withdraw liquidity backing an active advance | ✅ tested |
| 3 | Valid borrower can request one advance tied to a registered provider and job hash | ✅ tested + demoed |
| 4 | Invalid quote, provider, score tier or duplicate job is rejected | ✅ tested |
| 5 | Router can service an advance only after transferring USDC | ✅ tested |
| 6 | Partial servicing updates principal accounting exactly once | ✅ tested + invariants |
| 7 | Exact servicing settles the advance and bumps the score once | ✅ tested + demoed |
| 8 | Default records a correct shortfall and conditional lien | ✅ tested + demoed |
| 9 | Lien capture stops at the exact target | ✅ tested + demoed |
| 10 | Happy path works on the selected testnet | ⛔ local chain verified; X Layer deployment pending (§2) |
| 11 | Default path works on the selected testnet | ⛔ local chain verified; X Layer deployment pending (§2) |
| 12 | README accurately describes all trust assumptions | ✅ §7 |
| 13 | Demo never claims guaranteed recovery or universal lien enforcement | ✅ §8 and `docs/DEMO.md` §6 |
