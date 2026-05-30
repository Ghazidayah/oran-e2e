#!/usr/bin/env bash
set +e
set +u

PROFILE="${1:-embb}"
NS="${NS:-oran-ran}"
DEP="${DEP:-oai-nr-ue}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"

source "$REPO/scripts/ue/ue-common.sh"

case "$PROFILE" in
  embb|eMBB)
    RATE="${RATE:-50mbit}"
    BURST="${BURST:-256kb}"
    LATENCY="${LATENCY:-50ms}"
    ;;
  urllc|URLLC)
    RATE="${RATE:-20mbit}"
    BURST="${BURST:-64kb}"
    LATENCY="${LATENCY:-5ms}"
    ;;
  mmtc|mMTC)
    RATE="${RATE:-2mbit}"
    BURST="${BURST:-32kb}"
    LATENCY="${LATENCY:-100ms}"
    ;;
  v2x|V2X)
    RATE="${RATE:-10mbit}"
    BURST="${BURST:-128kb}"
    LATENCY="${LATENCY:-20ms}"
    ;;
  clear)
    RATE=""
    ;;
  *)
    echo "Unknown profile: $PROFILE"
    echo "VERDICT=UNKNOWN_RESOURCE_PROFILE"
    exit 0
    ;;
esac

UE="$(ue_pod_for_deployment "$NS" "$DEP")"

echo "===== Apply Phase 4 resource profile to protected UE1 ====="
echo "Profile: $PROFILE"
echo "Deployment: $DEP"
echo "Pod: $UE"

if [ -z "$UE" ]; then
  echo "FAIL: protected ue1 pod not found"
  echo "VERDICT=UE1_POD_NOT_FOUND"
  exit 0
fi

kubectl -n "$NS" exec "$UE" -- ip addr show oaitun_ue1 >/dev/null 2>&1

if [ $? -ne 0 ]; then
  echo "FAIL: oaitun_ue1 missing on protected ue1"
  echo "VERDICT=UE1_TUNNEL_MISSING"
  exit 0
fi

kubectl -n "$NS" exec "$UE" -- sh -lc 'command -v tc >/dev/null 2>&1'
if [ $? -ne 0 ]; then
  echo "FAIL: tc not available inside UE image"
  echo "VERDICT=TC_NOT_AVAILABLE"
  exit 0
fi

if [ "$PROFILE" = "clear" ]; then
  kubectl -n "$NS" exec "$UE" -- sh -lc 'tc qdisc del dev oaitun_ue1 root 2>/dev/null || true'
  kubectl -n "$NS" exec "$UE" -- sh -lc 'tc qdisc show dev oaitun_ue1 || true'
  echo "VERDICT=UE1_RESOURCE_PROFILE_CLEARED"
  exit 0
fi

kubectl -n "$NS" exec "$UE" -- sh -lc "
  tc qdisc replace dev oaitun_ue1 root handle 1: tbf rate $RATE burst $BURST latency $LATENCY
  tc qdisc show dev oaitun_ue1
"

echo "VERDICT=UE1_RESOURCE_PROFILE_APPLIED"
