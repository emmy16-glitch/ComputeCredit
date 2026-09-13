#!/usr/bin/env bash
#
# ComputeCredit - local end-to-end demo driver.
#
# Spec reference: ComputeCredit_v2.pdf §14 (Deployment plan, Day 7 - testnet integration:
# "Deploy the contracts. Run the full happy path. Run partial servicing. Run default and recovery.
# Record transaction hashes."), §16 (Demo script).
#
# What it does, against a local anvil chain:
#   1. checks that anvil is reachable (starts one in the background if not);
#   2. broadcasts phase 1: deployment, lender deposit, happy path (§9.1), partial servicing (§9.2);
#   3. advances the chain clock past the advance window using the node's evm RPCs - a blockchain
#      clock cannot be moved from inside a transaction, which is why this is a two-phase script;
#   4. broadcasts phase 2: default, lien target, conditional recovery (§9.3);
#   5. prints the onchain summary and where the transaction hashes were recorded.
#
# Usage:
#   bash scripts/demo-local.sh                # default RPC http://127.0.0.1:8545
#   RPC_URL=http://127.0.0.1:9545 bash scripts/demo-local.sh

set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
CHAIN_ID="${CHAIN_ID:-31337}"
ADVANCE_WINDOW="${ADVANCE_WINDOW:-43200}"          # 12h, matches ComputeCreditVault.ADVANCE_WINDOW
FOUNDRY_BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin}"
FORGE="${FORGE:-$FOUNDRY_BIN/forge}"
CAST="${CAST:-$FOUNDRY_BIN/cast}"
ANVIL="${ANVIL:-$FOUNDRY_BIN/anvil}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTRACTS_DIR="$REPO_ROOT/contracts"
STARTED_ANVIL=0

# anvil started by this script is left running by default (the dashboard can then read the same
# chain). Set STOP_ANVIL=1 to shut it down when the demo finishes.
cleanup() {
  if [ "${STOP_ANVIL:-0}" = "1" ] && [ "$STARTED_ANVIL" = "1" ] && [ -n "${ANVIL_PID:-}" ]; then
    kill "$ANVIL_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

rpc_alive() {
  "$CAST" chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1
}

if ! rpc_alive; then
  echo "==> No chain at $RPC_URL - starting anvil"
  "$ANVIL" --host 0.0.0.0 --port "${RPC_URL##*:}" --chain-id "$CHAIN_ID" >"$CONTRACTS_DIR/anvil.log" 2>&1 &
  ANVIL_PID=$!
  STARTED_ANVIL=1
  for _ in $(seq 1 40); do
    if rpc_alive; then break; fi
    sleep 0.5
  done
  rpc_alive || { echo "ERROR: anvil did not start"; exit 1; }
  echo "    anvil pid $ANVIL_PID (log: contracts/anvil.log, stop with: kill $ANVIL_PID)"
fi

echo "==> Chain id: $("$CAST" chain-id --rpc-url "$RPC_URL")"

cd "$CONTRACTS_DIR"
mkdir -p deployments

echo
echo "==============================================================="
echo " PHASE 1/2  deployment + happy path + partial servicing"
echo "==============================================================="
"$FORGE" script script/DemoLocal.s.sol:DemoLocal \
  --rpc-url "$RPC_URL" --broadcast --skip-simulation

echo
echo "==============================================================="
echo " advancing the chain clock by $ADVANCE_WINDOW s + 1 (past dueAt)"
echo "==============================================================="
"$CAST" rpc evm_increaseTime "$((ADVANCE_WINDOW + 1))" --rpc-url "$RPC_URL" >/dev/null
"$CAST" rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
echo "new chain timestamp: $("$CAST" block latest --field timestamp --rpc-url "$RPC_URL")"

echo
echo "==============================================================="
echo " PHASE 2/2  default + lien + conditional recovery"
echo "==============================================================="
"$FORGE" script script/DemoLocal.s.sol:DemoLocal \
  --sig "runDefaultPhase()" \
  --rpc-url "$RPC_URL" --broadcast --skip-simulation

echo
echo "==> Transaction hashes: contracts/broadcast/DemoLocal.s.sol/$CHAIN_ID/run-latest.json"
echo "==> State snapshots   : contracts/deployments/$CHAIN_ID.json, contracts/deployments/$CHAIN_ID-demo.json"
echo
echo "Next:  bash scripts/dashboard.sh   (read-only dashboard against this chain)"
