#!/usr/bin/env bash
set -u
set -o pipefail

REPO="${REPO:-$HOME/oran-e2e-freeze}"
NS="${RAN_NS:-${NS:-oran-ran}}"
UE="${UE:-ue1}"
UE_DEPLOY="${UE_DEPLOY:-oai-nr-ue}"
UE_CM="${UE_CM:-oai-nrue-config}"
DU_DEPLOY="${DU_DEPLOY:-oai-du0}"
DU_CM="${DU_CM:-oai-du0-f1-config}"
TS="$(date +%Y%m%d-%H%M%S)"
PROOF_ROOT="${PROOF_ROOT:-$HOME/oran-proof/actual-frequency-retune-du-aware}"
PROOF_DIR="${PROOF_DIR:-$PROOF_ROOT/$TS}"
LOG="$PROOF_DIR/retune.log"
PROFILE="${1:-status}"

mkdir -p "$PROOF_DIR" "$PROOF_DIR/before" "$PROOF_DIR/after" "$PROOF_DIR/work"
exec > >(tee -a "$LOG") 2>&1

PASS=0
WARN=0
FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
warn(){ echo "[WARN] $1"; WARN=$((WARN+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
section(){ echo; echo "============================================================"; echo "$1"; echo "============================================================"; }

usage(){
  cat <<USAGE
Usage:
  $0 status
  $0 n78-current
  $0 n78-raster-high
  $0 n78-raster-higher
  $0 n78-cband-3780
  $0 restore

Raster-safe Phase-A actual OAI carrier retune for ue1/DU0 only.

Disabled old profiles:
  n78-low  : invalid in this lab because -40 ARFCN moves SSB off OAI sync raster.
  n78-high : replaced by n78-raster-high because arbitrary +1000 ARFCN is not raster-safe.
USAGE
}

profile_values(){
  case "$PROFILE" in
    status) return 0 ;;

    n78-current|restore)
      TARGET_NAME="n78-current"
      TARGET_SSB="621312"
      TARGET_POINTA="620040"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3319680000"
      ;;

    n78-raster-high)
      # Validated on 2026-06-04.
      # +96 ARFCN = +1.44 MHz, preserving OAI SSB sync raster.
      TARGET_NAME="n78-raster-high"
      TARGET_SSB="621408"
      TARGET_POINTA="620136"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3321120000"
      ;;

    n78-raster-higher)
      # Experimental, not yet validated.
      # +192 ARFCN = +2.88 MHz, also raster-aligned.
      TARGET_NAME="n78-raster-higher"
      TARGET_SSB="621504"
      TARGET_POINTA="620232"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3322560000"
      ;;

    n78-cband-3780)
      # Experimental real upper n78 / C-band profile.
      # SSB = 3779.04 MHz, raster-safe.
      # PointA keeps same SSB-PointA offset: 1272 ARFCN.
      TARGET_NAME="n78-cband-3780"
      TARGET_SSB="651936"
      TARGET_POINTA="650664"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3779040000"
      ;;

    n78-low|n78-high)
      usage
      fail "Profile $PROFILE is disabled. Use raster-safe profiles only: n78-raster-high or n78-raster-higher."
      exit 2
      ;;

    -h|--help|help)
      usage
      exit 0
      ;;

    *)
      usage
      fail "unknown profile: $PROFILE"
      exit 2
      ;;
  esac
}

require_tools(){
  command -v kubectl >/dev/null 2>&1 || { fail "kubectl not found"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { fail "python3 not found"; exit 1; }
  cd "$REPO" || { fail "cannot cd to $REPO"; exit 1; }
}

capture_baseline(){
  section "Capture current baseline"
  kubectl -n "$NS" get cm "$DU_CM" -o yaml > "$PROOF_DIR/before/$DU_CM.yaml" || fail "cannot capture $DU_CM"
  kubectl -n "$NS" get deploy "$DU_DEPLOY" -o yaml > "$PROOF_DIR/before/$DU_DEPLOY.yaml" || warn "cannot capture $DU_DEPLOY yaml"
  kubectl -n "$NS" get cm "$UE_CM" -o yaml > "$PROOF_DIR/before/$UE_CM.yaml" || warn "cannot capture $UE_CM"
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o yaml > "$PROOF_DIR/before/$UE_DEPLOY.yaml" || warn "cannot capture $UE_DEPLOY yaml"
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o json > "$PROOF_DIR/before/$UE_DEPLOY.json" || warn "cannot capture $UE_DEPLOY json"
  pass "baseline captured"
}

status_report(){
  section "Actual retune status"
  echo "PROFILE_REQUEST=$PROFILE"
  echo "NS=$NS"
  echo "DU_CM=$DU_CM"
  echo "DU_DEPLOY=$DU_DEPLOY"
  echo "UE_CM=$UE_CM"
  echo "UE_DEPLOY=$UE_DEPLOY"
  echo "PROOF_DIR=$PROOF_DIR"

  echo
  echo "--- Current DU0 carrier keys ---"
  kubectl -n "$NS" get cm "$DU_CM" -o jsonpath='{.data.gnb\.conf}' > "$PROOF_DIR/work/current-gnb.conf" 2>/dev/null || true
  grep -E 'absoluteFrequencySSB|dl_frequencyBand|dl_absoluteFrequencyPointA|dl_carrierBandwidth|ul_frequencyBand|ul_carrierBandwidth|subcarrierSpacing|ssb_' "$PROOF_DIR/work/current-gnb.conf" || true

  echo
  echo "--- UE1 ConfigMap serveraddr / S-NSSAI ---"
  kubectl -n "$NS" get cm "$UE_CM" -o jsonpath='{.data.nr-ue\.conf}' > "$PROOF_DIR/work/current-nr-ue.conf" 2>/dev/null || true
  grep -E 'serveraddr|nssai_sst|nssai_sd|frequency|arfcn|band|ssb|rfsimulator' "$PROOF_DIR/work/current-nr-ue.conf" || true

  echo
  echo "--- UE1 deployment frequency args/env direct JSON scan ---"
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o json > "$PROOF_DIR/work/$UE_DEPLOY.json" || true
  python3 - "$PROOF_DIR/work/$UE_DEPLOY.json" <<'PY' || true
import json, re, sys
p=sys.argv[1]
try:
    obj=json.load(open(p))
except Exception as e:
    print(f"ERROR: cannot parse deployment json: {e}")
    raise SystemExit(0)
containers=obj.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])
for c in containers:
    vals=[]
    vals += c.get("command") or []
    vals += c.get("args") or []
    for e in c.get("env") or []:
        vals.append(f"{e.get('name','')}={e.get('value','')}")
    joined="\n".join(map(str, vals))
    found=False
    for line in joined.splitlines():
        if re.search(r"(?i)(^|\s)-C(\s|=|$)|ssb|numerology|rfsimulator|frequency|arfcn|band", line):
            print(line)
            found=True
    toks=[]
    for v in vals:
        toks += str(v).split()
    if "-C" in toks:
        i=toks.index("-C")
        print(f"DETECTED_UE_C={toks[i+1] if i+1 < len(toks) else 'MISSING_VALUE'}")
        found=True
    m=re.search(r"(?:^|\s)-C(?:\s+|=)(\d+)", joined)
    if m:
        print(f"DETECTED_UE_C={m.group(1)}")
        found=True
    if not found:
        print("NO_UE_C_OR_FREQ_ARG_FOUND")
PY
}

patch_du_cm(){
  section "Patch DU0 actual carrier keys"
  kubectl -n "$NS" get cm "$DU_CM" -o json > "$PROOF_DIR/work/$DU_CM.before.json" || return 1
  python3 - "$PROOF_DIR/work/$DU_CM.before.json" "$PROOF_DIR/work/$DU_CM.after.json" "$TARGET_SSB" "$TARGET_POINTA" "$TARGET_BAND" "$TARGET_BW" <<'PY'
import json, re, sys
src, dst, ssb, pointa, band, bw = sys.argv[1:]
obj=json.load(open(src))
text=obj.get("data",{}).get("gnb.conf")
if not text:
    raise SystemExit("missing data['gnb.conf']")
repls={
    "absoluteFrequencySSB": ssb,
    "dl_frequencyBand": band,
    "dl_absoluteFrequencyPointA": pointa,
    "dl_carrierBandwidth": bw,
    "ul_frequencyBand": band,
    "ul_carrierBandwidth": bw,
}
for key,val in repls.items():
    pattern=rf"(\b{re.escape(key)}\b\s*=\s*)([^;\n]+)(;)"
    text2,n=re.subn(pattern, rf"\g<1>{val}\3", text, count=1)
    if n == 0:
        raise SystemExit(f"key not found: {key}")
    text=text2
obj.setdefault("data",{})["gnb.conf"]=text
meta=obj.setdefault("metadata",{})
for k in ["resourceVersion","uid","managedFields","creationTimestamp","generation","selfLink"]:
    meta.pop(k, None)
obj.pop("status", None)
json.dump(obj, open(dst,"w"), indent=2)
PY
  kubectl apply -f "$PROOF_DIR/work/$DU_CM.after.json"
  pass "patched $DU_CM with SSB=$TARGET_SSB PointA=$TARGET_POINTA"
}

patch_ue_c_if_present(){
  section "Patch UE1 -C if present"
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o json > "$PROOF_DIR/work/$UE_DEPLOY.before.json" || return 1
  python3 - "$PROOF_DIR/work/$UE_DEPLOY.before.json" "$PROOF_DIR/work/$UE_DEPLOY.after.json" "$TARGET_C_HZ" "$PROOF_DIR/work/ue-c-patch-status.txt" <<'PY'
import json, re, sys
src, dst, c_hz, status = sys.argv[1:]
obj=json.load(open(src))
patched=[]
spec=obj.get("spec",{}).get("template",{}).get("spec",{})
for ci,c in enumerate(spec.get("containers",[])):
    for field in ("command","args"):
        arr=c.get(field)
        if not isinstance(arr, list):
            continue
        i=0
        while i < len(arr):
            s=str(arr[i])
            if s == "-C" and i + 1 < len(arr):
                old=arr[i+1]
                arr[i+1]=c_hz
                patched.append(f"container[{ci}].{field}[{i+1}] {old}->{c_hz}")
                i += 2
                continue
            ns,n=re.subn(r"(^|\s)-C(\s+|=)(\d+)", rf"\1-C\2{c_hz}", s)
            if n:
                arr[i]=ns
                patched.append(f"container[{ci}].{field}[{i}] inline -C->{c_hz}")
            i += 1
meta=obj.setdefault("metadata",{})
for k in ["resourceVersion","uid","managedFields","creationTimestamp","generation","selfLink"]:
    meta.pop(k, None)
obj.pop("status", None)
open(status,"w").write("\n".join(patched) if patched else "NO_UE_C_FOUND\n")
json.dump(obj, open(dst,"w"), indent=2)
PY
  cat "$PROOF_DIR/work/ue-c-patch-status.txt"
  if grep -q '^NO_UE_C_FOUND' "$PROOF_DIR/work/ue-c-patch-status.txt"; then
    warn "UE1 deployment does not expose -C; leaving UE deployment unchanged"
  else
    kubectl apply -f "$PROOF_DIR/work/$UE_DEPLOY.after.json"
    pass "patched UE1 deployment -C to $TARGET_C_HZ"
  fi
}

rollout_and_wait(){
  section "Rollout DU0 and UE1 only"
  kubectl -n "$NS" rollout restart deploy "$DU_DEPLOY" || return 1
  kubectl -n "$NS" rollout status deploy "$DU_DEPLOY" --timeout=8m || return 1
  pass "$DU_DEPLOY rollout complete"

  kubectl -n "$NS" rollout restart deploy "$UE_DEPLOY" || return 1
  kubectl -n "$NS" rollout status deploy "$UE_DEPLOY" --timeout=8m || return 1
  pass "$UE_DEPLOY rollout complete"
}

wait_ue_tunnel(){
  section "Wait for UE1 oaitun_ue1"
  local pod=""
  for i in $(seq 1 90); do
    pod="$(kubectl -n "$NS" get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
    if [ -n "$pod" ] && kubectl -n "$NS" exec "$pod" -- ip addr show oaitun_ue1 >/dev/null 2>&1; then
      echo "UE_POD=$pod" | tee "$PROOF_DIR/after/ue-pod.txt"
      kubectl -n "$NS" exec "$pod" -- ip addr show oaitun_ue1 | tee "$PROOF_DIR/after/oaitun_ue1.txt"
      kubectl -n "$NS" exec "$pod" -- ip route | tee "$PROOF_DIR/after/ip-route.txt"
      pass "UE1 tunnel ready"
      return 0
    fi
    echo "waiting for UE1 tunnel... poll=$i pod=${pod:-not-ready}"
    sleep 4
  done
  fail "UE1 tunnel did not return"
  return 1
}

run_validation(){
  section "Run validate-e2e.sh"
  if bash scripts/validate-e2e.sh > "$PROOF_DIR/after/validate-e2e.log" 2>&1; then
    tail -120 "$PROOF_DIR/after/validate-e2e.log"
    pass "validate-e2e.sh passed"
    return 0
  else
    tail -160 "$PROOF_DIR/after/validate-e2e.log" || true
    fail "validate-e2e.sh failed"
    return 1
  fi
}

capture_after(){
  section "Capture after-state proof"
  kubectl -n "$NS" get cm "$DU_CM" -o yaml > "$PROOF_DIR/after/$DU_CM.yaml" || true
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o yaml > "$PROOF_DIR/after/$UE_DEPLOY.yaml" || true
  kubectl -n "$NS" get pods -o wide > "$PROOF_DIR/after/pods.txt" || true
  kubectl -n "$NS" get cm "$DU_CM" -o jsonpath='{.data.gnb\.conf}' > "$PROOF_DIR/after/gnb.conf" 2>/dev/null || true
  grep -E 'absoluteFrequencySSB|dl_frequencyBand|dl_absoluteFrequencyPointA|dl_carrierBandwidth|ul_frequencyBand|ul_carrierBandwidth' "$PROOF_DIR/after/gnb.conf" | tee "$PROOF_DIR/after/carrier-keys.txt" || true
}

restore_baseline_internal(){
  section "AUTO-RESTORE n78-current baseline"
  local saved_profile="$PROFILE"
  PROFILE="restore"
  profile_values
  patch_du_cm || true
  patch_ue_c_if_present || true
  rollout_and_wait || true
  wait_ue_tunnel || true
  run_validation || true
  PROFILE="$saved_profile"
}

main(){
  require_tools
  profile_values

  section "Actual OAI carrier retune Phase-A"
  echo "REQUESTED_PROFILE=$PROFILE"
  echo "TARGET_NAME=${TARGET_NAME:-status-only}"
  echo "UE=$UE"
  echo "DU=$DU_DEPLOY / $DU_CM"
  echo "UE_DEPLOY=$UE_DEPLOY / $UE_CM"
  echo "PROOF_DIR=$PROOF_DIR"

  if [ "$PROFILE" = "status" ]; then
    status_report
    echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_STATUS_DONE" | tee "$PROOF_DIR/final-verdict.txt"
    exit 0
  fi

  capture_baseline
  status_report

  patch_du_cm || { fail "DU ConfigMap patch failed"; exit 1; }
  patch_ue_c_if_present || { warn "UE -C patch step had issues"; }

  if ! rollout_and_wait || ! wait_ue_tunnel || ! run_validation; then
    if [ "$PROFILE" = "n78-low" ] || [ "$PROFILE" = "n78-high" ]; then
      warn "apply failed for $PROFILE; restoring baseline automatically"
      restore_baseline_internal
      capture_after
      echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
      echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_${PROFILE}_FAILED_RESTORED" | tee "$PROOF_DIR/final-verdict.txt"
      exit 1
    else
      capture_after
      echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
      echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_${PROFILE}_FAILED" | tee "$PROOF_DIR/final-verdict.txt"
      exit 1
    fi
  fi

  capture_after
  echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
  echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_${TARGET_NAME}_PASS" | tee "$PROOF_DIR/final-verdict.txt"
  echo "Proof: $PROOF_DIR"
}

main "$@"
