#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"

echo "===== Stop F1 CU/DU ====="
kubectl -n "$NS" scale deploy/oai-cu --replicas=0 --ignore-not-found=true || true
kubectl -n "$NS" scale deploy/oai-du0 --replicas=0 --ignore-not-found=true || true
kubectl -n "$NS" scale deploy/oai-du1 --replicas=0 --ignore-not-found=true || true

echo "===== Clean stale monolithic gNB leases ====="
sudo find /var/lib/cni/networks -type f \( \
  -name '10.10.0.110' -o \
  -name '10.20.0.110' \
\) -delete || true

echo "===== Restore monolithic gNB ====="
kubectl -n "$NS" scale deploy/oai-gnb --replicas=1
kubectl -n "$NS" rollout status deploy/oai-gnb --timeout=5m

echo "===== Restart UEs ====="
for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n "$NS" rollout restart deploy/"$d" || true
done

for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n "$NS" rollout status deploy/"$d" --timeout=5m || true
done

kubectl -n "$NS" get pods -o wide
