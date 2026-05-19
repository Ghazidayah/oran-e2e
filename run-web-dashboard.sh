#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
APP_DIR="$BASE_DIR/web-dashboard"
PORT="${ORAN_DASHBOARD_PORT:-18080}"

cd "$APP_DIR"

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

. .venv/bin/activate
pip install -q -r requirements.txt

echo "Starting O-RAN Dashboard..."
echo "Open: http://192.168.1.142:${PORT}"
python3 app.py
