#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
SEQ_DIR="$HOME/oran-proof/f1-du-switch-sequence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SEQ_DIR"

echo "SEQ_DIR=$SEQ_DIR" | tee "$SEQ_DIR/00-sequence-dir.txt"

echo "===== Step A: switch to DU0 ====="
RUN_DIR="$SEQ_DIR/01-switch-du0" ./scripts/switch-f1-du.sh du0 2>&1 | tee "$SEQ_DIR/01-switch-du0.log"

echo "===== Short stability check on DU0 ====="
UE_POD=$(kubectl -n "$NS" get pods -l app=oai-nr-ue --field-selector=status.phase=Running -o name | head -n 1 | cut -d/ -f2)
kubectl -n "$NS" exec "$UE_POD" -- ping -I oaitun_ue1 -c 10 8.8.8.8 2>&1 | tee "$SEQ_DIR/02-du0-stability-ping.txt"

echo "===== Step B: switch to DU1 ====="
RUN_DIR="$SEQ_DIR/03-switch-du1" ./scripts/switch-f1-du.sh du1 2>&1 | tee "$SEQ_DIR/03-switch-du1.log"

echo "===== Short stability check on DU1 ====="
UE_POD=$(kubectl -n "$NS" get pods -l app=oai-nr-ue --field-selector=status.phase=Running -o name | head -n 1 | cut -d/ -f2)
kubectl -n "$NS" exec "$UE_POD" -- ping -I oaitun_ue1 -c 10 8.8.8.8 2>&1 | tee "$SEQ_DIR/04-du1-stability-ping.txt"

echo "===== Step C: switch back to DU0 ====="
RUN_DIR="$SEQ_DIR/05-switch-back-du0" ./scripts/switch-f1-du.sh du0 2>&1 | tee "$SEQ_DIR/05-switch-back-du0.log"

echo "===== Final state ====="
kubectl -n "$NS" get pods -o wide | tee "$SEQ_DIR/06-final-pods.txt"
kubectl -n "$NS" get deploy -o wide | tee "$SEQ_DIR/07-final-deployments.txt"
kubectl -n "$NS" get endpoints oai-cu-ci oai-du0-rfsim oai-du1-rfsim -o wide | tee "$SEQ_DIR/08-final-endpoints.txt" || true

echo "F1_DU_SWITCH_SEQUENCE_OK"
echo "Evidence saved in: $SEQ_DIR"
