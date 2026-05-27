#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-}"
NS="${NS:-oran-ran}"

case "$PROFILE" in
  embb)
    LABEL="eMBB"
    SST="1"
    RATE="100mbit"
    BURST="256kb"
    LATENCY="50ms"
    ;;
  urllc)
    LABEL="URLLC"
    SST="2"
    RATE="10mbit"
    BURST="32kb"
    LATENCY="10ms"
    ;;
  mmtc)
    LABEL="mMTC"
    SST="3"
    RATE="256kbit"
    BURST="16kb"
    LATENCY="100ms"
    ;;
  v2x)
    LABEL="V2X"
    SST="4"
    RATE="15mbit"
    BURST="64kb"
    LATENCY="30ms"
    ;;
  clear)
    LABEL="CLEAR"
    SST="-"
    ;;
  *)
    echo "Usage: $0 embb|urllc|mmtc|v2x|clear"
    exit 1
    ;;
esac

UE="$(kubectl -n "$NS" get pods --no-headers | awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}')"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod found"; exit 1; }

echo "===== APPLY SLICE RESOURCE PROFILE ====="
echo "PROFILE=$PROFILE"
echo "LABEL=$LABEL"
echo "SST=$SST"
echo "UE=$UE"

kubectl -n "$NS" exec "$UE" -- ip addr show oaitun_ue1 >/dev/null

if ! kubectl -n "$NS" exec "$UE" -- sh -lc 'command -v tc >/dev/null 2>&1'; then
  echo "[FAIL] tc command not found inside UE container."
  echo "This Phase 4 resource enforcement needs tc/iproute2 inside the UE image."
  exit 1
fi

if [ "$PROFILE" = "clear" ]; then
  kubectl -n "$NS" exec "$UE" -- sh -lc 'tc qdisc del dev oaitun_ue1 root 2>/dev/null || true'
  kubectl -n "$NS" exec "$UE" -- sh -lc 'tc qdisc show dev oaitun_ue1 || true'
  exit 0
fi

echo "Applying tc TBF: rate=$RATE burst=$BURST latency=$LATENCY"

kubectl -n "$NS" exec "$UE" -- sh -lc "
  tc qdisc replace dev oaitun_ue1 root handle 1: tbf rate $RATE burst $BURST latency $LATENCY
  tc qdisc show dev oaitun_ue1
"

echo "===== SLICE RESOURCE PROFILE APPLIED ====="
