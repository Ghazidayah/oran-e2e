#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/frequency-profile-functional-tests/$TS"
mkdir -p "$OUT"

LOG="$OUT/test.log"
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

restore_midband() {
  echo
  echo "===== SAFETY RESTORE mid-band-3500 / scheduler baseline ====="
  cd "$REPO" || return 0
  scripts/frequency/switch-ue-frequency-profile-du-aware.sh mid-band-3500 --apply \
    > "$OUT/restore-mid-band-3500.log" 2>&1 || true
  tail -120 "$OUT/restore-mid-band-3500.log" || true
}

trap 'echo "[INTERRUPTED] Restoring mid-band baseline"; restore_midband; exit 130' INT TERM

cd "$REPO" || exit 1

section "0. CONTEXT"
echo "Repo=$REPO"
echo "Dashboard=$BASE"
echo "Output=$OUT"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status-before.txt" || true

section "1. PREFLIGHT CLEAN STATE"
if bash -n scripts/frequency/switch-ue-frequency-profile-du-aware.sh; then
  pass "frequency switch script syntax OK"
else
  fail "frequency switch script syntax failed"
fi

if curl -fsS --max-time 20 "$BASE/api/handover/mixed-du/status" > "$OUT/handover-before.json"; then
  pass "handover status reachable"
  python3 -m json.tool "$OUT/handover-before.json" | head -120
else
  fail "handover status not reachable"
fi

python3 - "$OUT/handover-before.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("attached_count") == 5, d.get("attached_count")
assert d.get("handover_ready") is True, d.get("handover_ready")
assert "ue1" in d.get("blocked_ues", [])
print("PASS: 5 UEs attached, ue1 protected, topology ready")
PY

if [ "$?" -eq 0 ]; then
  pass "topology ready before frequency tests"
else
  fail "topology not ready before frequency tests"
fi

if bash scripts/validate-e2e.sh > "$OUT/validate-before.log" 2>&1; then
  pass "baseline validate-e2e passed before frequency tests"
else
  fail "baseline validate-e2e failed before frequency tests"
fi
tail -80 "$OUT/validate-before.log"

section "2. FREQUENCY PROFILE APPLY + KPI TESTS"

RESULTS_CSV="$OUT/results.csv"
echo "profile,apply_ok,e2e_ok,image_mbps,tcp_mbps,rf_values,tc_cmd,verdict" > "$RESULTS_CSV"

run_one_ue_job() {
  local profile="$1"
  local scenario="$2"
  local payload="$OUT/payload-${profile}-${scenario}.json"
  local result="$OUT/result-${profile}-${scenario}.json"

  cat > "$payload" <<JSON
{
  "jobs": [
    {"ue":"ue1","scenario":"$scenario"}
  ]
}
JSON

  echo "--- running ue1 scenario=$scenario for profile=$profile"

  if curl -fsS --max-time 900 \
    -H "Content-Type: application/json" \
    -X POST \
    --data-binary @"$payload" \
    "$BASE/api/ues/embb-scenarios" > "$result"; then
    python3 -m json.tool "$result" > "$result.pretty" 2>/dev/null || true
    head -140 "$result.pretty" 2>/dev/null || head -100 "$result"

    python3 - "$result" "$scenario" <<'PY'
import json, sys, re
path, scenario = sys.argv[1], sys.argv[2]
d=json.load(open(path))
ok = d.get("ok") is True and d.get("selected_count") == 1 and d.get("results", [{}])[0].get("ok") is True
r = d.get("results", [{}])[0]
out = r.get("output", "")
mbps = ""
try:
    inner = json.loads(out.split("\nScenario:")[0])
    mbps = inner.get("throughput_mbps", "")
except Exception:
    m = re.search(r"approx_total_mbps=([0-9.]+)", out)
    if m:
        mbps = m.group(1)

print("JOB_OK=true" if ok else "JOB_OK=false")
print(f"MBPS={mbps}")
PY
  else
    echo "JOB_OK=false"
    echo "MBPS="
    return 1
  fi
}

for profile in low-band-700 mid-band-3500 mmwave-28000-nlos; do
  section "2.$profile APPLY + KPI"

  APPLY_LOG="$OUT/apply-${profile}.log"

  if scripts/frequency/switch-ue-frequency-profile-du-aware.sh "$profile" --apply > "$APPLY_LOG" 2>&1; then
    pass "apply $profile completed"
    apply_ok="true"
  else
    fail "apply $profile failed"
    apply_ok="false"
  fi

  tail -160 "$APPLY_LOG"

  RESULT_JSON="$(find "$HOME/oran-proof/frequency-profile-control-du-aware" -path "*/result.json" -type f | sort | tail -n1)"
  cp "$RESULT_JSON" "$OUT/frequency-result-${profile}.json" 2>/dev/null || true

  rf_values="$(python3 - "$OUT/frequency-result-${profile}.json" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get("rf_values",""))
except Exception:
    print("")
PY
)"
  tc_cmd="$(python3 - "$OUT/frequency-result-${profile}.json" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print(d.get("tc_cmd",""))
except Exception:
    print("")
PY
)"

  if bash scripts/validate-e2e.sh > "$OUT/validate-${profile}.log" 2>&1; then
    pass "validate-e2e passed after $profile"
    e2e_ok="true"
  else
    fail "validate-e2e failed after $profile"
    e2e_ok="false"
  fi
  tail -80 "$OUT/validate-${profile}.log"

  image_out="$(run_one_ue_job "$profile" image | tee "$OUT/job-image-${profile}.log")"
  image_mbps="$(echo "$image_out" | awk -F= '/^MBPS=/{print $2}' | tail -1)"
  image_ok="$(echo "$image_out" | awk -F= '/^JOB_OK=/{print $2}' | tail -1)"

  if [ "$image_ok" = "true" ]; then
    pass "image KPI OK for $profile: ${image_mbps} Mbps"
  else
    fail "image KPI failed for $profile"
  fi

  tcp_out="$(run_one_ue_job "$profile" tcp_download | tee "$OUT/job-tcp-${profile}.log")"
  tcp_mbps="$(echo "$tcp_out" | awk -F= '/^MBPS=/{print $2}' | tail -1)"
  tcp_ok="$(echo "$tcp_out" | awk -F= '/^JOB_OK=/{print $2}' | tail -1)"

  if [ "$tcp_ok" = "true" ]; then
    pass "tcp_download KPI OK for $profile: ${tcp_mbps} Mbps"
  else
    fail "tcp_download KPI failed for $profile"
  fi

  verdict="PASS"
  if [ "$apply_ok" != "true" ] || [ "$e2e_ok" != "true" ] || [ "$image_ok" != "true" ] || [ "$tcp_ok" != "true" ]; then
    verdict="FAIL"
  fi

  echo "$profile,$apply_ok,$e2e_ok,$image_mbps,$tcp_mbps,\"$rf_values\",\"$tc_cmd\",$verdict" >> "$RESULTS_CSV"
done

section "3. RESTORE BASELINE"
restore_midband

if bash scripts/validate-e2e.sh > "$OUT/validate-after-restore.log" 2>&1; then
  pass "validate-e2e passed after frequency restore"
else
  fail "validate-e2e failed after frequency restore"
fi
tail -100 "$OUT/validate-after-restore.log"

section "4. RESULTS ANALYSIS"
column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"

python3 - "$RESULTS_CSV" > "$OUT/analysis.txt" <<'PY'
import csv, sys

rows=list(csv.DictReader(open(sys.argv[1])))
failures=0
warnings=0

print("Frequency KPI analysis:")
for r in rows:
    print(r)

def f(x):
    try:
        return float(x)
    except Exception:
        return None

vals={r["profile"]: f(r["tcp_mbps"]) for r in rows}

low=vals.get("low-band-700")
mid=vals.get("mid-band-3500")
nlos=vals.get("mmwave-28000-nlos")

if all(v is not None for v in [low, mid, nlos]):
    print(f"TCP low-band-700={low}")
    print(f"TCP mid-band-3500={mid}")
    print(f"TCP mmwave-28000-nlos={nlos}")

    if nlos < mid:
        print("[PASS] mmwave-28000-nlos is lower than mid-band baseline")
    else:
        print("[WARN] mmwave-28000-nlos was not lower than mid-band baseline")
        warnings += 1

    if nlos < low:
        print("[PASS] mmwave-28000-nlos is lower than low-band model")
    else:
        print("[WARN] mmwave-28000-nlos was not lower than low-band model")
        warnings += 1
else:
    print("[FAIL] Missing TCP KPI values")
    failures += 1

for r in rows:
    if r["verdict"] != "PASS":
        print("[FAIL] profile verdict not PASS:", r["profile"])
        failures += 1

print(f"KPI_WARNINGS={warnings}")
print(f"KPI_FAILURES={failures}")
raise SystemExit(1 if failures else 0)
PY

cat "$OUT/analysis.txt"

if grep -q "KPI_FAILURES=0" "$OUT/analysis.txt"; then
  pass "frequency KPI analysis has no hard failures"
else
  fail "frequency KPI analysis has hard failures"
fi

if grep -q "KPI_WARNINGS=0" "$OUT/analysis.txt"; then
  pass "frequency KPI ladder has no warnings"
else
  warn "frequency KPI ladder has warnings; may need tuning"
fi

section "5. SUMMARY"
git status --short | tee "$OUT/git-status-after.txt" || true

echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=FREQUENCY_PROFILE_CLI_FUNCTIONAL_PASS"
else
  echo "VERDICT=FREQUENCY_PROFILE_CLI_FUNCTIONAL_HAS_FAILURES"
fi
