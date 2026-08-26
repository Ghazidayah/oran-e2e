#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Platform shutdown, with a state snapshot beforehand.
#
# Role     : photograph the current state before stopping, to keep a record
#            of what was running at shutdown time.
# Captures : deployments, pods, services, endpoints and volumes, for each of
#            the three namespaces.
# Then     : workloads are stopped in the reverse order of startup.
# Usage    : bash scripts/platform-stop.sh
# ---------------------------------------------------------------------------
set -euo pipefail

STATE_DIR="${HOME}/.oran-lab"
STATE_FILE="${STATE_DIR}/platform-replicas.tsv"
SNAP_DIR="${HOME}/oran-proof/platform-power"
TS="$(date +%Y%m%d-%H%M%S)"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
TARGET_NAMESPACES="${ORAN_PLATFORM_NAMESPACES:-oran-ran oran-core monitoring}"

mkdir -p "$STATE_DIR" "$SNAP_DIR"

section() {
  echo
  echo "===== $* ====="
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

stop_dashboard() {
  section "Stopping local dashboard on port ${PORT}"

  if [ -x "./stop-web-dashboard.sh" ]; then
    ORAN_DASHBOARD_PORT="$PORT" ./stop-web-dashboard.sh || true
    return 0
  fi

  if have_cmd fuser; then
    fuser -k "${PORT}/tcp" >/dev/null 2>&1 || true
  elif have_cmd lsof; then
    pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
    if [ -n "${pids:-}" ]; then
      kill $pids 2>/dev/null || true
    fi
  else
    pkill -f "python3 app.py" 2>/dev/null || true
  fi
}

save_snapshot_for_namespace() {
  ns="$1"
  snap="$2"

  if ! namespace_exists "$ns"; then
    echo "[SKIP] namespace does not exist: $ns"
    return 0
  fi

  mkdir -p "$snap/$ns"
  kubectl -n "$ns" get deploy -o wide > "$snap/$ns/deployments.txt" 2>&1 || true
  kubectl -n "$ns" get statefulset -o wide > "$snap/$ns/statefulsets.txt" 2>&1 || true
  kubectl -n "$ns" get pods -o wide > "$snap/$ns/pods.txt" 2>&1 || true
  kubectl -n "$ns" get svc -o wide > "$snap/$ns/services.txt" 2>&1 || true
  kubectl -n "$ns" get endpoints -o wide > "$snap/$ns/endpoints.txt" 2>&1 || true
  kubectl -n "$ns" get pvc -o wide > "$snap/$ns/pvc.txt" 2>&1 || true
}

save_replicas_for_namespace() {
  ns="$1"
  output="$2"

  if ! namespace_exists "$ns"; then
    return 0
  fi

  kubectl -n "$ns" get deploy -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas --no-headers 2>/dev/null \
    | while read -r name replicas; do
        [ -z "${name:-}" ] && continue
        replicas="${replicas:-0}"
        echo "$ns deploy $name $replicas" >> "$output"
      done

  kubectl -n "$ns" get statefulset -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas --no-headers 2>/dev/null \
    | while read -r name replicas; do
        [ -z "${name:-}" ] && continue
        replicas="${replicas:-0}"
        echo "$ns statefulset $name $replicas" >> "$output"
      done
}

scale_namespace_to_zero() {
  ns="$1"

  if ! namespace_exists "$ns"; then
    echo "[SKIP] namespace does not exist: $ns"
    return 0
  fi

  echo "Scaling namespace to zero: $ns"
  kubectl -n "$ns" scale deploy --all --replicas=0 || true
  kubectl -n "$ns" scale statefulset --all --replicas=0 || true
}

show_namespace_pods() {
  ns="$1"

  if ! namespace_exists "$ns"; then
    return 0
  fi

  echo
  echo "----- $ns -----"
  kubectl -n "$ns" get pods -o wide || true
}

echo "===== O-RAN platform stop / cool mode ====="
echo "Timestamp: $TS"
echo "Dashboard port: $PORT"
echo "Target namespaces: $TARGET_NAMESPACES"

have_cmd kubectl || {
  echo "ERROR: kubectl not found"
  exit 1
}

section "Saving status snapshot"
SNAP="${SNAP_DIR}/before-stop-${TS}"
mkdir -p "$SNAP"

kubectl get nodes -o wide > "$SNAP/nodes.txt" 2>&1 || true

for ns in $TARGET_NAMESPACES; do
  save_snapshot_for_namespace "$ns" "$SNAP"
done

echo "Snapshot saved to: $SNAP"

section "Saving current replica counts"
TMP_STATE="${STATE_FILE}.tmp"
: > "$TMP_STATE"

for ns in $TARGET_NAMESPACES; do
  save_replicas_for_namespace "$ns" "$TMP_STATE"
done

TOTAL_REPLICAS="$(awk '{s += $4} END {print s+0}' "$TMP_STATE")"

if [ "$TOTAL_REPLICAS" -eq 0 ]; then
  echo "[WARN] Saved state has total replicas=0."
  echo "[WARN] Keeping file anyway: $TMP_STATE"
  mv "$TMP_STATE" "$STATE_FILE"
else
  mv "$TMP_STATE" "$STATE_FILE"
  echo "Replica state saved to: $STATE_FILE"
fi

section "Saved state file"
cat "$STATE_FILE" || true

stop_dashboard

section "Scaling workloads to zero"
scale_namespace_to_zero "oran-ran"
scale_namespace_to_zero "oran-core"
scale_namespace_to_zero "monitoring"

section "Final pod state"
for ns in $TARGET_NAMESPACES; do
  show_namespace_pods "$ns"
done

echo
echo "VERDICT=PLATFORM_STOPPED_COOL_MODE"
echo "You can keep working on repo files while live RAN/core workloads are stopped."
