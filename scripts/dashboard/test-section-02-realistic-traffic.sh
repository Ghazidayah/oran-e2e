#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
TRAFFIC_API="${TRAFFIC_API:-http://127.0.0.1:5055}"

# Set RUN_ALL=0 if you want to skip the final Run All button test.
RUN_ALL="${RUN_ALL:-1}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-02-realistic-traffic-$TS"
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
echo "RUN_ALL=$RUN_ALL"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status.txt" || true

section "1. PREFLIGHT: DASHBOARD, TRAFFIC API, UE1"
if curl -fsS --max-time 15 "$BASE/" > "$OUT/dashboard.html"; then
  pass "dashboard page reachable"
else
  fail "dashboard page not reachable"
fi

if curl -fsS --max-time 15 "$TRAFFIC_API/api/traffic/health" > "$OUT/traffic-health.json"; then
  pass "Traffic API health reachable"
  python3 -m json.tool "$OUT/traffic-health.json" | head -60
else
  fail "Traffic API health failed"
fi

if curl -fsS --max-time 15 "$TRAFFIC_API/api/traffic/scenarios" > "$OUT/traffic-scenarios.json"; then
  pass "Traffic scenarios endpoint reachable"
  python3 -m json.tool "$OUT/traffic-scenarios.json"
else
  fail "Traffic scenarios endpoint failed"
fi

UE1_POD="$(kubectl -n oran-ran get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
echo "UE1_POD=$UE1_POD" | tee "$OUT/ue1-pod.txt"

if [ -n "$UE1_POD" ] && kubectl -n oran-ran exec "$UE1_POD" -- ip addr show oaitun_ue1 > "$OUT/ue1-oaitun-before.txt" 2>&1; then
  pass "ue1 oaitun_ue1 exists before traffic tests"
else
  fail "ue1 oaitun_ue1 missing before traffic tests"
fi

if [ -n "$UE1_POD" ] && kubectl -n oran-ran exec "$UE1_POD" -- ip route > "$OUT/ue1-route-before.txt" 2>&1; then
  pass "ue1 route readable before traffic tests"
  cat "$OUT/ue1-route-before.txt"
else
  fail "ue1 route unreadable before traffic tests"
fi

section "2. VERIFY TRAFFIC SCRIPTS EXIST"
SCENARIOS_BASE="image web video streaming iperf-tcp udp"
SCENARIOS="$SCENARIOS_BASE"

if [ "$RUN_ALL" = "1" ]; then
  SCENARIOS="$SCENARIOS run-all"
fi

for scenario in $SCENARIOS; do
  script="$(python3 - "$scenario" "$OUT/traffic-scenarios.json" <<'PY'
import json, sys
scenario = sys.argv[1]
path = sys.argv[2]
try:
    data = json.load(open(path))
    for item in data.get("scenarios", []):
        if item.get("id") == scenario:
            print(item.get("script", ""))
            break
except Exception:
    pass
PY
)"
  if [ -n "$script" ] && [ -f "$script" ]; then
    pass "script exists for $scenario: $script"
  else
    fail "script missing for $scenario: ${script:-unknown}"
  fi
done

start_job() {
  local scenario="$1"
  local file="$OUT/start-${scenario}.json"

  echo "--- START scenario=$scenario"
  if curl -fsS --max-time 30 \
    -H "Content-Type: application/json" \
    -X POST \
    "$TRAFFIC_API/api/traffic/run/${scenario}" > "$file"; then
    python3 -m json.tool "$file"
  else
    fail "failed to start scenario $scenario"
    return 1
  fi

  python3 - "$file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("job_id", ""))
PY
}

poll_job() {
  local scenario="$1"
  local job_id="$2"
  local max_wait="${3:-1200}"
  local poll_sleep=5
  local elapsed=0
  local job_file="$OUT/job-${scenario}-${job_id}.json"
  local final_file="$OUT/final-${scenario}-${job_id}.json"

  echo "--- POLL scenario=$scenario job_id=$job_id max_wait=${max_wait}s"

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
      echo "[$scenario] elapsed=${elapsed}s status=$status"

      if [ "$status" = "ok" ] || [ "$status" = "failed" ] || [ "$status" = "timeout" ] || [ "$status" = "error" ]; then
        cp "$job_file" "$final_file"
        python3 -m json.tool "$final_file" | head -120

        job_ok="$(python3 - "$final_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
job = data.get("job", {})
print("true" if job.get("ok") is True and job.get("status") == "ok" else "false")
PY
)"
        if [ "$job_ok" = "true" ]; then
          pass "scenario $scenario completed OK"
          echo "--- output tail for $scenario ---"
          python3 - "$final_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
out = data.get("output", "")
print(out[-5000:])
PY
          return 0
        else
          fail "scenario $scenario completed with status=$status"
          echo "--- output tail for failed $scenario ---"
          python3 - "$final_file" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
out = data.get("output", "")
print(out[-8000:])
PY
          return 1
        fi
      fi
    else
      warn "could not poll job $job_id for $scenario at elapsed=${elapsed}s"
    fi

    sleep "$poll_sleep"
    elapsed=$((elapsed + poll_sleep))
  done

  fail "scenario $scenario did not finish within ${max_wait}s"
  return 1
}

section "3. RUN REALISTIC TRAFFIC SCENARIOS"
RESULTS_CSV="$OUT/results.csv"
echo "scenario,job_id,result" > "$RESULTS_CSV"

for scenario in $SCENARIOS; do
  section "3.$scenario TRAFFIC BUTTON/API TEST"

  job_id="$(start_job "$scenario" | tee "$OUT/start-${scenario}.log" | tail -n 1)"

  if [ -z "$job_id" ] || [ "$job_id" = "null" ]; then
    fail "no job_id returned for $scenario"
    echo "$scenario,,NO_JOB_ID" >> "$RESULTS_CSV"
    continue
  fi

  echo "job_id=$job_id" | tee "$OUT/job-id-${scenario}.txt"

  if [ "$scenario" = "run-all" ]; then
    max_wait=1500
  else
    max_wait=900
  fi

  if poll_job "$scenario" "$job_id" "$max_wait"; then
    echo "$scenario,$job_id,OK" >> "$RESULTS_CSV"
  else
    echo "$scenario,$job_id,FAILED" >> "$RESULTS_CSV"
  fi

  echo "--- UE1 route after $scenario ---"
  if [ -n "$UE1_POD" ]; then
    kubectl -n oran-ran exec "$UE1_POD" -- ip route > "$OUT/ue1-route-after-${scenario}.txt" 2>&1 || true
    cat "$OUT/ue1-route-after-${scenario}.txt"
  fi
done

section "4. POST-TRAFFIC PLATFORM CHECK"
if bash scripts/validate-e2e.sh > "$OUT/validate-e2e-after-traffic.log" 2>&1; then
  pass "validate-e2e.sh passed after traffic tests"
else
  fail "validate-e2e.sh failed after traffic tests"
fi
tail -120 "$OUT/validate-e2e-after-traffic.log"

if curl -fsS --max-time 20 "$BASE/api/ues/live_metrics" > "$OUT/live-metrics-after.json"; then
  pass "live metrics readable after traffic tests"
  python3 -m json.tool "$OUT/live-metrics-after.json" | head -80
else
  fail "live metrics failed after traffic tests"
fi

section "5. RESULTS TABLE"
column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"

FAILED_ROWS="$(awk -F, 'NR>1 && $3!="OK"{print}' "$RESULTS_CSV")"
if [ -n "$FAILED_ROWS" ]; then
  fail "one or more realistic traffic scenarios failed"
  echo "$FAILED_ROWS"
else
  pass "all realistic traffic scenarios passed"
fi

section "6. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_02_REALISTIC_TRAFFIC_PASS"
else
  echo "VERDICT=SECTION_02_REALISTIC_TRAFFIC_HAS_FAILURES"
fi
