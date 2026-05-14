#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.oran-lab"
STATE_FILE="${STATE_DIR}/platform-replicas.tsv"
SNAP_DIR="${HOME}/oran-proof/platform-power"
TS="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$STATE_DIR" "$SNAP_DIR"

TARGET_NAMESPACES="oran-ran oran-core monitoring"

echo "===== O-RAN platform stop ====="
echo "Timestamp: $TS"
echo

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl not found"
  exit 1
}

echo "===== Saving status snapshot ====="
SNAP="${SNAP_DIR}/before-stop-${TS}"
mkdir -p "$SNAP"

kubectl get nodes -o wide > "$SNAP/nodes.txt" 2>&1 || true

for ns in $TARGET_NAMESPACES; do
  mkdir -p "$SNAP/$ns"
  kubectl -n "$ns" get deploy -o wide > "$SNAP/$ns/deployments.txt" 2>&1 || true
  kubectl -n "$ns" get statefulset -o wide > "$SNAP/$ns/statefulsets.txt" 2>&1 || true
  kubectl -n "$ns" get pods -o wide > "$SNAP/$ns/pods.txt" 2>&1 || true
  kubectl -n "$ns" get pvc -o wide > "$SNAP/$ns/pvc.txt" 2>&1 || true
done

echo "Snapshot saved to: $SNAP"
echo

echo "===== Saving current replica counts ====="
TMP_STATE="${STATE_FILE}.tmp"
: > "$TMP_STATE"

TOTAL_REPLICAS=0

for ns in $TARGET_NAMESPACES; do
  kubectl -n "$ns" get deploy -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas --no-headers 2>/dev/null \
    | while read -r name replicas; do
        [ -z "${name:-}" ] && continue
        replicas="${replicas:-0}"
        echo "$ns deploy $name $replicas" >> "$TMP_STATE"
      done

  kubectl -n "$ns" get statefulset -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas --no-headers 2>/dev/null \
    | while read -r name replicas; do
        [ -z "${name:-}" ] && continue
        replicas="${replicas:-0}"
        echo "$ns statefulset $name $replicas" >> "$TMP_STATE"
      done
done

TOTAL_REPLICAS="$(awk '{s += $4} END {print s+0}' "$TMP_STATE")"

if [ "$TOTAL_REPLICAS" -eq 0 ] && [ -s "$STATE_FILE" ]; then
  echo "All target replicas are already 0. Keeping existing state file:"
  echo "$STATE_FILE"
  rm -f "$TMP_STATE"
else
  if [ -s "$STATE_FILE" ]; then
    cp "$STATE_FILE" "${STATE_DIR}/platform-replicas.${TS}.tsv"
    echo "Previous state backed up to: ${STATE_DIR}/platform-replicas.${TS}.tsv"
  fi

  mv "$TMP_STATE" "$STATE_FILE"
  echo "Replica state saved to: $STATE_FILE"
fi

echo
echo "===== State file ====="
cat "$STATE_FILE" || true
echo

echo "===== Scaling workloads to 0 ====="

echo "Stopping RAN and UE workloads..."
kubectl -n oran-ran scale deploy --all --replicas=0 || true
kubectl -n oran-ran scale statefulset --all --replicas=0 || true

echo "Stopping Open5GS core workloads..."
kubectl -n oran-core scale deploy --all --replicas=0 || true
kubectl -n oran-core scale statefulset --all --replicas=0 || true

echo "Stopping monitoring workloads..."
kubectl -n monitoring scale deploy --all --replicas=0 || true
kubectl -n monitoring scale statefulset --all --replicas=0 || true

echo
echo "===== Final pod status ====="
for ns in $TARGET_NAMESPACES; do
  echo
  echo "----- $ns -----"
  kubectl -n "$ns" get pods -o wide || true
done

echo
echo "Platform workloads have been scaled down."
echo "No deployments, services, configmaps, secrets, or PVCs were deleted."
