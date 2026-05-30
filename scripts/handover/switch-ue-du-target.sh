#!/usr/bin/env bash
set +e
set +u

NS="${NS:-oran-ran}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"
UE="${1:-}"
TARGET="${2:-}"

usage() {
  echo "Usage:"
  echo "  $0 ue1 du0|du1"
  echo "  $0 ue2 du0|du1"
  echo "  $0 ue3 du0|du1"
  echo "  $0 ue4 du0|du1"
  echo "  $0 ue5 du0|du1"
  echo
  echo "Rule:"
  echo "  DU switch changes only RFsim serveraddr."
  echo "  Slice switch changes only nssai_sst / nssai_sd."
}

if [ -z "$UE" ] || [ -z "$TARGET" ]; then
  usage
  echo "VERDICT=INVALID_ARGUMENTS"
  exit 0
fi

case "$UE" in
  ue1) CM="oai-nrue-config"; DEP="oai-nr-ue" ;;
  ue2) CM="oai-nrue-config-2"; DEP="oai-nr-ue-2" ;;
  ue3) CM="oai-nrue-config-3"; DEP="oai-nr-ue-3" ;;
  ue4) CM="oai-nrue-config-4"; DEP="oai-nr-ue-4" ;;
  ue5) CM="oai-nrue-config-5"; DEP="oai-nr-ue-5" ;;
  *)
    echo "Unsupported UE: $UE"
    echo "VERDICT=INVALID_UE"
    exit 0
    ;;
esac

case "$TARGET" in
  du0) RFSIM_TARGET="oai-du0-rfsim" ;;
  du1) RFSIM_TARGET="oai-du1-rfsim" ;;
  *)
    echo "Unsupported DU target: $TARGET"
    echo "VERDICT=INVALID_DU_TARGET"
    exit 0
    ;;
esac

if [ -f "$REPO/scripts/ue/ue-common.sh" ]; then
  source "$REPO/scripts/ue/ue-common.sh"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups/du-switch-$UE-$TARGET-$STAMP}"
mkdir -p "$BACKUP_DIR"

selector_for_dep() {
  local dep="$1"
  kubectl -n "$NS" get deploy "$dep" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d=json.load(sys.stdin)
    labels=d.get("spec",{}).get("selector",{}).get("matchLabels",{})
    print(",".join([f"{k}={v}" for k,v in labels.items()]))
except Exception:
    print("")
'
}

pod_for_dep() {
  local dep="$1"
  local selector=""
  selector="$(selector_for_dep "$dep")"
  [ -z "$selector" ] && echo "" && return

  kubectl -n "$NS" get pods -l "$selector" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d=json.load(sys.stdin)
    for p in d.get("items", []):
        name=p.get("metadata",{}).get("name","")
        phase=p.get("status",{}).get("phase","")
        deletion=p.get("metadata",{}).get("deletionTimestamp")
        if phase=="Running" and not deletion:
            print(name)
            break
except Exception:
    pass
'
}

serveraddr_from_cm() {
  kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null | python3 -c '
import sys, re
text=sys.stdin.read()
m=re.search(r"serveraddr\s*=\s*\"([^\"]+)\"", text)
if not m:
    m=re.search(r"serveraddr\s*=\s*([A-Za-z0-9_.-]+)", text)
print(m.group(1) if m else "")
'
}

slice_from_cm() {
  if command -v ue_slice_from_cm >/dev/null 2>&1; then
    ue_slice_from_cm "$NS" "$CM"
    return
  fi

  kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null | python3 -c '
import sys, re
text=sys.stdin.read()
sst=re.search(r"nssai_sst\s*=\s*([^;,\n}]+)", text)
sd=re.search(r"nssai_sd\s*=\s*([^;,\n}]+)", text)
sst_val=sst.group(1).strip() if sst else "unknown"
sd_val=sd.group(1).strip() if sd else "unknown"
print("nssai_sst={} nssai_sd={}".format(sst_val, sd_val))
'
}

echo "Switching $UE to $RFSIM_TARGET"
echo "ConfigMap: $CM"
echo "Deployment: $DEP"
echo "Backup dir: $BACKUP_DIR"

BEFORE_DU="$(serveraddr_from_cm)"
BEFORE_SLICE="$(slice_from_cm)"

echo "Before DU target: $BEFORE_DU"
echo "Before slice: $BEFORE_SLICE"

kubectl -n "$NS" get cm "$CM" -o yaml > "$BACKUP_DIR/$CM.before.yaml" 2>/dev/null
kubectl -n "$NS" get deploy "$DEP" -o yaml > "$BACKUP_DIR/$DEP.before.yaml" 2>/dev/null

TMP="/tmp/$CM.du-switch.$STAMP.conf"
kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' > "$TMP" 2>/dev/null

if [ ! -s "$TMP" ]; then
  echo "FAIL: could not read $CM"
  echo "VERDICT=CONFIGMAP_READ_FAILED"
  exit 0
fi

python3 - "$TMP" "$RFSIM_TARGET" <<'PY'
import sys, re
path, target = sys.argv[1:3]
text = open(path, encoding="utf-8", errors="ignore").read()

# DU switch only: change serveraddr, never nssai_sst/nssai_sd.
text2 = re.sub(
    r'(serveraddr\s*=\s*)("[^"]*"|[A-Za-z0-9_.-]+)',
    r'\1"' + target + r'"',
    text
)

open(path, "w", encoding="utf-8").write(text2)
PY

PAYLOAD="$(python3 - "$TMP" <<'PY'
import sys, json
data=open(sys.argv[1], encoding="utf-8").read()
print(json.dumps({"data":{"nr-ue.conf":data}}))
PY
)"

kubectl -n "$NS" patch cm "$CM" --type merge -p "$PAYLOAD" >/tmp/patch-$CM.log 2>&1
if [ $? -eq 0 ]; then
  echo "PASS: $CM patched"
else
  echo "FAIL: $CM patch failed"
  cat /tmp/patch-$CM.log
fi

DEP_JSON="/tmp/$DEP.du-switch.$STAMP.json"
OPS="/tmp/$DEP.du-switch.ops.$STAMP.json"

kubectl -n "$NS" get deploy "$DEP" -o json > "$DEP_JSON" 2>/dev/null

python3 - "$DEP_JSON" "$RFSIM_TARGET" > "$OPS" <<'PY'
import sys, json
path, target = sys.argv[1:3]
d=json.load(open(path))
ops=[]
wrong=["oai-du0-rfsim","oai-du1-rfsim","oai-gnb-rfsim","oai-gnb-b-rfsim"]

for ci,c in enumerate(d.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])):
    for field in ["command","args"]:
        arr=c.get(field)
        if not isinstance(arr,list):
            continue
        for i,val in enumerate(arr):
            if not isinstance(val,str):
                continue
            new=val
            for old in wrong:
                new=new.replace(old,target)
            if val.startswith("--rfsimulator.serveraddr="):
                new="--rfsimulator.serveraddr="+target
            if val == "--rfsimulator.serveraddr" and i+1 < len(arr):
                if arr[i+1] != target:
                    ops.append({"op":"replace","path":f"/spec/template/spec/containers/{ci}/{field}/{i+1}","value":target})
            if new != val:
                ops.append({"op":"replace","path":f"/spec/template/spec/containers/{ci}/{field}/{i}","value":new})
print(json.dumps(ops))
PY

if grep -q '^\[\]$' "$OPS"; then
  echo "INFO: $DEP args already target $RFSIM_TARGET"
else
  kubectl -n "$NS" patch deploy "$DEP" --type=json -p "$(cat "$OPS")" >/tmp/patch-$DEP-args.log 2>&1
  if [ $? -eq 0 ]; then
    echo "PASS: $DEP args patched"
  else
    echo "FAIL: $DEP args patch failed"
    cat /tmp/patch-$DEP-args.log
  fi
fi

AFTER_DU_PATCH="$(serveraddr_from_cm)"
AFTER_SLICE_PATCH="$(slice_from_cm)"

echo "After DU patch target: $AFTER_DU_PATCH"
echo "After DU patch slice: $AFTER_SLICE_PATCH"

if [ "$BEFORE_SLICE" != "$AFTER_SLICE_PATCH" ]; then
  echo "FAIL: slice changed during DU switch"
  echo "VERDICT=DU_SWITCH_CHANGED_SLICE_UNSAFE"
  exit 0
fi

kubectl -n "$NS" scale deploy/"$DEP" --replicas=0 >/dev/null 2>&1
sleep 8
kubectl -n "$NS" scale deploy/"$DEP" --replicas=1 >/dev/null 2>&1
kubectl -n "$NS" rollout restart deploy/"$DEP" >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/"$DEP" --timeout=300s >/tmp/rollout-$DEP.log 2>&1

cat /tmp/rollout-$DEP.log

FOUND=0
i=0
while [ $i -lt 240 ]; do
  POD="$(pod_for_dep "$DEP")"
  if [ -n "$POD" ]; then
    TUN="$(kubectl -n "$NS" exec "$POD" -- bash -lc 'ip -4 addr show oaitun_ue1 2>/dev/null | awk "/inet /{print \$2; exit}"' 2>/dev/null)"
    if [ -n "$TUN" ]; then
      echo "PASS: $UE attached after DU switch: pod=$POD tunnel=$TUN"
      FOUND=1
      break
    fi
  fi
  sleep 2
  i=$((i+2))
done

FINAL_DU="$(serveraddr_from_cm)"
FINAL_SLICE="$(slice_from_cm)"

echo "Final DU target: $FINAL_DU"
echo "Final slice: $FINAL_SLICE"

if [ "$BEFORE_SLICE" != "$FINAL_SLICE" ]; then
  echo "FAIL: final slice changed during DU switch"
  echo "VERDICT=DU_SWITCH_CHANGED_SLICE_UNSAFE"
  exit 0
fi

if [ "$FOUND" = "1" ]; then
  echo "VERDICT=UE_DU_SWITCH_OK"
else
  echo "FAIL: $UE did not attach after switch"
  echo "VERDICT=UE_DU_SWITCH_FAILED"
fi
