#!/usr/bin/env bash
# Move one UE (ue1..ue5) to DU0 or DU1.
#
# What this does (and what the previous version did not):
#   1. Reads the TARGET DU carrier (absoluteFrequencySSB / band) from its F1 ConfigMap
#      and re-aligns the UE "-C" (and "--band", if the UE already has one). A UE can only
#      attach to a DU running on the same carrier; moving a UE without re-aligning "-C"
#      is what left ue1 stuck on "Got NACK on ... SIB1" after a DU switch.
#   2. Scales the UE to 0, waits for the old pod to be gone, patches, scales to 1 ONCE
#      (no "rollout restart" on top: that registered the same IMSI twice in a row).
#   3. Waits for the tunnel directly instead of "rollout status": ue1 has a postStart hook
#      that keeps the pod from becoming ready until the tunnel exists.
#
# Env: NS (default oran-ran), BACKUP_DIR, DRY_RUN=1 (print the plan, change nothing),
#      ATTACH_TIMEOUT (seconds, default 300).
set +e
set +u

NS="${NS:-oran-ran}"
UE="${1:-}"
TARGET="${2:-}"
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-300}"
DRY_RUN="${DRY_RUN:-0}"

usage() {
  echo "Usage: $0 ue1|ue2|ue3|ue4|ue5 du0|du1"
  echo "  All UEs are DU-switchable. DRY_RUN=1 prints the plan without changing anything."
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
  *) echo "Unsupported UE: $UE"; usage; echo "VERDICT=INVALID_UE"; exit 0 ;;
esac

case "$TARGET" in
  du0) RFSIM_TARGET="oai-du0-rfsim"; DU_CM="oai-du0-f1-config" ;;
  du1) RFSIM_TARGET="oai-du1-rfsim"; DU_CM="oai-du1-f1-config" ;;
  *) echo "Unsupported target: $TARGET"; usage; echo "VERDICT=INVALID_DU_TARGET"; exit 0 ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
# Backups live outside the repository so the working tree stays clean.
BACKUP_DIR="${BACKUP_DIR:-$HOME/oran-proof/du-switch-backups/$UE-$TARGET-$STAMP}"
WORK="$(mktemp -d /tmp/du-switch.XXXXXX)"
mkdir -p "$BACKUP_DIR"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; }
info() { echo "INFO: $*"; }

selector_for_dep() {
  kubectl -n "$NS" get deploy "$1" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    labels = d.get("spec", {}).get("selector", {}).get("matchLabels", {})
    print(",".join(f"{k}={v}" for k, v in labels.items()))
except Exception:
    print("")
'
}

pod_for_dep() {
  local selector
  selector="$(selector_for_dep "$1")"
  [ -n "$selector" ] || return
  kubectl -n "$NS" get pods -l "$selector" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    for p in d.get("items", []):
        if p.get("status", {}).get("phase") == "Running" and not p.get("metadata", {}).get("deletionTimestamp"):
            print(p["metadata"]["name"])
            break
except Exception:
    pass
'
}

echo "Switching $UE to $RFSIM_TARGET in namespace $NS"
echo "Backup dir: $BACKUP_DIR"

# ---------------------------------------------------------------- 1. target DU carrier
DU_FREQ="$(kubectl -n "$NS" get cm "$DU_CM" -o jsonpath='{.data.gnb\.conf}' 2>/dev/null | python3 -c '
import re, sys
t = sys.stdin.read()
m = re.search(r"^\s*absoluteFrequencySSB\s*=\s*(\d+)\s*;", t, re.M)
b = re.search(r"^\s*dl_frequencyBand\s*=\s*(\d+)\s*;", t, re.M)
if not m or not b:
    sys.exit(1)
n = int(m.group(1))
# 3GPP TS 38.104 global raster: <3 GHz: 5 kHz steps; 3-24.25 GHz: 15 kHz steps from 3 GHz.
if n < 600000:
    hz = n * 5000
elif n < 2016667:
    hz = 3000000000 + (n - 600000) * 15000
else:
    sys.exit(2)
print(hz, b.group(1), n)
')"
if [ $? -ne 0 ] || [ -z "$DU_FREQ" ]; then
  fail "could not read the carrier of $TARGET from ConfigMap $DU_CM (nothing was changed)"
  echo "VERDICT=DU_FREQUENCY_READ_FAILED"
  exit 0
fi
read -r TARGET_C_HZ TARGET_BAND TARGET_SSB_ARFCN <<<"$DU_FREQ"
info "$TARGET carrier: SSB ARFCN=$TARGET_SSB_ARFCN -> -C $TARGET_C_HZ (band $TARGET_BAND)"

# ---------------------------------------------------------------- 2. backups + plan
kubectl -n "$NS" get cm "$CM" -o yaml > "$BACKUP_DIR/$CM.before.yaml" 2>/dev/null
kubectl -n "$NS" get deploy "$DEP" -o yaml > "$BACKUP_DIR/$DEP.before.yaml" 2>/dev/null
kubectl -n "$NS" get deploy "$DEP" -o json > "$WORK/dep.json" 2>/dev/null
if [ ! -s "$WORK/dep.json" ]; then
  fail "cannot read deployment $DEP"
  echo "VERDICT=DEPLOYMENT_READ_FAILED"
  exit 0
fi

python3 - "$WORK/dep.json" "$RFSIM_TARGET" "$TARGET_C_HZ" "$TARGET_BAND" > "$WORK/ops.json" 2> "$WORK/ops.txt" <<'PY'
import sys, json
path, target, c_hz, band = sys.argv[1:]
d = json.load(open(path))
ops = []
wrong = ["oai-du0-rfsim", "oai-du1-rfsim", "oai-gnb-rfsim", "oai-gnb-b-rfsim"]
for ci, c in enumerate(d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])):
    arr = c.get("args")
    if not isinstance(arr, list):
        continue
    new = list(arr)
    for i, v in enumerate(new):
        if not isinstance(v, str):
            continue
        if v.startswith("--rfsimulator.serveraddr="):
            new[i] = "--rfsimulator.serveraddr=" + target
        elif v == "--rfsimulator.serveraddr" and i + 1 < len(new):
            new[i + 1] = target
        elif v in ("-C", "--carrier-frequency") and i + 1 < len(new):
            new[i + 1] = c_hz
        elif v in ("--band", "-b") and i + 1 < len(new):
            new[i + 1] = band
    if new != arr:
        ops.append({"op": "replace", "path": f"/spec/template/spec/containers/{ci}/args", "value": new})
        print(f"container[{ci}] args: {' '.join(arr)}", file=sys.stderr)
        print(f"container[{ci}] ->   {' '.join(new)}", file=sys.stderr)
print(json.dumps(ops))
PY
cat "$WORK/ops.txt"

if [ "$DRY_RUN" = "1" ]; then
  info "DRY_RUN=1: ConfigMap would be re-pointed to $RFSIM_TARGET, deployment args as shown above. Nothing changed."
  echo "VERDICT=DRY_RUN"
  exit 0
fi

# ---------------------------------------------------------------- 3. stop the UE cleanly
SELECTOR="$(selector_for_dep "$DEP")"
kubectl -n "$NS" scale deploy/"$DEP" --replicas=0 >/dev/null 2>&1
if [ -n "$SELECTOR" ]; then
  kubectl -n "$NS" wait --for=delete pod -l "$SELECTOR" --timeout=90s >/dev/null 2>&1
fi
# Let the gNB/core notice the UE is gone before the same IMSI registers elsewhere.
sleep 10

# ---------------------------------------------------------------- 4. patch ConfigMap + args
kubectl -n "$NS" get cm "$CM" -o jsonpath='{.data.nr-ue\.conf}' > "$WORK/nr-ue.conf" 2>/dev/null
if [ ! -s "$WORK/nr-ue.conf" ]; then
  fail "could not read $CM nr-ue.conf"
  kubectl -n "$NS" scale deploy/"$DEP" --replicas=1 >/dev/null 2>&1
  echo "VERDICT=CONFIGMAP_READ_FAILED"
  exit 0
fi

python3 - "$WORK/nr-ue.conf" "$RFSIM_TARGET" <<'PY'
import sys, re
path, target = sys.argv[1:]
text = open(path, encoding="utf-8", errors="ignore").read()
for old in ["oai-du0-rfsim", "oai-du1-rfsim", "oai-gnb-rfsim", "oai-gnb-b-rfsim"]:
    text = text.replace(old, target)
text = re.sub(r'nssai_sst\s*=\s*[^;,\n}]+', 'nssai_sst = 1', text)
text = re.sub(r'nssai_sd\s*=\s*[^;,\n}]+', 'nssai_sd = 0xffffff', text)
text = re.sub(r'(serveraddr\s*=\s*)("[^"]*"|[A-Za-z0-9_.-]+)', r'\1"' + target + '"', text)
open(path, "w", encoding="utf-8").write(text)
PY

PAYLOAD="$(python3 -c 'import sys,json; print(json.dumps({"data": {"nr-ue.conf": open(sys.argv[1], encoding="utf-8").read()}}))' "$WORK/nr-ue.conf")"
if kubectl -n "$NS" patch cm "$CM" --type merge -p "$PAYLOAD" >"$WORK/cm.log" 2>&1; then
  pass "$CM patched"
else
  fail "$CM patch failed"; cat "$WORK/cm.log"
fi

if grep -q '^\[\]$' "$WORK/ops.json"; then
  info "$DEP args already match $RFSIM_TARGET / -C $TARGET_C_HZ"
elif kubectl -n "$NS" patch deploy "$DEP" --type=json -p "$(cat "$WORK/ops.json")" >"$WORK/args.log" 2>&1; then
  pass "$DEP args patched (serveraddr=$RFSIM_TARGET, -C=$TARGET_C_HZ, band=$TARGET_BAND)"
else
  fail "$DEP args patch failed"; cat "$WORK/args.log"
fi

# ---------------------------------------------------------------- 5. start once, wait for the tunnel
kubectl -n "$NS" scale deploy/"$DEP" --replicas=1 >/dev/null 2>&1

FOUND=0
i=0
while [ $i -lt "$ATTACH_TIMEOUT" ]; do
  POD="$(pod_for_dep "$DEP")"
  if [ -n "$POD" ]; then
    TUN="$(kubectl -n "$NS" exec "$POD" -- bash -lc 'ip -4 addr show oaitun_ue1 2>/dev/null | awk "/inet /{print \$2; exit}"' 2>/dev/null)"
    if [ -n "$TUN" ]; then
      pass "$UE attached after switch: pod=$POD tunnel=$TUN"
      FOUND=1
      break
    fi
  fi
  sleep 3
  i=$((i+3))
done

if [ "$FOUND" = "1" ]; then
  echo "VERDICT=UE_DU_SWITCH_OK"
else
  fail "$UE did not attach to $TARGET within ${ATTACH_TIMEOUT}s"
  echo "--- last UE log lines ($DEP) ---"
  kubectl -n "$NS" logs deploy/"$DEP" --tail=15 2>&1 | cut -c1-200
  echo "--- hints ---"
  echo " * 'NACK ... SIB1' repeated  -> UE carrier (-C) does not match the DU carrier"
  echo " * 'Registration reject'    -> core problem (AMF/AUSF/UDM), see: tools/diagnose-du-layout.sh"
  echo " * 'No AMF is associated'   -> restart oai-cu-cp (NG link to the AMF is down)"
  echo "VERDICT=UE_DU_SWITCH_FAILED"
fi
