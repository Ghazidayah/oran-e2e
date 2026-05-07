#!/usr/bin/env bash
set -euo pipefail

SRC_IMSI="${SRC_IMSI:-999700000000001}"
IMSIS="${IMSIS:-999700000000001 999700000000002 999700000000003 999700000000004 999700000000005}"

MONGO_INFO=$(kubectl get pods -A --no-headers | awk 'tolower($2) ~ /mongo|mongodb/ {print $1" "$2; exit}')
MONGO_NS=$(echo "$MONGO_INFO" | awk '{print $1}')
MONGO_POD=$(echo "$MONGO_INFO" | awk '{print $2}')

if [ -z "${MONGO_NS:-}" ] || [ -z "${MONGO_POD:-}" ]; then
  echo "[ERROR] MongoDB pod not found"
  exit 1
fi

BACKUP_DIR="$HOME/oran-proof/open5gs-subscriber-backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/subscribers-before-5ue-$(date +%Y%m%d-%H%M%S).json"

echo "[INFO] MongoDB pod: $MONGO_NS/$MONGO_POD"
echo "[INFO] Backup file: $BACKUP_FILE"

kubectl exec -n "$MONGO_NS" "$MONGO_POD" -- sh -lc "
if command -v mongosh >/dev/null 2>&1; then
  mongosh --quiet open5gs --eval 'JSON.stringify(db.subscribers.find({}).toArray(), null, 2)'
elif command -v mongo >/dev/null 2>&1; then
  mongo open5gs --quiet --eval 'JSON.stringify(db.subscribers.find({}).toArray(), null, 2)'
else
  echo no mongo shell found
  exit 2
fi
" > "$BACKUP_FILE"

TMP_JS="/tmp/provision-5ue-subscribers.js"

cat > "$TMP_JS" <<'JS'
const srcImsi = "__SRC_IMSI__";
const imsies = "__IMSIS__".split(" ");

const src = db.subscribers.findOne({ imsi: srcImsi });
if (!src) {
  throw new Error("Source subscriber not found: " + srcImsi);
}

for (const imsi of imsies) {
  const doc = JSON.parse(JSON.stringify(src));
  delete doc._id;
  doc.imsi = imsi;

  db.subscribers.deleteMany({ imsi: imsi });
  db.subscribers.insertOne(doc);
  print("provisioned " + imsi);
}

printjson(db.subscribers.find(
  { imsi: { $in: imsies } },
  { _id: 0, imsi: 1, slice: 1 }
).sort({ imsi: 1 }).toArray());
JS

sed -i "s/__SRC_IMSI__/$SRC_IMSI/g" "$TMP_JS"
sed -i "s/__IMSIS__/$IMSIS/g" "$TMP_JS"

kubectl cp "$TMP_JS" "$MONGO_NS/$MONGO_POD:/tmp/provision-5ue-subscribers.js"

kubectl exec -n "$MONGO_NS" "$MONGO_POD" -- sh -lc "
if command -v mongosh >/dev/null 2>&1; then
  mongosh --quiet open5gs /tmp/provision-5ue-subscribers.js
elif command -v mongo >/dev/null 2>&1; then
  mongo open5gs --quiet /tmp/provision-5ue-subscribers.js
else
  echo no mongo shell found
  exit 2
fi
"

echo "[OK] subscriber provisioning complete"
echo "[INFO] Backup saved at: $BACKUP_FILE"
