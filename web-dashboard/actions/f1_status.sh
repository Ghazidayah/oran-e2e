#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"

topology_ok=true
tunnel_ok=false

section() {
  echo
  echo "===== $1 ====="
}

get_pod() {
  local app="$1"
  kubectl -n "$NS" get pod -l "app=${app}" \
    --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp \
    -o name 2>/dev/null | tail -n 1 | cut -d/ -f2
}

check_deploy() {
  local deploy="$1"
  local avail desired

  desired="$(kubectl -n "$NS" get deploy "$deploy" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  avail="$(kubectl -n "$NS" get deploy "$deploy" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"

  desired="${desired:-0}"
  avail="${avail:-0}"

  if [ "$desired" -ge 1 ] && [ "$avail" -ge 1 ]; then
    echo "[OK] $deploy desired=$desired available=$avail"
  else
    echo "[FAIL] $deploy desired=$desired available=$avail"
    topology_ok=false
  fi
}

section "F1 topology deployments"
check_deploy oai-cu
check_deploy oai-du0
check_deploy oai-du1
check_deploy oai-nr-ue-f1

section "Old monolithic gNB deployments"
kubectl -n "$NS" get deploy oai-gnb oai-gnb-b 2>/dev/null || true

CU_POD="$(get_pod oai-cu)"
DU0_POD="$(get_pod oai-du0)"
DU1_POD="$(get_pod oai-du1)"
UE_POD="$(get_pod oai-nr-ue-f1)"

section "Detected pods"
echo "CU_POD=${CU_POD:-}"
echo "DU0_POD=${DU0_POD:-}"
echo "DU1_POD=${DU1_POD:-}"
echo "UE_POD=${UE_POD:-}"

if [ -z "${CU_POD:-}" ] || [ -z "${DU0_POD:-}" ] || [ -z "${DU1_POD:-}" ] || [ -z "${UE_POD:-}" ]; then
  echo "[FAIL] Missing one or more F1 pods"
  topology_ok=false
fi

section "Services"
kubectl -n "$NS" get svc oai-cu-ci oai-nr-ue-f1-rfsim 2>/dev/null || {
  echo "[FAIL] Missing oai-cu-ci or oai-nr-ue-f1-rfsim service"
  topology_ok=false
}

if [ -n "${UE_POD:-}" ]; then
  section "UE RFsim socket check"
  kubectl -n "$NS" exec "$UE_POD" -- sh -c '
    echo "Listening sockets:"
    ss -ltnp 2>/dev/null | grep 4043 || true
    echo
    echo "Established RFsim sockets:"
    ss -tnp 2>/dev/null | grep 4043 || true
  '

  ESTAB_COUNT="$(kubectl -n "$NS" exec "$UE_POD" -- sh -c "ss -tnp 2>/dev/null | grep 4043 | grep -c ESTAB || true")"
  if [ "${ESTAB_COUNT:-0}" -ge 2 ]; then
    echo "[OK] UE has at least two established RFsim connections"
  else
    echo "[WARN] UE has fewer than two established RFsim connections: ${ESTAB_COUNT:-0}"
  fi

  section "UE tunnel and user-plane readiness"
  if kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ip addr show oaitun_ue1 >/dev/null 2>&1'; then
    kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ip addr show oaitun_ue1; echo "-----"; ip route'
    if kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 -c 2 10.45.0.1 >/dev/null 2>&1'; then
      echo "[OK] UE tunnel exists and ping to 10.45.0.1 works"
      tunnel_ok=true
    else
      echo "[WARN] UE tunnel exists but ping to 10.45.0.1 failed"
    fi
  else
    echo "[WARN] oaitun_ue1 is missing"
  fi
fi

if [ -n "${CU_POD:-}" ]; then
  section "Recent useful CU F1 logs"
  kubectl -n "$NS" logs "$CU_POD" --tail=600 2>/dev/null | \
    egrep -i 'F1|F1AP|DU|Setup|du-rfsim|handover|RRCReconfiguration|complete|fail|error' | \
    grep -v 'E2 SETUP REQUEST timeout' | \
    tail -80 || true
fi

section "Summary"

if [ "$topology_ok" = true ]; then
  echo "F1_STATUS=READY"
  echo "F1_TOPOLOGY=READY"
else
  echo "F1_STATUS=NOT_READY"
  echo "F1_TOPOLOGY=NOT_READY"
fi

if [ "$tunnel_ok" = true ]; then
  echo "UE_TUNNEL=READY"
else
  echo "UE_TUNNEL=MISSING"
fi

if [ "$topology_ok" = true ] && [ "$tunnel_ok" = true ]; then
  echo "F1_HANDOVER_READY=YES"
else
  echo "F1_HANDOVER_READY=NO"
fi

if [ "$topology_ok" = true ]; then
  exit 0
else
  exit 1
fi
