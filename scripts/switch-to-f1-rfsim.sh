#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"

section() {
  echo
  echo "===== $1 ====="
}

section "Apply F1 RFsim manifest with dedicated F1 UE"
kubectl apply -f k8s/f1-rfsim/f1-ran.yaml

section "Ensure F1 CU/DU and dedicated F1 UE are running"
kubectl -n "$NS" scale deploy/oai-cu --replicas=1
kubectl -n "$NS" scale deploy/oai-du0 --replicas=1
kubectl -n "$NS" scale deploy/oai-du1 --replicas=1
kubectl -n "$NS" scale deploy/oai-nr-ue-f1 --replicas=1

section "Keep legacy gNB-B off"
kubectl -n "$NS" scale deploy/oai-gnb-b --replicas=0 || true

section "Wait for F1 deployments"
kubectl -n "$NS" rollout status deploy/oai-cu --timeout=180s
kubectl -n "$NS" rollout status deploy/oai-du0 --timeout=180s
kubectl -n "$NS" rollout status deploy/oai-du1 --timeout=180s
kubectl -n "$NS" rollout status deploy/oai-nr-ue-f1 --timeout=180s

section "Wait for F1 UE attach"
sleep 45

section "F1 readiness"
web-dashboard/actions/f1_status.sh

section "Current deployments"
kubectl -n "$NS" get deploy -o wide
