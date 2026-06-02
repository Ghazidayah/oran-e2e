#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
TRAFFIC_API="${TRAFFIC_API:-http://127.0.0.1:5055}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-03-real-slices-$TS"
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

cd "$REPO" || {
  echo "[FATAL] Cannot cd to $REPO"
  exit 1
}

section "0. CONTEXT"
echo "Repo=$REPO"
echo "Dashboard=$BASE"
echo "Traffic API=$TRAFFIC_API"
echo "Output=$OUT"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status.txt" || true

section "1. PREFLIGHT"
if curl -fsS --max-time 15 "$BASE/" > "$OUT/dashboard.html"; then
  pass "dashboard page reachable"
else
  fail "dashboard page not reachable"
fi

if grep -q "Real S-NSSAI Slice Traffic - Phase 3" "$OUT/dashboard.html"; then
  pass "real slice dashboard section exists"
else
  fail "real slice dashboard section missing"
fi

for marker in "Run eMBB Slice" "Run URLLC Slice" "Run mMTC Slice" "Run V2X Slice"; do
  if grep -q "$marker" "$OUT/dashboard.html"; then
    pass "button marker present: $marker"
  else
    fail "button marker missing: $marker"
  fi
done

if curl -fsS --max-time 20 "$TRAFFIC_API/api/traffic/health" > "$OUT/traffic-health.json"; then
  pass "Traffic API health reachable"
  python3 -m json.tool "$OUT/traffic-health.json" | head -60
else
  fail "Traffic API health failed"
fi

if curl -fsS --max-time 20 "$TRAFFIC_API/api/traffic/real-slices" > "$OUT/real-slices.json"; then
  pass "real slice profile endpoint reachable"
  python3 -m json.tool "$OUT/real-slices.json" | head -120
else
  fail "real slice profile endpoint failed"
fi

if bash -n scripts/slicing/run-real-slice-traffic.sh; then
  pass "run-real-slice-traffic.sh syntax OK"
else
  fail "run-real-slice-traffic.sh syntax failed"
fi

if bash -n scripts/slicing/switch-ue-slice.sh; then
  pass "switch-ue-slice.sh syntax OK"
else
  fail "switch-ue-slice.sh syntax failed"
fi

if bash -n scripts/slicing/validate-current-slice.sh; then
  pass "validate-current-slice.sh syntax OK"
else
  fail "validate-current-slice.sh syntax failed"
fi

section "2. BASELINE BEFORE SLICE TESTS"
if bash scripts/validate-e2e.sh > "$OUT/validate-before.log" 2>&1; then
  pass "baseline validate-e2e before slice tests passed"
else
  fail "baseline validate-e2e before slice tests failed"
fi
tail -100 "$OUT/validate-before.log"

curl -fsS --max-time 20 "$BASE/api/radio/status" > "$OUT/radio-before.json" \
  && python3 -m json.tool "$OUT/radio-before.json" | head -80 \
  && pass "radio status before slice tests readable" \
  || fail "radio status before slice tests failed"

start_job() {
  local profile="$1"
  local file="$OUT/start-${profile}.json"

  echo "--- START real slice profile=$profile"
  if curl -fsS --max-time 30 \
    -H "Content-Type: application/json" \
    -X POST \
    "$TRAFFIC_API/api/traffic/run-real-slice/${profile}" > "$file"; then
    python3 -m json.tool "$file"
  else
    fail "failed to start real slice $profile"
    return 1
  fi

  python3 - "$file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("job_id", ""))
PY
}

poll_job() {
  local profile="$1"
  local job_id="$2"
  local max_wait="${3:-1800}"
  local poll_sleep=5
  local elapsed=0
  local job_file="$OUT/job-${profile}-${job_id}.json"
  local final_file="$OUT/final-${profile}-${job_id}.json"

  echo "--- POLL real slice profile=$profile job_id=$job_id max_wait=${max_wait}s"

  while [ "$elapsed" -le "$max_wait" ]; do
    if curl -fsS --max-time 30 "$TRAFFIC_API/api/traffic/jobs/${job_id}" > "$job_file"; then
      status="$(python3 - "$job_file" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    job = data.get("job", {})
    print(job.get("status", "unknown"))
except Exception:
    print("invalid-json")
PY
)"
      echo "[$profile] elapsed=${elapsed}s status=$status"

      if [ "$status" = "ok" ] || [ "$status" = "failed" ] || [ "$status" = "timeout" ] || [ "$status" = "error" ]; then
        cp "$job_file" "$final_file"
        python3 -m json.tool "$final_file" | head -160

        job_ok="$(python3 - "$final_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
job = data.get("job", {})
print("true" if job.get("ok") is True and job.get("status") == "ok" else "false")
PY
)"
        if [ "$job_ok" = "true" ]; then
          pass "real slice $profile completed OK"
          echo "--- output tail for $profile ---"
          python3 - "$final_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
out = data.get("output", "")
print(out[-9000:])
PY
          return 0
        else
          fail "real slice $profile completed with status=$status"
          echo "--- output tail for failed $profile ---"
          python3 - "$final_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
out = data.get("output", "")
print(out[-12000:])
PY
          return 1
        fi
      fi
    else
      warn "could not poll job $job_id for $profile at elapsed=${elapsed}s"
    fi

    sleep "$poll_sleep"
    elapsed=$((elapsed + poll_sleep))
  done

  fail "real slice $profile did not finish within ${max_wait}s"
  return 1
}

check_job_output() {
  local profile="$1"
  local job_id="$2"
  local expected_sst="$3"
  local final_file="$OUT/final-${profile}-${job_id}.json"
  local output_file="$OUT/output-${profile}-${job_id}.txt"

  python3 - "$final_file" "$output_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
out = data.get("output", "")
open(sys.argv[2], "w").write(out)
PY

  if grep -Eq "VERDICT=OK|VERDICT=.*OK|Real Slice Traffic Validation.*OK" "$output_file"; then
    pass "$profile output contains OK verdict"
  else
    fail "$profile output missing OK verdict"
  fi

  if grep -Eq "SST=${expected_sst}|sst=${expected_sst}|SST = ${expected_sst}" "$output_file"; then
    pass "$profile output confirms SST=$expected_sst"
  else
    warn "$profile output did not clearly show SST=$expected_sst"
  fi

  if grep -Eq "switch-ue-slice.sh 1 0xffffff|restored.*SST=1|UE restored to SST=1|restore.*SST=1|SST=1" "$output_file"; then
    pass "$profile output shows restore/default SST=1 evidence"
  else
    warn "$profile output did not clearly show restore to SST=1"
  fi
}

section "3. RUN REAL S-NSSAI SLICE TRAFFIC"
RESULTS_CSV="$OUT/results.csv"
echo "profile,expected_sst,job_id,result" > "$RESULTS_CSV"

for item in "embb:1" "urllc:2" "mmtc:3" "v2x:4"; do
  profile="${item%%:*}"
  sst="${item##*:}"

  section "3.$profile REAL SLICE TEST SST=$sst"

  job_id="$(start_job "$profile" | tee "$OUT/start-${profile}.log" | tail -n 1)"

  if [ -z "$job_id" ] || [ "$job_id" = "null" ]; then
    fail "no job_id returned for $profile"
    echo "$profile,$sst,,NO_JOB_ID" >> "$RESULTS_CSV"
    continue
  fi

  echo "job_id=$job_id" | tee "$OUT/job-id-${profile}.txt"

  if poll_job "$profile" "$job_id" 1800; then
    check_job_output "$profile" "$job_id" "$sst"
    echo "$profile,$sst,$job_id,OK" >> "$RESULTS_CSV"
  else
    echo "$profile,$sst,$job_id,FAILED" >> "$RESULTS_CSV"
  fi

  echo "--- validate E2E after $profile; runner should restore eMBB/SST=1 ---"
  if bash scripts/validate-e2e.sh > "$OUT/validate-after-${profile}.log" 2>&1; then
    pass "validate-e2e passed after $profile"
  else
    fail "validate-e2e failed after $profile"
  fi
  tail -100 "$OUT/validate-after-${profile}.log"

  echo "--- radio status after $profile ---"
  if curl -fsS --max-time 20 "$BASE/api/radio/status" > "$OUT/radio-after-${profile}.json"; then
    python3 -m json.tool "$OUT/radio-after-${profile}.json" | head -80
    slice="$(python3 - "$OUT/radio-after-${profile}.json" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("slice",""))
PY
)"
    if echo "$slice" | grep -Eq "1 / 0xffffff|1 / 16777215|SST=1"; then
      pass "radio/slice state restored to eMBB after $profile"
    else
      warn "radio/slice state after $profile is not clearly eMBB: $slice"
    fi
  else
    fail "radio status failed after $profile"
  fi
done

section "4. POST-SLICE PLATFORM CHECK"
if bash scripts/validate-e2e.sh > "$OUT/validate-final.log" 2>&1; then
  pass "final validate-e2e.sh passed"
else
  fail "final validate-e2e.sh failed"
fi
tail -120 "$OUT/validate-final.log"

if curl -fsS --max-time 20 "$BASE/api/ues/live_metrics" > "$OUT/live-metrics-final.json"; then
  pass "final live metrics readable"
  python3 -m json.tool "$OUT/live-metrics-final.json" | head -80
else
  fail "final live metrics failed"
fi

section "5. RESULTS TABLE"
column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"

FAILED_ROWS="$(awk -F, 'NR>1 && $4!="OK"{print}' "$RESULTS_CSV")"
if [ -n "$FAILED_ROWS" ]; then
  fail "one or more real slice tests failed"
  echo "$FAILED_ROWS"
else
  pass "all real slice tests passed"
fi

section "6. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_03_REAL_SLICES_PASS"
else
  echo "VERDICT=SECTION_03_REAL_SLICES_HAS_FAILURES"
fi
