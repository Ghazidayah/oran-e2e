#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/serial-a-to-b-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"
refresh_pods

echo "RUN_DIR=$RUN_DIR" | tee "$RUN_DIR/00-path.txt"
echo "UE=$UE_POD" | tee "$RUN_DIR/01-pods.txt"
echo "GNB_A_SOURCE=$GNB_A_POD" | tee -a "$RUN_DIR/01-pods.txt"
echo "GNB_B_TARGET=$GNB_B_POD" | tee -a "$RUN_DIR/01-pods.txt"

log_section "Pre-check source gNB-A"
ci_check_one "$GNB_A_POD" 19090 "source-gnb-a" "$RUN_DIR" | tee "$RUN_DIR/02-source-gnb-a-ci.txt"

log_section "Pre-check target gNB-B"
ci_check_one "$GNB_B_POD" 19092 "target-gnb-b" "$RUN_DIR" | tee "$RUN_DIR/03-target-gnb-b-ci.txt"

log_section "Start live captures"
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 10.45.0.1' > "$RUN_DIR/04-ue-continuous-ping.log" 2>&1 &
PING_PID=$!

kubectl -n oran-ran logs "$GNB_A_POD" --since=5s -f > "$RUN_DIR/05-source-gnb-a.log" 2>&1 &
LOG_A_PID=$!

kubectl -n oran-ran logs "$GNB_B_POD" --since=5s -f > "$RUN_DIR/06-target-gnb-b.log" 2>&1 &
LOG_B_PID=$!

kubectl -n oran-core logs deploy/open5gs-amf --since=5s -f > "$RUN_DIR/07-amf.log" 2>&1 &
LOG_AMF_PID=$!

kubectl -n oran-core logs deploy/open5gs-smf --since=5s -f > "$RUN_DIR/08-smf.log" 2>&1 &
LOG_SMF_PID=$!

kubectl -n oran-core logs deploy/open5gs-upf --since=5s -f > "$RUN_DIR/09-upf.log" 2>&1 &
LOG_UPF_PID=$!

kubectl -n oran-ran port-forward pod/"$GNB_A_POD" 19090:9090 > "$RUN_DIR/10-portforward-trigger.log" 2>&1 &
PF_PID=$!

sleep 5

log_section "Trigger A to B N2 HO"
timeout 5 bash -lc 'printf "ci trigger_n2_ho 1,1\r\n" | nc 127.0.0.1 19090' | tee "$RUN_DIR/11-ho-trigger-output.txt" || true

sleep 45

kill "$PF_PID" "$PING_PID" "$LOG_A_PID" "$LOG_B_PID" "$LOG_AMF_PID" "$LOG_SMF_PID" "$LOG_UPF_PID" 2>/dev/null || true
sleep 2

log_section "Post-HO UE state"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "----- routes -----"
ip route || true
echo "----- ping DN gateway -----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
echo "----- ping internet -----"
ping -I oaitun_ue1 -c 4 8.8.8.8 || true
' | tee "$RUN_DIR/12-ue-post-state.txt"

log_section "Post-HO CI source gNB-A"
ci_check_one "$GNB_A_POD" 19090 "post-source-gnb-a" "$RUN_DIR" | tee "$RUN_DIR/13-post-source-ci.txt"

log_section "Post-HO CI target gNB-B"
ci_check_one "$GNB_B_POD" 19092 "post-target-gnb-b" "$RUN_DIR" | tee "$RUN_DIR/14-post-target-ci.txt"

log_section "Classification grep"
grep -RInE 'ci trigger_n2_ho|triggered N2 HO|handover|N2|HO|RRCReconfiguration|RRCSetup|RRCSetupComplete|Msg3|WAIT_Msg3|RA failed|InitialUEMessage|Registration|Path|UE Context|DUPLICATED|connection refused|accepted|error|fail' \
"$RUN_DIR" 2>/dev/null | tee "$RUN_DIR/15-classification-grep.txt" || true

cat > "$RUN_DIR/RESULT-SUMMARY.txt" <<EOF2
Serial A -> B N2 handover validation

Result:
Needs review. Expected successful HO requires target gNB-B ownership after trigger.

Success criteria:
- Source gNB-A accepts trigger.
- Target gNB-B completes RA/Msg3.
- Target gNB-B owns ue_id 1 after trigger.
- UE user-plane remains alive.
- No dirty state: different number of UEs / No DU connected on target after HO means failure.

Evidence saved in:
$RUN_DIR

Fast checks:
- Trigger output: $RUN_DIR/11-ho-trigger-output.txt
- Target logs: $RUN_DIR/06-target-gnb-b.log
- Post target CI: $RUN_DIR/14-post-target-ci.txt
- UE state: $RUN_DIR/12-ue-post-state.txt
- Grep: $RUN_DIR/15-classification-grep.txt
EOF2

cat "$RUN_DIR/RESULT-SUMMARY.txt"
