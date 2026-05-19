#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
CORE_NS="${CORE_NS:-oran-core}"
RUN_ROOT="${RUN_ROOT:-$HOME/oran-proof/web-dashboard-runs}"

RUN_DIR="$RUN_ROOT/$(date +%Y%m%d-%H%M%S)-f1-handover"
mkdir -p "$RUN_DIR"

echo "RUN_DIR=$RUN_DIR" | tee "$RUN_DIR/00-run-dir.txt"

get_pod() {
  local app="$1"
  kubectl -n "$NS" get pod -l "app=${app}" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>/dev/null | tail -n 1 | cut -d/ -f2
}

UE_POD="$(get_pod oai-nr-ue-f1)"
CU_POD="$(get_pod oai-cu)"
DU0_POD="$(get_pod oai-du0)"
DU1_POD="$(get_pod oai-du1)"

{
  echo "UE_POD=$UE_POD"
  echo "CU_POD=$CU_POD"
  echo "DU0_POD=$DU0_POD"
  echo "DU1_POD=$DU1_POD"
} | tee "$RUN_DIR/01-pods.txt"

if [ -z "$UE_POD" ] || [ -z "$CU_POD" ] || [ -z "$DU0_POD" ] || [ -z "$DU1_POD" ]; then
  echo "[FAIL] Missing one or more F1 pods"
  echo "F1_HANDOVER_RESULT=FAILED"
  exit 1
fi

echo
echo "===== Pre-check UE tunnel ====="
kubectl -n "$NS" exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1
echo "-----"
ip route
echo "-----"
ping -I oaitun_ue1 -c 4 10.45.0.1
' | tee "$RUN_DIR/02-ue-before-ho.txt"

echo
echo "===== Start capture ====="
kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 -O -D 10.45.0.1' \
  > "$RUN_DIR/10-ping-during-f1-ho.log" 2>&1 &
PING_PID=$!

kubectl -n "$NS" logs "$CU_POD" --since=5s -f > "$RUN_DIR/11-cu-ho.log" 2>&1 &
LOG_CU_PID=$!

kubectl -n "$NS" logs "$DU0_POD" --since=5s -f > "$RUN_DIR/12-du0-ho.log" 2>&1 &
LOG_DU0_PID=$!

kubectl -n "$NS" logs "$DU1_POD" --since=5s -f > "$RUN_DIR/13-du1-ho.log" 2>&1 &
LOG_DU1_PID=$!

kubectl -n "$CORE_NS" logs deploy/open5gs-amf --since=5s -f > "$RUN_DIR/14-amf-ho.log" 2>&1 &
LOG_AMF_PID=$!

kubectl -n "$NS" port-forward svc/oai-cu-ci 19091:9090 > "$RUN_DIR/15-cu-portforward.log" 2>&1 &
PF_PID=$!

cleanup() {
  kill "$PING_PID" "$LOG_CU_PID" "$LOG_DU0_PID" "$LOG_DU1_PID" "$LOG_AMF_PID" "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

sleep 5

echo
echo "===== Trigger F1 handover ====="
date -Iseconds | tee "$RUN_DIR/16-trigger-time.txt"

timeout 5 bash -lc 'printf "ci trigger_f1_ho\r\n" | nc 127.0.0.1 19091' \
  | tee "$RUN_DIR/17-trigger-f1-ho.txt" || true

sleep 35
cleanup
sleep 2

echo
echo "===== Post-handover UE check ====="
if kubectl -n "$NS" exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1
echo "-----"
ip route
echo "-----"
ping -I oaitun_ue1 -c 4 10.45.0.1
' | tee "$RUN_DIR/18-ue-after-ho.txt"; then
  POST_PING_OK=true
else
  POST_PING_OK=false
fi

echo
echo "===== Handover evidence summary ====="
{
  echo "--- Trigger ---"
  grep -HnE 'trigger_f1_ho|RRC F1 handover triggered' "$RUN_DIR/17-trigger-f1-ho.txt" "$RUN_DIR/11-cu-ho.log" 2>/dev/null || true

  echo
  echo "--- CU handover ---"
  grep -HnE 'Handover triggered|HO acknowledged|update RNTI|RRCReconfigurationComplete|handover for UE .* complete|trigger release' "$RUN_DIR/11-cu-ho.log" 2>/dev/null || true

  echo
  echo "--- Target DU access / CFRA ---"
  grep -HnE 'PUSCH with TC_RNTI|CFRA procedure succeeded|Adding new UE context|UE RNTI .* in-sync' "$RUN_DIR/12-du0-ho.log" "$RUN_DIR/13-du1-ho.log" 2>/dev/null | awk 'NR<=20' || true

  echo
  echo "--- Post-handover ping ---"
  grep -HnE 'PING|packets transmitted|0% packet loss' "$RUN_DIR/18-ue-after-ho.txt" 2>/dev/null || true
} | tee "$RUN_DIR/99-f1-ho-summary.txt"
TRIGGER_OK=false
CU_COMPLETE=false
RRC_COMPLETE=false
DU_CFRA=false

grep -RqiE 'RRC F1 handover triggered|trigger_f1_ho' "$RUN_DIR" && TRIGGER_OK=true
grep -RqiE 'handover for UE .* complete|handover .* complete' "$RUN_DIR" && CU_COMPLETE=true
grep -Rqi 'RRCReconfigurationComplete' "$RUN_DIR" && RRC_COMPLETE=true
grep -RqiE 'CFRA procedure succeeded|PUSCH with TC_RNTI|Adding new UE context' "$RUN_DIR" && DU_CFRA=true

echo
echo "===== Result ====="
echo "TRIGGER_OK=$TRIGGER_OK"
echo "CU_COMPLETE=$CU_COMPLETE"
echo "RRC_COMPLETE=$RRC_COMPLETE"
echo "DU_CFRA=$DU_CFRA"
echo "POST_PING_OK=$POST_PING_OK"
echo "RUN_DIR=$RUN_DIR"

if [ "$TRIGGER_OK" = true ] && [ "$CU_COMPLETE" = true ] && [ "$RRC_COMPLETE" = true ] && [ "$DU_CFRA" = true ] && [ "$POST_PING_OK" = true ]; then
  echo "F1_HANDOVER_RESULT=SUCCESS"
  exit 0
else
  echo "F1_HANDOVER_RESULT=FAILED"
  exit 1
fi
