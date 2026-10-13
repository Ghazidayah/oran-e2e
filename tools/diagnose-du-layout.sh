#!/usr/bin/env bash
# Read-only snapshot of the UE <-> DU layout, to compare a working layout with a broken one.
# Changes nothing in the cluster. Run it once in each state and compare the two reports:
#   tools/diagnose-du-layout.sh working
#   tools/diagnose-du-layout.sh broken
set -u

LABEL="${1:-snapshot}"
NS="${NS:-oran-ran}"
CORE_NS="${CORE_NS:-oran-core}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
OUT_DIR="$HOME/oran-proof/diagnose-du-layout"
OUT="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-$LABEL.txt"
mkdir -p "$OUT_DIR"

section() { printf '\n==================== %s ====================\n' "$*"; }


# Automatic checks: the three root causes found so far, evaluated in one place.
auto_checks() {
  section "AUTOMATIC CHECKS"

  # (a) UE carrier (-C) must equal the carrier of the DU it points to
  local du cm freq
  declare -A DU_C
  for du in du0 du1; do
    cm="oai-$du-f1-config"
    freq="$(kubectl -n "$NS" get cm "$cm" -o jsonpath='{.data.gnb\.conf}' 2>/dev/null | python3 -c '
import re, sys
t = sys.stdin.read()
m = re.search(r"^\s*absoluteFrequencySSB\s*=\s*(\d+)\s*;", t, re.M)
if m:
    n = int(m.group(1))
    print(n * 5000 if n < 600000 else 3000000000 + (n - 600000) * 15000)
')"
    DU_C[$du]="${freq:-?}"
    echo "carrier $du: -C ${freq:-unknown}"
  done
  local i dep args c target_du
  for i in "" -2 -3 -4 -5; do
    dep="oai-nr-ue$i"
    args="$(kubectl -n "$NS" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)"
    c="$(echo "$args" | python3 -c 'import sys,json
try:
    a=json.load(sys.stdin); print(a[a.index("-C")+1])
except Exception:
    print("?")')"
    target_du="$(echo "$args" | grep -o 'oai-du[01]-rfsim' | head -1 | sed 's/oai-\(du[01]\)-rfsim/\1/')"
    if [ -z "$target_du" ] || [ "${DU_C[$target_du]:-?}" = "?" ] || [ "$c" = "?" ]; then
      echo "CHECK carrier $dep: UNKNOWN (ue -C=$c, target=${target_du:-?})"
    elif [ "$c" = "${DU_C[$target_du]}" ]; then
      echo "CHECK carrier $dep: OK (-C $c = $target_du)"
    else
      echo "CHECK carrier $dep: PROBLEM (ue -C $c but $target_du runs ${DU_C[$target_du]}) -> UE cannot decode SIB1"
    fi
  done

  # (b) CU-CP <-> AMF (NG) association
  local cu
  cu="$(kubectl -n "$NS" logs deploy/oai-cu-cp --tail=1500 2>/dev/null | grep -E "NGSetupResponse|NGAP_DEREGISTERED_GNB_IND|No AMF is associated" | tail -1)"
  case "$cu" in
    *NGSetupResponse*) echo "CHECK cu-cp NG link: OK" ;;
    "") echo "CHECK cu-cp NG link: UNKNOWN (no NG line in last 1500 log lines)" ;;
    *) echo "CHECK cu-cp NG link: PROBLEM ($cu) -> kubectl -n $NS rollout restart deploy/oai-cu-cp" ;;
  esac

  # (c) core service routing / authentication
  local scp rej
  scp="$(kubectl -n "$CORE_NS" logs deploy/open5gs-scp --since=10m 2>/dev/null | grep -c "No route to host")"
  rej="$(kubectl -n "$CORE_NS" logs deploy/open5gs-amf --since=10m 2>/dev/null | grep -c "Registration reject")"
  [ "${scp:-0}" -eq 0 ] && echo "CHECK core SCP routing: OK" \
    || echo "CHECK core SCP routing: PROBLEM ($scp 'No route to host' in 10 min) -> restart udr, udm, ausf"
  [ "${rej:-0}" -eq 0 ] && echo "CHECK AMF registrations: OK" \
    || echo "CHECK AMF registrations: PROBLEM ($rej 'Registration reject' in 10 min)"

  # (d) UE pods stuck in a restart loop
  local bad
  bad="$(kubectl -n "$NS" get pods 2>/dev/null | grep -E "oai-nr-ue" | grep -cE "CrashLoopBackOff|Error")"
  [ "${bad:-0}" -eq 0 ] && echo "CHECK UE pods: OK" || echo "CHECK UE pods: PROBLEM ($bad in CrashLoopBackOff/Error)"
}

report() {
  auto_checks

  section "PODS ($NS)"
  kubectl -n "$NS" get pods -o wide

  section "UE CONFIG vs RUNNING STATE"
  local i dep cm pod serv tun
  for i in "" -2 -3 -4 -5; do
    dep="oai-nr-ue$i"
    cm="oai-nrue-config$i"
    serv="$(kubectl -n "$NS" get cm "$cm" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
      | grep -o 'serveraddr *= *"[^"]*"' | head -1)"
    # select by label: grepping "pod/oai-nr-ue-" also matched oai-nr-ue-2..5
    pod="$(kubectl -n "$NS" get pods -l "app=$dep" -o name 2>/dev/null | head -1 | cut -d/ -f2)"
    echo "--- $dep | configmap: ${serv:-?} | pod: ${pod:-none}"
    kubectl -n "$NS" get deploy "$dep" -o jsonpath='deploy args: {.spec.template.spec.containers[0].args}{"\n"}' 2>/dev/null
    [ -n "$pod" ] || continue
    tun="$(kubectl -n "$NS" exec "$pod" -- sh -c 'ip -4 -o addr show oaitun_ue1 2>/dev/null' 2>&1)"
    echo "tunnel: ${tun:-MISSING}"
    kubectl -n "$NS" exec "$pod" -- sh -c 'ip route get 8.8.8.8 2>&1; ping -I oaitun_ue1 -c 2 -W 2 8.8.8.8 2>&1 | tail -3' 2>&1
  done

  section "DASHBOARD VIEW"
  curl -s -m 15 "http://127.0.0.1:$PORT/api/ues" | head -c 3000; echo
  curl -s -m 15 "http://127.0.0.1:$PORT/api/handover/mixed-du/status" | head -c 3000; echo

  for du in oai-du0 oai-du1; do
    section "$du LOG (last 400 lines, UE / RA / F1 / error lines)"
    kubectl -n "$NS" logs "deploy/$du" --tail=400 2>&1 | grep -iE "UE |RNTI|RA |F1AP|release|error|fail|lost|sync" | tail -40
  done

  section "CU-CP LOG (UE contexts, last 400 lines)"
  kubectl -n "$NS" logs deploy/oai-cu-cp --tail=400 2>&1 | grep -iE "UE |release|error|fail|NGAP|F1AP|context" | tail -40

  section "AMF LOG (registrations / rejects)"
  kubectl -n "$CORE_NS" logs deploy/open5gs-amf --tail=300 2>&1 | grep -iE "Registration|reject|InitialUE|Cause|SUCI|IMSI|error|duplicate" | tail -40

  section "SMF LOG (PDU sessions)"
  kubectl -n "$CORE_NS" logs deploy/open5gs-smf --tail=300 2>&1 | grep -iE "PDU|session|error|release|IMSI" | tail -30

  section "UE POD LOGS (last 25 lines each)"
  for i in "" -2 -3 -4 -5; do
    echo "--- oai-nr-ue$i"
    kubectl -n "$NS" logs "deploy/oai-nr-ue$i" --tail=25 2>&1
  done
}

report > "$OUT" 2>&1
echo "Report written to: $OUT"
