#!/usr/bin/env bash
#
# ComputeCredit - read-only dashboard launcher (spec §12).
#
# Reads contract state from the configured RPC and serves a read-only page on DASHBOARD_PORT.
# It holds no keys and sends no transactions.
#
# Usage:
#   bash scripts/dashboard.sh                       # defaults to the local demo chain
#   CHAIN_ID=195 RPC_URL=https://... bash scripts/dashboard.sh   # any deployed network

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DASHBOARD_PORT="${DASHBOARD_PORT:-8787}"
export DASHBOARD_HOST="${DASHBOARD_HOST:-0.0.0.0}"
export RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export CHAIN_ID="${CHAIN_ID:-31337}"

cd "$REPO_ROOT/dashboard"

if [ ! -d "$REPO_ROOT/node_modules/ethers" ]; then
  echo "==> installing dependencies (npm install at the repository root)"
  (cd "$REPO_ROOT" && npm install --no-audit --no-fund)
fi

echo "==> dashboard: http://127.0.0.1:$DASHBOARD_PORT  (chain $CHAIN_ID via $RPC_URL)"
exec node server.mjs
