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
