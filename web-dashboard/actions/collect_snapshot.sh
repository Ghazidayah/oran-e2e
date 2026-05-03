#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/snapshot-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"

log_section "Snapshot directory"
echo "$RUN_DIR"

log_section "Kubernetes node"
kubectl get nodes -o wide | tee "$RUN_DIR/01-nodes.txt"

log_section "RAN pods"
kubectl -n oran-ran get pods -o wide | tee "$RUN_DIR/02-ran-pods.txt"

log_section "Core pods"
kubectl -n oran-core get pods -o wide | tee "$RUN_DIR/03-core-pods.txt"

log_section "Monitoring pods"
kubectl -n monitoring get pods -o wide | tee "$RUN_DIR/04-monitoring-pods.txt" || true

log_section "Services"
kubectl -n oran-ran get svc -o wide | tee "$RUN_DIR/05-ran-services.txt"
kubectl -n oran-core get svc -o wide | tee "$RUN_DIR/06-core-services.txt"
kubectl -n monitoring get svc -o wide | tee "$RUN_DIR/07-monitoring-services.txt" || true

refresh_pods

echo "UE_POD=$UE_POD" | tee "$RUN_DIR/08-current-pods.txt"
echo "GNB_A_POD=$GNB_A_POD" | tee -a "$RUN_DIR/08-current-pods.txt"
echo "GNB_B_POD=$GNB_B_POD" | tee -a "$RUN_DIR/08-current-pods.txt"

log_section "UE tunnel state"
if [ -n "$UE_POD" ]; then
  kubectl -n oran-ran exec "$UE_POD" -- sh -c '
    ip addr show oaitun_ue1 || true
    echo "----- routes -----"
    ip route || true
    echo "----- ping DN gateway -----"
    ping -I oaitun_ue1 -c 3 10.45.0.1 || true
    echo "----- ping internet -----"
    ping -I oaitun_ue1 -c 3 8.8.8.8 || true
  ' | tee "$RUN_DIR/09-ue-tunnel.txt"
fi

log_section "Recent gNB-A radio state"
if [ -n "$GNB_A_POD" ]; then
  kubectl -n oran-ran logs "$GNB_A_POD" --since=5m | \
    egrep -i 'UE RNTI|CU-UE-ID|in-sync|RRCSetup|RRCSetupComplete|InitialContext|PDU|handover|error|fail' | \
    tail -n 120 | tee "$RUN_DIR/10-gnb-a-radio.txt" || true
fi

log_section "Recent gNB-B radio state"
if [ -n "$GNB_B_POD" ]; then
  kubectl -n oran-ran logs "$GNB_B_POD" --since=5m | \
    egrep -i 'UE RNTI|CU-UE-ID|in-sync|RRCSetup|RRCSetupComplete|InitialContext|PDU|handover|error|fail' | \
    tail -n 120 | tee "$RUN_DIR/11-gnb-b-radio.txt" || true
fi

log_section "AMF view"
kubectl -n oran-core logs deploy/open5gs-amf --since=10m | \
  egrep -i 'gNB-N2|InitialUEMessage|Registration complete|PDU|DNN|imsi|error|fail' | \
  tail -n 160 | tee "$RUN_DIR/12-amf.txt" || true

log_section "SMF view"
kubectl -n oran-core logs deploy/open5gs-smf --since=10m | \
  egrep -i 'imsi|DNN|10.45.0|IPv4|PFCP|session|error|fail' | \
  tail -n 120 | tee "$RUN_DIR/13-smf.txt" || true

log_section "UPF view"
kubectl -n oran-core logs deploy/open5gs-upf --since=10m | \
  egrep -i 'gtp_connect|10.20.0|PFCP|Invalid packet|error|fail' | \
  tail -n 120 | tee "$RUN_DIR/14-upf.txt" || true

cat > "$RUN_DIR/SNAPSHOT-SUMMARY.txt" <<EOF2
O-RAN lab evidence snapshot

Status:
Snapshot completed.

Saved in:
$RUN_DIR

Contains:
- Kubernetes node state
- RAN/Core/Monitoring pods and services
- UE tunnel state
- DN gateway and internet ping checks
- gNB-A/gNB-B radio logs
- AMF/SMF/UPF recent logs
EOF2

log_section "Snapshot complete"
cat "$RUN_DIR/SNAPSHOT-SUMMARY.txt"
