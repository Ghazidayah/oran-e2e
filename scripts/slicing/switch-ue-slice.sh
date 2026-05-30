#!/usr/bin/env bash
set +e
set +u

NS="${NS:-oran-ran}"
CM="${CM:-oai-nrue-config}"
DEP="${DEP:-oai-nr-ue}"
SST="${1:-1}"
SD="${2:-0xffffff}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"

source "$REPO/scripts/ue/ue-common.sh"

echo "===== DU-aware UE1 slice switch ====="
echo "Namespace: $NS"
echo "ConfigMap: $CM"
echo "Deployment: $DEP"
echo "Requested SST: $SST"
echo "Requested SD: $SD"

if [ "$DEP" != "oai-nr-ue" ] || [ "$CM" != "oai-nrue-config" ]; then
  echo "FAIL: this Phase 3/4 slice switch is restricted to protected ue1 only."
  echo "VERDICT=NOT_PROTECTED_UE1"
  exit 0
fi

BEFORE_DU="$(ue_serveraddr_from_cm "$NS" "$CM")"
BEFORE_SLICE="$(ue_slice_from_cm "$NS" "$CM")"

echo "Before DU target: $BEFORE_DU"
echo "Before slice: $BEFORE_SLICE"

TMP="/tmp/$CM.du-aware-slice.conf.$$"

kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' > "$TMP" 2>/dev/null

if [ ! -s "$TMP" ]; then
  echo "FAIL: could not read $CM nr-ue.conf"
  echo "VERDICT=CONFIGMAP_READ_FAILED"
  exit 0
fi

python3 - "$TMP" "$SST" "$SD" <<'PY'
import sys, re

path, sst, sd = sys.argv[1:4]
text = open(path, encoding="utf-8", errors="ignore").read()

# Important: change only slice fields. Do NOT touch serveraddr.
new = f'pdu_sessions = ({{ dnn = "oai"; nssai_sst = {sst}; nssai_sd = {sd}; }});'

text2 = re.sub(
    r'pdu_sessions\s*=\s*\(\{\s*dnn\s*=\s*"oai"\s*;\s*nssai_sst\s*=\s*[^;]+;\s*nssai_sd\s*=\s*[^;]+;\s*\}\);',
    new,
    text,
)

if text2 == text:
    text2 = re.sub(r'nssai_sst\s*=\s*[^;,\n}]+', f'nssai_sst = {sst}', text2)
    text2 = re.sub(r'nssai_sd\s*=\s*[^;,\n}]+', f'nssai_sd = {sd}', text2)

open(path, "w", encoding="utf-8").write(text2)
PY

PAYLOAD="$(python3 - "$TMP" <<'PY'
import sys, json
data = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"data": {"nr-ue.conf": data}}))
PY
)"

kubectl -n "$NS" patch cm "$CM" --type merge -p "$PAYLOAD"

AFTER_DU="$(ue_serveraddr_from_cm "$NS" "$CM")"
AFTER_SLICE="$(ue_slice_from_cm "$NS" "$CM")"

echo "After DU target: $AFTER_DU"
echo "After slice: $AFTER_SLICE"

if [ "$BEFORE_DU" != "$AFTER_DU" ]; then
  echo "FAIL: serveraddr changed during slice switch. This is not DU-aware."
  echo "VERDICT=DU_TARGET_CHANGED_UNSAFE"
  exit 0
fi

kubectl -n "$NS" scale deploy/"$DEP" --replicas=1 >/dev/null 2>&1
kubectl -n "$NS" rollout restart deploy/"$DEP" >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/"$DEP" --timeout=300s

RESULT="$(wait_exact_ue_tunnel "$NS" "$DEP" 240)"
POD="${RESULT%%|*}"
TUN="${RESULT##*|}"

if [ -n "$POD" ] && [ -n "$TUN" ]; then
  echo "PASS: protected ue1 tunnel ready pod=$POD tunnel=$TUN"
  echo "VERDICT=DU_AWARE_SLICE_SWITCH_OK"
else
  echo "FAIL: protected ue1 tunnel not ready after slice switch"
  echo "VERDICT=DU_AWARE_SLICE_SWITCH_TUNNEL_FAILED"
fi
