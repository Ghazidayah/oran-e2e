#!/usr/bin/env bash
set -euo pipefail

NS="${RAN_NS:-oran-ran}"
UE="${UE:-ue1}"
PROFILE="${1:-status}"
MODE="${2:---apply}"

TS="$(date +%Y%m%d-%H%M%S)"
PROOF_DIR="${PROOF_DIR:-$HOME/oran-proof/frequency-profile-control-du-aware/$TS}"
mkdir -p "$PROOF_DIR"

log() { echo "[INFO] $*"; }
fail() { echo "[FAIL] $*" >&2; exit 1; }

case "$UE" in
  ue1)
    UE_CM="oai-nrue-config"
    UE_DEPLOY="oai-nr-ue"
    ;;
  *)
    fail "Frequency profile control is currently protected for ue1 only. Got UE=$UE"
    ;;
esac

profile_values() {
  local p="$1"

  case "$p" in
    status)
      echo "description=status only"
      echo "freq_mhz=status"
      echo "band_label=status"
      echo "model=status"
      echo "enb_ploss=KEEP"
      echo "enb_noise=KEEP"
      echo "ue_ploss=KEEP"
      echo "ue_noise=KEEP"
      echo "tc_cmd=status"
      echo "expected=read current state"
      ;;

    restore|mid-band-3500|scheduler-auto)
      echo "description=mid-band baseline n78-like 3.5GHz"
      echo "freq_mhz=3500"
      echo "band_label=mid-band-n78"
      echo "model=balanced mid-band reference"
      echo "enb_ploss=20"
      echo "enb_noise=-4"
      echo "ue_ploss=20"
      echo "ue_noise=-2"
      echo "tc_cmd=clear"
      echo "expected=baseline balanced throughput"
      ;;

    low-band-700)
      echo "description=coverage-band 700MHz model"
      echo "freq_mhz=700"
      echo "band_label=low-band-coverage"
      echo "model=lower path loss but lower channel bandwidth ceiling"
      echo "enb_ploss=14"
      echo "enb_noise=-8"
      echo "ue_ploss=14"
      echo "ue_noise=-6"
      echo "tc_cmd=rate 22mbit delay 5ms 1ms loss 0%"
      echo "expected=stable coverage, medium throughput"
      ;;

    cband-3800)
      echo "description=upper mid-band 3.8GHz model"
      echo "freq_mhz=3800"
      echo "band_label=cband-upper-mid"
      echo "model=slightly higher path loss than 3.5GHz"
      echo "enb_ploss=23"
      echo "enb_noise=-2"
      echo "ue_ploss=23"
      echo "ue_noise=0"
      echo "tc_cmd=rate 36mbit delay 3ms 1ms loss 0%"
      echo "expected=good throughput, slightly lower than clean mid-band"
      ;;

    mmwave-28000-los)
      echo "description=28GHz mmWave LOS model"
      echo "freq_mhz=28000"
      echo "band_label=mmwave-los"
      echo "model=high bandwidth with clean line-of-sight"
      echo "enb_ploss=28"
      echo "enb_noise=-4"
      echo "ue_ploss=28"
      echo "ue_noise=-2"
      echo "tc_cmd=rate 70mbit delay 1ms 0ms loss 0%"
      echo "expected=highest throughput if LOS"
      ;;

    mmwave-28000-nlos)
      echo "description=28GHz mmWave NLOS/blockage model"
      echo "freq_mhz=28000"
      echo "band_label=mmwave-nlos"
      echo "model=high obstruction loss and more unstable channel"
      echo "enb_ploss=55"
      echo "enb_noise=20"
      echo "ue_ploss=55"
      echo "ue_noise=22"
      echo "tc_cmd=rate 10mbit delay 35ms 10ms loss 1%"
      echo "expected=lowest throughput and higher latency"
      ;;

    *)
      fail "Unknown frequency profile: $p"
      ;;
  esac
}

get_kv() {
  profile_values "$PROFILE" | awk -F= -v k="$1" '$1==k {print substr($0, index($0,$2))}'
}

DESCRIPTION="$(get_kv description)"
FREQ_MHZ="$(get_kv freq_mhz)"
BAND_LABEL="$(get_kv band_label)"
MODEL="$(get_kv model)"
ENB_PLOSS="$(get_kv enb_ploss)"
ENB_NOISE="$(get_kv enb_noise)"
UE_PLOSS="$(get_kv ue_ploss)"
UE_NOISE="$(get_kv ue_noise)"
TC_CMD="$(get_kv tc_cmd)"
EXPECTED="$(get_kv expected)"

log "UE=$UE"
log "PROFILE=$PROFILE"
log "MODE=$MODE"
log "PROOF_DIR=$PROOF_DIR"

kubectl -n "$NS" get cm "$UE_CM" -o jsonpath='{.data.nr-ue\.conf}' > "$PROOF_DIR/ue-original-nr-ue.conf" \
  || fail "could not read $UE_CM nr-ue.conf"

SERVERADDR="$(grep -E 'serveraddr[[:space:]]*=' "$PROOF_DIR/ue-original-nr-ue.conf" | head -1 | sed -E 's/.*serveraddr[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/' || true)"
[ -n "$SERVERADDR" ] || fail "could not detect UE serveraddr"

case "$SERVERADDR" in
  oai-du0-rfsim)
    ACTIVE_DU_CM="oai-du0-f1-config"
    ACTIVE_DU_DEPLOY="oai-du0"
    ;;
  oai-du1-rfsim)
    ACTIVE_DU_CM="oai-du1-f1-config"
    ACTIVE_DU_DEPLOY="oai-du1"
    ;;
  *)
    fail "unsupported serveraddr=$SERVERADDR"
    ;;
esac

kubectl -n "$NS" get cm "$ACTIVE_DU_CM" -o jsonpath='{.data.gnb\.conf}' > "$PROOF_DIR/du-original-gnb.conf" \
  || fail "could not read $ACTIVE_DU_CM gnb.conf"

extract_sst_sd() {
  local file="$1"
  grep -E 'nssai_sst|nssai_sd' "$file" || true
}

extract_radio_values() {
  local file="$1"
  python3 - "$file" <<'PY'
import re, sys
text=open(sys.argv[1]).read().splitlines()
current=None
vals={}
for line in text:
    m=re.search(r'model_name\s*=\s*"([^"]+)"', line)
    if m:
        current=m.group(1)
        vals.setdefault(current,{})
    elif current and "ploss_dB" in line:
        m=re.search(r'ploss_dB\s*=\s*([^;]+)', line)
        if m: vals[current]["ploss_dB"]=m.group(1).strip()
    elif current and "noise_power_dB" in line:
        m=re.search(r'noise_power_dB\s*=\s*([^;]+)', line)
        if m: vals[current]["noise_power_dB"]=m.group(1).strip()

for model in ["rfsimu_channel_enB0", "rfsimu_channel_ue0"]:
    print(f"{model}_ploss_dB={vals.get(model,{}).get('ploss_dB','MISSING')}")
    print(f"{model}_noise_power_dB={vals.get(model,{}).get('noise_power_dB','MISSING')}")
PY
}

extract_frequency_values() {
  local file="$1"
  grep -E 'absoluteFrequencySSB|dl_frequencyBand|dl_absoluteFrequencyPointA|dl_carrierBandwidth|ul_frequencyBand|ul_carrierBandwidth' "$file" || true
}

echo "===== CURRENT UE SERVER/S-NSSAI =====" | tee "$PROOF_DIR/status.txt"
echo "serveraddr=$SERVERADDR" | tee -a "$PROOF_DIR/status.txt"
extract_sst_sd "$PROOF_DIR/ue-original-nr-ue.conf" | tee -a "$PROOF_DIR/status.txt"

echo "===== CURRENT DU FREQUENCY KEYS =====" | tee -a "$PROOF_DIR/status.txt"
extract_frequency_values "$PROOF_DIR/du-original-gnb.conf" | tee -a "$PROOF_DIR/status.txt"

echo "===== CURRENT RFsim VALUES =====" | tee -a "$PROOF_DIR/status.txt"
extract_radio_values "$PROOF_DIR/ue-original-nr-ue.conf" | tee -a "$PROOF_DIR/status.txt"

echo "===== FREQUENCY PROFILE =====" | tee -a "$PROOF_DIR/status.txt"
cat <<INFO | tee -a "$PROOF_DIR/status.txt"
PROFILE=$PROFILE
DESCRIPTION=$DESCRIPTION
FREQ_MHZ=$FREQ_MHZ
BAND_LABEL=$BAND_LABEL
MODEL=$MODEL
EXPECTED=$EXPECTED
TC_CMD=$TC_CMD
ACTIVE_DU_CM=$ACTIVE_DU_CM
ACTIVE_DU_DEPLOY=$ACTIVE_DU_DEPLOY
IMPORTANT=This is a frequency channel profile model. Stable OAI RFsim carrier keys are preserved unless explicit retune mode is added later.
INFO

if [ "$PROFILE" = "status" ]; then
  UE_POD="$(kubectl -n "$NS" get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  echo "UE_POD=$UE_POD" | tee -a "$PROOF_DIR/status.txt"
  if [ -n "$UE_POD" ]; then
    kubectl -n "$NS" exec "$UE_POD" -- sh -c 'ip addr show oaitun_ue1; tc qdisc show dev oaitun_ue1' \
      | tee -a "$PROOF_DIR/status.txt" || true
  fi
  echo "VERDICT=FREQUENCY_PROFILE_STATUS_DONE"
  echo "Proof: $PROOF_DIR"
  exit 0
fi

if [ "$MODE" = "--dry-run" ]; then
  echo "VERDICT=FREQUENCY_PROFILE_DRY_RUN_DONE"
  echo "Proof: $PROOF_DIR"
  exit 0
fi

patch_rfsim_values() {
  local input="$1"
  local output="$2"

  python3 - "$input" "$output" "$ENB_PLOSS" "$ENB_NOISE" "$UE_PLOSS" "$UE_NOISE" <<'PY'
import re, sys
src, dst, enb_ploss, enb_noise, ue_ploss, ue_noise = sys.argv[1:7]
lines=open(src).read().splitlines()
out=[]
current=None

for line in lines:
    m=re.search(r'model_name\s*=\s*"([^"]+)"', line)
    if m:
        current=m.group(1)

    if current == "rfsimu_channel_enB0" and "ploss_dB" in line:
        line=re.sub(r'ploss_dB\s*=\s*[^;]+;', f'ploss_dB       = {enb_ploss};', line)
    elif current == "rfsimu_channel_enB0" and "noise_power_dB" in line:
        line=re.sub(r'noise_power_dB\s*=\s*[^;]+;', f'noise_power_dB = {enb_noise};', line)
    elif current == "rfsimu_channel_ue0" and "ploss_dB" in line:
        line=re.sub(r'ploss_dB\s*=\s*[^;]+;', f'ploss_dB       = {ue_ploss};', line)
    elif current == "rfsimu_channel_ue0" and "noise_power_dB" in line:
        line=re.sub(r'noise_power_dB\s*=\s*[^;]+;', f'noise_power_dB = {ue_noise};', line)

    out.append(line)

open(dst, "w").write("\n".join(out) + "\n")
PY
}

patch_rfsim_values "$PROOF_DIR/ue-original-nr-ue.conf" "$PROOF_DIR/ue-new-nr-ue.conf"
patch_rfsim_values "$PROOF_DIR/du-original-gnb.conf" "$PROOF_DIR/du-new-gnb.conf"

echo "===== UE DIFF =====" | tee "$PROOF_DIR/diff.txt"
diff -u "$PROOF_DIR/ue-original-nr-ue.conf" "$PROOF_DIR/ue-new-nr-ue.conf" | tee -a "$PROOF_DIR/diff.txt" || true

echo "===== DU DIFF =====" | tee -a "$PROOF_DIR/diff.txt"
diff -u "$PROOF_DIR/du-original-gnb.conf" "$PROOF_DIR/du-new-gnb.conf" | tee -a "$PROOF_DIR/diff.txt" || true

kubectl -n "$NS" create cm "$ACTIVE_DU_CM" \
  --from-file=gnb.conf="$PROOF_DIR/du-new-gnb.conf" \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl -n "$NS" create cm "$UE_CM" \
  --from-file=nr-ue.conf="$PROOF_DIR/ue-new-nr-ue.conf" \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl -n "$NS" rollout restart deploy/"$ACTIVE_DU_DEPLOY"
kubectl -n "$NS" rollout status deploy/"$ACTIVE_DU_DEPLOY" --timeout=180s

kubectl -n "$NS" rollout restart deploy/"$UE_DEPLOY"
kubectl -n "$NS" rollout status deploy/"$UE_DEPLOY" --timeout=240s

log "Waiting for UE tunnel"
UE_POD=""
for i in $(seq 1 60); do
  UE_POD="$(kubectl -n "$NS" get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$UE_POD" ] && kubectl -n "$NS" exec "$UE_POD" -- ip addr show oaitun_ue1 >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

[ -n "$UE_POD" ] || fail "UE pod not found after rollout"

kubectl -n "$NS" exec "$UE_POD" -- ip addr show oaitun_ue1 | tee "$PROOF_DIR/ue-oaitun-after.txt"

if [ "$TC_CMD" = "clear" ]; then
  kubectl -n "$NS" exec "$UE_POD" -- sh -c 'tc qdisc del dev oaitun_ue1 root 2>/dev/null || true'
  echo "[INFO] tc shaping cleared"
elif [ "$TC_CMD" = "status" ]; then
  true
else
  kubectl -n "$NS" exec "$UE_POD" -- sh -c 'tc qdisc del dev oaitun_ue1 root 2>/dev/null || true'
  kubectl -n "$NS" exec "$UE_POD" -- sh -c "tc qdisc add dev oaitun_ue1 root netem $TC_CMD"
  echo "[INFO] tc netem applied: $TC_CMD"
fi

kubectl -n "$NS" exec "$UE_POD" -- tc qdisc show dev oaitun_ue1 | tee "$PROOF_DIR/tc-after.txt"

cat > "$PROOF_DIR/result.json" <<JSON
{
  "ok": true,
  "ue": "$UE",
  "profile": "$PROFILE",
  "description": "$DESCRIPTION",
  "freq_mhz": "$FREQ_MHZ",
  "band_label": "$BAND_LABEL",
  "model": "$MODEL",
  "expected": "$EXPECTED",
  "active_du_cm": "$ACTIVE_DU_CM",
  "active_du_deploy": "$ACTIVE_DU_DEPLOY",
  "serveraddr": "$SERVERADDR",
  "rf_values": "enB0 $ENB_PLOSS/$ENB_NOISE, ue0 $UE_PLOSS/$UE_NOISE",
  "tc_cmd": "$TC_CMD",
  "ue_pod": "$UE_POD",
  "proof_dir": "$PROOF_DIR",
  "note": "Frequency profile is implemented as RFsim channel metadata plus tc/netem shaping. Actual arbitrary NR band retune is intentionally not enabled yet because UE ConfigMaps do not expose matching frequency keys."
}
JSON

cat "$PROOF_DIR/result.json"

echo "VERDICT=FREQUENCY_PROFILE_APPLY_OK"
echo "Proof: $PROOF_DIR"
