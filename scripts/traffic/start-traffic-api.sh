#!/usr/bin/env bash
set -euo pipefail

cd "$HOME/oran-e2e"

LOG_DIR="$HOME/oran-proof/phase2-traffic-api"
mkdir -p "$LOG_DIR"

pkill -f "traffic_api_server.py" 2>/dev/null || true

nohup web-dashboard/.venv/bin/python scripts/traffic/traffic_api_server.py \
  > "$LOG_DIR/server.log" 2>&1 &

echo $! > "$LOG_DIR/server.pid"

sleep 3

echo "===== PROCESS ====="
ps aux | grep '[t]raffic_api_server.py' || true

echo
echo "===== HEALTH ====="
curl -s http://127.0.0.1:5055/api/traffic/health | python3 -m json.tool

echo
echo "Traffic API available at:"
echo "http://127.0.0.1:5055"
echo "http://192.168.1.142:5055"
