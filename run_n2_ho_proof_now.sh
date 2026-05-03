#!/usr/bin/env bash

cd ~/oran-e2e-freeze || exit 1

RUN_DIR=~/oran-proof/n2-ho-proof-now-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN_DIR"

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
GNB_A_POD=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
GNB_B_POD=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)

{
  echo "UE_POD=$UE_POD"
  echo "GNB_A_POD=$GNB_A_POD"
  echo "GNB_B_POD=$GNB_B_POD"
} | tee "$RUN_DIR/00-pods.txt"

echo "===== baseline UE =====" | tee "$RUN_DIR/01-ue-baseline.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1
echo "-----"
ip route
echo "-----"
ping -I oaitun_ue1 -c 3 10.45.0.1
' | tee -a "$RUN_DIR/01-ue-baseline.txt"

echo "===== start continuous ping ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 10.45.0.1' \
  > "$RUN_DIR/02-ue-ping.log" 2>&1 &
PING_PID=$!

echo "===== start live logs ====="
kubectl -n oran-ran logs "$GNB_A_POD" --since=5s -f > "$RUN_DIR/03-gnb-a.log" 2>&1 &
A_PID=$!

kubectl -n oran-ran logs "$GNB_B_POD" --since=5s -f > "$RUN_DIR/04-gnb-b.log" 2>&1 &
B_PID=$!

kubectl -n oran-core logs deploy/open5gs-amf --since=5s -f > "$RUN_DIR/05-amf.log" 2>&1 &
M_PID=$!

echo "===== start port-forward ====="
kubectl -n oran-ran port-forward pod/"$GNB_A_POD" 19091:9090 > "$RUN_DIR/06-portforward.log" 2>&1 &
PF_PID=$!
sleep 5

echo "===== CI pre-check =====" | tee "$RUN_DIR/07-ci-pre.txt"
timeout 3 bash -lc 'printf "ci get_single_rnti\r\n" | nc 127.0.0.1 19091' | tee -a "$RUN_DIR/07-ci-pre.txt"
timeout 3 bash -lc 'printf "ci fetch_du_by_ue_id 1\r\n" | nc 127.0.0.1 19091' | tee -a "$RUN_DIR/07-ci-pre.txt"

echo "===== trigger N2 HO =====" | tee "$RUN_DIR/08-ci-trigger.txt"
timeout 5 bash -lc 'printf "ci trigger_n2_ho 1,1\r\n" | nc 127.0.0.1 19091' | tee -a "$RUN_DIR/08-ci-trigger.txt"

echo "===== let it settle 25s ====="
sleep 25

kill $PF_PID 2>/dev/null || true
kill $A_PID 2>/dev/null || true
kill $B_PID 2>/dev/null || true
kill $M_PID 2>/dev/null || true
kill $PING_PID 2>/dev/null || true

echo "===== gNB-A key =====" | tee "$RUN_DIR/09-gnb-a-key.txt"
egrep -i 'ho|handover|release|source|target|RNTI|CU-UE-ID|Reconfiguration|error|fail' "$RUN_DIR/03-gnb-a.log" \
  | tail -n 200 | tee -a "$RUN_DIR/09-gnb-a-key.txt" || true

echo "===== gNB-B key =====" | tee "$RUN_DIR/10-gnb-b-key.txt"
egrep -i 'ho|handover|release|source|target|RNTI|CU-UE-ID|Create UE context|RRCSetup|InitialContext|error|fail' "$RUN_DIR/04-gnb-b.log" \
  | tail -n 200 | tee -a "$RUN_DIR/10-gnb-b-key.txt" || true

echo "===== AMF key =====" | tee "$RUN_DIR/11-amf-key.txt"
egrep -i 'handover|path switch|UE Context|gNB|ngap|error|fail' "$RUN_DIR/05-amf.log" \
  | tail -n 200 | tee -a "$RUN_DIR/11-amf-key.txt" || true

echo "===== ping tail =====" | tee "$RUN_DIR/12-ping-tail.txt"
tail -n 80 "$RUN_DIR/02-ue-ping.log" | tee -a "$RUN_DIR/12-ping-tail.txt"

echo
echo "RUN_DIR=$RUN_DIR"
