#!/usr/bin/env bash
set -euo pipefail

cd ~/oran-e2e-freeze || exit 1

RUN_DIR=~/oran-proof/gnb-b-attach-raw-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN_DIR"

echo "===== keep only gNB-B =====" | tee "$RUN_DIR/01-scale.txt"
kubectl -n oran-ran scale deploy/oai-gnb --replicas=0 | tee -a "$RUN_DIR/01-scale.txt"

echo "===== restart UE =====" | tee "$RUN_DIR/02-ue-restart.txt"
kubectl -n oran-ran rollout restart deploy/oai-nr-ue | tee -a "$RUN_DIR/02-ue-restart.txt"
sleep 10

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
echo "UE_POD=$UE_POD" | tee "$RUN_DIR/00-pods.txt"

echo "===== wait for UE Ready =====" | tee "$RUN_DIR/03-ue-ready.txt"
kubectl -n oran-ran wait --for=condition=Ready "pod/$UE_POD" --timeout=300s | tee -a "$RUN_DIR/03-ue-ready.txt" || true

UE_IP=$(kubectl -n oran-ran get pod "$UE_POD" -o jsonpath='{.status.podIP}')
echo "UE_IP=$UE_IP" | tee -a "$RUN_DIR/03-ue-ready.txt"

echo "===== RFsim service =====" | tee "$RUN_DIR/04-service.txt"
kubectl -n oran-ran get svc oai-nr-ue-rfsim -o wide | tee -a "$RUN_DIR/04-service.txt"
echo "-----" | tee -a "$RUN_DIR/04-service.txt"
kubectl -n oran-ran get endpointslice -l kubernetes.io/service-name=oai-nr-ue-rfsim \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready}{"\n"}{end}' \
  | tee -a "$RUN_DIR/04-service.txt"
echo "-----" | tee -a "$RUN_DIR/04-service.txt"
kubectl -n oran-ran describe svc oai-nr-ue-rfsim | tee -a "$RUN_DIR/04-service.txt"

echo "===== UE pre-check =====" | tee "$RUN_DIR/05-ue-pre.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ps -ef | grep nr-uesoftmodem | grep -v grep || true
echo "-----"
ss -ltnp 2>/dev/null | grep 4043 || true
echo "-----"
ip addr show oaitun_ue1 || true
echo "-----"
ip route || true
' | tee -a "$RUN_DIR/05-ue-pre.txt"

GNB_B_POD=$(kubectl -n oran-ran get pod -l app=oai-gnb-b -o jsonpath='{.items[0].metadata.name}')
echo "GNB_B_POD=$GNB_B_POD" | tee -a "$RUN_DIR/00-pods.txt"

echo "===== restart gNB-B container =====" | tee "$RUN_DIR/06-gnb-b-restart.txt"
kubectl -n oran-ran exec "$GNB_B_POD" -- sh -c 'kill 1' | tee -a "$RUN_DIR/06-gnb-b-restart.txt" || true
kubectl -n oran-ran wait --for=condition=Ready "pod/$GNB_B_POD" --timeout=180s | tee -a "$RUN_DIR/06-gnb-b-restart.txt" || true

echo "===== collect for one attach cycle =====" | tee "$RUN_DIR/07-wait.txt"
sleep 220

echo "===== save raw logs ====="
kubectl -n oran-ran logs "$UE_POD" --since=15m > "$RUN_DIR/08-ue-full.log" 2>&1 || true
kubectl -n oran-ran logs "$GNB_B_POD" --since=15m > "$RUN_DIR/09-gnb-b-full.log" 2>&1 || true
kubectl -n oran-core logs deploy/open5gs-amf --since=15m > "$RUN_DIR/10-amf-full.log" 2>&1 || true

RNTI=$(sed -n 's/.*rnti: \([0-9a-fA-F]\+\).*/\1/p' "$RUN_DIR/09-gnb-b-full.log" | tail -n1)
echo "RNTI=$RNTI" | tee "$RUN_DIR/11-rnti.txt"

echo "===== gNB-B window ====="
grep -n -i -C 50 \
  "Create UE context\|Remove NR rnti\|RRCSetup\|RRCSetupComplete\|DL Information Transfer\|UL Information Transfer\|InitialContext\|Authentication\|Security\|$RNTI\|error\|fail" \
  "$RUN_DIR/09-gnb-b-full.log" > "$RUN_DIR/12-gnb-b-window.txt" || true
cat "$RUN_DIR/12-gnb-b-window.txt"

echo "===== UE window ====="
grep -n -i -C 50 \
  "registration\|rrc\|nas\|security\|auth\|synch\|$RNTI\|error\|fail" \
  "$RUN_DIR/08-ue-full.log" > "$RUN_DIR/13-ue-window.txt" || true
cat "$RUN_DIR/13-ue-window.txt"

echo "===== AMF window ====="
grep -n -i -C 50 \
  "InitialUEMessage\|Registration\|Authentication\|Security\|InitialContext\|Removed\|error\|fail" \
  "$RUN_DIR/10-amf-full.log" > "$RUN_DIR/14-amf-window.txt" || true
cat "$RUN_DIR/14-amf-window.txt"

echo "===== UE final check =====" | tee "$RUN_DIR/15-ue-final.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "-----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
' | tee -a "$RUN_DIR/15-ue-final.txt"

echo "===== restore gNB-A =====" | tee "$RUN_DIR/16-restore.txt"
kubectl -n oran-ran scale deploy/oai-gnb --replicas=1 | tee -a "$RUN_DIR/16-restore.txt"
kubectl -n oran-ran rollout status deploy/oai-gnb --timeout=180s | tee -a "$RUN_DIR/16-restore.txt" || true

echo "RUN_DIR=$RUN_DIR"
