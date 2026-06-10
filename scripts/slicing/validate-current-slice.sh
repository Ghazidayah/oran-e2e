#!/usr/bin/env bash
# Validate protected UE1's CURRENT slice (v2, 2026-06-10).
# v1 only checked the requested config + tunnel + ping — which let a silent
# fallback to the default slice pass as "validated". v2 additionally asserts the
# slice the core actually GRANTED (AMF S_NSSAI log line) matches the request.
set +e
set +u

NS="${NS:-oran-ran}"
NS_CORE="${NS_CORE:-oran-core}"
CM="${CM:-oai-nrue-config}"
DEP="${DEP:-oai-nr-ue}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"
DIR="${DIR:-$HOME/oran-proof/phase3-current-slice-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$DIR"

source "$REPO/scripts/ue/ue-common.sh"

echo "===== Validate protected UE1 current slice (requested vs GRANTED) ====="
SERVERADDR="$(ue_serveraddr_from_cm "$NS" "$CM")"
UE="$(ue_pod_for_deployment "$NS" "$DEP")"
echo "DU target: $SERVERADDR" | tee "$DIR/du-target.txt"
echo "UE pod: $UE" | tee "$DIR/ue-pod.txt"
[ -z "$UE" ] && { echo "FAIL: no running ue1 pod"; echo "VERDICT=UE1_POD_NOT_FOUND"; exit 0; }

CONF="$(kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}')"
IMSI="$(echo "$CONF" | sed -n 's/.*imsi[[:space:]]*=[[:space:]]*"\([0-9]*\)".*/\1/p' | head -1)"
REQ_SST="$(echo "$CONF" | sed -n 's/.*nssai_sst[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
echo "IMSI: $IMSI  Requested SST: ${REQ_SST:-unknown}" | tee "$DIR/ue-requested-slice.txt"

kubectl -n "$NS" exec "$UE" -- ip addr show oaitun_ue1 | tee "$DIR/oaitun.txt"
kubectl -n "$NS" exec "$UE" -- ping -I oaitun_ue1 -c 4 8.8.8.8 | tee "$DIR/ping.txt"
PING_OK=$?

GRANTED="$(kubectl -n "$NS_CORE" logs deploy/open5gs-amf --tail=300 2>/dev/null \
  | grep "imsi-$IMSI" | grep -o 'S_NSSAI\[SST:[0-9]*' | tail -1 | grep -o '[0-9]*$')"
echo "AMF granted: SST=${GRANTED:-unknown}" | tee "$DIR/granted-slice.txt"

if [ "$PING_OK" -ne 0 ]; then
  echo "VERDICT=SLICE_VALIDATION_PING_FAILED"
elif [ -z "$GRANTED" ]; then
  echo "WARN: no S_NSSAI line found in recent AMF log (session may be old); requested=$REQ_SST"
  echo "VERDICT=SLICE_GRANT_EVIDENCE_NOT_FOUND"
elif [ "$GRANTED" = "$REQ_SST" ]; then
  echo "PASS: requested SST=$REQ_SST and core granted SST=$GRANTED (match)"
  echo "VERDICT=REAL_SLICE_VALIDATED"
else
  echo "FAIL: requested SST=$REQ_SST but core granted SST=$GRANTED"
  echo "VERDICT=GRANTED_SLICE_MISMATCH"
fi
