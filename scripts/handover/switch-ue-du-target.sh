#!/usr/bin/env bash
set +e
set +u

NS="${NS:-oran-ran}"
UE="${1:-}"
TARGET="${2:-}"

usage() {
  echo "Usage:"
  echo "  $0 ue1 du0|du1   (ue1 is the reference UE; DU0 is its baseline home)"
  echo "  $0 ue2 du0|du1"
  echo "  $0 ue3 du0|du1"
  echo "  $0 ue4 du0|du1"
  echo "  $0 ue5 du0|du1"
  echo
  echo "Note:"
  echo "  All UEs (ue1-ue5) are DU-switchable between DU0 and DU1."
}

if [ -z "$UE" ] || [ -z "$TARGET" ]; then
  usage
  echo "VERDICT=INVALID_ARGUMENTS"
  exit 0
fi

case "$UE" in
  ue1) CM="oai-nrue-config";   DEP="oai-nr-ue"   ;;
  ue2) CM="oai-nrue-config-2"; DEP="oai-nr-ue-2" ;;
  ue3) CM="oai-nrue-config-3"; DEP="oai-nr-ue-3" ;;
  ue4) CM="oai-nrue-config-4"; DEP="oai-nr-ue-4" ;;
  ue5) CM="oai-nrue-config-5"; DEP="oai-nr-ue-5" ;;
  *)
    echo "Unsupported UE: $UE"
    usage
    echo "VERDICT=INVALID_UE"
    exit 0
    ;;
esac

case "$TARGET" in
  du0) RFSIM_TARGET="oai-du0-rfsim" ;;
  du1) RFSIM_TARGET="oai-du1-rfsim" ;;
  *)
    echo "Unsupported target: $TARGET"
    usage
    echo "VERDICT=INVALID_DU_TARGET"
    exit 0
    ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups/du-switch-$UE-$TARGET-$STAMP}"
mkdir -p "$BACKUP_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; }
info() { echo "INFO: $*"; }

selector_for_dep() {
  local dep="$1"
  kubectl -n "$NS" get deploy "$dep" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    labels = d.get("spec", {}).get("selector", {}).get("matchLabels", {})
    print(",".join([f"{k}={v}" for k, v in labels.items()]))
except Exception:
    print("")
'
}

pod_for_dep() {
  local dep="$1"
  local selector=""
  selector="$(selector_for_dep "$dep")"
  if [ -z "$selector" ]; then
    echo ""
    return
  fi
  kubectl -n "$NS" get pods -l "$selector" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for p in d.get("items", []):
        name = p.get("metadata", {}).get("name", "")
        phase = p.get("status", {}).get("phase", "")
        deletion = p.get("metadata", {}).get("deletionTimestamp")
        if phase == "Running" and not deletion:
            print(name)
            break
except Exception:
    pass
'
}

echo "Switching $UE to $RFSIM_TARGET in namespace $NS"
echo "Backup dir: $BACKUP_DIR"

kubectl -n "$NS" get cm "$CM" -o yaml > "$BACKUP_DIR/$CM.before.yaml" 2>/dev/null
kubectl -n "$NS" get deploy "$DEP" -o yaml > "$BACKUP_DIR/$DEP.before.yaml" 2>/dev/null

TMP="/tmp/$CM.du-switch.$STAMP.conf"
kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' > "$TMP" 2>/dev/null

if [ ! -s "$TMP" ]; then
  fail "Could not read $CM nr-ue.conf"
  echo "VERDICT=CONFIGMAP_READ_FAILED"
  exit 0
fi

python3 - "$TMP" "$RFSIM_TARGET" <<'PY'
import sys, re

path = sys.argv[1]
target = sys.argv[2]

text = open(path, encoding="utf-8", errors="ignore").read()

for old in ["oai-du0-rfsim", "oai-du1-rfsim", "oai-gnb-rfsim", "oai-gnb-b-rfsim"]:
    text = text.replace(old, target)

text = re.sub(r'nssai_sst\s*=\s*[^;,\n}]+', 'nssai_sst = 1', text)
text = re.sub(r'nssai_sd\s*=\s*[^;,\n}]+', 'nssai_sd = 0xffffff', text)
text = re.sub(
    r'(serveraddr\s*=\s*)("[^"]*"|[A-Za-z0-9_.-]+)',
    r'\1"' + target + r'"',
    text
)

open(path, "w", encoding="utf-8").write(text)
PY

PAYLOAD="$(python3 - "$TMP" <<'PY'
import sys, json
data = open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"data": {"nr-ue.conf": data}}))
PY
)"

kubectl -n "$NS" patch cm "$CM" --type merge -p "$PAYLOAD" >/tmp/patch-$CM.log 2>&1
if [ $? -eq 0 ]; then
  pass "$CM patched"
else
  fail "$CM patch failed"
  cat /tmp/patch-$CM.log
fi

DEP_JSON="/tmp/$DEP.du-switch.$STAMP.json"
OPS="/tmp/$DEP.du-switch.ops.$STAMP.json"

kubectl -n "$NS" get deploy "$DEP" -o json > "$DEP_JSON" 2>/dev/null

python3 - "$DEP_JSON" "$RFSIM_TARGET" > "$OPS" <<'PY'
import sys, json

path = sys.argv[1]
target = sys.argv[2]
d = json.load(open(path))
ops = []
wrong = ["oai-du0-rfsim", "oai-du1-rfsim", "oai-gnb-rfsim", "oai-gnb-b-rfsim"]

for ci, c in enumerate(d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])):
    for field in ["command", "args"]:
        arr = c.get(field)
        if not isinstance(arr, list):
            continue

        for i, val in enumerate(arr):
            if not isinstance(val, str):
                continue

            new = val
            for old in wrong:
                new = new.replace(old, target)

            if val.startswith("--rfsimulator.serveraddr="):
                new = "--rfsimulator.serveraddr=" + target

            if val == "--rfsimulator.serveraddr" and i + 1 < len(arr):
                if arr[i + 1] != target:
                    ops.append({
                        "op": "replace",
                        "path": f"/spec/template/spec/containers/{ci}/{field}/{i+1}",
                        "value": target
                    })

            if new != val:
                ops.append({
                    "op": "replace",
                    "path": f"/spec/template/spec/containers/{ci}/{field}/{i}",
                    "value": new
                })

print(json.dumps(ops))
PY

if grep -q '^\[\]$' "$OPS"; then
  info "$DEP args already target $RFSIM_TARGET"
else
  kubectl -n "$NS" patch deploy "$DEP" --type=json -p "$(cat "$OPS")" >/tmp/patch-$DEP-args.log 2>&1
  if [ $? -eq 0 ]; then
    pass "$DEP args patched"
  else
    fail "$DEP args patch failed"
    cat /tmp/patch-$DEP-args.log
  fi
fi

kubectl -n "$NS" scale deploy/"$DEP" --replicas=0 >/dev/null 2>&1
sleep 8
kubectl -n "$NS" scale deploy/"$DEP" --replicas=1 >/dev/null 2>&1
kubectl -n "$NS" rollout restart deploy/"$DEP" >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/"$DEP" --timeout=180s >/tmp/rollout-$DEP.log 2>&1

if [ $? -eq 0 ]; then
  pass "$DEP rollout ready"
else
  fail "$DEP rollout not ready"
  cat /tmp/rollout-$DEP.log
fi

FOUND=0
i=0

while [ $i -lt 240 ]; do
  POD="$(pod_for_dep "$DEP")"
  if [ -n "$POD" ]; then
    TUN="$(kubectl -n "$NS" exec "$POD" -- bash -lc 'ip -4 addr show oaitun_ue1 2>/dev/null | awk "/inet /{print \$2; exit}"' 2>/dev/null)"
    if [ -n "$TUN" ]; then
      pass "$UE attached after switch: pod=$POD tunnel=$TUN"
      FOUND=1
      break
    fi
  fi
  sleep 2
  i=$((i+2))
done

if [ "$FOUND" = "1" ]; then
  echo "VERDICT=UE_DU_SWITCH_OK"
else
  fail "$UE did not attach after switch"
  echo "VERDICT=UE_DU_SWITCH_FAILED"
fi
