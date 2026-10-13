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

report() {
  section "PODS ($NS)"
  kubectl -n "$NS" get pods -o wide

  section "UE CONFIG vs RUNNING STATE"
  local i dep cm pod serv tun
  for i in "" -2 -3 -4 -5; do
    dep="oai-nr-ue$i"
    cm="oai-nrue-config$i"
    serv="$(kubectl -n "$NS" get cm "$cm" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
      | grep -o 'serveraddr *= *"[^"]*"' | head -1)"
    pod="$(kubectl -n "$NS" get pods -o name 2>/dev/null | grep "pod/$dep-" | head -1 | cut -d/ -f2)"
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
