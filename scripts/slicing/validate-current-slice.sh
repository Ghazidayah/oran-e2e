#!/usr/bin/env bash
set +e
set +u

NS="${NS:-oran-ran}"
CM="${CM:-oai-nrue-config}"
DEP="${DEP:-oai-nr-ue}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"
DIR="${DIR:-$HOME/oran-proof/phase3-current-slice-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$DIR"

source "$REPO/scripts/ue/ue-common.sh"

echo "===== Validate protected UE1 current slice ====="
echo "Namespace: $NS"
echo "Deployment: $DEP"
echo "ConfigMap: $CM"

SERVERADDR="$(ue_serveraddr_from_cm "$NS" "$CM")"
SLICE="$(ue_slice_from_cm "$NS" "$CM")"
UE="$(ue_pod_for_deployment "$NS" "$DEP")"

echo "DU target: $SERVERADDR" | tee "$DIR/du-target.txt"
echo "Requested slice: $SLICE" | tee "$DIR/ue-requested-slice.txt"
echo "UE pod: $UE" | tee "$DIR/ue-pod.txt"

if [ -z "$UE" ]; then
  echo "FAIL: no running protected ue1 pod found"
  echo "VERDICT=UE1_POD_NOT_FOUND"
  exit 0
fi

kubectl -n "$NS" exec "$UE" -- ip addr show oaitun_ue1 | tee "$DIR/oaitun.txt"
kubectl -n "$NS" exec "$UE" -- ip route | tee "$DIR/ip-route.txt"
kubectl -n "$NS" exec "$UE" -- ping -I oaitun_ue1 -c 4 8.8.8.8 | tee "$DIR/ping.txt"
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-counters.txt"

echo "VERDICT=PROTECTED_UE1_CURRENT_SLICE_VALIDATED"
