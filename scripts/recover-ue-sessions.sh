#!/usr/bin/env bash
# recover-ue-sessions.sh — diagnose-first recovery after a core/CU event.
#
# After an AMF/SMF/UPF/mongo/CU restart, PDU sessions are torn down. UEs usually
# reattach on their own with NEW IPs, but some can strand a stale oaitun_ue1
# (old IP / dead GTP state) while still printing MAC stats. Blind rollout-restart
# of all UEs is wasteful and churns the IP pool, so this script:
#   1) reads each UE's IMSI from its ConfigMap,
#   2) finds the SMF's most-recent IPv4[] assignment for that IMSI,
#   3) compares it to the IP actually on the pod's oaitun_ue1,
#   4) pings the DN gateway (10.45.0.1) through the tunnel,
# and only rollout-restarts the UEs that MISMATCH or FAIL the data-plane check.
#
# Default is DRY-RUN (diagnose only). Pass --fix to actually restart the bad UEs.
#
# Usage:
#   scripts/recover-ue-sessions.sh            # diagnose only
#   scripts/recover-ue-sessions.sh --fix      # diagnose + restart unhealthy UEs
#   scripts/recover-ue-sessions.sh --fix --yes   # skip the confirm prompt

set -uo pipefail

REPO="${REPO:-$HOME/oran-e2e}"
source "$REPO/scripts/ue/ue-common.sh"

NS_RAN="${NS_RAN:-oran-ran}"
NS_CORE="${NS_CORE:-oran-core}"
DN_GW="${DN_GW:-10.45.0.1}"
SMF_DEPLOY="${SMF_DEPLOY:-open5gs-smf}"
SMF_LOG_TAIL="${SMF_LOG_TAIL:-20000}"

UE_DEPLOYMENTS=("oai-nr-ue" "oai-nr-ue-2" "oai-nr-ue-3" "oai-nr-ue-4" "oai-nr-ue-5")

DO_FIX=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --fix) DO_FIX=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $arg (use --fix, --yes)"; exit 2 ;;
  esac
done

cm_for_deployment() {
  local dep="$1"
  local suffix="${dep#oai-nr-ue}"
  echo "oai-nrue-config${suffix}"
}

imsi_from_cm() {
  local cm="$1"
  kubectl -n "$NS_RAN" get cm "$cm" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
    | python3 -c '
import sys, re
m = re.search(r"imsi\s*=\s*\"?([0-9]{15})\"?", sys.stdin.read())
print(m.group(1) if m else "")
'
}

smf_ip_for_imsi() {
  local imsi="$1"
  echo "$SMF_LOG" | grep "imsi-$imsi" | grep -oE 'IPv4\[[0-9.]+\]' \
    | tail -1 | sed -E 's/IPv4\[([0-9.]+)\]/\1/'
}

echo "=================================================================="
echo " UE SESSION RECOVERY — diagnose-first  (mode: $([ "$DO_FIX" = 1 ] && echo FIX || echo DRY-RUN))"
echo " RAN ns=$NS_RAN  CORE ns=$NS_CORE  DN gw=$DN_GW"
echo "=================================================================="

SMF_LOG="$(kubectl -n "$NS_CORE" logs "deploy/$SMF_DEPLOY" --tail="$SMF_LOG_TAIL" 2>/dev/null)"
if [ -z "$SMF_LOG" ]; then
  echo "WARN: could not read SMF log (deploy/$SMF_DEPLOY in $NS_CORE) — IP-match check will be skipped."
fi

UNHEALTHY=()
printf "\n%-14s %-16s %-15s %-15s %-8s %s\n" "DEPLOY" "IMSI" "POD_TUNNEL" "SMF_IPv4" "PING" "STATUS"
printf -- "------------------------------------------------------------------------------------------\n"

for dep in "${UE_DEPLOYMENTS[@]}"; do
  cm="$(cm_for_deployment "$dep")"
  imsi="$(imsi_from_cm "$cm")"
  pod="$(ue_pod_for_deployment "$NS_RAN" "$dep")"

  if [ -z "$pod" ]; then
    printf "%-14s %-16s %-15s %-15s %-8s %s\n" "$dep" "${imsi:-?}" "NO_POD" "-" "-" "UNHEALTHY(no-pod)"
    UNHEALTHY+=("$dep"); continue
  fi

  pod_tun="$(ue_tunnel_ip_for_pod "$NS_RAN" "$pod")"; pod_tun="${pod_tun%%/*}"
  smf_ip="$(smf_ip_for_imsi "$imsi")"

  if [ -n "$pod_tun" ]; then
    ploss="$(kubectl -n "$NS_RAN" exec "$pod" -- ping -I oaitun_ue1 -c 3 -W 2 "$DN_GW" 2>/dev/null \
              | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')"
  else
    ploss=""
  fi
  ping_ok=0; [ -n "$ploss" ] && [ "$ploss" -lt 100 ] && ping_ok=1

  ip_ok=1
  if [ -n "$SMF_LOG" ] && [ -n "$smf_ip" ] && [ -n "$pod_tun" ] && [ "$pod_tun" != "$smf_ip" ]; then
    ip_ok=0
  fi

  if [ "$ping_ok" = 1 ] && [ "$ip_ok" = 1 ]; then
    status="HEALTHY"
  elif [ "$ping_ok" = 1 ] && [ "$ip_ok" = 0 ]; then
    status="CHECK(ip-mismatch,ping-ok)"
  else
    status="UNHEALTHY(ping-fail)"
    UNHEALTHY+=("$dep")
  fi

  printf "%-14s %-16s %-15s %-15s %-8s %s\n" \
    "$dep" "${imsi:-?}" "${pod_tun:-NONE}" "${smf_ip:-?}" \
    "$([ "$ping_ok" = 1 ] && echo OK || echo FAIL)" "$status"
done

echo
if [ "${#UNHEALTHY[@]}" -eq 0 ]; then
  echo "RESULT: all UEs healthy — no recovery needed."
  echo "VERDICT=ALL_HEALTHY"
  exit 0
fi

echo "UNHEALTHY (ping-failing) UEs: ${UNHEALTHY[*]}"
if [ "$DO_FIX" != 1 ]; then
  echo
  echo "DRY-RUN: re-run with --fix to rollout-restart the above deployment(s)."
  echo "VERDICT=RECOVERY_NEEDED"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Rollout-restart ${#UNHEALTHY[@]} deployment(s): ${UNHEALTHY[*]} ? [y/N] " ans
  case "$ans" in y|Y|yes) : ;; *) echo "Aborted."; echo "VERDICT=ABORTED"; exit 0 ;; esac
fi

for dep in "${UNHEALTHY[@]}"; do
  echo "--- rollout restart $dep"
  kubectl -n "$NS_RAN" rollout restart "deploy/$dep"
done

echo
echo "Waiting for tunnels to re-form (up to 240s each)..."
for dep in "${UNHEALTHY[@]}"; do
  res="$(wait_exact_ue_tunnel "$NS_RAN" "$dep" 240)"
  pod="${res%%|*}"; tun="${res##*|}"
  if [ -n "$pod" ] && [ -n "$tun" ]; then
    ploss="$(kubectl -n "$NS_RAN" exec "$pod" -- ping -I oaitun_ue1 -c 3 -W 2 "$DN_GW" 2>/dev/null \
              | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')"
    echo "  $dep -> pod=$pod tun=$tun ping_loss=${ploss:-?}%"
  else
    echo "  $dep -> tunnel did NOT re-form within timeout"
  fi
done

echo "VERDICT=RECOVERY_ATTEMPTED"
