# Deployment runbook — X Layer testnet (chain 1952)

## Day 0: integration gates (do not build further until these pass)
- [ ] RPC responds: `curl -X POST -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -H 'Content-Type: application/json' https://testrpc.xlayer.tech/terigon`
- [ ] Explorer reachable: https://www.oklink.com/x-layer-testnet
- [ ] Gas funded: claim **0.2 OKB/day** from the official faucet https://web3.okx.com/xlayer/faucet (connect wallet → Get 0.2 OKB). Backup: thirdweb X Layer faucet.
- [ ] Decide the demo USD rail (verified Sep 2026: the official faucet dispenses OKB + USDG/test ERC20s — **no native testnet USDC**):
  - Option A (recommended for the demo): leave `USDC` unset → deploy script deploys `MockUSDC` (6 decimals, permissionless `mint` for testnet velocity).
  - Option B: set `USDC=` to any 6-decimal test stable you control.
- [ ] One provider payment round trip on testnet (plain transfer). If this fails, stop — do not build optional modules.

## Local end-to-end (proves the whole loop before testnet)
```bash
bash scripts/demo-local.sh   # starts anvil if needed; STOP_ANVIL=1 to shut it down after
```
This broadcasts `DemoLocalPhase1` (deploy, 50 USDC deposit, happy-path settle, partial
servicing, default candidate), warps past the 12h window, then broadcasts `DemoLocalPhase2`
(default, lien recovery, final onchain assertions). Records land in
`contracts/deployments/31337-demo.json` + `phase1/2-txs.json`. It must end with
`ALL LOCAL DEMO ASSERTIONS PASSED` — any revert is a ship-blocker.

## Deploy
```bash
cp .env.example .env   # repo already ships a working local .env; for testnet, fill OPERATOR_PRIVATE_KEY / DEPLOYER_PRIVATE_KEY, PROVIDER_*, SERVICE_ID
export PATH="$HOME/.foundry/bin:$PATH"
forge build && forge test   # must be green (61/61) before broadcast
forge script contracts/script/Deploy.s.sol \
  --rpc-url https://testrpc.xlayer.tech/terigon --broadcast
# record addresses below + DEPLOY_BLOCK (for bot /history) in .env
```

## Post-deploy checklist
- [ ] Paste addresses into `README.md` + `.env` (`VAULT PASSPORT REGISTRY ROUTER USDC`).
- [ ] `registry.quote(provider)` returns expected price (onchain, not a screenshot).
- [ ] Seed demo borrower: `passport.seedDefault(nova)` (or `seedScore` 300) from attester key.
- [ ] Lender `deposit` 10 USDC → shares visible.
- [ ] Happy path on testnet: advance → provider paid → buyer `routePayment` → settled → score bump. Save tx hashes.
- [ ] Default path on testnet: `penalize` after expiry → lien capture on next routed payment. Save tx hashes.
- [ ] Start keeper: `KEEPER_BORROWERS=<nova> npm run keeper` (or `--watch 600` loop).
- [ ] Start bot, run every command once against testnet.
- [ ] Verify contracts on OKLink (flatten or `--verify` with explorer API if supported; at minimum publish sources + addresses in README).
- [ ] Render fallback demo recording.

## Rehearsal gates (from docs/DEMO.md)
- `forge test` 61/61 green (24 core + 10 escrow + 4 fuzz + 8 security + 1 invariant suite + 9 production + 5 RWA). `npm run typecheck` clean.
- Never claim: guaranteed recovery, universal lien, sybil-proof scores, "x402 facilitator settles on X Layer".
