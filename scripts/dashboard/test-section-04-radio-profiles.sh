#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

# Set RUN_KPI=0 to test only profile apply/restore without image+TCP KPI tests.
RUN_KPI="${RUN_KPI:-1}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-04-radio-profiles-$TS"
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

json_post() {
  local name="$1"
  local url="$2"
  local body="$3"
  local file="$4"
  local timeout="${5:-900}"

  echo "--- POST $url body=$body timeout=${timeout}s"
  if curl -fsS --max-time "$timeout" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$body" \
    "$url" > "$file"; then
    if python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null; then
      pass "$name"
      head -120 "${file}.pretty"
      return 0
    else
      fail "$name returned invalid JSON"
      head -80 "$file"
      return 1
    fi
  else
    fail "$name failed"
    return 1
  fi
}

json_get() {
  local name="$1"
  local url="$2"
  local file="$3"

  echo "--- GET $url"
  if curl -fsS --max-time 60 "$url" > "$file"; then
    if python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null; then
      pass "$name"
      head -100 "${file}.pretty"
      return 0
    else
      fail "$name returned invalid JSON"
      head -80 "$file"
      return 1
    fi
  else
    fail "$name failed"
    return 1
  fi
}

restore_scheduler_auto() {
  echo
  echo "===== SAFETY RESTORE scheduler-auto ====="
  curl -fsS --max-time 600 \
    -H "Content-Type: application/json" \
    -X POST \
    "$BASE/api/radio/restore" > "$OUT/restore-scheduler-auto.json" 2>&1 || true
  python3 -m json.tool "$OUT/restore-scheduler-auto.json" > "$OUT/restore-scheduler-auto.pretty" 2>/dev/null || true
  head -120 "$OUT/restore-scheduler-auto.pretty" 2>/dev/null || cat "$OUT/restore-scheduler-auto.json"
}

trap 'echo "[INTERRUPTED] Restoring scheduler-auto before exit"; restore_scheduler_auto; exit 130' INT TERM

cd "$REPO" || {
  echo "[FATAL] Cannot cd to $REPO"
  exit 1
}

section "0. CONTEXT"
echo "Repo=$REPO"
echo "Dashboard=$BASE"
echo "Output=$OUT"
echo "RUN_KPI=$RUN_KPI"
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

for marker in \
  "Radio / Modulation Profile Control" \
  "Radio Profile Results / Comparison" \
  "Radio Profile Logs"
do
  if grep -q "$marker" "$OUT/dashboard.html"; then
    pass "radio UI marker present: $marker"
  else
    fail "radio UI marker missing: $marker"
  fi
done

if bash -n scripts/radio/switch-ue-radio-profile-du-aware.sh; then
  pass "radio switch script syntax OK"
else
  fail "radio switch script syntax failed"
fi

if bash scripts/validate-e2e.sh > "$OUT/validate-before.log" 2>&1; then
  pass "baseline validate-e2e before radio tests passed"
else
  fail "baseline validate-e2e before radio tests failed"
fi
tail -100 "$OUT/validate-before.log"

json_get "radio status before tests" "$BASE/api/radio/status" "$OUT/radio-status-before.json"
json_get "radio results before tests" "$BASE/api/radio/results" "$OUT/radio-results-before.json"

section "2. PROFILE APPLY + KPI TESTS"
RESULTS_CSV="$OUT/results.csv"
echo "profile,api_ok,active_after,tunnel_after,rf_values,netem_params,tcp_mbps,image_mbps,ping_avg_ms,verdict" > "$RESULTS_CSV"

PROFILES="qpsk-robust qam16-balanced qam64-throughput"

for profile in $PROFILES; do
  section "2.$profile RADIO PROFILE TEST"

  apply_file="$OUT/apply-${profile}.json"
  if json_post "apply $profile" "$BASE/api/radio/apply" "{\"profile\":\"$profile\",\"ue\":\"ue1\"}" "$apply_file" 600; then
    apply_ok="$(python3 - "$apply_file" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print("true" if data.get("ok") is True else "false")
PY
)"
    if [ "$apply_ok" = "true" ]; then
      pass "apply $profile returned ok=true"
    else
      fail "apply $profile returned ok=false"
    fi
  fi

  status_file="$OUT/status-after-apply-${profile}.json"
  json_get "status after apply $profile" "$BASE/api/radio/status" "$status_file"

  active="$(python3 - "$status_file" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("active_profile","unknown"))
PY
)"
  tunnel="$(python3 - "$status_file" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("tunnel_ready","unknown"))
PY
)"
  rf="$(python3 - "$status_file" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("rf_values","unknown"))
PY
)"
  netem="$(python3 - "$status_file" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("netem_params","unknown"))
PY
)"

  echo "active=$active tunnel=$tunnel rf=$rf netem=$netem"

  if [ "$active" = "$profile" ]; then
    pass "active profile became $profile"
  else
    fail "active profile expected $profile but got $active"
  fi

  if [ "$tunnel" = "yes" ]; then
    pass "UE tunnel ready after $profile"
  else
    fail "UE tunnel not ready after $profile"
  fi

  if bash scripts/validate-e2e.sh > "$OUT/validate-after-apply-${profile}.log" 2>&1; then
    pass "validate-e2e passed after apply $profile"
  else
    fail "validate-e2e failed after apply $profile"
  fi
  tail -80 "$OUT/validate-after-apply-${profile}.log"

  tcp_mbps="—"
  image_mbps="—"
  ping_avg_ms="—"
  row_verdict="APPLY_ONLY"

  if [ "$RUN_KPI" = "1" ]; then
    kpi_file="$OUT/kpi-${profile}.json"
    if json_post "kpi-test $profile" "$BASE/api/radio/kpi-test" "{\"profile\":\"$profile\",\"ue\":\"ue1\"}" "$kpi_file" 1000; then
      kpi_ok="$(python3 - "$kpi_file" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print("true" if data.get("ok") is True else "false")
PY
)"
      if [ "$kpi_ok" = "true" ]; then
        pass "kpi-test $profile returned ok=true"
      else
        fail "kpi-test $profile returned ok=false"
      fi

      python3 - "$kpi_file" > "$OUT/kpi-row-${profile}.txt" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
row=data.get("row", {})
for k in ["profile","netem_params","rf_values","tcp_mbps","retransmits","ping_avg_ms","image_mbps","verdict"]:
    print(f"{k}={row.get(k,'')}")
PY
      cat "$OUT/kpi-row-${profile}.txt"

      tcp_mbps="$(awk -F= '/^tcp_mbps=/{print $2}' "$OUT/kpi-row-${profile}.txt" | tail -1)"
      image_mbps="$(awk -F= '/^image_mbps=/{print $2}' "$OUT/kpi-row-${profile}.txt" | tail -1)"
      ping_avg_ms="$(awk -F= '/^ping_avg_ms=/{print $2}' "$OUT/kpi-row-${profile}.txt" | tail -1)"
      row_verdict="$(awk -F= '/^verdict=/{print $2}' "$OUT/kpi-row-${profile}.txt" | tail -1)"

      if [ -n "$tcp_mbps" ] && [ "$tcp_mbps" != "—" ]; then
        pass "$profile TCP KPI captured: $tcp_mbps Mbps"
      else
        warn "$profile TCP KPI not captured"
      fi

      if [ -n "$image_mbps" ] && [ "$image_mbps" != "—" ]; then
        pass "$profile image KPI captured: $image_mbps Mbps"
      else
        warn "$profile image KPI not captured"
      fi
    fi
  fi

  echo "$profile,true,$active,$tunnel,\"$rf\",\"$netem\",$tcp_mbps,$image_mbps,$ping_avg_ms,$row_verdict" >> "$RESULTS_CSV"

  json_get "radio results after $profile" "$BASE/api/radio/results" "$OUT/results-after-${profile}.json"
done

section "3. RESTORE scheduler-auto"
restore_scheduler_auto

if json_get "status after restore" "$BASE/api/radio/status" "$OUT/status-after-restore.json"; then
  restored="$(python3 - "$OUT/status-after-restore.json" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("active_profile","unknown"))
PY
)"
  tunnel="$(python3 - "$OUT/status-after-restore.json" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("tunnel_ready","unknown"))
PY
)"
  slice_state="$(python3 - "$OUT/status-after-restore.json" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
print(data.get("slice","unknown"))
PY
)"

  if [ "$restored" = "scheduler-auto" ]; then
    pass "active profile restored to scheduler-auto"
  else
    fail "active profile not restored to scheduler-auto: $restored"
  fi

  if [ "$tunnel" = "yes" ]; then
    pass "UE tunnel ready after restore"
  else
    fail "UE tunnel not ready after restore"
  fi

  if echo "$slice_state" | grep -Eq "1 / 0xffffff|1 / 16777215"; then
    pass "slice state is eMBB after restore"
  else
    warn "slice state after restore not clearly eMBB: $slice_state"
  fi
fi

if bash scripts/validate-e2e.sh > "$OUT/validate-final.log" 2>&1; then
  pass "final validate-e2e passed after radio restore"
else
  fail "final validate-e2e failed after radio restore"
fi
tail -100 "$OUT/validate-final.log"

section "4. KPI SEPARATION CHECK"
column -t -s, "$RESULTS_CSV" 2>/dev/null || cat "$RESULTS_CSV"

if [ "$RUN_KPI" = "1" ]; then
  python3 - "$RESULTS_CSV" > "$OUT/kpi-analysis.txt" <<'PY'
import csv, sys, math

path=sys.argv[1]
rows=list(csv.DictReader(open(path)))
vals={}
for r in rows:
    def f(x):
        try:
            return float(x)
        except Exception:
            return None
    vals[r["profile"]] = {
        "tcp": f(r.get("tcp_mbps")),
        "image": f(r.get("image_mbps")),
        "ping": f(r.get("ping_avg_ms")),
        "netem": r.get("netem_params"),
    }

print("KPI analysis:")
for p,v in vals.items():
    print(f"{p}: tcp={v['tcp']} image={v['image']} ping={v['ping']} netem={v['netem']}")

failures=0
warnings=0

# We expect qpsk-robust to be clearly lower than the top-throughput profile.
qpsk=vals.get("qpsk-robust",{}).get("tcp")
q64=vals.get("qam64-throughput",{}).get("tcp")

if qpsk is not None and q64 is not None:
    if qpsk < q64:
        print("[PASS] TCP ladder: qpsk-robust < qam64-throughput")
    else:
        print("[WARN] TCP ladder not separated: qpsk-robust >= qam64-throughput")
        warnings += 1
else:
    print("[WARN] Not enough TCP data to compare qpsk-robust and qam64-throughput")
    warnings += 1

# Check at least some measurable TCP values.
measured=[v["tcp"] for v in vals.values() if v.get("tcp") is not None]
if len(measured) >= 3:
    print("[PASS] TCP KPIs captured for at least three profiles")
else:
    print("[FAIL] Not enough TCP KPI values captured")
    failures += 1

print(f"KPI_WARNINGS={warnings}")
print(f"KPI_FAILURES={failures}")
raise SystemExit(1 if failures else 0)
PY

  cat "$OUT/kpi-analysis.txt"

  if grep -q "KPI_FAILURES=0" "$OUT/kpi-analysis.txt"; then
    pass "KPI analysis has no hard failures"
  else
    fail "KPI analysis has hard failures"
  fi

  if grep -q "KPI_WARNINGS=0" "$OUT/kpi-analysis.txt"; then
    pass "KPI ladder has no warnings"
  else
    warn "KPI ladder has warnings; inspect $OUT/kpi-analysis.txt"
  fi
else
  warn "RUN_KPI=0, KPI separation check skipped"
fi

section "5. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_04_RADIO_PROFILES_PASS"
else
  echo "VERDICT=SECTION_04_RADIO_PROFILES_HAS_FAILURES"
fi
