#!/usr/bin/env bash
# DEPRECATED (legacy single-DU F1 era). Superseded by the Mixed-DU handover
# (web-dashboard/mixed_du_handover_api.py). Not used by platform-start or the
# dashboard. Targets the monolithic oai-cu; scheduled for deletion in Phase 2
# alongside the monolithic CU. Do not use with the CU-CP/CU-UP (E1) split.
set -euo pipefail

NS="${NS:-oran-ran}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "===== Create F1 configmaps ====="
kubectl -n "$NS" create configmap oai-cu-f1-config \
  --from-file=gnb.conf="$ROOT_DIR/manifests/ran/f1/cu.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap oai-du0-f1-config \
  --from-file=gnb.conf="$ROOT_DIR/manifests/ran/f1/du0.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap oai-du1-f1-config \
  --from-file=gnb.conf="$ROOT_DIR/manifests/ran/f1/du1.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "===== Apply F1 manifests ====="
kubectl apply -f "$ROOT_DIR/manifests/ran/f1/f1-ran.yaml"

echo "===== Stop monolithic gNB and extra UEs ====="
kubectl -n "$NS" scale deploy/oai-gnb --replicas=0
kubectl -n "$NS" scale deploy/oai-gnb-b --replicas=0 || true

for d in oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n "$NS" scale deploy/"$d" --replicas=0 || true
done

echo "===== Patch UE1 to connect to DU0 RFsim server ====="
kubectl -n "$NS" patch deploy oai-nr-ue --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/11","value":"516"},
  {"op":"replace","path":"/spec/template/spec/containers/0/args/13","value":"oai-du0-rfsim"}
]' || true

echo "===== Clean possible stale Multus IP leases ====="
sudo find /var/lib/cni/networks -type f \( \
  -name '10.10.0.120' -o \
  -name '10.20.0.120' -o \
  -name '10.10.0.121' -o \
  -name '10.10.0.132' \
\) -delete || true

echo "===== Start CU and DU0 only ====="
kubectl -n "$NS" scale deploy/oai-cu --replicas=1
kubectl -n "$NS" scale deploy/oai-du0 --replicas=1
kubectl -n "$NS" scale deploy/oai-du1 --replicas=0

kubectl -n "$NS" rollout status deploy/oai-cu --timeout=5m
kubectl -n "$NS" rollout status deploy/oai-du0 --timeout=5m

echo "===== Restart UE1 ====="
kubectl -n "$NS" delete pod -l app=oai-nr-ue --grace-period=0 --force || true
kubectl -n "$NS" rollout restart deploy/oai-nr-ue
kubectl -n "$NS" rollout status deploy/oai-nr-ue --timeout=8m || true

echo "===== Current RAN pods ====="
kubectl -n "$NS" get pods -o wide

echo "===== F1 endpoints ====="
kubectl -n "$NS" get endpoints oai-cu-ci oai-du0-rfsim oai-du1-rfsim -o wide || true
