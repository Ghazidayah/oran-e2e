#!/usr/bin/env bash
# Real S-NSSAI slice switch for protected UE1 (v2, 2026-06-10).
# Proven mechanism (see docs/slicing-real-snssai-validation.md):
#   1) UE config must use the LEGACY uicc0 keys (dnn/nssai_sst/nssai_sd) — the
#      pdu_sessions = ({...}) block is silently IGNORED by the 2025.w45 nr-ue.
#   2) The OAI UE sends no Requested NSSAI at registration, so Open5GS allows only
#      the subscriber's DEFAULT slice -> the MongoDB default_indicator must be
#      flipped to the target slice together with the UE config.
#   3) Success = the AMF actually GRANTS S_NSSAI[SST:<target>] (checked here).
# Usage: switch-ue-slice.sh <SST> [SD]   (env: NS, CM, DEP, NS_CORE)
set +e
set +u

NS="${NS:-oran-ran}"
NS_CORE="${NS_CORE:-oran-core}"
CM="${CM:-oai-nrue-config}"
DEP="${DEP:-oai-nr-ue}"
SST="${1:-1}"
SD="${2:-0xffffff}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"

source "$REPO/scripts/ue/ue-common.sh"

echo "===== Real S-NSSAI slice switch (UE config + subscriber default) ====="
echo "Namespace: $NS  Core: $NS_CORE"
echo "ConfigMap: $CM  Deployment: $DEP"
echo "Requested SST: $SST  SD: $SD"

if [ "$DEP" != "oai-nr-ue" ] || [ "$CM" != "oai-nrue-config" ]; then
  echo "FAIL: this slice switch is restricted to protected ue1 only."
  echo "VERDICT=NOT_PROTECTED_UE1"
  exit 0
fi

case "$SST" in 1|2|3|4) : ;; *) echo "FAIL: SST must be 1..4 (subscribed slices)"; echo "VERDICT=INVALID_SST"; exit 0 ;; esac

BEFORE_DU="$(ue_serveraddr_from_cm "$NS" "$CM")"
echo "DU target (must not change): $BEFORE_DU"

TMP="/tmp/$CM.slice.conf.$$"
kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' > "$TMP" 2>/dev/null
if [ ! -s "$TMP" ]; then
  echo "FAIL: could not read $CM nr-ue.conf"; echo "VERDICT=CONFIGMAP_READ_FAILED"; exit 0
fi

IMSI="$(sed -n 's/.*imsi[[:space:]]*=[[:space:]]*"\([0-9]*\)".*/\1/p' "$TMP" | head -1)"
[ -z "$IMSI" ] && { echo "FAIL: could not parse IMSI from UE config"; echo "VERDICT=IMSI_PARSE_FAILED"; exit 0; }
echo "IMSI: $IMSI"

# --- 1) UE config: write LEGACY slice keys (replace pdu_sessions block if present) ---
python3 - "$TMP" "$SST" "$SD" <<'PY'
import sys, re
path, sst, sd = sys.argv[1:4]
text = open(path, encoding="utf-8", errors="ignore").read()
legacy = f'dnn = "oai";\n  nssai_sst = {sst};\n  nssai_sd = {sd};'
text2, n = re.subn(r'pdu_sessions\s*=\s*\(\{[^}]*\}\);', legacy, text)
if n == 0:
    text2 = re.sub(r'nssai_sst\s*=\s*[^;,\n}]+', f'nssai_sst = {sst}', text)
    text2 = re.sub(r'nssai_sd\s*=\s*[^;,\n}]+', f'nssai_sd = {sd}', text2)
open(path, "w", encoding="utf-8").write(text2)
print(f"UE config: slice keys set (legacy syntax), pdu_sessions blocks replaced: {n}")
PY

PAYLOAD="$(python3 - "$TMP" <<'PY'
import sys, json
print(json.dumps({"data": {"nr-ue.conf": open(sys.argv[1], encoding="utf-8").read()}}))
PY
)"
kubectl -n "$NS" patch cm "$CM" --type merge -p "$PAYLOAD" >/dev/null || { echo "VERDICT=CONFIGMAP_PATCH_FAILED"; exit 0; }

AFTER_DU="$(ue_serveraddr_from_cm "$NS" "$CM")"
[ "$BEFORE_DU" != "$AFTER_DU" ] && { echo "FAIL: serveraddr changed during slice switch."; echo "VERDICT=DU_TARGET_CHANGED_UNSAFE"; exit 0; }

# --- 2) MongoDB: make target slice the subscriber default (required: UE sends no Requested NSSAI) ---
MONGO="$(kubectl -n "$NS_CORE" get pod -o name | grep -i mongo | head -1)"
[ -z "$MONGO" ] && { echo "FAIL: no mongodb pod found in $NS_CORE"; echo "VERDICT=MONGO_NOT_FOUND"; exit 0; }
MONGO="${MONGO#pod/}"

mongo_eval(){
  kubectl -n "$NS_CORE" exec "$MONGO" -- mongosh --quiet open5gs --eval "$1" 2>/dev/null \
  || kubectl -n "$NS_CORE" exec "$MONGO" -- mongo --quiet open5gs --eval "$1"
}
mongo_eval "db.subscribers.updateOne({imsi:\"$IMSI\"},{\$set:{\"slice.\$[].default_indicator\":false}})" >/dev/null
mongo_eval "db.subscribers.updateOne({imsi:\"$IMSI\"},{\$set:{\"slice.\$[t].default_indicator\":true}},{arrayFilters:[{\"t.sst\":$SST}]})" >/dev/null
DEFNOW="$(mongo_eval "db.subscribers.findOne({imsi:\"$IMSI\"}).slice.filter(s=>s.default_indicator).map(s=>s.sst)" | tr -d '[] \r')"
echo "Subscriber default slice now: SST=$DEFNOW"
[ "$DEFNOW" = "$SST" ] || { echo "FAIL: Mongo default flip did not land"; echo "VERDICT=MONGO_DEFAULT_FLIP_FAILED"; exit 0; }

# --- 3) Restart UE and wait for tunnel ---
kubectl -n "$NS" rollout restart deploy/"$DEP" >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/"$DEP" --timeout=300s
RESULT="$(wait_exact_ue_tunnel "$NS" "$DEP" 240)"
POD="${RESULT%%|*}"; TUN="${RESULT##*|}"
if [ -z "$POD" ] || [ -z "$TUN" ]; then
  echo "FAIL: ue1 tunnel not ready after slice switch"
  echo "Hint: check UE log for 'NSSAI parameters not match with allowed NSSAI'"
  echo "VERDICT=SLICE_SWITCH_TUNNEL_FAILED"
  exit 0
fi
echo "Tunnel ready: pod=$POD tunnel=$TUN"

# --- 4) THE REAL CHECK: what slice did the core actually GRANT? ---
sleep 3
GRANTED="$(kubectl -n "$NS_CORE" logs deploy/open5gs-amf --tail=200 2>/dev/null \
  | grep "imsi-$IMSI" | grep -o 'S_NSSAI\[SST:[0-9]*' | tail -1 | grep -o '[0-9]*$')"
echo "AMF granted: SST=${GRANTED:-unknown}  (requested SST=$SST)"
if [ "$GRANTED" = "$SST" ]; then
  echo "PASS: core granted the requested slice (AMF S_NSSAI evidence)"
  echo "VERDICT=REAL_SLICE_SWITCH_OK"
else
  echo "FAIL: tunnel is up but the granted slice does not match the request"
  echo "VERDICT=GRANTED_SLICE_MISMATCH"
fi
