#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
TRAFFIC_API="${TRAFFIC_API:-http://127.0.0.1:5055}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-07-final-regression-$TS"
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

json_get() {
  local name="${1:-GET}"
  local url="${2:-}"
  local file="${3:-}"

  echo "--- GET $url"
  if curl -fsS --max-time 60 "$url" > "$file"; then
    python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null || true
    head -120 "${file}.pretty" 2>/dev/null || head -80 "$file"
    pass "$name"
    return 0
  else
    fail "$name"
    return 1
  fi
}

cd "$REPO" || exit 1

section "0. CONTEXT"
echo "Repo=$REPO"
echo "Dashboard=$BASE"
echo "Traffic API=$TRAFFIC_API"
echo "Output=$OUT"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status-before.txt" || true

section "1. DASHBOARD FRONTEND FINAL CHECK"
if curl -fsS --max-time 20 "$BASE/" > "$OUT/dashboard.html"; then
  pass "dashboard page reachable"
else
  fail "dashboard page not reachable"
fi

for marker in \
  "Radio / Modulation Profile Control" \
  "Frequency Scenarios" \
  "Scenario KPI Results" \
  "realFreqLog" \
  "End-to-End UE Validation Scenarios" \
  "Real S-NSSAI Slice Traffic" \
  "Real-Time Multi-UE Data Transfer" \
  "mixedDuLowerHandoverSection" \
  "DU Continuity / Handover" \
  "Multi-UE Control" \
  "eMBB Parallel Realistic Scenarios"
do
  if grep -q "$marker" "$OUT/dashboard.html"; then
    pass "UI marker present: $marker"
  else
    fail "UI marker missing: $marker"
  fi
done

if grep -qE "Check F1 Status|runF1HandoverButton|F1 Handover Readiness" "$OUT/dashboard.html"; then
  fail "old top F1 handover card still present"
else
  pass "old top F1 handover card removed"
fi

section "2. STATIC ASSETS FINAL CHECK"
for asset in \
  dashboard-inline.js \
  dashboard-multi-ue.js \
  mixed-du-handover.js \
  mixed-du-table.js \
  frequency-profile.js \
  dashboard-status-live.js
do
  if curl -fsS --max-time 20 "$BASE/static/$asset" > "$OUT/$asset"; then
    pass "static asset served: $asset"
  else
    fail "static asset missing: $asset"
  fi

  if command -v node >/dev/null 2>&1; then
    if node --check "web-dashboard/static/$asset" > "$OUT/${asset}.nodecheck" 2>&1; then
      pass "JS syntax OK: $asset"
    else
      fail "JS syntax failed: $asset"
      cat "$OUT/${asset}.nodecheck"
    fi
  fi
done

section "3. API FINAL CHECK"
json_get "GET /api/status" "$BASE/api/status" "$OUT/api-status.json"
json_get "GET /api/ues" "$BASE/api/ues" "$OUT/api-ues.json"
json_get "GET /api/ues/live_metrics" "$BASE/api/ues/live_metrics" "$OUT/live-metrics.json"
json_get "GET /api/radio/status" "$BASE/api/radio/status" "$OUT/radio-status.json"
json_get "GET /api/radio/results" "$BASE/api/radio/results" "$OUT/radio-results.json"
json_get "GET /api/real-frequency/status" "$BASE/api/real-frequency/status" "$OUT/frequency-status.json"
json_get "GET /api/real-frequency/results" "$BASE/api/real-frequency/results" "$OUT/frequency-results.json"
json_get "GET /api/real-frequency/profiles" "$BASE/api/real-frequency/profiles" "$OUT/frequency-profiles.json"
json_get "GET /api/handover/mixed-du/status" "$BASE/api/handover/mixed-du/status" "$OUT/handover-status.json"
json_get "Traffic API health" "$TRAFFIC_API/api/traffic/health" "$OUT/traffic-health.json"

section "4. FINAL LOGIC ASSERTIONS"
python3 - "$OUT" <<'PY'
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
failures = 0
warnings = 0

def load(name):
    try:
        return json.loads((out / name).read_text())
    except Exception as e:
        print(f"[FAIL] could not load {name}: {e}")
        return {}

ues = load("api-ues.json")
radio = load("radio-status.json")
frequency = load("frequency-status.json")
handover = load("handover-status.json")
traffic = load("traffic-health.json")

def check(cond, ok_msg, fail_msg):
    global failures
    if cond:
        print("[PASS]", ok_msg)
    else:
        print("[FAIL]", fail_msg)
        failures += 1

check(ues.get("ok") is True, "UE API ok=true", "UE API not ok")
check(ues.get("running_count") == 5, "5 UE deployments running", f"running_count={ues.get('running_count')}")
check(ues.get("attached_count") == 5, "5 UEs attached", f"attached_count={ues.get('attached_count')}")

check(radio.get("ok") is True, "radio API ok=true", "radio API not ok")
check(radio.get("active_profile") == "scheduler-auto", "radio active profile is scheduler-auto", f"active_profile={radio.get('active_profile')}")
check(radio.get("tunnel_ready") == "yes", "radio UE tunnel ready", f"tunnel_ready={radio.get('tunnel_ready')}")
check(radio.get("slice") in ("1 / 0xffffff", "1 / 16777215"), "radio slice is eMBB SST=1", f"slice={radio.get('slice')}")

check(frequency.get("ok") is True, "frequency API ok=true", "frequency API not ok")
check(frequency.get("active_profile") is not None, "frequency active profile is set", f"active_profile={frequency.get('active_profile')}")
check(frequency.get("tunnel_ready") == "yes", "frequency UE tunnel ready", f"tunnel_ready={frequency.get('tunnel_ready')}")
check(bool(frequency.get("carrier_keys")), "frequency carrier keys present (real retune)", "frequency carrier_keys missing")
# (removed: old netem qdisc check — real-frequency uses real OAI carrier retune, no tc/netem)

check(handover.get("ok") is True, "handover API ok=true", "handover API not ok")
check(handover.get("attached_count") == 5, "handover attached_count=5", f"handover attached_count={handover.get('attached_count')}")
check(handover.get("handover_ready") is True, "handover_ready=true", f"handover_ready={handover.get('handover_ready')}")
check("ue1" in handover.get("blocked_ues", []), "ue1 blocked/protected", f"blocked_ues={handover.get('blocked_ues')}")
check(all(u in handover.get("allowed_ues", []) for u in ["ue2","ue3","ue4","ue5"]), "ue2-ue5 allowed/switchable", f"allowed_ues={handover.get('allowed_ues')}")

expected = {
    "ue1": ("du0", "oai-du0-rfsim", True),
    "ue2": ("du1", "oai-du1-rfsim", False),
    "ue3": ("du1", "oai-du1-rfsim", False),
    "ue4": ("du1", "oai-du1-rfsim", False),
    "ue5": ("du1", "oai-du1-rfsim", False),
}

by_name = {u.get("name"): u for u in handover.get("ues", [])}
for name, (du, server, protected) in expected.items():
    u = by_name.get(name, {})
    check(
        u.get("attached") is True and u.get("du") == du and u.get("serveraddr") == server and bool(u.get("protected")) == protected and bool(u.get("tunnel_ip")),
        f"{name} final topology correct",
        f"{name} topology wrong: {u}"
    )

check(traffic.get("ok") is True, "Traffic API ok=true", "Traffic API not ok")

print(f"FINAL_LOGIC_FAILURES={failures}")
raise SystemExit(1 if failures else 0)
PY

if [ "$?" -eq 0 ]; then
  pass "final logic assertions passed"
else
  fail "final logic assertions failed"
fi

section "5. KUBERNETES FINAL CHECK"
if kubectl -n oran-core get pods -o wide > "$OUT/core-pods.txt" 2>&1; then
  pass "core pods listed"
else
  fail "core pods list failed"
fi
cat "$OUT/core-pods.txt"

if kubectl -n oran-ran get pods -o wide > "$OUT/ran-pods.txt" 2>&1; then
  pass "RAN pods listed"
else
  fail "RAN pods list failed"
fi
cat "$OUT/ran-pods.txt"

BAD_CORE="$(kubectl -n oran-core get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print}' || true)"
BAD_RAN="$(kubectl -n oran-ran get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print}' || true)"

if [ -z "$BAD_CORE" ]; then
  pass "all core pods Running/Completed"
else
  fail "some core pods unhealthy"
  echo "$BAD_CORE"
fi

if [ -z "$BAD_RAN" ]; then
  pass "all RAN pods Running/Completed"
else
  fail "some RAN pods unhealthy"
  echo "$BAD_RAN"
fi

section "6. FINAL E2E"
if bash scripts/validate-e2e.sh > "$OUT/validate-e2e-final.log" 2>&1; then
  pass "final validate-e2e passed"
else
  fail "final validate-e2e failed"
fi
tail -120 "$OUT/validate-e2e-final.log"

section "7. FINAL SUMMARY"
git status --short 2>/dev/null | tee "$OUT/git-status-after.txt" || true

echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_07_FINAL_REGRESSION_PASS"
else
  echo "VERDICT=SECTION_07_FINAL_REGRESSION_HAS_FAILURES"
fi
