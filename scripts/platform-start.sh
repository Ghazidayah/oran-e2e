#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ORAN_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${HOME}/.oran-lab"
STATE_FILE="${STATE_DIR}/platform-replicas.tsv"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
START_DASHBOARD="${ORAN_START_DASHBOARD:-1}"
RECOVER_MIXED_DU="${ORAN_RECOVER_MIXED_DU:-1}"
TARGET_NAMESPACES="${ORAN_PLATFORM_NAMESPACES:-oran-core oran-ran monitoring}"

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

state_replicas() {
  ns="$1"
  kind="$2"
  name="$3"

  awk -v ns="$ns" -v kind="$kind" -v name="$name" \
    '$1 == ns && $2 == kind && $3 == name {print $4}' "$STATE_FILE" | tail -1
}

restore_one() {
  ns="$1"
  kind="$2"
  name="$3"
  replicas="$4"

  replicas="${replicas:-0}"

  if ! namespace_exists "$ns"; then
    echo "[SKIP] namespace does not exist: $ns"
    return 0
  fi

  if ! kubectl -n "$ns" get "$kind/$name" >/dev/null 2>&1; then
    echo "[SKIP] missing resource: $ns $kind/$name"
    return 0
  fi

  echo "Restoring $ns $kind/$name to replicas=$replicas"
  kubectl -n "$ns" scale "$kind/$name" --replicas="$replicas" || true
}

restore_all() {
  while read -r ns kind name replicas; do
    [ -z "${ns:-}" ] && continue
    restore_one "$ns" "$kind" "$name" "$replicas"
  done < "$STATE_FILE"
}

wait_deploy_if_needed() {
  ns="$1"
  name="$2"
  timeout="${3:-240s}"

  if ! namespace_exists "$ns"; then
    return 0
  fi

  if ! kubectl -n "$ns" get "deploy/$name" >/dev/null 2>&1; then
    return 0
  fi

  replicas="$(state_replicas "$ns" deploy "$name")"
  replicas="${replicas:-0}"

  if [ "$replicas" -gt 0 ]; then
    echo "Waiting for $ns deploy/$name..."
    kubectl -n "$ns" rollout status "deploy/$name" --timeout="$timeout" || true
  fi
}

wait_statefulset_if_needed() {
  ns="$1"
  name="$2"
  timeout="${3:-240s}"

  if ! namespace_exists "$ns"; then
    return 0
  fi

  if ! kubectl -n "$ns" get "statefulset/$name" >/dev/null 2>&1; then
    return 0
  fi

  replicas="$(state_replicas "$ns" statefulset "$name")"
  replicas="${replicas:-0}"

  if [ "$replicas" -gt 0 ]; then
    echo "Waiting for $ns statefulset/$name..."
    kubectl -n "$ns" rollout status "statefulset/$name" --timeout="$timeout" || true
  fi
}

start_dashboard() {
  if [ "$START_DASHBOARD" != "1" ]; then
    echo "[SKIP] ORAN_START_DASHBOARD=$START_DASHBOARD"
    return 0
  fi

  section "Starting local dashboard on port ${PORT}"

  if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
    echo "Dashboard port already listening: $PORT"
    return 0
  fi

  if [ ! -x "$ROOT_DIR/run-web-dashboard.sh" ]; then
    echo "[WARN] run-web-dashboard.sh not found or not executable"
    return 0
  fi

  mkdir -p "${HOME}/oran-proof/dashboard-logs"
  log="${HOME}/oran-proof/dashboard-logs/platform-start-dashboard-$(date +%Y%m%d-%H%M%S).log"

  (
    cd "$ROOT_DIR"
    nohup env \
      ORAN_DASHBOARD_PORT="$PORT" \
      ORAN_RAN_NS="${ORAN_RAN_NS:-oran-ran}" \
      ORAN_REPO="$ROOT_DIR" \
      ./run-web-dashboard.sh > "$log" 2>&1 &
  )

  sleep 5
  echo "Dashboard log: $log"
  tail -40 "$log" || true
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

recover_mixed_du_if_available() {
  if [ "$RECOVER_MIXED_DU" != "1" ]; then
    echo "[SKIP] ORAN_RECOVER_MIXED_DU=$RECOVER_MIXED_DU"
    return 0
  fi

  if [ ! -x "$ROOT_DIR/scripts/handover/recover-mixed-du-state.sh" ]; then
    echo "[SKIP] Mixed-DU recovery script not found"
    return 0
  fi

  section "Recovering validated Mixed-DU state"
  (
    cd "$ROOT_DIR"
    ORAN_DASHBOARD_PORT="$PORT" bash "$ROOT_DIR/scripts/handover/recover-mixed-du-state.sh" || true
  )
}

# ---- CU<->AMF NGAP association gate -------------------------------------
# A "Ready" CU pod is NOT a NGAP-associated CU. On cold start the CU can sit in
# "[NGAP] No AMF is associated to the gNB" and never self-heal; then every UE
# RRC-connects but is released and no oaitun tunnel forms. Reconciling UEs is
# futile until the CU re-associates, so gate on it here.
NGAP_GATE="${ORAN_NGAP_GATE:-1}"
NGAP_MAX_TRIES="${ORAN_NGAP_MAX_TRIES:-3}"
NGAP_SETTLE="${ORAN_NGAP_SETTLE_SECONDS:-25}"

cu_ngap_down() {
  # actively failing = "No AMF is associated" still being appended (2 samples)
  kubectl -n oran-ran logs deploy/oai-cu --tail=10 2>/dev/null \
    | grep -q "No AMF is associated" || return 1
  sleep 5
  kubectl -n oran-ran logs deploy/oai-cu --tail=5 2>/dev/null \
    | grep -q "No AMF is associated"
}

amf_has_gnb() {
  kubectl -n oran-core logs deploy/open5gs-amf --since=5m 2>/dev/null \
    | grep -q "gNB-N2 accepted"
}

ensure_cu_ngap_associated() {
  if [ "$NGAP_GATE" != "1" ]; then echo "[SKIP] ORAN_NGAP_GATE=$NGAP_GATE"; return 0; fi
  section "Verifying CU<->AMF NGAP association"
  local i
  for i in $(seq 1 "$NGAP_MAX_TRIES"); do
    echo "Settling ${NGAP_SETTLE}s before NGAP check (attempt $i/$NGAP_MAX_TRIES)..."
    sleep "$NGAP_SETTLE"
    if ! cu_ngap_down; then
      echo "CU is NGAP-associated with the AMF."
      amf_has_gnb && echo "AMF confirms: gNB-N2 accepted."
      return 0
    fi
    echo "[WARN] CU has NO AMF association. Restarting CU + DUs (re-form F1)..."
    kubectl -n oran-ran rollout restart deploy/oai-cu
    kubectl -n oran-ran rollout status  deploy/oai-cu  --timeout=180s || true
    kubectl -n oran-ran rollout restart deploy/oai-du0 deploy/oai-du1
    kubectl -n oran-ran rollout status  deploy/oai-du0 --timeout=180s || true
    kubectl -n oran-ran rollout status  deploy/oai-du1 --timeout=180s || true
  done
  echo "[WARN] CU still not NGAP-associated after $NGAP_MAX_TRIES attempts."
  echo "[WARN] Inspect N2/Multus (br-n2) and AMF SCTP 38412 before demoing."
  return 1
}

reconcile_ue_sessions() {
  if [ "${ORAN_RECONCILE_UES:-1}" != "1" ]; then
    echo "[SKIP] ORAN_RECONCILE_UES=${ORAN_RECONCILE_UES:-1}"
    return 0
  fi

  local rec="$ROOT_DIR/scripts/recover-ue-sessions.sh"
  if [ ! -x "$rec" ]; then
    echo "[SKIP] recover-ue-sessions.sh not found"
    return 0
  fi

  section "Reconciling UE PDU sessions"

  # Pods can be Ready while their oaitun_ue1 tunnel has not formed yet.
  # Let freshly-restored UEs self-attach before we judge them.
  local settle="${ORAN_UE_SETTLE_SECONDS:-45}"
  echo "Settling ${settle}s before first UE health check..."
  sleep "$settle"

  # Diagnose + restart ONLY the UEs that still have no working tunnel.
  # recover-ue-sessions.sh waits up to 240s/UE for tunnels to re-form.
  "$rec" --fix --yes || true

  section "Final UE health confirmation"
  if "$rec" | grep -q "VERDICT=ALL_HEALTHY"; then
    echo "All UEs healthy."
  else
    echo "[WARN] UEs still not all healthy after reconcile."
    echo "[WARN] Inspect DU1 + UE logs before demoing (UE2-5 home on DU1)."
  fi
}

echo "===== O-RAN platform start ====="
echo "Root dir: $ROOT_DIR"
echo "State file: $STATE_FILE"
echo "Dashboard port: $PORT"
echo "Recover Mixed-DU: $RECOVER_MIXED_DU"

have_cmd kubectl || {
  echo "ERROR: kubectl not found"
  exit 1
}

if [ ! -s "$STATE_FILE" ]; then
  echo "ERROR: no saved replica state found."
  echo "Expected: $STATE_FILE"
  echo "Run scripts/platform-stop.sh once while the platform is running."
  exit 1
fi

section "Saved replica state"
cat "$STATE_FILE"

section "Restoring saved replicas"
restore_all

section "Waiting for key workloads"
for dep in mongodb amf smf upf; do
  wait_deploy_if_needed oran-core "$dep" 240s
done

for dep in oai-cu oai-du0 oai-du1 oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  wait_deploy_if_needed oran-ran "$dep" 240s
done

for dep in prometheus grafana; do
  wait_deploy_if_needed monitoring "$dep" 240s
done

start_dashboard
ensure_cu_ngap_associated
recover_mixed_du_if_available
reconcile_ue_sessions

section "Final pod state"
for ns in $TARGET_NAMESPACES; do
  show_namespace_pods "$ns"
done

echo
echo "VERDICT=PLATFORM_STARTED"
