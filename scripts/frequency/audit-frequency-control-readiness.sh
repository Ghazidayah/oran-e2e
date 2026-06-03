#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
NS="${RAN_NS:-oran-ran}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/frequency-control-readiness/$TS"
mkdir -p "$OUT"

LOG="$OUT/audit.log"
exec > >(tee -a "$LOG") 2>&1

PASS=0
FAIL=0
WARN=0

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN+1)); }

section() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

cd "$REPO" || {
  echo "[FATAL] Cannot cd to $REPO"
  exit 1
}

section "0. CONTEXT"
echo "Repo=$REPO"
echo "Namespace=$NS"
echo "Dashboard=$BASE"
echo "Output=$OUT"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status.txt" || true

section "1. CURRENT VALIDATED DASHBOARD STATE"

if curl -fsS --max-time 20 "$BASE/api/radio/status" > "$OUT/radio-status.json"; then
  pass "radio status reachable"
  python3 -m json.tool "$OUT/radio-status.json" | head -100

  ACTIVE_PROFILE="$(python3 - "$OUT/radio-status.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d.get("active_profile",""))
PY
)"
  if [ "$ACTIVE_PROFILE" = "scheduler-auto" ]; then
    pass "radio profile is scheduler-auto"
  else
    warn "radio profile is $ACTIVE_PROFILE, expected scheduler-auto before frequency work"
  fi
else
  fail "radio status not reachable"
fi

if curl -fsS --max-time 20 "$BASE/api/handover/mixed-du/status" > "$OUT/handover-status.json"; then
  pass "handover status reachable"
  python3 -m json.tool "$OUT/handover-status.json" | head -160

  python3 - "$OUT/handover-status.json" <<'PY' > "$OUT/handover-clean-check.txt"
import json, sys
d=json.load(open(sys.argv[1]))
print("attached_count=", d.get("attached_count"))
print("expected_count=", d.get("expected_count"))
print("handover_ready=", d.get("handover_ready"))
for u in d.get("ues", []):
    print(u.get("name"), u.get("attached"), u.get("du"), u.get("serveraddr"), u.get("protected"), u.get("tunnel_ip"))

ok = (
    d.get("attached_count") == 5 and
    d.get("expected_count") == 5 and
    d.get("handover_ready") is True and
    "ue1" in d.get("blocked_ues", [])
)
print("CLEAN_HANDOVER_OK=", ok)
PY

  cat "$OUT/handover-clean-check.txt"

  if grep -q "CLEAN_HANDOVER_OK= True" "$OUT/handover-clean-check.txt"; then
    pass "handover topology is ready"
  else
    fail "handover topology is not clean/ready"
  fi
else
  fail "handover status not reachable"
fi

if curl -fsS --max-time 20 "$BASE/api/ues" > "$OUT/api-ues.json"; then
  pass "UE API reachable"
  python3 -m json.tool "$OUT/api-ues.json" | head -140
else
  fail "UE API not reachable"
fi

section "2. CONFIGMAP INVENTORY"

if kubectl -n "$NS" get cm > "$OUT/configmaps.txt" 2>&1; then
  pass "ConfigMaps listed"
else
  fail "ConfigMaps list failed"
fi

cat "$OUT/configmaps.txt"

CMS=(
  "oai-nrue-config"
  "oai-nrue-config-2"
  "oai-nrue-config-3"
  "oai-nrue-config-4"
  "oai-nrue-config-5"
  "oai-du0-f1-config"
  "oai-du1-f1-config"
)

for cm in "${CMS[@]}"; do
  echo
  echo "--- Dumping ConfigMap: $cm"
  if kubectl -n "$NS" get cm "$cm" -o yaml > "$OUT/${cm}.yaml" 2>&1; then
    pass "dumped $cm"
  else
    warn "could not dump $cm"
  fi
done

section "3. FREQUENCY / BANDWIDTH KEY DISCOVERY"

PATTERN='freq|frequency|arfcn|absoluteFrequency|PointA|SSB|ssb|carrierBandwidth|bandwidth|N_RB|nr_band|subcarrier|sCS|dl_|ul_|downlink|uplink'

for cm in "${CMS[@]}"; do
  file="$OUT/${cm}.yaml"
  [ -f "$file" ] || continue

  echo
  echo "===== $cm frequency-related lines ====="
  grep -Ein "$PATTERN" "$file" | tee "$OUT/${cm}.frequency-lines.txt" || true

  if [ -s "$OUT/${cm}.frequency-lines.txt" ]; then
    pass "$cm has frequency/bandwidth related keys"
  else
    warn "$cm has no obvious frequency/bandwidth keys"
  fi
done

section "4. RFsim CHANNEL KEY DISCOVERY"

RF_PATTERN='rfsimu|AWGN|ploss|noise_power|forgetfact|model_name|channel|serveraddr'

for cm in "${CMS[@]}"; do
  file="$OUT/${cm}.yaml"
  [ -f "$file" ] || continue

  echo
  echo "===== $cm RFsim/channel lines ====="
  grep -Ein "$RF_PATTERN" "$file" | tee "$OUT/${cm}.rfsim-lines.txt" || true

  if [ -s "$OUT/${cm}.rfsim-lines.txt" ]; then
    pass "$cm has RFsim/channel keys"
  else
    warn "$cm has no obvious RFsim/channel keys"
  fi
done

section "5. RAN PODS AND RFsim ENDPOINTS"

if kubectl -n "$NS" get pods -o wide > "$OUT/ran-pods.txt" 2>&1; then
  pass "RAN pods listed"
else
  fail "RAN pods list failed"
fi
cat "$OUT/ran-pods.txt"

if kubectl -n "$NS" get endpoints oai-du0-rfsim oai-du1-rfsim -o wide > "$OUT/du-rfsim-endpoints.txt" 2>&1; then
  pass "DU0/DU1 RFsim endpoints exist"
else
  fail "DU0/DU1 RFsim endpoints missing"
fi
cat "$OUT/du-rfsim-endpoints.txt"

section "6. UE1 tc/netem READINESS"

UE1_POD="$(kubectl -n "$NS" get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
echo "UE1_POD=$UE1_POD" | tee "$OUT/ue1-pod.txt"

if [ -n "$UE1_POD" ]; then
  if kubectl -n "$NS" exec "$UE1_POD" -- ip addr show oaitun_ue1 > "$OUT/ue1-oaitun.txt" 2>&1; then
    pass "ue1 oaitun_ue1 exists"
    cat "$OUT/ue1-oaitun.txt"
  else
    fail "ue1 oaitun_ue1 missing"
    cat "$OUT/ue1-oaitun.txt"
  fi

  if kubectl -n "$NS" exec "$UE1_POD" -- sh -c 'command -v tc >/dev/null 2>&1 && tc qdisc show dev oaitun_ue1' > "$OUT/ue1-tc.txt" 2>&1; then
    pass "tc available in ue1 pod"
    cat "$OUT/ue1-tc.txt"
  else
    fail "tc not available or qdisc unreadable in ue1 pod"
    cat "$OUT/ue1-tc.txt"
  fi
else
  fail "ue1 pod not found"
fi

section "7. REUSE RADIO PROFILE INFRASTRUCTURE"

for f in \
  web-dashboard/radio_profile_api.py \
  web-dashboard/static/mixed-du-handover.js \
  scripts/radio/switch-ue-radio-profile-du-aware.sh \
  web-dashboard/radio-profile-results.json
do
  if [ -f "$f" ]; then
    pass "exists: $f"
  else
    fail "missing: $f"
  fi
done

grep -R "tc qdisc\|netem\|ploss_dB\|noise_power_dB\|radio_bp\|/api/radio" -n \
  scripts/radio \
  web-dashboard/radio_profile_api.py \
  web-dashboard/static/mixed-du-handover.js \
  > "$OUT/reuse-radio-infra-grep.txt" 2>&1 || true

head -180 "$OUT/reuse-radio-infra-grep.txt"

section "8. FREQUENCY PROFILE MODEL PROPOSAL"

cat > "$OUT/frequency-profile-model.md" <<'MD'
# Frequency Control Model Proposal

Goal:
- Not only changing a number in the config.
- A frequency profile should change:
  1. Frequency/band metadata when supported by current OAI configs.
  2. RFsim path-loss/noise metadata.
  3. tc/netem shaping on oaitun_ue1.
  4. KPI results visible in dashboard.

Important:
- RFsim does not guarantee realistic KPI changes from frequency number alone.
- Therefore, use a physics-inspired profile:
  FSPL delta = 20 * log10(freq_mhz / baseline_freq_mhz)
- Combine with bandwidth and LOS/NLOS assumptions.

Candidate profiles:

| profile | freq_mhz | band label | model | expected behavior |
|---|---:|---|---|---|
| low-band-700 | 700 | coverage band | lower path loss, lower bandwidth ceiling | stable, medium/low throughput |
| mid-band-3500 | 3500 | 5G n78-like | balanced path loss + bandwidth | balanced throughput |
| cband-3800 | 3800 | high mid-band | slightly higher path loss | slightly lower than 3500 |
| mmwave-28000-los | 28000 | mmWave LOS | high bandwidth, clean LOS | highest throughput |
| mmwave-28000-nlos | 28000 | mmWave NLOS | high obstruction loss | lowest / unstable throughput |

Dashboard output should show:
- active frequency profile
- frequency MHz
- band label
- path loss delta
- RFsim values
- netem values
- ping avg
- TCP Mbps
- image Mbps
- verdict
MD

cat "$OUT/frequency-profile-model.md"

section "9. BASELINE E2E SAFETY CHECK"

if bash scripts/validate-e2e.sh > "$OUT/validate-e2e.log" 2>&1; then
  pass "validate-e2e passed"
else
  fail "validate-e2e failed"
fi
tail -100 "$OUT/validate-e2e.log"

section "10. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=FREQUENCY_CONTROL_READINESS_PASS"
else
  echo "VERDICT=FREQUENCY_CONTROL_READINESS_HAS_FAILURES"
fi
