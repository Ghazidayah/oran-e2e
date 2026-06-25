#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ORAN_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${HOME}/.oran-lab"
STATE_FILE="${STATE_DIR}/platform-replicas.tsv"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
START_DASHBOARD="${ORAN_START_DASHBOARD:-1}"
START_TRAFFIC_API="${ORAN_START_TRAFFIC_API:-1}"
TRAFFIC_API_PORT="${TRAFFIC_API_PORT:-5055}"
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

check_ifb_module() {
  section "Checking ifb kernel module (downlink slice QoS shaping)"
  if lsmod 2>/dev/null | grep -q '^ifb'; then
    echo "ifb module loaded."
  else
    echo "[WARN] ifb module NOT loaded — downlink (download) slice QoS will NOT cap."
    echo "[WARN] Load now:     sudo modprobe ifb"
    echo "[WARN] Persist boot: echo ifb | sudo tee /etc/modules-load.d/ifb.conf"
  fi
}

start_traffic_api() {
  if [ "$START_TRAFFIC_API" != "1" ]; then echo "[SKIP] ORAN_START_TRAFFIC_API=$START_TRAFFIC_API"; return 0; fi
  section "Starting Traffic API on port ${TRAFFIC_API_PORT}"
  if ss -ltn 2>/dev/null | grep -q ":${TRAFFIC_API_PORT} "; then
    echo "Traffic API port already listening: ${TRAFFIC_API_PORT}"; return 0
  fi
  local starter="$ROOT_DIR/scripts/traffic/start-traffic-api.sh"
  if [ ! -x "$starter" ]; then echo "[WARN] start-traffic-api.sh missing/not executable"; return 0; fi
  bash "$starter" || true
  if curl -fsS "http://127.0.0.1:${TRAFFIC_API_PORT}/api/traffic/health" >/dev/null 2>&1; then
    echo "Traffic API healthy on ${TRAFFIC_API_PORT}."
  else
    echo "[WARN] Traffic API not responding on ${TRAFFIC_API_PORT} — see ~/oran-proof/phase2-traffic-api/server.log"
  fi
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

# ---- CU plane gate: CU-CP<->AMF (NGAP) + CU-UP<->CU-CP (E1) -------------
# The split CU has two SCTP associations a "Ready" pod does NOT guarantee:
#   - CU-CP <-> AMF over N2 (NGAP).  If down: "[NGAP] No AMF is associated".
#   - CU-UP <-> CU-CP over E1 (SCTP 38462). If down: no user plane / no tunnels.
# OAI caveat: a CU-UP that (re)connects to an already-running CU-CP can be
# rejected until the CU-CP restarts, so when re-pairing we restart CU-CP THEN CU-UP.
CU_GATE="${ORAN_CU_GATE:-1}"
CU_MAX_TRIES="${ORAN_CU_MAX_TRIES:-3}"
CU_SETTLE="${ORAN_CU_SETTLE_SECONDS:-25}"

cucp_ngap_down() {
  kubectl -n oran-ran logs deploy/oai-cu-cp --tail=10 2>/dev/null \
    | grep -q "No AMF is associated" || return 1
  sleep 5
  kubectl -n oran-ran logs deploy/oai-cu-cp --tail=5 2>/dev/null \
    | grep -q "No AMF is associated"
}

amf_has_gnb() {
  kubectl -n oran-core logs deploy/open5gs-amf --since=5m 2>/dev/null \
    | grep -q "gNB-N2 accepted"
}

e1_associated() {
  kubectl -n oran-ran logs deploy/oai-cu-cp --tail=300 2>/dev/null \
    | grep -qiE "Accepting new CU-UP|E1AP_SETUP_RESP" && return 0
  kubectl -n oran-ran logs deploy/oai-cu-up --tail=300 2>/dev/null \
    | grep -qiE "E1 connection established|SCTP_STATE_ESTABLISHED"
}

wait_ready() { kubectl -n oran-ran rollout status deploy/"$1" --timeout="${2:-180s}" >/dev/null 2>&1; }

ensure_cu_plane_healthy() {
  if [ "$CU_GATE" != "1" ]; then echo "[SKIP] ORAN_CU_GATE=$CU_GATE"; return 0; fi
  section "Bringing up split CU plane (CU-CP + CU-UP); verifying NGAP + E1"
  # Ensure the split CMs + deployments exist (idempotent; safe on fresh cluster).
  kubectl apply -f "$ROOT_DIR/manifests/ran/e1/e1-split.yaml" >/dev/null 2>&1 || true
  local i ngap_ok e1_ok
  for i in $(seq 1 "$CU_MAX_TRIES"); do
    echo "Attempt $i/$CU_MAX_TRIES: start CU-CP, then CU-UP (correct E1 order)"
    kubectl -n oran-ran scale deploy/oai-cu-cp --replicas=1 >/dev/null 2>&1
    wait_ready oai-cu-cp 180s
    kubectl -n oran-ran scale deploy/oai-cu-up --replicas=1 >/dev/null 2>&1
    wait_ready oai-cu-up 180s
    echo "Settling ${CU_SETTLE}s before checking NGAP + E1..."
    sleep "$CU_SETTLE"
    ngap_ok=1; e1_ok=1
    cucp_ngap_down && ngap_ok=0
    e1_associated   || e1_ok=0
    if [ "$ngap_ok" = 1 ] && [ "$e1_ok" = 1 ]; then
      echo "CU-CP is NGAP-associated with the AMF."
      amf_has_gnb && echo "AMF confirms: gNB-N2 accepted."
      echo "CU-UP is E1-associated with the CU-CP."
      section "Restarting DUs so F1-C re-associates to the CU-CP"
      kubectl -n oran-ran rollout restart deploy/oai-du0 deploy/oai-du1 >/dev/null 2>&1
      wait_ready oai-du0 120s; wait_ready oai-du1 120s
      return 0
    fi
    [ "$ngap_ok" = 0 ] && echo "[WARN] CU-CP has no AMF (NGAP) association."
    [ "$e1_ok"   = 0 ] && echo "[WARN] CU-UP not E1-associated (OAI: re-pair needs CU-CP restart)."
    echo "Re-pairing: restart CU-CP, then CU-UP..."
    kubectl -n oran-ran rollout restart deploy/oai-cu-cp >/dev/null 2>&1; wait_ready oai-cu-cp 180s
    kubectl -n oran-ran rollout restart deploy/oai-cu-up >/dev/null 2>&1; wait_ready oai-cu-up 180s
  done
  echo "[WARN] CU plane not fully healthy after $CU_MAX_TRIES attempts."
  echo "[WARN] Check CU-CP<->AMF (N2/38412) and CU-UP<->CU-CP (E1/38462) before demoing."
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
check_ifb_module

section "Waiting for key workloads"
for dep in mongodb amf smf upf; do
  wait_deploy_if_needed oran-core "$dep" 240s
done

for dep in oai-du0 oai-du1 oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  wait_deploy_if_needed oran-ran "$dep" 240s
done

for dep in prometheus grafana; do
  wait_deploy_if_needed monitoring "$dep" 240s
done

start_dashboard
start_traffic_api
ensure_cu_plane_healthy
recover_mixed_du_if_available
reconcile_ue_sessions

section "Final pod state"
for ns in $TARGET_NAMESPACES; do
  show_namespace_pods "$ns"
done

echo
echo "VERDICT=PLATFORM_STARTED"
