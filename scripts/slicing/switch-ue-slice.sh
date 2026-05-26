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
