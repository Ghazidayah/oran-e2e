#!/usr/bin/env bash
set -euo pipefail

echo "===== ROLLBACK REAL S-NSSAI SLICING ====="
echo "Backup source: /home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup"

kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/open5gs-amf-cm.yaml"
kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/open5gs-smf-cm.yaml"
kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/open5gs-nssf-cm.yaml"
kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/oai-cu-f1-config-cm.yaml"
kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/oai-du0-f1-config-cm.yaml"
kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/oai-du1-f1-config-cm.yaml"
kubectl apply -f "/home/ghazi/oran-proof/phase3-real-snssai-apply/20260526-021239/backup/oai-nrue-config-cm.yaml"

MONGO_POD="$(kubectl -n "oran-core" get pods --no-headers | awk '/mongodb/ {print $1; exit}')"
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

printjson(db.subscribers.updateMany({ imsi: /^99970/ }, { $set: { slice: slices } }));
printjson(db.subscribers.find({}, { imsi: 1, slice: 1 }).toArray());
JS

kubectl -n "oran-core" cp /tmp/rollback-subscriber-slices.js "$MONGO_POD:/tmp/rollback-subscriber-slices.js"
kubectl -n "oran-core" exec "$MONGO_POD" -- sh -lc '
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet open5gs /tmp/rollback-subscriber-slices.js
  elif command -v mongo >/dev/null 2>&1; then
    mongo --quiet open5gs /tmp/rollback-subscriber-slices.js
  fi
'

kubectl -n "oran-core" rollout restart deploy/open5gs-amf deploy/open5gs-smf deploy/open5gs-nssf
kubectl -n "oran-core" rollout status deploy/open5gs-amf --timeout=180s
kubectl -n "oran-core" rollout status deploy/open5gs-smf --timeout=180s
kubectl -n "oran-core" rollout status deploy/open5gs-nssf --timeout=180s

kubectl -n "oran-ran" rollout restart deploy/oai-cu-cp deploy/oai-cu-up deploy/oai-du0 deploy/oai-nr-ue
kubectl -n "oran-ran" rollout status deploy/oai-cu-cp --timeout=180s
kubectl -n "oran-ran" rollout status deploy/oai-cu-up --timeout=180s
kubectl -n "oran-ran" rollout status deploy/oai-du0 --timeout=180s
kubectl -n "oran-ran" rollout status deploy/oai-nr-ue --timeout=180s

echo "Rollback complete."
