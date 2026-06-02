#!/usr/bin/env bash
set -Eeuo pipefail

RAN_NS="${RAN_NS:-oran-ran}"
UE="${1:-}"
PROFILE="${2:-}"
MODE="${3:---apply}"

PROOF_ROOT="${PROOF_ROOT:-$HOME/oran-proof/radio-profile-control-du-aware}"
TS="$(date +%Y%m%d-%H%M%S)"
PROOF_DIR="$PROOF_ROOT/$TS"
mkdir -p "$PROOF_DIR"

die() {
  echo "[FAIL] $*" >&2
  echo "VERDICT=FAIL"
  echo "REASON=$*" | tee -a "$PROOF_DIR/verdict.txt"
  exit 1
}

info() {
  echo "[INFO] $*" | tee -a "$PROOF_DIR/run.log"
}

usage() {
  cat <<EOF
Usage:
  $0 ue1 status
  $0 ue1 <profile> --apply

Profiles:
  scheduler-auto
  qpsk-robust
  qam16-balanced
  qam64-throughput
  qam256-max
  qpsk-stress

This script:
  1. Preserves serveraddr / DU target
  2. Preserves nssai_sst / nssai_sd
  3. Updates RFsim metadata on UE + active DU
  4. Restarts active DU + UE
  5. Waits for oaitun_ue1
  6. Applies tc netem shaping on oaitun_ue1 inside the UE pod
EOF
}

case "$UE" in
  ue1)
    UE_DEPLOY="oai-nr-ue"
    UE_CM="oai-nrue-config"
    UE_APP_LABEL="app=oai-nr-ue"
    ;;
  ""|-h|--help)
    usage
    exit 0
    ;;
  *)
    die "Only ue1 is supported in this validated radio-profile script. Got: $UE"
    ;;
esac

profile_values() {
  case "$PROFILE" in
    scheduler-auto)
      ENB_PLOSS="20"; ENB_NOISE="-4"; UE_PLOSS="20"; UE_NOISE="-2"
      TC_MODE="clear"
      TC_DESC="no tc shaping / baseline"
      PROFILE_DESC="baseline scheduler auto"
      ;;
    qpsk-robust)
      ENB_PLOSS="40"; ENB_NOISE="10"; UE_PLOSS="40"; UE_NOISE="12"
      TC_MODE="netem"; TC_RATE="18mbit"; TC_DELAY="8ms"; TC_JITTER="2ms"; TC_LOSS="0%"
      TC_DESC="rate 18mbit delay 8ms 2ms loss 0%"
      PROFILE_DESC="robust low-throughput profile using RFsim metadata + calibrated netem"
      ;;
    qam16-balanced)
      ENB_PLOSS="26"; ENB_NOISE="0"; UE_PLOSS="26"; UE_NOISE="2"
      TC_MODE="netem"; TC_RATE="32mbit"; TC_DELAY="2ms"; TC_JITTER="1ms"; TC_LOSS="0%"
      TC_DESC="rate 32mbit delay 2ms 1ms loss 0%"
      PROFILE_DESC="balanced medium-throughput profile using RFsim metadata + calibrated netem"
      ;;
    qam64-throughput)
      ENB_PLOSS="18"; ENB_NOISE="-6"; UE_PLOSS="18"; UE_NOISE="-4"
      TC_MODE="netem"; TC_RATE="45mbit"; TC_DELAY="1ms"; TC_JITTER="0ms"; TC_LOSS="0%"
      TC_DESC="rate 45mbit delay 1ms 0ms loss 0%"
      PROFILE_DESC="high-throughput profile using RFsim metadata + light calibrated netem"
      ;;
    qam256-max)
      ENB_PLOSS="12"; ENB_NOISE="-10"; UE_PLOSS="12"; UE_NOISE="-8"
      TC_MODE="clear"
      TC_DESC="clear / no shaping / native ceiling"
      PROFILE_DESC="max-throughput profile using RFsim metadata + native ceiling"
      ;;
    qpsk-stress)
      ENB_PLOSS="60"; ENB_NOISE="25"; UE_PLOSS="60"; UE_NOISE="28"
      TC_MODE="netem"; TC_RATE="8mbit"; TC_DELAY="50ms"; TC_JITTER="15ms"; TC_LOSS="2%"
      TC_DESC="rate 8mbit delay 50ms 15ms loss 2%"
      PROFILE_DESC="stress profile for calibration only"
      ;;
    status)
      return 1
      ;;
    *)
      die "Unsupported profile: $PROFILE"
      ;;
  esac
}

extract_ue_state() {
  local file="$1"
  python3 - "$file" <<'PY'
import re, sys
s=open(sys.argv[1]).read()

def one(name, pattern):
    m=re.search(pattern, s)
    print(f"{name}={m.group(1).strip() if m else 'MISSING'}")

one("serveraddr", r'serveraddr\s*=\s*"([^"]+)"')
one("nssai_sst", r'nssai_sst\s*=\s*([^;]+)')
one("nssai_sd", r'nssai_sd\s*=\s*([^;]+)')

current=None
vals={"enB0":{}, "ue0":{}}
for line in s.splitlines():
    if "model_name" in line and "rfsimu_channel_enB0" in line:
        current="enB0"
    elif "model_name" in line and "rfsimu_channel_ue0" in line:
        current="ue0"
    elif current and "ploss_dB" in line:
        m=re.search(r'ploss_dB\s*=\s*([^;]+)', line)
        if m: vals[current]["ploss_dB"]=m.group(1).strip()
    elif current and "noise_power_dB" in line:
        m=re.search(r'noise_power_dB\s*=\s*([^;]+)', line)
        if m: vals[current]["noise_power_dB"]=m.group(1).strip()

for model in ["enB0", "ue0"]:
    print(f"{model}_ploss_dB={vals[model].get('ploss_dB','MISSING')}")
    print(f"{model}_noise_power_dB={vals[model].get('noise_power_dB','MISSING')}")
PY
}

extract_radio_state() {
  local file="$1"
  python3 - "$file" <<'PY'
import re, sys
s=open(sys.argv[1]).read()
current=None
vals={"enB0":{}, "ue0":{}}
for line in s.splitlines():
    if "model_name" in line and "rfsimu_channel_enB0" in line:
        current="enB0"
    elif "model_name" in line and "rfsimu_channel_ue0" in line:
        current="ue0"
    elif current and "ploss_dB" in line:
        m=re.search(r'ploss_dB\s*=\s*([^;]+)', line)
        if m: vals[current]["ploss_dB"]=m.group(1).strip()
    elif current and "noise_power_dB" in line:
        m=re.search(r'noise_power_dB\s*=\s*([^;]+)', line)
        if m: vals[current]["noise_power_dB"]=m.group(1).strip()
for model in ["enB0", "ue0"]:
    print(f"{model}_ploss_dB={vals[model].get('ploss_dB','MISSING')}")
    print(f"{model}_noise_power_dB={vals[model].get('noise_power_dB','MISSING')}")
PY
}

patch_radio_file() {
  local orig="$1"
  local new="$2"
  python3 - "$orig" "$new" "$ENB_PLOSS" "$ENB_NOISE" "$UE_PLOSS" "$UE_NOISE" <<'PY'
import re, sys
src, dst, enb_ploss, enb_noise, ue_ploss, ue_noise = sys.argv[1:]
s=open(src).read()
if "channelmod" not in s:
    raise SystemExit("[FAIL] no channelmod block found in config")

lines=s.splitlines()
out=[]
current=None

for line in lines:
    if "model_name" in line and "rfsimu_channel_enB0" in line:
        current="enB0"
    elif "model_name" in line and "rfsimu_channel_ue0" in line:
        current="ue0"

    if current == "enB0" and re.search(r'\bploss_dB\b', line):
        line=re.sub(r'ploss_dB\s*=\s*[^;]+;', f'ploss_dB       = {enb_ploss};', line)
    elif current == "enB0" and re.search(r'\bnoise_power_dB\b', line):
        line=re.sub(r'noise_power_dB\s*=\s*[^;]+;', f'noise_power_dB = {enb_noise};', line)
    elif current == "ue0" and re.search(r'\bploss_dB\b', line):
        line=re.sub(r'ploss_dB\s*=\s*[^;]+;', f'ploss_dB       = {ue_ploss};', line)
    elif current == "ue0" and re.search(r'\bnoise_power_dB\b', line):
        line=re.sub(r'noise_power_dB\s*=\s*[^;]+;', f'noise_power_dB = {ue_noise};', line)
    out.append(line)

open(dst, "w").write("\n".join(out) + "\n")
PY
}

wait_for_tunnel() {
  for i in $(seq 1 90); do
    POD="$(kubectl -n "$RAN_NS" get pod -l "$UE_APP_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "$POD" ]; then
      if kubectl -n "$RAN_NS" exec "$POD" -- ip addr show oaitun_ue1 >/dev/null 2>&1; then
        echo "$POD"
        return 0
      fi
    fi
    sleep 2
  done
  return 1
}

apply_tc_profile() {
  local pod="$1"

  kubectl -n "$RAN_NS" exec "$pod" -- sh -lc 'command -v tc >/dev/null 2>&1' \
    || die "tc command not found inside UE pod $pod"

  kubectl -n "$RAN_NS" exec "$pod" -- sh -lc 'ip addr show oaitun_ue1 >/dev/null 2>&1' \
    || die "oaitun_ue1 not found inside UE pod $pod"

  kubectl -n "$RAN_NS" exec "$pod" -- sh -lc 'tc qdisc del dev oaitun_ue1 root 2>/dev/null || true'

  if [ "$TC_MODE" = "clear" ]; then
    info "tc shaping cleared on oaitun_ue1"
  else
    info "Applying tc netem on oaitun_ue1: $TC_DESC"

    NETEM_CMD="tc qdisc add dev oaitun_ue1 root netem"

    if [ "${TC_DELAY:-0ms}" != "0ms" ]; then
      if [ "${TC_JITTER:-0ms}" != "0ms" ]; then
        NETEM_CMD="$NETEM_CMD delay $TC_DELAY $TC_JITTER distribution normal"
      else
        NETEM_CMD="$NETEM_CMD delay $TC_DELAY"
      fi
    fi

    if [ "${TC_LOSS:-0%}" != "0%" ]; then
      NETEM_CMD="$NETEM_CMD loss $TC_LOSS"
    fi

    if [ -n "${TC_RATE:-}" ]; then
      NETEM_CMD="$NETEM_CMD rate $TC_RATE"
    fi

    echo "NETEM_CMD=$NETEM_CMD" | tee "$PROOF_DIR/tc-command.txt"

    kubectl -n "$RAN_NS" exec "$pod" -- sh -lc "$NETEM_CMD" \
      || die "failed to apply tc netem: $TC_DESC"
  fi

  kubectl -n "$RAN_NS" exec "$pod" -- sh -lc 'tc qdisc show dev oaitun_ue1' | tee "$PROOF_DIR/tc-qdisc.txt"
}

info "UE=$UE"
info "PROFILE=$PROFILE"
info "MODE=$MODE"
info "PROOF_DIR=$PROOF_DIR"

[ "$MODE" = "--apply" ] || [ "$PROFILE" = "status" ] || die "This final script supports --apply only. Got MODE=$MODE"

kubectl -n "$RAN_NS" get cm "$UE_CM" >/dev/null 2>&1 || die "Missing UE ConfigMap: $UE_CM"
kubectl -n "$RAN_NS" get deploy "$UE_DEPLOY" >/dev/null 2>&1 || die "Missing UE deployment: $UE_DEPLOY"

UE_ORIG="$PROOF_DIR/ue-original-nr-ue.conf"
UE_NEW="$PROOF_DIR/ue-new-nr-ue.conf"
UE_BEFORE="$PROOF_DIR/ue-before-state.txt"
UE_AFTER="$PROOF_DIR/ue-after-state.txt"

kubectl -n "$RAN_NS" get cm "$UE_CM" -o jsonpath='{.data.nr-ue\.conf}' > "$UE_ORIG"
cp "$UE_ORIG" "$UE_NEW"

extract_ue_state "$UE_ORIG" | tee "$UE_BEFORE"

SERVERADDR="$(awk -F= '$1=="serveraddr"{print $2}' "$UE_BEFORE" | tail -n1)"

case "$SERVERADDR" in
  oai-du0-rfsim)
    DU_CM="oai-du0-f1-config"
    DU_DEPLOY="oai-du0"
    ;;
  oai-du1-rfsim)
    DU_CM="oai-du1-f1-config"
    DU_DEPLOY="oai-du1"
    ;;
  *)
    die "Unknown serveraddr=$SERVERADDR. Refusing to guess active DU."
    ;;
esac

info "ACTIVE_DU_CM=$DU_CM"
info "ACTIVE_DU_DEPLOY=$DU_DEPLOY"

DU_ORIG="$PROOF_DIR/du-original-gnb.conf"
DU_NEW="$PROOF_DIR/du-new-gnb.conf"
DU_BEFORE="$PROOF_DIR/du-before-state.txt"
DU_AFTER="$PROOF_DIR/du-after-state.txt"

kubectl -n "$RAN_NS" get cm "$DU_CM" -o jsonpath='{.data.gnb\.conf}' > "$DU_ORIG"
cp "$DU_ORIG" "$DU_NEW"

echo "===== ACTIVE DU RADIO STATE BEFORE =====" | tee "$DU_BEFORE"
extract_radio_state "$DU_ORIG" | tee -a "$DU_BEFORE"

if [ "$PROFILE" = "status" ]; then
  POD="$(kubectl -n "$RAN_NS" get pod -l "$UE_APP_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  echo "ACTIVE_DU_CM=$DU_CM"
  echo "ACTIVE_DU_DEPLOY=$DU_DEPLOY"
  echo "UE_POD=$POD"
  if [ -n "$POD" ]; then
    kubectl -n "$RAN_NS" exec "$POD" -- sh -lc 'tc qdisc show dev oaitun_ue1 2>/dev/null || true'
  fi
  echo "VERDICT=DU_AWARE_RADIO_PROFILE_STATUS_DONE" | tee "$PROOF_DIR/verdict.txt"
  echo "Proof: $PROOF_DIR"
  exit 0
fi

profile_values

patch_radio_file "$UE_ORIG" "$UE_NEW"
patch_radio_file "$DU_ORIG" "$DU_NEW"

extract_ue_state "$UE_NEW" | tee "$UE_AFTER"
echo "===== ACTIVE DU RADIO STATE AFTER =====" | tee "$DU_AFTER"
extract_radio_state "$DU_NEW" | tee -a "$DU_AFTER"

for key in serveraddr nssai_sst nssai_sd; do
  before="$(awk -F= -v k="$key" '$1==k{print $2}' "$UE_BEFORE" | tail -n1)"
  after="$(awk -F= -v k="$key" '$1==k{print $2}' "$UE_AFTER" | tail -n1)"
  [ "$before" = "$after" ] || die "Preservation failed for $key: before=$before after=$after"
done

echo "===== UE DIFF ====="
diff -u "$UE_ORIG" "$UE_NEW" | tee "$PROOF_DIR/ue-diff.txt" || true

echo "===== ACTIVE DU DIFF ====="
diff -u "$DU_ORIG" "$DU_NEW" | tee "$PROOF_DIR/du-diff.txt" || true

cat > "$PROOF_DIR/profile-summary.txt" <<EOF
UE=$UE
PROFILE=$PROFILE
DESCRIPTION=$PROFILE_DESC
MODE=$MODE
UE_CONFIGMAP=$UE_CM
UE_DEPLOYMENT=$UE_DEPLOY
ACTIVE_DU_CONFIGMAP=$DU_CM
ACTIVE_DU_DEPLOYMENT=$DU_DEPLOY
SERVERADDR_PRESERVED=$SERVERADDR
S_NSSAI_PRESERVED=yes
TC_PROFILE=$TC_DESC

RFsim metadata:
  rfsimu_channel_enB0:
    ploss_dB=$ENB_PLOSS
    noise_power_dB=$ENB_NOISE
  rfsimu_channel_ue0:
    ploss_dB=$UE_PLOSS
    noise_power_dB=$UE_NOISE

Important:
  Direct forced modulation was not proven.
  This final profile combines RFsim metadata with tc netem shaping.
EOF

cat "$PROOF_DIR/profile-summary.txt"

kubectl -n "$RAN_NS" get cm "$UE_CM" -o yaml > "$PROOF_DIR/${UE_CM}-backup.yaml"
kubectl -n "$RAN_NS" get cm "$DU_CM" -o yaml > "$PROOF_DIR/${DU_CM}-backup.yaml"

info "Applying active DU ConfigMap update: $DU_CM"
kubectl -n "$RAN_NS" create configmap "$DU_CM" \
  --from-file=gnb.conf="$DU_NEW" \
  --dry-run=client -o yaml | kubectl -n "$RAN_NS" apply -f - | tee "$PROOF_DIR/apply-du-configmap.txt"

info "Applying UE ConfigMap update: $UE_CM"
kubectl -n "$RAN_NS" create configmap "$UE_CM" \
  --from-file=nr-ue.conf="$UE_NEW" \
  --dry-run=client -o yaml | kubectl -n "$RAN_NS" apply -f - | tee "$PROOF_DIR/apply-ue-configmap.txt"

info "Restarting active DU deployment: $DU_DEPLOY"
kubectl -n "$RAN_NS" rollout restart deploy "$DU_DEPLOY" | tee "$PROOF_DIR/restart-du.txt"
kubectl -n "$RAN_NS" rollout status deploy "$DU_DEPLOY" --timeout=5m | tee "$PROOF_DIR/status-du.txt"

info "Restarting UE deployment: $UE_DEPLOY"
kubectl -n "$RAN_NS" rollout restart deploy "$UE_DEPLOY" | tee "$PROOF_DIR/restart-ue.txt"
kubectl -n "$RAN_NS" rollout status deploy "$UE_DEPLOY" --timeout=5m | tee "$PROOF_DIR/status-ue.txt"

info "Waiting for UE tunnel"
UE_POD="$(wait_for_tunnel)" || die "oaitun_ue1 did not return after profile switch"
echo "UE_POD=$UE_POD" | tee "$PROOF_DIR/ue-pod.txt"

kubectl -n "$RAN_NS" exec "$UE_POD" -- ip addr show oaitun_ue1 | tee "$PROOF_DIR/oaitun_ue1.txt"
kubectl -n "$RAN_NS" exec "$UE_POD" -- ip route | tee "$PROOF_DIR/ue-route.txt"

apply_tc_profile "$UE_POD"

echo "VERDICT=DU_AWARE_RADIO_PROFILE_APPLY_OK" | tee "$PROOF_DIR/verdict.txt"
echo "Proof: $PROOF_DIR"
