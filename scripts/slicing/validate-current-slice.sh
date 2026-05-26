#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
PROOF_BASE="${PROOF_BASE:-$HOME/oran-proof/phase3-real-snssai-validation}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$PROOF_BASE/$RUN_ID"
mkdir -p "$DIR"

UE="$(kubectl -n "$NS" get pods --no-headers | awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}')"
[ -n "$UE" ] || { echo "[FAIL] UE not running"; exit 1; }

echo "RUN_ID=$RUN_ID"
echo "DIR=$DIR"
echo "UE=$UE"

echo "===== UE CONFIG SLICE ====="
kubectl -n "$NS" get cm oai-nrue-config -o json \
  | python3 -c 'import sys,json; data=json.load(sys.stdin).get("data",{}); print(data.get("nr-ue.conf",""))' \
  | grep "pdu_sessions" | tee "$DIR/ue-requested-slice.txt"

echo "===== UE TUNNEL ====="
kubectl -n "$NS" exec "$UE" -- ip addr show oaitun_ue1 | tee "$DIR/oaitun.txt"

echo "===== UE ROUTE ====="
kubectl -n "$NS" exec "$UE" -- ip route | tee "$DIR/route.txt"

echo "===== PING INTERNET THROUGH TUNNEL ====="
kubectl -n "$NS" exec "$UE" -- ping -I oaitun_ue1 -c 4 8.8.8.8 | tee "$DIR/ping.txt"

echo "===== OAITUN COUNTERS ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-counters.txt"

echo "===== VALIDATION OK ====="
