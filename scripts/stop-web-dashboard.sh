#!/usr/bin/env bash
set +e
pkill -f "web-dashboard/app.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k 18080/tcp 2>/dev/null || true
fi
echo "Stopped O-RAN dashboard processes on port 18080 if they were running."
