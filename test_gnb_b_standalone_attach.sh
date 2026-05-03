#!/usr/bin/env bash
cd ~/oran-e2e-freeze || exit 1

RUN_DIR=~/oran-proof/gnb-b-standalone-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN_DIR"

echo "===== scale gNB-A down ====="
kubectl -n oran-ran scale deploy/oai-gnb --replicas=0
sleep 10
kubectl -n oran-ran get pods -o wide | tee "$RUN_DIR/01-ran-pods.txt"

echo "===== capture gNB-B + AMF ====="
GNB_B_POD=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
kubectl -n oran-ran logs "$GNB_B_POD" --since=5s -f > "$RUN_DIR/02-gnb-b.log" 2>&1 &
B_PID=$!
kubectl -n oran-core logs deploy/open5gs-amf --since=5s -f > "$RUN_DIR/03-amf.log" 2>&1 &
M_PID=$!

echo "===== restart UE ====="
kubectl -n oran-ran rollout restart deploy/oai-nr-ue
kubectl -n oran-ran rollout status deploy/oai-nr-ue --timeout=180s || true
sleep 20

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')

echo "===== UE check =====" | tee "$RUN_DIR/04-ue-check.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "-----"
ip route || true
echo "-----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
' | tee -a "$RUN_DIR/04-ue-check.txt"

kill $B_PID 2>/dev/null || true
kill $M_PID 2>/dev/null || true

echo "===== gNB-B key =====" | tee "$RUN_DIR/05-gnb-b-key.txt"
egrep -i 'Create UE context|RRCSetup|RRCSetupComplete|InitialContext|RA failed|WAIT_Msg3|RNTI|CU-UE-ID|error|fail' \
  "$RUN_DIR/02-gnb-b.log" | tail -n 200 | tee -a "$RUN_DIR/05-gnb-b-key.txt" || true

echo "===== AMF key =====" | tee "$RUN_DIR/06-amf-key.txt"
egrep -i 'InitialUEMessage|Registration|gNB-UEs|error|fail' \
  "$RUN_DIR/03-amf.log" | tail -n 200 | tee -a "$RUN_DIR/06-amf-key.txt" || true

echo "===== restore gNB-A ====="
kubectl -n oran-ran scale deploy/oai-gnb --replicas=1
kubectl -n oran-ran rollout status deploy/oai-gnb --timeout=180s || true

echo "RUN_DIR=$RUN_DIR"
