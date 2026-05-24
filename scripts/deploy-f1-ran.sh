#!/usr/bin/env bash
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

echo "===== Stop monolithic gNB to avoid NGAP conflict ====="
kubectl -n "$NS" scale deploy/oai-gnb --replicas=0

echo "===== Clean possible stale Multus IP leases ====="
sudo find /var/lib/cni/networks -type f \( \
  -name '10.10.0.120' -o \
  -name '10.20.0.120' -o \
  -name '10.10.0.121' -o \
  -name '10.10.0.132' \
\) -delete || true

echo "===== Start CU and DUs ====="
kubectl -n "$NS" scale deploy/oai-cu --replicas=1
kubectl -n "$NS" scale deploy/oai-du0 --replicas=1
kubectl -n "$NS" scale deploy/oai-du1 --replicas=1

kubectl -n "$NS" rollout status deploy/oai-cu --timeout=5m
kubectl -n "$NS" rollout status deploy/oai-du0 --timeout=5m
kubectl -n "$NS" rollout status deploy/oai-du1 --timeout=5m

echo "===== Restart UEs for fresh attach ====="
for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n "$NS" rollout restart deploy/"$d" || true
done

for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n "$NS" rollout status deploy/"$d" --timeout=5m || true
done

echo "===== Current RAN pods ====="
kubectl -n "$NS" get pods -o wide
