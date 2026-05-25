#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic-suite}"
SUITE_ID="$(date +%Y%m%d-%H%M%S)"
SUITE_DIR="$BASE/$SUITE_ID"

mkdir -p "$SUITE_DIR"

echo "===== O-RAN PHASE 2 REALISTIC TRAFFIC SUITE ====="
echo "SUITE_ID=$SUITE_ID"
echo "SUITE_DIR=$SUITE_DIR"

run_scenario() {
  local name="$1"
  local script="$2"
  local log="$SUITE_DIR/${name}.log"

  echo
  echo "===== RUNNING: $name ====="
  echo "SCRIPT=$script"
  echo "LOG=$log"

  if bash "$script" 2>&1 | tee "$log"; then
    echo "OK" > "$SUITE_DIR/${name}.status"
    echo "[OK] $name"
  else
    echo "FAIL" > "$SUITE_DIR/${name}.status"
    echo "[FAIL] $name"
    return 1
  fi
}

FAIL=0

run_scenario "01-image-download" "scripts/traffic/run-image-download.sh" || FAIL=1
run_scenario "02-iperf-tcp" "scripts/traffic/run-iperf-tcp.sh" || FAIL=1
run_scenario "03-custom-udp" "scripts/traffic/run-udp-traffic.sh" || FAIL=1
run_scenario "04-video-download" "scripts/traffic/run-video-download.sh" || FAIL=1
run_scenario "05-web-browsing" "scripts/traffic/run-web-browsing.sh" || FAIL=1
run_scenario "06-streaming-like" "scripts/traffic/run-streaming-like.sh" || FAIL=1

echo
echo "===== SUITE SUMMARY ====="

{
  echo "O-RAN Phase 2 Realistic Traffic Suite"
  echo "Suite ID: $SUITE_ID"
  echo "Suite directory: $SUITE_DIR"
  echo
  for f in "$SUITE_DIR"/*.status; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .status)"
    status="$(cat "$f")"
    echo "$name: $status"
  done
  echo
  echo "Known limitation:"
  echo "- iperf3 UDP was tested but not retained."
  echo "- Custom UDP is used for jitter/loss because it works through oaitun_ue1."
} | tee "$SUITE_DIR/summary.txt"

echo
echo "Proof directory: $SUITE_DIR"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=OK"
  exit 0
else
  echo "VERDICT=FAIL"
  exit 2
fi
