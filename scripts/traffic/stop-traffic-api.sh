#!/usr/bin/env bash
set -euo pipefail

echo "===== STOP PHASE 2 TRAFFIC API ====="

pkill -f "traffic_api_server.py" 2>/dev/null || true

sleep 1

if ps aux | grep '[t]raffic_api_server.py' >/dev/null 2>&1; then
  echo "[FAIL] traffic_api_server.py still running"
  ps aux | grep '[t]raffic_api_server.py'
  exit 1
fi

echo "[OK] Traffic API stopped"
