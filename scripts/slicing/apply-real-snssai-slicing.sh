#!/usr/bin/env bash

# DU-aware safety guard.
#
# This installer/generator predates the Mixed-DU architecture.
# It can overwrite DU-aware runtime scripts such as:
#   scripts/slicing/switch-ue-slice.sh
#   scripts/slicing/validate-current-slice.sh
#
# The validated runtime scripts are now committed separately.
# To intentionally rerun this legacy generator, set:
#   ALLOW_LEGACY_SNSSAI_GENERATOR=1
if [ "${ALLOW_LEGACY_SNSSAI_GENERATOR:-0}" != "1" ]; then
  echo "BLOCKED: legacy real S-NSSAI generator is disabled by default."
  echo "Reason: it may overwrite DU-aware Phase 3 / Phase 4 / E2E runtime scripts."
  echo "Use the committed DU-aware runtime scripts instead."
  echo "To force this legacy generator, rerun with ALLOW_LEGACY_SNSSAI_GENERATOR=1."
  echo "VERDICT=LEGACY_SNSSAI_GENERATOR_BLOCKED"
  exit 0
fi


set -euo pipefail

NS_CORE="${NS_CORE:-oran-core}"
NS_RAN="${NS_RAN:-oran-ran}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
BASE="$HOME/oran-proof/phase3-real-snssai-apply"
DIR="$BASE/$RUN_ID"
WORK="$DIR/work"
BACKUP="$DIR/backup"

mkdir -p "$WORK" "$BACKUP"

echo "===== APPLY REAL S-NSSAI SLICING SUPPORT ====="
echo "RUN_ID=$RUN_ID"
echo "DIR=$DIR"
echo "WORK=$WORK"
echo "BACKUP=$BACKUP"

extract_cm_key() {
  local ns="$1"
  local cm="$2"
  local key="$3"
  local out="$4"

  kubectl -n "$ns" get cm "$cm" -o json \
    | python3 -c 'import sys,json; key=sys.argv[1]; data=json.load(sys.stdin).get("data",{}); sys.stdout.write(data.get(key,""))' "$key" \
    > "$out"

  [ -s "$out" ] || {
    echo "[FAIL] Empty extraction: $ns/$cm key=$key"
    exit 1
  }
}

apply_cm_key() {
  local ns="$1"
  local cm="$2"
  local key="$3"
  local file="$4"

  echo "Applying $ns/$cm key=$key from $file"

  kubectl -n "$ns" create configmap "$cm" \
    --from-file="$key=$file" \
    --dry-run=client -o yaml | kubectl apply -f -
}

echo
echo "===== 1. BACKUP LIVE CONFIGMAPS ====="
kubectl -n "$NS_CORE" get cm open5gs-amf -o yaml > "$BACKUP/open5gs-amf-cm.yaml"
kubectl -n "$NS_CORE" get cm open5gs-smf -o yaml > "$BACKUP/open5gs-smf-cm.yaml"
kubectl -n "$NS_CORE" get cm open5gs-nssf -o yaml > "$BACKUP/open5gs-nssf-cm.yaml"

kubectl -n "$NS_RAN" get cm oai-cu-f1-config -o yaml > "$BACKUP/oai-cu-f1-config-cm.yaml"
kubectl -n "$NS_RAN" get cm oai-du0-f1-config -o yaml > "$BACKUP/oai-du0-f1-config-cm.yaml"
kubectl -n "$NS_RAN" get cm oai-du1-f1-config -o yaml > "$BACKUP/oai-du1-f1-config-cm.yaml"
kubectl -n "$NS_RAN" get cm oai-nrue-config -o yaml > "$BACKUP/oai-nrue-config-cm.yaml"

echo
echo "===== 2. EXTRACT CURRENT LIVE CONFIGS ====="
extract_cm_key "$NS_CORE" open5gs-amf amf.yaml "$WORK/amf.yaml"
extract_cm_key "$NS_CORE" open5gs-smf smf.yaml "$WORK/smf.yaml"
extract_cm_key "$NS_CORE" open5gs-nssf nssf.yaml "$WORK/nssf.yaml"

extract_cm_key "$NS_RAN" oai-cu-f1-config gnb.conf "$WORK/oai-cu.conf"
extract_cm_key "$NS_RAN" oai-du0-f1-config gnb.conf "$WORK/oai-du0.conf"
extract_cm_key "$NS_RAN" oai-du1-f1-config gnb.conf "$WORK/oai-du1.conf"
extract_cm_key "$NS_RAN" oai-nrue-config nr-ue.conf "$WORK/nr-ue.conf"

cp "$WORK/amf.yaml" "$BACKUP/amf.yaml"
cp "$WORK/smf.yaml" "$BACKUP/smf.yaml"
cp "$WORK/nssf.yaml" "$BACKUP/nssf.yaml"
cp "$WORK/oai-cu.conf" "$BACKUP/oai-cu.conf"
cp "$WORK/oai-du0.conf" "$BACKUP/oai-du0.conf"
cp "$WORK/oai-du1.conf" "$BACKUP/oai-du1.conf"
cp "$WORK/nr-ue.conf" "$BACKUP/nr-ue.conf"

echo
echo "===== 3. PATCH AMF / SMF / NSSF / RAN CONFIGS ====="
python3 - "$WORK" <<'PY'
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])

# AMF: allow SST 1/2/3/4 for PLMN 999/70.
amf = (work / "amf.yaml").read_text()

amf_new_block = '''  plmn_support:
    -
      plmn_id:
        mcc: "999"
        mnc: "70"
      s_nssai:
      - sst: 1
      - sst: 2
      - sst: 3
      - sst: 4
'''

amf = re.sub(
    r'  plmn_support:\n    -\n      plmn_id:\n        mcc: "999"\n        mnc: "70"\n      s_nssai:\n(?:      - .*\n)+',
    amf_new_block,
    amf,
    count=1
)

(work / "amf.yaml").write_text(amf)

# SMF: advertise DNN=oai for SST 1/2/3/4 with SD 0xffffff.
smf = (work / "smf.yaml").read_text()

smf_new_info = '''  info:
    - s_nssai:
        - sst: 1
          sd: 0xffffff
          dnn:
            - oai
        - sst: 2
          sd: 0xffffff
          dnn:
            - oai
        - sst: 3
          sd: 0xffffff
          dnn:
            - oai
        - sst: 4
          sd: 0xffffff
          dnn:
            - oai
'''

smf = re.sub(
    r'  info:\n    - s_nssai:\n        - sst: 1\n          sd: 0xffffff\n          dnn:\n            - oai\n',
    smf_new_info,
    smf,
    count=1
)

(work / "smf.yaml").write_text(smf)

# NSSF: map SST 1/2/3/4 to NRF/SCP path.
nssf = (work / "nssf.yaml").read_text()

nssf_new_nsi = '''      nsi:
      - uri: http://open5gs-nrf-sbi:7777
        s_nssai:
          sst: "1"
          sd: "0xffffff"
      - uri: http://open5gs-nrf-sbi:7777
        s_nssai:
          sst: "2"
          sd: "0xffffff"
      - uri: http://open5gs-nrf-sbi:7777
        s_nssai:
          sst: "3"
          sd: "0xffffff"
      - uri: http://open5gs-nrf-sbi:7777
        s_nssai:
          sst: "4"
          sd: "0xffffff"
'''

nssf = re.sub(
    r'      nsi:\n      - uri: http://open5gs-nrf-sbi:7777\n        s_nssai:\n          sst: "1"\n          sd: "0xffffff"\n',
    nssf_new_nsi,
    nssf,
    count=1
)

(work / "nssf.yaml").write_text(nssf)

# OAI CU/DU: advertise supported slices SST 1/2/3/4.
new_snssai = 'snssaiList = ({ sst = 1; }, { sst = 2; }, { sst = 3; }, { sst = 4; })'

for name in ["oai-cu.conf", "oai-du0.conf", "oai-du1.conf"]:
    p = work / name
    text = p.read_text()
    text = re.sub(r'snssaiList = \(\{ sst = 1; \}\)', new_snssai, text, count=1)
    p.write_text(text)

# Keep UE on SST=1 for first validation.
ue = (work / "nr-ue.conf").read_text()
ue = re.sub(
    r'pdu_sessions = \(\{ dnn = "oai"; nssai_sst = \d+; nssai_sd = 0x[0-9a-fA-F]+; \}\);',
    'pdu_sessions = ({ dnn = "oai"; nssai_sst = 1; nssai_sd = 0xffffff; });',
    ue,
    count=1
)
(work / "nr-ue.conf").write_text(ue)
PY

echo
echo "===== 4. SHOW PATCHED SLICE LINES ====="
grep -nA15 -B3 "plmn_support" "$WORK/amf.yaml"
grep -nA25 -B3 "info:" "$WORK/smf.yaml" | head -n 60
grep -nA25 -B3 "nsi:" "$WORK/nssf.yaml" | head -n 60
grep -n "snssaiList\|plmn_list" "$WORK/oai-cu.conf" "$WORK/oai-du0.conf" "$WORK/oai-du1.conf"
grep -n "pdu_sessions" "$WORK/nr-ue.conf"

echo
echo "===== 5. APPLY PATCHED CONFIGMAPS ====="
apply_cm_key "$NS_CORE" open5gs-amf amf.yaml "$WORK/amf.yaml"
apply_cm_key "$NS_CORE" open5gs-smf smf.yaml "$WORK/smf.yaml"
apply_cm_key "$NS_CORE" open5gs-nssf nssf.yaml "$WORK/nssf.yaml"

apply_cm_key "$NS_RAN" oai-cu-f1-config gnb.conf "$WORK/oai-cu.conf"
apply_cm_key "$NS_RAN" oai-du0-f1-config gnb.conf "$WORK/oai-du0.conf"
apply_cm_key "$NS_RAN" oai-du1-f1-config gnb.conf "$WORK/oai-du1.conf"
apply_cm_key "$NS_RAN" oai-nrue-config nr-ue.conf "$WORK/nr-ue.conf"

echo
echo "===== 6. BACKUP AND PATCH OPEN5GS SUBSCRIBER DB ====="
MONGO_POD="$(kubectl -n "$NS_CORE" get pods --no-headers | awk '/mongodb/ {print $1; exit}')"
[ -n "$MONGO_POD" ] || { echo "[FAIL] MongoDB pod not found"; exit 1; }

echo "MONGO_POD=$MONGO_POD"

kubectl -n "$NS_CORE" exec "$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs --eval "JSON.stringify(db.subscribers.find({}).toArray(), null, 2)"
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs --eval "JSON.stringify(db.subscribers.find({}).toArray(), null, 2)"
  else
    echo "NO_MONGO_CLIENT"
  fi
' > "$BACKUP/subscribers-before.json"

cat > "$WORK/update-subscriber-slices.js" <<'JS'
const sessionTemplate = {
  name: "oai",
  type: 3,
  ambr: {
    downlink: { value: 1, unit: 3 },
    uplink: { value: 1, unit: 3 }
  },
  qos: {
    index: 9,
    arp: {
      priority_level: 8,
      pre_emption_capability: 1,
      pre_emption_vulnerability: 1
    }
  }
};

const slices = [1, 2, 3, 4].map((sst) => ({
  sst: sst,
  sd: "FFFFFF",
  default_indicator: sst === 1,
  session: [sessionTemplate]
}));

const result = db.subscribers.updateMany(
  { imsi: /^99970/ },
  { $set: { slice: slices } }
);

printjson(result);
print("Subscribers after update:");
printjson(db.subscribers.find({}, { imsi: 1, slice: 1 }).toArray());
JS

kubectl -n "$NS_CORE" cp "$WORK/update-subscriber-slices.js" "$MONGO_POD:/tmp/update-subscriber-slices.js"

kubectl -n "$NS_CORE" exec "$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs /tmp/update-subscriber-slices.js
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs /tmp/update-subscriber-slices.js
  else
    echo "NO_MONGO_CLIENT"
    exit 1
  fi
' | tee "$DIR/subscriber-update-result.txt"

echo
echo "===== 7. CREATE UE SLICE SWITCH SCRIPT ====="
cat > "$HOME/oran-e2e-freeze/scripts/slicing/switch-ue-slice.sh" <<'SWITCH'
#!/usr/bin/env bash
set -euo pipefail

SST="${1:-}"
SD="${2:-0xffffff}"
NS="${NS:-oran-ran}"
CM="${CM:-oai-nrue-config}"
KEY="${KEY:-nr-ue.conf}"

if [[ ! "$SST" =~ ^[1-4]$ ]]; then
  echo "Usage: $0 <sst:1|2|3|4> [sd_hex_default_0xffffff]"
  exit 1
fi

TMP="$(mktemp -d)"
OUT="$TMP/nr-ue.conf"

kubectl -n "$NS" get cm "$CM" -o json \
  | python3 -c 'import sys,json; key=sys.argv[1]; data=json.load(sys.stdin).get("data",{}); sys.stdout.write(data.get(key,""))' "$KEY" \
  > "$OUT"

python3 - "$OUT" "$SST" "$SD" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
sst = sys.argv[2]
sd = sys.argv[3]

text = path.read_text()
new = f'pdu_sessions = ({{ dnn = "oai"; nssai_sst = {sst}; nssai_sd = {sd}; }});'
text = re.sub(
    r'pdu_sessions = \(\{ dnn = "oai"; nssai_sst = \d+; nssai_sd = 0x[0-9a-fA-F]+; \}\);',
    new,
    text,
    count=1
)
path.write_text(text)
PY

kubectl -n "$NS" create configmap "$CM" \
  --from-file="$KEY=$OUT" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Restarting UE with SST=$SST SD=$SD"
kubectl -n "$NS" rollout restart deploy/oai-nr-ue
kubectl -n "$NS" rollout status deploy/oai-nr-ue --timeout=180s

echo "Current UE requested slice:"
kubectl -n "$NS" get cm "$CM" -o json \
  | python3 -c 'import sys,json; data=json.load(sys.stdin).get("data",{}); print(data.get("nr-ue.conf",""))' \
  | grep "pdu_sessions"
SWITCH

chmod +x "$HOME/oran-e2e-freeze/scripts/slicing/switch-ue-slice.sh"

echo
echo "===== 8. CREATE CURRENT SLICE VALIDATION SCRIPT ====="
cat > "$HOME/oran-e2e-freeze/scripts/slicing/validate-current-slice.sh" <<'VALIDATE'
#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
PROOF_BASE="${PROOF_BASE:-$HOME/oran-proof/phase3-real-snssai-validation}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$PROOF_BASE/$RUN_ID"
mkdir -p "$DIR"

UE="$(kubectl -n "$NS" get pods --no-headers | awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}')"
[ -n "$UE" ] || { echo "[FAIL] UE not running"; exit 1; }

echo "RUN_ID=$RUN_ID"
echo "DIR=$DIR"
echo "UE=$UE"

echo "===== UE CONFIG SLICE ====="
kubectl -n "$NS" get cm oai-nrue-config -o json \
  | python3 -c 'import sys,json; data=json.load(sys.stdin).get("data",{}); print(data.get("nr-ue.conf",""))' \
  | grep "pdu_sessions" | tee "$DIR/ue-requested-slice.txt"

echo "===== UE TUNNEL ====="
kubectl -n "$NS" exec "$UE" -- ip addr show oaitun_ue1 | tee "$DIR/oaitun.txt"

echo "===== UE ROUTE ====="
kubectl -n "$NS" exec "$UE" -- ip route | tee "$DIR/route.txt"

echo "===== PING INTERNET THROUGH TUNNEL ====="
kubectl -n "$NS" exec "$UE" -- ping -I oaitun_ue1 -c 4 8.8.8.8 | tee "$DIR/ping.txt"

echo "===== OAITUN COUNTERS ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-counters.txt"

echo "===== VALIDATION OK ====="
VALIDATE

chmod +x "$HOME/oran-e2e-freeze/scripts/slicing/validate-current-slice.sh"

echo
echo "===== 9. CREATE ROLLBACK SCRIPT ====="
cat > "$HOME/oran-e2e-freeze/scripts/slicing/rollback-real-snssai-slicing.sh" <<ROLLBACK
#!/usr/bin/env bash
set -euo pipefail

echo "===== ROLLBACK REAL S-NSSAI SLICING ====="
echo "Backup source: $BACKUP"

kubectl apply -f "$BACKUP/open5gs-amf-cm.yaml"
kubectl apply -f "$BACKUP/open5gs-smf-cm.yaml"
kubectl apply -f "$BACKUP/open5gs-nssf-cm.yaml"
kubectl apply -f "$BACKUP/oai-cu-f1-config-cm.yaml"
kubectl apply -f "$BACKUP/oai-du0-f1-config-cm.yaml"
kubectl apply -f "$BACKUP/oai-du1-f1-config-cm.yaml"
kubectl apply -f "$BACKUP/oai-nrue-config-cm.yaml"

MONGO_POD="\$(kubectl -n "$NS_CORE" get pods --no-headers | awk '/mongodb/ {print \$1; exit}')"
cat > /tmp/rollback-subscriber-slices.js <<'JS'
const sessionTemplate = {
  name: "oai",
  type: 3,
  ambr: {
    downlink: { value: 1, unit: 3 },
    uplink: { value: 1, unit: 3 }
  },
  qos: {
    index: 9,
    arp: {
      priority_level: 8,
      pre_emption_capability: 1,
      pre_emption_vulnerability: 1
    }
  }
};

const slices = [{
  sst: 1,
  sd: "FFFFFF",
  default_indicator: true,
  session: [sessionTemplate]
}];

printjson(db.subscribers.updateMany({ imsi: /^99970/ }, { \$set: { slice: slices } }));
printjson(db.subscribers.find({}, { imsi: 1, slice: 1 }).toArray());
JS

kubectl -n "$NS_CORE" cp /tmp/rollback-subscriber-slices.js "\$MONGO_POD:/tmp/rollback-subscriber-slices.js"
kubectl -n "$NS_CORE" exec "\$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs /tmp/rollback-subscriber-slices.js
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs /tmp/rollback-subscriber-slices.js
  fi
'

kubectl -n "$NS_CORE" rollout restart deploy/open5gs-amf deploy/open5gs-smf deploy/open5gs-nssf
kubectl -n "$NS_CORE" rollout status deploy/open5gs-amf --timeout=180s
kubectl -n "$NS_CORE" rollout status deploy/open5gs-smf --timeout=180s
kubectl -n "$NS_CORE" rollout status deploy/open5gs-nssf --timeout=180s

kubectl -n "$NS_RAN" rollout restart deploy/oai-cu deploy/oai-du0 deploy/oai-nr-ue
kubectl -n "$NS_RAN" rollout status deploy/oai-cu --timeout=180s
kubectl -n "$NS_RAN" rollout status deploy/oai-du0 --timeout=180s
kubectl -n "$NS_RAN" rollout status deploy/oai-nr-ue --timeout=180s

echo "Rollback complete."
ROLLBACK

chmod +x "$HOME/oran-e2e-freeze/scripts/slicing/rollback-real-snssai-slicing.sh"

echo
echo "===== 10. RESTART CORE SLICE FUNCTIONS ====="
kubectl -n "$NS_CORE" rollout restart deploy/open5gs-amf deploy/open5gs-smf deploy/open5gs-nssf
kubectl -n "$NS_CORE" rollout status deploy/open5gs-amf --timeout=180s
kubectl -n "$NS_CORE" rollout status deploy/open5gs-smf --timeout=180s
kubectl -n "$NS_CORE" rollout status deploy/open5gs-nssf --timeout=180s

echo
echo "===== 11. RESTART ACTIVE RAN / UE ====="
kubectl -n "$NS_RAN" rollout restart deploy/oai-cu deploy/oai-du0 deploy/oai-nr-ue
kubectl -n "$NS_RAN" rollout status deploy/oai-cu --timeout=180s
kubectl -n "$NS_RAN" rollout status deploy/oai-du0 --timeout=180s
kubectl -n "$NS_RAN" rollout status deploy/oai-nr-ue --timeout=180s

echo
echo "===== 12. VALIDATE BASELINE WITH UE STILL ON SST=1 ====="
"$HOME/oran-e2e-freeze/scripts/slicing/validate-current-slice.sh" | tee "$DIR/validate-sst1-after-apply.txt"

echo
echo "===== 13. SAVE SUMMARY ====="
cat > "$DIR/summary.txt" <<EOF
Phase 3 real S-NSSAI slicing support applied.

Applied:
- AMF allowed NSSAI: SST 1,2,3,4
- SMF info: SST 1,2,3,4 with SD 0xffffff and DNN=oai
- NSSF NSI: SST 1,2,3,4 with SD 0xffffff
- OAI CU/DU supported snssaiList: SST 1,2,3,4
- Open5GS subscriber DB updated with SST 1,2,3,4 for DNN=oai
- UE kept on SST=1 for first baseline validation

Proof directory:
$DIR

Rollback:
scripts/slicing/rollback-real-snssai-slicing.sh
EOF

cat "$DIR/summary.txt"

echo
echo "===== APPLY REAL S-NSSAI SUPPORT DONE ====="
