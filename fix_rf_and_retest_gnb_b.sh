#!/usr/bin/env bash
set -uo pipefail

cd ~/oran-e2e-freeze || exit 1

RUN_DIR=~/oran-proof/gnb-b-rfsim-retest-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN_DIR"

echo "===== keep only gNB-B =====" | tee "$RUN_DIR/01-step.txt"
kubectl -n oran-ran scale deploy/oai-gnb --replicas=0 | tee -a "$RUN_DIR/01-step.txt"

echo "===== restart UE =====" | tee "$RUN_DIR/02-ue-restart.txt"
kubectl -n oran-ran rollout restart deploy/oai-nr-ue | tee -a "$RUN_DIR/02-ue-restart.txt"
sleep 10

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
GNB_B_POD=$(kubectl -n oran-ran get pod -l app=oai-gnb-b -o jsonpath='{.items[0].metadata.name}')

{
  echo "UE_POD=$UE_POD"
  echo "GNB_B_POD=$GNB_B_POD"
} | tee "$RUN_DIR/00-pods.txt"

echo "===== wait for UE pod Ready =====" | tee "$RUN_DIR/03-ue-ready.txt"
kubectl -n oran-ran wait --for=condition=Ready "pod/$UE_POD" --timeout=300s | tee -a "$RUN_DIR/03-ue-ready.txt" || true

UE_IP=$(kubectl -n oran-ran get pod "$UE_POD" -o jsonpath='{.status.podIP}')
echo "UE_IP=$UE_IP" | tee -a "$RUN_DIR/03-ue-ready.txt"

echo "===== RFsim service + endpoint =====" | tee "$RUN_DIR/04-service.txt"
kubectl -n oran-ran get svc oai-nr-ue-rfsim -o wide | tee -a "$RUN_DIR/04-service.txt"
echo "-----" | tee -a "$RUN_DIR/04-service.txt"
kubectl -n oran-ran get endpointslice -l kubernetes.io/service-name=oai-nr-ue-rfsim \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}' \
  | tee -a "$RUN_DIR/04-service.txt"
echo "-----" | tee -a "$RUN_DIR/04-service.txt"
kubectl -n oran-ran describe svc oai-nr-ue-rfsim | tee -a "$RUN_DIR/04-service.txt"

echo "===== UE RFsim state =====" | tee "$RUN_DIR/05-ue-rfsim.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ps -ef | grep nr-uesoftmodem | grep -v grep || true
echo "-----"
ss -ltnp 2>/dev/null | grep 4043 || true
echo "-----"
ip addr show oaitun_ue1 || true
echo "-----"
ip route || true
' | tee -a "$RUN_DIR/05-ue-rfsim.txt"

echo "===== UE recent logs =====" | tee "$RUN_DIR/06-ue-logs.txt"
kubectl -n oran-ran logs "$UE_POD" --since=5m | \
egrep -i '4043|rfsim|server|listen|registration|nas|rrc|error|fail' | \
tee -a "$RUN_DIR/06-ue-logs.txt" || true

echo "===== bounce gNB-B in place =====" | tee "$RUN_DIR/07-gnb-b-restart.txt"
kubectl -n oran-ran exec "$GNB_B_POD" -- sh -c 'kill 1' | tee -a "$RUN_DIR/07-gnb-b-restart.txt" || true
kubectl -n oran-ran wait --for=condition=Ready "pod/$GNB_B_POD" --timeout=180s | tee -a "$RUN_DIR/07-gnb-b-restart.txt" || true
sleep 10

echo "===== gNB-B after reconnect =====" | tee "$RUN_DIR/08-gnb-b-after.txt"
kubectl -n oran-ran logs "$GNB_B_POD" --since=3m | \
egrep -i '4043|connect|Create UE context|RRCSetup|RRCSetupComplete|RA failed|WAIT_Msg3|RNTI|CU-UE-ID|InitialContext|error|fail' | \
tee -a "$RUN_DIR/08-gnb-b-after.txt" || true

echo "===== AMF after reconnect =====" | tee "$RUN_DIR/09-amf-after.txt"
kubectl -n oran-core logs deploy/open5gs-amf --since=3m | \
egrep -i 'InitialUEMessage|Registration|Authentication|InitialContext|gNB-UEs|error|fail' | \
tee -a "$RUN_DIR/09-amf-after.txt" || true

echo "===== final UE check =====" | tee "$RUN_DIR/10-ue-final.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "-----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
' | tee -a "$RUN_DIR/10-ue-final.txt"

echo "===== restore gNB-A =====" | tee "$RUN_DIR/11-restore.txt"
kubectl -n oran-ran scale deploy/oai-gnb --replicas=1 | tee -a "$RUN_DIR/11-restore.txt"
kubectl -n oran-ran rollout status deploy/oai-gnb --timeout=180s | tee -a "$RUN_DIR/11-restore.txt" || true

echo "RUN_DIR=$RUN_DIR"
