#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
NS="${NS:-oran-ran}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$TARGET" != "du0" ] && [ "$TARGET" != "du1" ]; then
  echo "Usage: $0 du0|du1"
  exit 2
fi

if [ "$TARGET" = "du0" ]; then
  ACTIVE_DEPLOY="oai-du0"
  INACTIVE_DEPLOY="oai-du1"
  ACTIVE_SERVICE="oai-du0-rfsim"
  ACTIVE_IP_LEASE="10.10.0.121"
else
  ACTIVE_DEPLOY="oai-du1"
  INACTIVE_DEPLOY="oai-du0"
  ACTIVE_SERVICE="oai-du1-rfsim"
  ACTIVE_IP_LEASE="10.10.0.132"
fi

RUN_DIR="${RUN_DIR:-$HOME/oran-proof/f1-switch-${TARGET}-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RUN_DIR"

echo "RUN_DIR=$RUN_DIR" | tee "$RUN_DIR/00-run-dir.txt"
echo "TARGET=$TARGET" | tee "$RUN_DIR/01-target.txt"
echo "ACTIVE_DEPLOY=$ACTIVE_DEPLOY" | tee -a "$RUN_DIR/01-target.txt"
echo "ACTIVE_SERVICE=$ACTIVE_SERVICE" | tee -a "$RUN_DIR/01-target.txt"

echo "===== Apply F1 configmaps ====="
kubectl -n "$NS" create configmap oai-cu-f1-config \
  --from-file=gnb.conf="$ROOT_DIR/manifests/ran/f1/cu.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap oai-du0-f1-config \
  --from-file=gnb.conf="$ROOT_DIR/manifests/ran/f1/du0.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create configmap oai-du1-f1-config \
  --from-file=gnb.conf="$ROOT_DIR/manifests/ran/f1/du1.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$ROOT_DIR/manifests/ran/f1/f1-ran.yaml"

echo "===== Stop monolithic gNB and extra UEs ====="
kubectl -n "$NS" scale deploy/oai-gnb --replicas=0 || true
kubectl -n "$NS" scale deploy/oai-gnb-b --replicas=0 || true

for d in oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n "$NS" scale deploy/"$d" --replicas=0 || true
done

echo "===== Switch DU ====="
kubectl -n "$NS" scale deploy/"$INACTIVE_DEPLOY" --replicas=0 || true

sudo find /var/lib/cni/networks -type f -name "$ACTIVE_IP_LEASE" -delete || true

kubectl -n "$NS" scale deploy/oai-cu --replicas=1
kubectl -n "$NS" scale deploy/"$ACTIVE_DEPLOY" --replicas=1

kubectl -n "$NS" rollout status deploy/oai-cu --timeout=5m
kubectl -n "$NS" rollout status deploy/"$ACTIVE_DEPLOY" --timeout=5m

echo "===== Patch UE1 to active DU RFsim service ====="
kubectl -n "$NS" patch deploy oai-nr-ue --type='json' -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/11\",\"value\":\"516\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args/13\",\"value\":\"$ACTIVE_SERVICE\"}
]"

kubectl -n "$NS" delete pod -l app=oai-nr-ue --grace-period=0 --force || true
kubectl -n "$NS" rollout restart deploy/oai-nr-ue
kubectl -n "$NS" rollout status deploy/oai-nr-ue --timeout=8m || true

echo "===== Wait UE attach ====="
sleep 180

echo "===== Pods =====" | tee "$RUN_DIR/02-pods.txt"
kubectl -n "$NS" get pods -o wide | tee -a "$RUN_DIR/02-pods.txt"

echo "===== Deployments =====" | tee "$RUN_DIR/03-deployments.txt"
kubectl -n "$NS" get deploy -o wide | tee -a "$RUN_DIR/03-deployments.txt"

echo "===== Endpoints =====" | tee "$RUN_DIR/04-endpoints.txt"
kubectl -n "$NS" get endpoints oai-cu-ci oai-du0-rfsim oai-du1-rfsim -o wide | tee -a "$RUN_DIR/04-endpoints.txt" || true

ACTIVE_POD=$(kubectl -n "$NS" get pods -l app="$ACTIVE_DEPLOY" --field-selector=status.phase=Running -o name | head -n 1 | cut -d/ -f2)
UE_POD=$(kubectl -n "$NS" get pods -l app=oai-nr-ue --field-selector=status.phase=Running -o name | head -n 1 | cut -d/ -f2)

echo "ACTIVE_POD=$ACTIVE_POD" | tee "$RUN_DIR/05-selected-pods.txt"
echo "UE_POD=$UE_POD" | tee -a "$RUN_DIR/05-selected-pods.txt"

echo "===== Active DU sockets =====" | tee "$RUN_DIR/06-active-du-sockets.txt"
kubectl -n "$NS" exec "$ACTIVE_POD" -- sh -lc 'ss -ltnp || true' | tee -a "$RUN_DIR/06-active-du-sockets.txt"

echo "===== Active DU logs =====" | tee "$RUN_DIR/07-active-du-logs.txt"
kubectl -n "$NS" logs "$ACTIVE_POD" --tail=200 | egrep -i 'rfsim|listen|connect|sync|rach|rrc|f1|in-sync|error|fail' | tee -a "$RUN_DIR/07-active-du-logs.txt" || true

echo "===== UE tunnel =====" | tee "$RUN_DIR/08-ue-tunnel.txt"
kubectl -n "$NS" exec "$UE_POD" -- sh -lc '
ip addr show oaitun_ue1
ip route
ping -c 2 10.45.0.1
ping -I oaitun_ue1 -c 4 8.8.8.8
' | tee -a "$RUN_DIR/08-ue-tunnel.txt"

echo "SWITCH_${TARGET}_OK"
echo "Evidence saved in: $RUN_DIR"
