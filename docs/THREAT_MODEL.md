# Threat model

Solidity: 0.8.26, OpenZeppelin 5.3 (ERC4626, SafeERC20, ReentrancyGuard, Pausable, EIP712, ECDSA).
All token-moving functions: CEI ordering + `nonReentrant` + `whenNotPaused`.

| Threat | Impact | MVP mitigation | Test | Production upgrade |
|---|---|---|---|---|
| Inflated provider quote | Excess advance | Onchain registry ceiling; `cost ≤ pricePerJob` enforced | `test_OverProviderPriceReverts` | Signed provider quote + buyer escrow |
| Unauthorized advance (operator borrows for victim) | Pool loss | Operator allowlist + borrower-self path + EIP-712 intent w/ nonce+expiry | `test_NonOperatorCannotRequest`, `test_RequestWithSigWorks/BadSig` | Agent-signed requests only; wallet policy |
| Fake repayment record | False settlement | `serviceAdvanceWithTransfer` pulls USDC before accounting; single `_applyService` | `test_NonRouterServiceReverts`, `test_NoDoubleDecrementOnSettle` | Facilitator atomic settlement |
| Router compromise | Misrouted revenue | Small allowlisted router; router cannot mint/withdraw/scores | `test_NonRouterServiceReverts` | Audited router + policy wallet + multisig admin |
| Advance stacking | Hidden leverage | `activeAdvanceId` invariant; second request reverts | `test_NoTwoActiveAdvances` | Per-agent global caps |
| Job replay | Double-spend same work | `usedJobHash` forever | `test_JobHashReuseRevertsAfterSettle` | Buyer-signed job nonces |
| Revenue-source swap mid-loan | Lien evasion | Source locked while active; lien blocks new advance | `test_LienCapture…` (locked) | Contract-controlled receiving wallet |
| Wallet reset (sybil) | Repeat low-tier borrowing | One advance, ≤5 USDC bootstrap tier, slow +50 growth | tiers in passport | Stake/history proofs, cross-wallet identity |
| Default, no future revenue | Lender loss | Conditional lien + −300 score; honest "no guarantee" copy | `test_DefaultRecordsShortfallAndLien` | Escrowed receivable/collateral |
| Reentrancy (ERC777-style/USDC callbacks) | Accounting/token loss | Guards + SafeERC20 + pull-pattern | `Security.t.sol` (8 tests) with adversarial `ReentrantUSDC` mock proving reentrant servicing/default paths revert or stay consistent | Audit + invariant fuzzing |
| Share inflation (first-depositor) | Lender theft | ERC4626 standard (virtual offset via OZ) | `test_SecondDepositProportionalAfterLoss` | Audit |
| Wrong decimals | Mispriced amounts | Single 6-decimal USDC config; mock matches | all amounts in base units | Deployment-time decimals assertion |
| Admin key compromise | Router/operator/risk swapped | `Ownable` + events; risk setters bounded (`split≤100%`, `window≥1h`) | — | Multisig + timelock |
| Chain/facilitator confusion | False "x402 settles on X Layer" claim | Documented: split enforced onchain on X Layer; facilitator unsupported there | — | Deploy router on facilitator-supported chain or run own facilitator |

## Explicit non-guarantees (must appear in demo + README)
- Lenders are NOT guaranteed returns or full recovery.
- Lien captures ONLY revenue through the registered route.
- Scores are NOT sybil-resistant.
- This is NOT regulated factoring; it is an onchain revenue-based advance primitive.
