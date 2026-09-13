# ComputeCredit — Threat Model

> Spec reference: `ComputeCredit_v2.pdf` v2.1 §3 (Roles and trust boundaries), §10 (Security
> model), §17 (Judge questions and accurate answers).
>
> Scope: the MVP as shipped in this repository (local chain + the deployment plan for X Layer).
> This is a working prototype with explicit trust boundaries — **not** a trustless production
> lending system, and it does not claim that every default is recovered.

## 1. The three MVP trust assumptions (spec §3.1)

These are deliberate, documented centralization assumptions. They must appear in the README and
in the demo narration.

1. **The orchestrator may submit a request for a borrower** if the borrower has authorized that
   action, or the demo wallet is controlled by the orchestrator.
2. **The orchestrator may issue work attestations.**
3. **The revenue router controls the registered demo receiving path.**

Everything else is enforced onchain: the vault rejects invalid quotes, providers, tiers, job
hashes and duplicate settlements regardless of what the orchestrator asks for.

## 2. Assets and actors

| Asset | Custodian | Notes |
| --- | --- | --- |
| Lender USDC (pool liquidity) | ComputeCreditVault | Withdrawable only up to the lender's proportional share of **idle** assets. |
| Outstanding receivables | borrower agents | Not liquidity; not withdrawable; may never be repaid. |
| Conditional lien targets | nobody (a claim, not a balance) | Realised only if revenue flows through the registered route. |
| Provider payments | provider wallet from the registry | Solvency-checked against the registered price. |
| Trust scores / attestations | TrustPassport | Bounded, event-logged, one-time seeded. |

Actors: lender, borrower agent, provider, buyer (external payer), vault (onchain authority),
passport (onchain registry), revenue router (allowlisted), orchestrator (trusted in MVP),
keeper (permissionless caller of `penalize`).

## 3. Threat table

| # | Threat | Mitigation in the MVP | Residual risk |
| --- | --- | --- | --- |
| T1 | Inflated provider quote drains the vault | The vault reads the price from `ProviderRegistry` and caps `computeCost` at it; a caller-supplied quote is never accepted. | A compromised registry administrator can raise the registered price (event-logged, bounded by the borrower's tier ceiling). |
| T2 | Double settlement / double counting | `serviced`, `settled` and `defaulted` are explicit per-advance fields; `totalOutstanding` is decremented exactly once per principal unit; settled advances are skipped by servicing and penalization. | None onchain; covered by unit + invariant tests. |
| T3 | Router services an advance without transferring USDC | `serviceAdvanceWithTransfer` performs `safeTransferFrom` **before** updating accounting, and is restricted to allowlisted routers (`setApprovedRouter`). | An allowlisted-but-malicious router can only move funds it actually holds. |
| T4 | Reentrancy through a hostile settlement token | `ReentrancyGuard` on every token-moving path; `SafeERC20` everywhere; dedicated hostile-token tests (`ReentrantUSDC`, `BlockingUSDC`). | A fee-on-transfer or rebasing token would break accounting — the vault validates `decimals() == 6` and regular USDC semantics are assumed. |
| T5 | Orchestrator steals funds | The orchestrator cannot mint shares, mint scores, bypass the registry price, or record repayment without the router authorisation. It can only submit requests for borrowers who authorised it. | Trust assumption #1/#2. Production replaces it with agent-signed EIP-712 requests and policy-controlled wallets. |
| T6 | Borrower avoids the lien by changing wallets | Not prevented. Payments that do not flow through the registered route are invisible to the lien. | **Known limitation.** Production requires a contract-controlled receiving wallet, wallet policy, or facilitator-level split settlement. |
| T7 | Sybil reset after a default | A defaulted wallet is penalized (score 0 + lien); a fresh wallet starts at the bootstrap tier. | **Known limitation** — cross-wallet identity is Post-MVP. |
| T8 | Stale or replayed job binding | `jobHash = keccak256(borrower, provider, serviceId, price, nonce, expiry)`; each hash is single-use (`usedJobHash`) and bound to provider, service, price and expiry. | Offchain job-coordination trust: in the MVP the orchestrator may act as the trusted job coordinator. |
| T9 | Lender bank-run on liquidity backing an advance | `withdrawLiquidity` only allows the caller's proportional claim on **idle** assets; receivables are not withdrawable. | Lenders may still exit up to idle liquidity, as intended. |
| T10 | First-depositor share-price manipulation | The first deposit mints 1:1; later deposits mint `amount × totalShares / idleAssets` rounded **down**, and a deposit with zero minted shares reverts. Withdrawals burn shares rounded **up**. | Donation-based inflation is neutralised because share price uses idle assets, and an empty pool with shares outstanding (`S > 0, A = 0`) refuses deposits instead of dividing by zero. |
| T11 | Griefing the permissionless default path | `penalize` is intentionally permissionless (any keeper); it cannot be called before `dueAt` and does not move tokens, so it stays available while the vault is paused. | None material; a keeper can only record a fact the chain already implies. |
| T12 | Admin key compromise | Admin paths are limited to allowlisting, registry administration and pausing; they cannot move lender principal or rewrite an advance. | Owner keys are a trusted component in the MVP; production should use multisig/timelock. |
| T13 | Token mismatch / wrong decimals | The vault validates the settlement token at construction (non-zero, has code, `decimals() == 6`) and stores it immutably. | Deploying with a non-USDC 6-decimal token is an operational risk, not a code risk. |

## 4. Authorization matrix (spec §10.1)

| Call | Who may call it |
| --- | --- |
| `depositLiquidity`, `withdrawLiquidity` | any lender |
| `requestComputeAdvance` | the borrower |
| `requestComputeAdvanceFor` | approved operator **or** a requester the borrower authorised |
| `serviceAdvanceWithTransfer`, `captureLien` | allowlisted revenue router only |
| `repayEarly` | the borrower, an approved operator, or an authorised requester |
| `penalize` | anyone (permissionless) after expiry |
| `increaseScore`, `slashToZero`, lien bookkeeping on TrustPassport | the vault only |
| `seedScore`, `attest*` | the trusted attester only |
| registry registration / price updates | registry owner or approved administrator |
| approvals, pause, revenue-source registration | vault owner; revenue-source changes are rejected while an advance is active |

## 5. Known limitations (state these honestly)

* The MVP trusts the orchestrator for coordination and attestation, and the router for the
  receiving path (assumptions #1–#3 above).
* Recovery is **conditional**, not guaranteed: the lien only captures revenue that flows through
  the registered route, and it stops at exactly the target.
* A default is recovered only if the borrower earns again through that route.
* Scores are only weakly sybil resistant; a new wallet restarts at the bootstrap tier.
* The demo settlement asset is a local mock token; X Layer testnet/mainnet use real USDC
  (`README.md` lists the confirmed network parameters and the mainnet USDC address).
* No formal verification; invariants are fuzz-tested with Foundry, not proven.
* Not a regulated financial product: this is an onchain revenue-based advance prototype.

## 6. Production migration path (spec §3.2)

1. Agent-signed EIP-712 advance requests (removes assumption #1).
2. Multiple independent attesters and verifiable attestation sources (removes #2).
3. A contract-controlled receiving wallet, wallet policy or facilitator-level split settlement
   (removes #3 and closes T6).
4. Escrowed receivables via `WorkEscrow` so the buyer's payment is locked before the advance.
5. Cross-wallet identity / sybil resistance and multisig + timelock administration.
