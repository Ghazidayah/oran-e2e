#!/usr/bin/env bash
set +e
PORT="${ORAN_DASHBOARD_PORT:-18080}"

pkill -f "web-dashboard/app.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi
echo "Stopped O-RAN dashboard processes on port ${PORT} if they were running."
