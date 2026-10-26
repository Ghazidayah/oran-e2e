#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Ordered platform startup.
#
# Role     : bring the chain up in a strict dependency order, so that a cold
#            start produces a working platform without manual intervention.
# Why this order: in a service-based architecture, the AMF discovers the
#            authentication functions via the NRF. If the AMF starts before
#            they're registered, it rejects ALL terminals (5GMM cause #9)
#            until it hits CrashLoopBackOff. The fix is ordering, not
#            detection.
# Tiers    : 1) mongodb, nrf, scp
#            2) udr, udm, ausf, bsf, nssf, pcf, upf, sepp, webui
#            3) profile-registration settle delay
#            4) amf and smf LAST, against an already-populated NRF
#            5) CU plane, then DU, then the terminal fleet
# State    : this script is SELF-SUFFICIENT. It no longer needs the file written
#            by platform-stop.sh: it (re)generates ~/.oran-lab/platform-replicas.tsv
#            itself at every start, with replicas=1 for every workload.
# Variables: ORAN_CORE_GATE, ORAN_CORE_REGISTER_SETTLE,
#            ORAN_EXCLUDE_WORKLOADS (default "oai-gnb oai-gnb-b": monolithic gNBs
#            that must stay at 0 because the split CU/DU replaces them)
# Usage    : bash ./platform-start.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="${ORAN_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
STATE_DIR="${HOME}/.oran-lab"
STATE_FILE="${STATE_DIR}/platform-replicas.tsv"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
START_DASHBOARD="${ORAN_START_DASHBOARD:-1}"
# Mixed-DU recovery is a HANDOVER-DEMO routine, not a bootstrap step: it switches
# UEs to DU1 and runs traffic tests. Running it on cold start (before UEs attach)
# both wastes ~6 min and thrashes UEs out of attaching. OFF by default; the normal
# attach path (reconcile_ue_sessions) brings UEs up. Set ORAN_RECOVER_MIXED_DU=1
# only when you explicitly want to stage/demo the mixed-DU handover layout.
RECOVER_MIXED_DU="${ORAN_RECOVER_MIXED_DU:-0}"
TARGET_NAMESPACES="${ORAN_PLATFORM_NAMESPACES:-oran-core oran-ran monitoring}"
# Workloads that must NOT be started (kept at 0, not written in the state file).
# oai-gnb / oai-gnb-b are the monolithic gNBs: running them next to the split
# CU-CP/CU-UP/DU chain would give two gNBs on the same PLMN/cell.
EXCLUDE_WORKLOADS="${ORAN_EXCLUDE_WORKLOADS:-oai-gnb oai-gnb-b}"

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

# ---- State file generation (replaces the dependency on platform-stop.sh) ----
# Known workloads (namespace kind name). Used even if the cluster listing is
# empty; missing resources are simply skipped by restore_one.
baseline_workloads() {
  cat <<'LIST'
oran-core deploy open5gs-mongodb
oran-core deploy open5gs-nrf
oran-core deploy open5gs-scp
oran-core deploy open5gs-udr
oran-core deploy open5gs-udm
oran-core deploy open5gs-ausf
oran-core deploy open5gs-bsf
oran-core deploy open5gs-nssf
oran-core deploy open5gs-pcf
oran-core deploy open5gs-upf
oran-core deploy open5gs-sepp
oran-core deploy open5gs-webui
oran-core deploy open5gs-amf
oran-core deploy open5gs-smf
oran-ran deploy oai-cu-cp
oran-ran deploy oai-cu-up
oran-ran deploy oai-du0
oran-ran deploy oai-du1
oran-ran deploy oai-nr-ue
oran-ran deploy oai-nr-ue-2
oran-ran deploy oai-nr-ue-3
oran-ran deploy oai-nr-ue-4
oran-ran deploy oai-nr-ue-5
monitoring deploy oran-monitoring-grafana
monitoring deploy oran-monitoring-kube-prome-operator
monitoring deploy oran-monitoring-kube-state-metrics
monitoring statefulset alertmanager-oran-monitoring-kube-prome-alertmanager
monitoring statefulset prometheus-oran-monitoring-kube-prome-prometheus
LIST
}

# Everything that currently exists in the target namespaces (even at replicas=0).
discover_workloads() {
  local ns kind
  for ns in $TARGET_NAMESPACES; do
    namespace_exists "$ns" || continue
    for kind in deploy statefulset; do
      kubectl -n "$ns" get "$kind" -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null \
        | awk -v ns="$ns" -v kind="$kind" 'NF {print ns, kind, $1}' || true
    done
  done
}

generate_state_file() {
  section "Generating replica state file (all replicas=1)"
  mkdir -p "$STATE_DIR"

  if [ -s "$STATE_FILE" ]; then
    cp "$STATE_FILE" "${STATE_DIR}/platform-replicas.$(date +%Y%m%d-%H%M%S).tsv" 2>/dev/null || true
  fi

  local tmp="${STATE_FILE}.tmp"
  { baseline_workloads; discover_workloads; } \
    | awk -v ex="$EXCLUDE_WORKLOADS" '
        BEGIN { n = split(ex, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 }
        NF >= 3 && !($3 in skip) && !seen[$1" "$2" "$3]++ { print $1, $2, $3, 1 }
      ' > "$tmp"

  if [ ! -s "$tmp" ]; then
    echo "ERROR: could not build the workload list."
    rm -f "$tmp"
    exit 1
  fi

  mv "$tmp" "$STATE_FILE"
  echo "State file written: $STATE_FILE ($(wc -l < "$STATE_FILE") workloads, all replicas=1)"
  echo "Excluded (kept at 0): ${EXCLUDE_WORKLOADS:-none}"
}

# Make sure the excluded workloads (monolithic gNBs) are really off.
enforce_excluded_off() {
  local ns w
  for ns in $TARGET_NAMESPACES; do
    namespace_exists "$ns" || continue
    for w in $EXCLUDE_WORKLOADS; do
      if kubectl -n "$ns" get "deploy/$w" >/dev/null 2>&1; then
        echo "Keeping $ns deploy/$w at replicas=0"
        kubectl -n "$ns" scale "deploy/$w" --replicas=0 >/dev/null 2>&1 || true
      fi
    done
  done
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

  if [ ! -x "$ROOT_DIR/scripts/run-web-dashboard.sh" ]; then
    echo "[WARN] scripts/run-web-dashboard.sh not found or not executable"
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
      ./scripts/run-web-dashboard.sh > "$log" 2>&1 &
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

  local rec="$ROOT_DIR/tools/recover-ue-sessions.sh"
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
echo "State file (generated): $STATE_FILE"
echo "Dashboard port: $PORT"
echo "Recover Mixed-DU: $RECOVER_MIXED_DU"

have_cmd kubectl || {
  echo "ERROR: kubectl not found"
  exit 1
}

# ---- 5GC startup ordering: AMF/SMF must start AFTER NF discovery is populated --
# Confirmed root cause of cold-start "Registration reject [9]" (5GMM cause #9,
# "identity cannot be derived"): on a cold start the AMF can boot before the NRF
# has the AUSF/UDM/UDR registered, so it cannot resolve UE identity and rejects
# every UE -> CrashLoopBackOff. The cure is ORDERING, not detection: bring up the
# registry + data + auth NFs first, let them register into the NRF, THEN restart
# AMF+SMF last so they boot into a populated NRF and discover everyone on attempt 1.
# (Restarting AMF here is also why it must run BEFORE the CU-plane gate: the CU-CP's
# NGAP and the UEs both depend on a stable AMF.)
CORE_GATE="${ORAN_CORE_GATE:-1}"
CORE_REGISTER_SETTLE="${ORAN_CORE_REGISTER_SETTLE:-25}"

core_dep_ready() {
  kubectl -n oran-core get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]'
}

wait_core_dep() {
  local d="$1" max="${2:-180}" t=0
  while [ "$t" -lt "$max" ]; do core_dep_ready "$d" && return 0; sleep 5; t=$((t+5)); done
  return 1
}

ensure_core_amf_ready() {
  if [ "$CORE_GATE" != "1" ]; then echo "[SKIP] ORAN_CORE_GATE=$CORE_GATE"; return 0; fi
  section "5GC ordering: NF directory up first, then (re)start AMF+SMF last"
  # 1. Registry + data + auth NFs must be Ready before the AMF can discover them.
  local d
  for d in open5gs-mongodb open5gs-nrf open5gs-scp open5gs-udr open5gs-udm open5gs-ausf open5gs-upf; do
    if wait_core_dep "$d" 180; then echo "  ready: $d"; else echo "  [WARN] $d not Ready in time"; fi
  done
  # 2. Give the NFs time to register their profiles into the NRF.
  echo "Letting NFs register into the NRF (${CORE_REGISTER_SETTLE}s)..."
  sleep "$CORE_REGISTER_SETTLE"
  # 3. Restart AMF + SMF LAST so they boot into a populated NRF (discover AUSF/UDM/UPF).
  echo "Restarting AMF + SMF so they discover the populated NRF..."
  kubectl -n oran-core rollout restart deploy/open5gs-amf deploy/open5gs-smf >/dev/null 2>&1
  kubectl -n oran-core rollout status  deploy/open5gs-amf --timeout=150s >/dev/null 2>&1
  kubectl -n oran-core rollout status  deploy/open5gs-smf --timeout=150s >/dev/null 2>&1
  # 4. Positive confirmation: AMF logged NF profiles discovered from the NRF.
  sleep 6
  local seen
  seen=$(kubectl -n oran-core logs deploy/open5gs-amf --tail=200 2>/dev/null | grep -c "NF registered")
  if [ "${seen:-0}" -ge 1 ]; then
    echo "AMF discovered ${seen} NF profile(s) via NRF — UE identity resolution ready."
  else
    echo "[WARN] AMF shows no 'NF registered' yet; reconcile will restart UEs to retry."
  fi
}

generate_state_file

section "Replica state"
cat "$STATE_FILE"

section "Restoring replicas"
restore_all
enforce_excluded_off
check_ifb_module

section "Waiting for key workloads"
for dep in open5gs-mongodb open5gs-nrf open5gs-scp open5gs-udr open5gs-udm open5gs-ausf open5gs-upf open5gs-amf open5gs-smf; do
  wait_deploy_if_needed oran-core "$dep" 240s
done

for dep in oai-du0 oai-du1 oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  wait_deploy_if_needed oran-ran "$dep" 240s
done

for dep in oran-monitoring-grafana oran-monitoring-kube-prome-operator oran-monitoring-kube-state-metrics; do
  wait_deploy_if_needed monitoring "$dep" 240s
done
wait_statefulset_if_needed monitoring prometheus-oran-monitoring-kube-prome-prometheus 240s

start_dashboard
ensure_core_amf_ready
ensure_cu_plane_healthy
recover_mixed_du_if_available
reconcile_ue_sessions

section "Final pod state"
for ns in $TARGET_NAMESPACES; do
  show_namespace_pods "$ns"
done

echo
echo "VERDICT=PLATFORM_STARTED"
