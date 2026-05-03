#!/usr/bin/env bash
cd ~/oran-e2e-freeze || exit 1

RUN_DIR=~/oran-proof/gnb-b-fresh-attach-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN_DIR"

echo "===== keep only gNB-B ====="
kubectl -n oran-ran scale deploy/oai-gnb --replicas=0

echo "===== restart UE first ====="
kubectl -n oran-ran rollout restart deploy/oai-nr-ue
sleep 25

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
GNB_B_POD=$(kubectl -n oran-ran get pod -l app=oai-gnb-b -o jsonpath='{.items[0].metadata.name}')

{
  echo "UE_POD=$UE_POD"
  echo "GNB_B_POD=$GNB_B_POD"
} | tee "$RUN_DIR/00-pods.txt"

echo "===== restart gNB-B container in place ====="
kubectl -n oran-ran exec "$GNB_B_POD" -- sh -c 'kill 1' || true
kubectl -n oran-ran wait --for=condition=Ready "pod/$GNB_B_POD" --timeout=180s || true
sleep 5

echo "===== gNB-B sockets =====" | tee "$RUN_DIR/01-gnb-b-sockets.txt"
kubectl -n oran-ran exec "$GNB_B_POD" -- sh -c '
ss -tnp 2>/dev/null | grep 4043 || true
echo "-----"
ss -lunp 2>/dev/null | grep 2152 || true
' | tee -a "$RUN_DIR/01-gnb-b-sockets.txt"

echo "===== UE check =====" | tee "$RUN_DIR/02-ue-check.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "-----"
ip route || true
echo "-----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
' | tee -a "$RUN_DIR/02-ue-check.txt"

echo "===== gNB-B key logs =====" | tee "$RUN_DIR/03-gnb-b-key.txt"
kubectl -n oran-ran logs "$GNB_B_POD" --since=3m | \
egrep -i '4043|connect|Create UE context|RRCSetup|RRCSetupComplete|RA failed|WAIT_Msg3|RNTI|CU-UE-ID|InitialContext|error|fail' | \
tee -a "$RUN_DIR/03-gnb-b-key.txt" || true

echo "===== AMF key logs =====" | tee "$RUN_DIR/04-amf-key.txt"
kubectl -n oran-core logs deploy/open5gs-amf --since=3m | \
egrep -i 'InitialUEMessage|Registration|Authentication|InitialContext|gNB-UEs|error|fail' | \
tee -a "$RUN_DIR/04-amf-key.txt" || true

echo "RUN_DIR=$RUN_DIR"
