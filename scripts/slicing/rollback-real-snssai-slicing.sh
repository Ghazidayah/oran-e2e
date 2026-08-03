#!/usr/bin/env bash

# OBSOLETE — pre-E1-split rollback. Disabled by default.
#
# This script restores a ConfigMap snapshot taken on 2026-05-26, before the
# CU was split into CU-CP / CU-UP. It cannot work as written:
#
#   * it hardcodes /home/ghazi/oran-proof/..., a path outside this repository
#     that is not part of any delivery;
#   * it applies oai-cu-f1-config-cm.yaml, and the ConfigMap oai-cu-f1-config
#     no longer exists (the current names are oai-cucp-config / oai-cuup-config);
#   * the snapshots carry a stale resourceVersion, so 6 of the 7 kubectl apply
#     calls fail with "Error from server (Conflict)" (verified 2026-08-02 with
#     kubectl apply --dry-run=server);
#   * line 59 restarts only oai-du0 and oai-nr-ue — neither DU1 nor UE2-UE5.
#
# With `set -euo pipefail` it therefore aborts on its first apply. It is kept
# for traceability only. To roll slicing back today, re-apply the intended
# S-NSSAI configuration through the normal path instead:
#
#   scripts/slicing/switch-ue-slice.sh 1 0xffffff
#
# To run this legacy script anyway (it will almost certainly fail), set:
#   ALLOW_LEGACY_SNSSAI_ROLLBACK=1
if [ "${ALLOW_LEGACY_SNSSAI_ROLLBACK:-0}" != "1" ]; then
  echo "BLOCKED: this rollback predates the E1 split and depends on a local"
  echo "snapshot that is not part of the repository. It cannot succeed."
  echo "Use scripts/slicing/switch-ue-slice.sh 1 0xffffff instead."
  echo "VERDICT=LEGACY_SNSSAI_ROLLBACK_BLOCKED"
  exit 0
fi

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
