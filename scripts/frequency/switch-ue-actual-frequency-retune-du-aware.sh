#!/usr/bin/env bash
set -u
set -o pipefail

REPO="${REPO:-$HOME/oran-e2e}"
NS="${RAN_NS:-${NS:-oran-ran}}"

UE_DEPLOY="${UE_DEPLOY:-oai-nr-ue}"
UE_CM="${UE_CM:-oai-nrue-config}"

# DU-aware: follow the UE's CURRENT DU unless DU_DEPLOY is explicitly provided.
# Resolves serveraddr (oai-du0-rfsim / oai-du1-rfsim) -> DU deployment, and
# derives the matching F1 ConfigMap. Keeps full backward-compat via env override.
if [ -z "${DU_DEPLOY:-}" ]; then
  # shellcheck disable=SC1091
  . "$REPO/scripts/ue/ue-common.sh" 2>/dev/null || true
  _ue_sa="$(ue_serveraddr_from_cm "$NS" "$UE_CM" 2>/dev/null)"
  case "$_ue_sa" in
    oai-du1-rfsim) DU_DEPLOY="oai-du1" ;;
    *)             DU_DEPLOY="oai-du0" ;;
  esac
fi
DU_CM="${DU_CM:-${DU_DEPLOY}-f1-config}"

PROFILE="${1:-status}"
TS="$(date +%Y%m%d-%H%M%S)"
PROOF_ROOT="${PROOF_ROOT:-$HOME/oran-proof/actual-frequency-retune-du-aware}"
PROOF_DIR="${PROOF_DIR:-$PROOF_ROOT/$TS}"
LOG="$PROOF_DIR/retune.log"

mkdir -p "$PROOF_DIR"/{before,after,work}
exec > >(tee -a "$LOG") 2>&1

PASS=0
WARN=0
FAIL=0

pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
warn(){ echo "[WARN] $1"; WARN=$((WARN+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

section(){
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

usage(){
  cat <<USAGE
Usage:
  $0 status
  $0 n78-current
  $0 n78-raster-high
  $0 n78-3500
  $0 n41-2600
  $0 n77-4174
  $0 restore

Validated real actual OAI carrier retune profiles for UE1.
DU is auto-detected from the UE current serveraddr (DU0 or DU1); override with DU_DEPLOY=.
USAGE
}

profile_values(){
  case "$PROFILE" in
    status)
      TARGET_NAME="status-only"
      return 0
      ;;

    n78-current|restore)
      TARGET_NAME="n78-current"
      TARGET_SSB="621312"
      TARGET_POINTA="620040"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3319680000"
      TARGET_UE_BAND="78"
      TARGET_SSB_ARG="516"
      ;;

    n78-raster-high)
      TARGET_NAME="n78-raster-high"
      TARGET_SSB="621408"
      TARGET_POINTA="620136"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3321120000"
      TARGET_UE_BAND="78"
      TARGET_SSB_ARG="516"
      ;;

    n78-3500)
      TARGET_NAME="n78-3500"
      TARGET_SSB="633312"
      TARGET_POINTA="632040"
      TARGET_BAND="78"
      TARGET_BW="106"
      TARGET_C_HZ="3499680000"
      TARGET_UE_BAND="78"
      TARGET_SSB_ARG="516"
      ;;

    n41-2600)
      # VALIDATED 2026-06-04.
      # 2600 MHz-class Band 41 profile using OAI known 106PRB values.
      # SSB = 2593.35 MHz, PointA = 2574.27 MHz.
      # Requires UE --band 41 + -C 2593350000 + --ssb 516.
      TARGET_NAME="n41-2600"
      TARGET_SSB="518670"
      TARGET_POINTA="514854"
      TARGET_BAND="41"
      TARGET_BW="106"
      TARGET_C_HZ="2593350000"
      TARGET_UE_BAND="41"
      TARGET_SSB_ARG="516"
      ;;

    n77-4174)
      # n77 4173.6 MHz TDD, 106 PRB, 30 kHz. SSB centered (GSCN 8314), carrier inside 3300-4200.
      # n77 min channel BW = 10 MHz -> same CORESET#0 table as n78, so centered geometry is valid.
      # Requires UE --band 77 + -C 4173600000 + --ssb 516.
      TARGET_NAME="n77-4174"
      TARGET_SSB="678240"
      TARGET_POINTA="676968"
      TARGET_BAND="77"
      TARGET_BW="106"
      TARGET_C_HZ="4173600000"
      TARGET_UE_BAND="77"
      TARGET_SSB_ARG="516"
      ;;

    n78-raster-higher)
      fail "n78-raster-higher is experimental and not enabled in this clean validated script."
      exit 2
      ;;

    n41-2600-raster|n41-oai-2593)
      fail "$PROFILE was diagnostic only. Use validated profile: n41-2600"
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

capture_state(){
  local phase="$1"
  mkdir -p "$PROOF_DIR/$phase"

  kubectl -n "$NS" get cm "$DU_CM" -o yaml > "$PROOF_DIR/$phase/$DU_CM.yaml" 2>&1 || true
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o yaml > "$PROOF_DIR/$phase/$UE_DEPLOY.yaml" 2>&1 || true
  kubectl -n "$NS" get pods -o wide > "$PROOF_DIR/$phase/pods.txt" 2>&1 || true

  kubectl -n "$NS" get cm "$DU_CM" -o jsonpath='{.data.gnb\.conf}' > "$PROOF_DIR/$phase/gnb.conf" 2>/dev/null || true
  grep -E 'absoluteFrequencySSB|dl_frequencyBand|dl_absoluteFrequencyPointA|dl_carrierBandwidth|ul_frequencyBand|ul_carrierBandwidth|subcarrierSpacing|ssb_' \
    "$PROOF_DIR/$phase/gnb.conf" > "$PROOF_DIR/$phase/carrier-keys.txt" 2>&1 || true

  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].args}' \
    > "$PROOF_DIR/$phase/ue-args.txt" 2>&1 || true
}

status_report(){
  section "Actual retune status"
  echo "PROFILE_REQUEST=$PROFILE"
  echo "TARGET_NAME=${TARGET_NAME:-status-only}"
  echo "NS=$NS"
  echo "DU_DEPLOY=$DU_DEPLOY"
  echo "DU_CM=$DU_CM"
  echo "UE_DEPLOY=$UE_DEPLOY"
  echo "UE_CM=$UE_CM"
  echo "PROOF_DIR=$PROOF_DIR"

  echo
  echo "--- Current $DU_DEPLOY carrier keys ---"
  kubectl -n "$NS" get cm "$DU_CM" -o jsonpath='{.data.gnb\.conf}' > "$PROOF_DIR/work/current-gnb.conf" 2>/dev/null || true
  grep -E 'absoluteFrequencySSB|dl_frequencyBand|dl_absoluteFrequencyPointA|dl_carrierBandwidth|ul_frequencyBand|ul_carrierBandwidth|subcarrierSpacing|ssb_' \
    "$PROOF_DIR/work/current-gnb.conf" || true

  echo
  echo "--- UE1 args ---"
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].args}' || true
  echo
}

patch_du_cm(){
  section "Patch $DU_DEPLOY actual carrier keys"

  kubectl -n "$NS" get cm "$DU_CM" -o json > "$PROOF_DIR/work/$DU_CM.before.json" || return 1

  python3 - "$PROOF_DIR/work/$DU_CM.before.json" "$PROOF_DIR/work/$DU_CM.after.json" \
    "$TARGET_SSB" "$TARGET_POINTA" "$TARGET_BAND" "$TARGET_BW" <<'PY'
import json, re, sys
src, dst, ssb, pointa, band, bw = sys.argv[1:]
obj = json.load(open(src))
text = obj.get("data", {}).get("gnb.conf")
if not text:
    raise SystemExit("missing data['gnb.conf']")

pairs = {
    "absoluteFrequencySSB": ssb,
    "dl_absoluteFrequencyPointA": pointa,
    "dl_frequencyBand": band,
    "ul_frequencyBand": band,
    "dl_carrierBandwidth": bw,
    "ul_carrierBandwidth": bw,
}

for key, val in pairs.items():
    text, n = re.subn(rf"(\b{re.escape(key)}\b\s*=\s*)([^;\n]+)(;)", rf"\g<1>{val}\3", text, count=1)
    if n != 1:
        raise SystemExit(f"missing key {key}")

obj["data"]["gnb.conf"] = text

meta = obj.setdefault("metadata", {})
for k in ["resourceVersion", "uid", "managedFields", "creationTimestamp", "generation", "selfLink"]:
    meta.pop(k, None)
obj.pop("status", None)

json.dump(obj, open(dst, "w"), indent=2)
PY

  kubectl apply -f "$PROOF_DIR/work/$DU_CM.after.json"
  pass "patched $DU_DEPLOY: SSB=$TARGET_SSB PointA=$TARGET_POINTA band=$TARGET_BAND bw=$TARGET_BW"
}

patch_ue_args(){
  section "Patch UE1 frequency args"

  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o json > "$PROOF_DIR/work/$UE_DEPLOY.before.json" || return 1

  python3 - "$PROOF_DIR/work/$UE_DEPLOY.before.json" "$PROOF_DIR/work/$UE_DEPLOY.after.json" \
    "$TARGET_C_HZ" "$TARGET_UE_BAND" "$TARGET_SSB_ARG" "$PROOF_DIR/work/ue-patch-status.txt" <<'PY'
import json, sys
src, dst, c_hz, band, ssb_arg, status = sys.argv[1:]
obj = json.load(open(src))
changes = []

containers = obj.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
for ci, c in enumerate(containers):
    arr = c.get("args")
    if not isinstance(arr, list):
        continue

    found_c = False
    for i, x in enumerate(arr):
        if x == "-C" and i + 1 < len(arr):
            old = arr[i + 1]
            arr[i + 1] = c_hz
            found_c = True
            changes.append(f"container[{ci}] -C {old}->{c_hz}")

    cleaned = []
    i = 0
    while i < len(arr):
        if arr[i] in ("--band", "-b", "--ssb", "-s") and i + 1 < len(arr):
            changes.append(f"container[{ci}] remove {arr[i]} {arr[i+1]}")
            i += 2
            continue
        cleaned.append(arr[i])
        i += 1
    arr[:] = cleaned

    insert_at = len(arr)
    if "-C" in arr:
        insert_at = arr.index("-C")
    arr[insert_at:insert_at] = ["--band", band]
    changes.append(f"container[{ci}] insert --band {band}")

    insert_at = len(arr)
    if "--rfsimulator.serveraddr" in arr:
        insert_at = arr.index("--rfsimulator.serveraddr")
    arr[insert_at:insert_at] = ["--ssb", ssb_arg]
    changes.append(f"container[{ci}] insert --ssb {ssb_arg}")

    if not found_c:
        changes.append(f"container[{ci}] WARNING no -C found")

meta = obj.setdefault("metadata", {})
for k in ["resourceVersion", "uid", "managedFields", "creationTimestamp", "generation", "selfLink"]:
    meta.pop(k, None)
obj.pop("status", None)

open(status, "w").write("\n".join(changes) + "\n")
json.dump(obj, open(dst, "w"), indent=2)
PY

  cat "$PROOF_DIR/work/ue-patch-status.txt"
  kubectl apply -f "$PROOF_DIR/work/$UE_DEPLOY.after.json"
  pass "patched UE1 args: -C=$TARGET_C_HZ --band=$TARGET_UE_BAND --ssb=$TARGET_SSB_ARG"
}

rollout_and_wait(){
  section "Rollout $DU_DEPLOY and UE1"

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
    if [ -n "${pod:-}" ] && kubectl -n "$NS" exec "$pod" -- ip addr show oaitun_ue1 >/dev/null 2>&1; then
      echo "UE_POD=$pod" | tee "$PROOF_DIR/after/ue-pod.txt"
      kubectl -n "$NS" exec "$pod" -- ip addr show oaitun_ue1 | tee "$PROOF_DIR/after/oaitun_ue1.txt"
      kubectl -n "$NS" exec "$pod" -- ip route | tee "$PROOF_DIR/after/ip-route.txt"
      pass "UE1 tunnel ready"
      return 0
    fi
    echo "waiting for UE1 tunnel... poll=$i pod=${pod:-none}"
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
  fi

  tail -160 "$PROOF_DIR/after/validate-e2e.log" || true
  fail "validate-e2e.sh failed"
  return 1
}

restore_internal(){
  section "AUTO RESTORE n78-current"

  TARGET_NAME="n78-current"
  TARGET_SSB="621312"
  TARGET_POINTA="620040"
  TARGET_BAND="78"
  TARGET_BW="106"
  TARGET_C_HZ="3319680000"
  TARGET_UE_BAND="78"
  TARGET_SSB_ARG="516"

  patch_du_cm || true
  patch_ue_args || true
  rollout_and_wait || true
  wait_ue_tunnel || true
  run_validation || true
}

main(){
  require_tools
  profile_values

  section "Actual OAI carrier retune"
  echo "REQUESTED_PROFILE=$PROFILE"
  echo "TARGET_NAME=${TARGET_NAME:-status-only}"
  echo "PROOF_DIR=$PROOF_DIR"

  if [ "$PROFILE" = "status" ]; then
    status_report
    echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_STATUS_DONE" | tee "$PROOF_DIR/final-verdict.txt"
    exit 0
  fi

  capture_state before
  status_report

  if ! patch_du_cm || ! patch_ue_args || ! rollout_and_wait || ! wait_ue_tunnel || ! run_validation; then
    capture_state failed
    if [ "$PROFILE" != "restore" ] && [ "$PROFILE" != "n78-current" ]; then
      warn "profile $PROFILE failed; restoring baseline automatically"
      restore_internal
      capture_state after
      echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
      echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_${TARGET_NAME}_FAILED_RESTORED" | tee "$PROOF_DIR/final-verdict.txt"
      exit 1
    fi

    capture_state after
    echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
    echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_${TARGET_NAME}_FAILED" | tee "$PROOF_DIR/final-verdict.txt"
    exit 1
  fi

  capture_state after
  echo "PASS=$PASS WARN=$WARN FAIL=$FAIL"
  echo "VERDICT=ACTUAL_FREQUENCY_RETUNE_${TARGET_NAME}_PASS" | tee "$PROOF_DIR/final-verdict.txt"

  # --- FSPL degradation cap (opt-in via FSPL_CAP=1) -------------------------
  # Applies the frequency-band throughput cap derived from the FSPL model,
  # using the SAME carrier the UE was just retuned to (TARGET_C_HZ).
  # Percentage is computed live by apply-fspl-band-profile.sh; nothing hardcoded.
  if [ "${FSPL_CAP:-0}" = "1" ] && [ -n "${TARGET_C_HZ:-}" ]; then
    F_MHZ="$(awk "BEGIN{printf \"%.2f\", ${TARGET_C_HZ}/1000000}")"
    section "FSPL degradation cap (f=${F_MHZ} MHz)"
    bash "$(dirname "$0")/apply-fspl-band-profile.sh" "$F_MHZ" || warn "FSPL cap application failed (non-fatal)"
  fi
  # --------------------------------------------------------------------------
  echo "Proof: $PROOF_DIR"
}

main "$@"
