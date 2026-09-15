#!/usr/bin/env bash
#
# ComputeCredit v3 — local end-to-end demo driver (idea credit: Arena AI draft PR).
#
# Against a local anvil chain it:
#   1. starts anvil if none is reachable (PID tracked in a file — killed by PID, never pkill);
#   2. broadcasts Phase 1: deploy, lender deposit, happy path, partial servicing;
#   3. advances the chain clock past the 12h advance window (impossible from inside a tx,
#      hence the two phases);
#   4. broadcasts Phase 2: default, lien target, conditional recovery + final assertions;
#   5. saves deployment + per-phase transaction records under contracts/deployments/.
#
# Usage:
#   bash scripts/demo-local.sh
#   RPC_URL=http://127.0.0.1:9545 STOP_ANVIL=1 bash scripts/demo-local.sh
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
RPC_PORT="${RPC_URL##*:}"
# Local anvil has no funds for keys from a testnet .env (forge autoloads .env
# into vm.envOr). An explicit shell env var takes precedence, so default the
# demo key to anvil's dev account when targeting localhost. Explicit exports
# still win; testnet runs never touch this script.
if [[ "$RPC_URL" == *"127.0.0.1"* || "$RPC_URL" == *"localhost"* ]]; then
  export DEMO_PRIVATE_KEY="${DEMO_PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
fi
ADVANCE_WINDOW="${ADVANCE_WINDOW:-43200}"
FOUNDRY_BIN="${FOUNDRY_BIN:-$HOME/.foundry/bin}"
FORGE="$FOUNDRY_BIN/forge"
CAST="$FOUNDRY_BIN/cast"
ANVIL="$FOUNDRY_BIN/anvil"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PID_FILE="/tmp/computecredit-anvil.pid"
DEPLOY_DIR="$REPO_ROOT/contracts/deployments"
STARTED_BY_ME=0

cleanup() {
  if [ "$STARTED_BY_ME" = "1" ] && [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
}
[ "${STOP_ANVIL:-0}" = "1" ] && trap cleanup EXIT

rpc_alive() { "$CAST" chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; }

if ! rpc_alive; then
  echo "==> starting anvil on port $RPC_PORT"
  mkdir -p "$DEPLOY_DIR"
  "$ANVIL" --host 127.0.0.1 --port "$RPC_PORT" >"$DEPLOY_DIR/anvil.log" 2>&1 &
  echo $! > "$PID_FILE"
  STARTED_BY_ME=1
  for _ in $(seq 1 40); do rpc_alive && break; sleep 0.5; done
  rpc_alive || { echo "ERROR: anvil did not start (see $DEPLOY_DIR/anvil.log)"; exit 1; }
  echo "    anvil pid $(cat "$PID_FILE")"
fi
echo "==> chain id: $("$CAST" chain-id --rpc-url "$RPC_URL")"
echo "==> deployer balance: $("$CAST" balance 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url "$RPC_URL")"

cd "$REPO_ROOT"
mkdir -p "$DEPLOY_DIR"

echo
echo "==============================================================="
echo " PHASE 1/2  deploy + happy path + partial servicing"
echo "==============================================================="
"$FORGE" script contracts/script/DemoLocal.s.sol:DemoLocalPhase1 \
  --rpc-url "$RPC_URL" --broadcast
cp broadcast/DemoLocal.s.sol/31337/run-latest.json "$DEPLOY_DIR/phase1-txs.json"
echo "saved: contracts/deployments/31337-demo.json + phase1-txs.json"

echo
echo "==============================================================="
echo " advancing clock by $((ADVANCE_WINDOW + 1))s (past dueAt)"
echo "==============================================================="
"$CAST" rpc evm_increaseTime "$((ADVANCE_WINDOW + 1))" --rpc-url "$RPC_URL" >/dev/null
"$CAST" rpc evm_mine --rpc-url "$RPC_URL" >/dev/null
echo "new timestamp: $("$CAST" block latest --field timestamp --rpc-url "$RPC_URL")"

echo
echo "==============================================================="
echo " PHASE 2/2  default + lien recovery + final assertions"
echo "==============================================================="
"$FORGE" script contracts/script/DemoLocal.s.sol:DemoLocalPhase2 \
  --rpc-url "$RPC_URL" --broadcast
cp broadcast/DemoLocal.s.sol/31337/run-latest.json "$DEPLOY_DIR/phase2-txs.json"
echo "saved: contracts/deployments/phase2-txs.json"

echo
python3 -c "
import json
for phase in ('phase1-txs', 'phase2-txs'):
    d = json.load(open('contracts/deployments/%s.json' % phase))
    txs = d.get('transactions', [])
    print('%s: %d broadcast transactions' % (phase, len(txs)))
    for t in txs:
        print('  ', t.get('transactionType', '?'), t.get('hash', ''))
"
echo
echo "LOCAL END-TO-END DEMO COMPLETE — no errors."
