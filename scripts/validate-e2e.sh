#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Health verdict for the end-to-end 5G chain.
#
# Role     : determine in a single command whether a terminal has full 5G
#            service. The most heavily used script in the project: every
#            disruptive operation (retune, MCS change, DU handover) ends with
#            a run of this script.
# Inputs   : NS (default oran-ran), DEP (default oai-nr-ue), REPO
# Logic    : the pod is resolved from its deployment, never hardcoded by name,
#            so the script survives any restart. Three checks chained from
#            most structural to most functional:
#              1. the oaitun_ue1 tunnel interface exists
#              2. the routing table is consistent
#              3. traffic actually goes out: ping -I oaitun_ue1 8.8.8.8
#            The -I flag forces the traffic out through the tunnel: without
#            it, the test would take the pod's own network path and would
#            prove nothing.
# Output   : a single VERDICT= line at the end of the run, even on failure.
#            This is the line the dashboard and the acceptance suite parse.
# Usage    : bash scripts/validate-e2e.sh
# ---------------------------------------------------------------------------
set +e
set +u

NS="${NS:-oran-ran}"
DEP="${DEP:-oai-nr-ue}"
REPO="${REPO:-$HOME/oran-e2e}"

source "$REPO/scripts/ue/ue-common.sh"

echo "===== End-to-End UE Validation - protected UE1 ====="

UE_POD="$(ue_pod_for_deployment "$NS" "$DEP")"

if [ -z "$UE_POD" ]; then
  echo "FAIL: protected ue1 pod not found"
  echo "VERDICT=E2E_UE1_POD_NOT_FOUND"
  exit 0
fi

echo "UE pod: $UE_POD"

kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ip addr show oaitun_ue1 >/dev/null 2>&1'
if [ $? -ne 0 ]; then
  echo "FAIL: oaitun_ue1 missing"
  echo "VERDICT=E2E_UE1_TUNNEL_MISSING"
  exit 0
fi

kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ip addr | grep -A2 oaitun_ue1'
kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ip route'
kubectl -n "$NS" exec "$UE_POD" -- ping -I oaitun_ue1 -c 4 8.8.8.8

if [ $? -eq 0 ]; then
  echo "VERDICT=E2E_UE1_VALIDATION_OK"
else
  echo "VERDICT=E2E_UE1_PING_FAILED"
fi
