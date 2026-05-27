#!/usr/bin/env bash
set -euo pipefail

NS_CORE="${NS_CORE:-oran-core}"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
BASE="$HOME/oran-proof/phase4-qos-resource-profiles"
DIR="$BASE/$RUN_ID"
mkdir -p "$DIR"

echo "===== PHASE 4 APPLY PER-SLICE QOS / RESOURCE PROFILES ====="
echo "RUN_ID=$RUN_ID"
echo "DIR=$DIR"

echo
echo "===== 1. CREATE SAFETY TAG ====="
TAG="before-phase4-qos-resource-profiles-$RUN_ID"
git tag "$TAG" || true
echo "TAG=$TAG" | tee "$DIR/git-tag.txt"

echo
echo "===== 2. CHECK MONGO POD ====="
MONGO_POD="$(kubectl -n "$NS_CORE" get pods --no-headers | awk '/mongodb/ {print $1; exit}')"
[ -n "$MONGO_POD" ] || { echo "[FAIL] MongoDB pod not found"; exit 1; }
echo "MONGO_POD=$MONGO_POD" | tee "$DIR/mongo-pod.txt"

echo
echo "===== 3. BACKUP SUBSCRIBERS BEFORE PHASE 4 ====="
kubectl -n "$NS_CORE" exec "$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs --eval "JSON.stringify(db.subscribers.find({}).toArray(), null, 2)"
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs --eval "JSON.stringify(db.subscribers.find({}).toArray(), null, 2)"
  else
    echo "NO_MONGO_CLIENT"
    exit 1
  fi
' | tee "$DIR/subscribers-before-phase4.json" >/dev/null

echo
echo "===== 4. APPLY PER-SLICE QOS / AMBR / ARP PROFILES ====="

cat > "$DIR/apply-phase4-qos.js" <<'JS'
function session(name, dlValue, dlUnit, ulValue, ulUnit, fiveQi, arpPriority) {
  return {
    name: name,
    type: 3,
    ambr: {
      downlink: { value: dlValue, unit: dlUnit },
      uplink: { value: ulValue, unit: ulUnit }
    },
    qos: {
      index: fiveQi,
      arp: {
        priority_level: arpPriority,
        pre_emption_capability: 1,
        pre_emption_vulnerability: 1
      }
    }
  };
}

/*
Open5GS bitrate unit convention used here:
unit 2 = Mbps-level profile
unit 3 = Gbps-level profile

The values below create different subscriber QoS intentions per S-NSSAI.
The measurable traffic behavior is also enforced later with tc on oaitun_ue1.
*/

const slices = [
  {
    sst: 1,
    sd: "FFFFFF",
    default_indicator: true,
    session: [
      session("oai", 1, 3, 1, 3, 9, 8)       // eMBB: high AMBR, default 5QI 9
    ]
  },
  {
    sst: 2,
    sd: "FFFFFF",
    default_indicator: false,
    session: [
      session("oai", 100, 2, 100, 2, 80, 1)   // URLLC: high priority ARP, low-latency 5QI-style value
    ]
  },
  {
    sst: 3,
    sd: "FFFFFF",
    default_indicator: false,
    session: [
      session("oai", 1, 2, 1, 2, 9, 15)       // mMTC: very small AMBR, low priority
    ]
  },
  {
    sst: 4,
    sd: "FFFFFF",
    default_indicator: false,
    session: [
      session("oai", 50, 2, 50, 2, 79, 2)     // V2X: priority profile, continuity traffic
    ]
  }
];

const result = db.subscribers.updateMany(
  { imsi: /^99970/ },
  { $set: { slice: slices } }
);

print("PHASE4_UPDATE_RESULT");
printjson(result);

print("PHASE4_SUBSCRIBERS_AFTER");
printjson(db.subscribers.find({}, { imsi: 1, slice: 1 }).toArray());
JS

kubectl -n "$NS_CORE" cp "$DIR/apply-phase4-qos.js" "$MONGO_POD:/tmp/apply-phase4-qos.js"

kubectl -n "$NS_CORE" exec "$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs /tmp/apply-phase4-qos.js
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs /tmp/apply-phase4-qos.js
  else
    echo "NO_MONGO_CLIENT"
    exit 1
  fi
' | tee "$DIR/subscriber-qos-update-result.txt"

echo
echo "===== 5. RESTART POLICY / SESSION FUNCTIONS IF PRESENT ====="
for deploy in open5gs-pcf open5gs-smf open5gs-amf; do
  if kubectl -n "$NS_CORE" get deploy "$deploy" >/dev/null 2>&1; then
    kubectl -n "$NS_CORE" rollout restart deploy/"$deploy"
  fi
done

for deploy in open5gs-pcf open5gs-smf open5gs-amf; do
  if kubectl -n "$NS_CORE" get deploy "$deploy" >/dev/null 2>&1; then
    kubectl -n "$NS_CORE" rollout status deploy/"$deploy" --timeout=180s
  fi
done

echo
echo "===== 6. CREATE ROLLBACK TO PHASE 3 SHARED-QOS SLICE PROFILE ====="
cat > "$HOME/oran-e2e-freeze/scripts/slicing/rollback-phase4-qos-resource-profiles.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail

NS_CORE="${NS_CORE:-oran-core}"

echo "===== ROLLBACK PHASE 4 QOS RESOURCE PROFILES TO PHASE 3 SHARED TEMPLATE ====="

MONGO_POD="$(kubectl -n "$NS_CORE" get pods --no-headers | awk '/mongodb/ {print $1; exit}')"
[ -n "$MONGO_POD" ] || { echo "[FAIL] MongoDB pod not found"; exit 1; }

cat > /tmp/rollback-phase4-qos.js <<'JS'
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

printjson(db.subscribers.updateMany({ imsi: /^99970/ }, { $set: { slice: slices } }));
printjson(db.subscribers.find({}, { imsi: 1, slice: 1 }).toArray());
JS

kubectl -n "$NS_CORE" cp /tmp/rollback-phase4-qos.js "$MONGO_POD:/tmp/rollback-phase4-qos.js"

kubectl -n "$NS_CORE" exec "$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs /tmp/rollback-phase4-qos.js
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs /tmp/rollback-phase4-qos.js
  else
    echo "NO_MONGO_CLIENT"
    exit 1
  fi
'

for deploy in open5gs-pcf open5gs-smf open5gs-amf; do
  if kubectl -n "$NS_CORE" get deploy "$deploy" >/dev/null 2>&1; then
    kubectl -n "$NS_CORE" rollout restart deploy/"$deploy"
    kubectl -n "$NS_CORE" rollout status deploy/"$deploy" --timeout=180s
  fi
done

echo "Rollback complete."
ROLLBACK

chmod +x "$HOME/oran-e2e-freeze/scripts/slicing/rollback-phase4-qos-resource-profiles.sh"

echo
echo "===== 7. SUMMARY ====="
cat > "$DIR/summary.txt" <<EOF
Phase 4 QoS/resource profiles applied.

Control-plane subscriber profiles:
- eMBB SST=1: high AMBR, 5QI/index 9, ARP priority 8
- URLLC SST=2: 100 Mbps AMBR, 5QI/index 80, ARP priority 1
- mMTC SST=3: 1 Mbps AMBR, 5QI/index 9, ARP priority 15
- V2X SST=4: 50 Mbps AMBR, 5QI/index 79, ARP priority 2

Safety tag:
$TAG

Proof directory:
$DIR

Rollback:
scripts/slicing/rollback-phase4-qos-resource-profiles.sh
EOF

cat "$DIR/summary.txt"

echo
echo "===== PHASE 4 QOS PROFILE APPLY DONE ====="
