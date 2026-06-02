#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
TRAFFIC_API="${TRAFFIC_API:-http://127.0.0.1:5055}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-dashboard-audit/$TS"
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

run_check() {
  local name="$1"
  shift
  echo "--- $name"
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

curl_save() {
  local name="$1"
  local url="$2"
  local file="$3"

  echo "--- GET $url"
  if curl -fsS --max-time 25 "$url" > "$file"; then
    pass "$name"
    return 0
  else
    fail "$name"
    return 1
  fi
}

cd "$REPO" || {
  echo "[FATAL] Cannot cd to $REPO"
  exit 1
}

section "0. AUDIT CONTEXT"
echo "Repo: $REPO"
echo "Dashboard base: $BASE"
echo "Traffic API: $TRAFFIC_API"
echo "Output dir: $OUT"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status.txt" || true

section "1. REQUIRED FILES"
required_files=(
  "web-dashboard/app.py"
  "web-dashboard/templates/index.html"
  "web-dashboard/radio_profile_api.py"
  "web-dashboard/mixed_du_handover_api.py"
  "web-dashboard/multi_ue_api.py"
  "web-dashboard/static/mixed-du-handover.js"
  "web-dashboard/static/mixed-du-table.js"
  "web-dashboard/static/dashboard-multi-ue.js"
  "scripts/validate-e2e.sh"
  "scripts/traffic/traffic_api_server.py"
  "scripts/radio/switch-ue-radio-profile-du-aware.sh"
  "scripts/handover/switch-ue-du-target.sh"
)

for f in "${required_files[@]}"; do
  if [ -f "$f" ]; then
    pass "exists: $f"
  else
    fail "missing: $f"
  fi
done

section "2. STATIC SYNTAX CHECKS"
run_check "Python dashboard modules compile" python3 -m py_compile \
  web-dashboard/app.py \
  web-dashboard/radio_profile_api.py \
  web-dashboard/mixed_du_handover_api.py \
  web-dashboard/multi_ue_api.py

if command -v node >/dev/null 2>&1; then
  for js in \
    web-dashboard/static/mixed-du-handover.js \
    web-dashboard/static/mixed-du-table.js \
    web-dashboard/static/dashboard-multi-ue.js \
    web-dashboard/static/dashboard-inline.js \
    web-dashboard/static/dashboard-status-live.js
  do
    [ -f "$js" ] && run_check "JS syntax: $js" node --check "$js"
  done
else
  warn "node not installed; JS syntax checks skipped"
fi

for sh in \
  scripts/validate-e2e.sh \
  scripts/traffic/start-traffic-api.sh \
  scripts/traffic/stop-traffic-api.sh \
  scripts/radio/switch-ue-radio-profile-du-aware.sh \
  scripts/handover/switch-ue-du-target.sh
do
  [ -f "$sh" ] && run_check "bash syntax: $sh" bash -n "$sh"
done

section "3. FLASK ROUTE MAP"
(
  cd web-dashboard || exit 1
  PYTHONPATH=. ORAN_REPO="$REPO" ORAN_DASHBOARD_PORT="$PORT" python3 - <<'PY'
from app import app
for rule in sorted(app.url_map.iter_rules(), key=lambda r: str(r)):
    methods = ",".join(sorted(m for m in rule.methods if m not in ("HEAD", "OPTIONS")))
    print(f"{methods:12s} {rule}")
PY
) > "$OUT/flask-routes.txt" 2>&1

if grep -q "/api/radio/status" "$OUT/flask-routes.txt" \
   && grep -q "/api/handover/mixed-du/status" "$OUT/flask-routes.txt" \
   && grep -q "/api/ues" "$OUT/flask-routes.txt"; then
  pass "Flask route map contains radio, handover, and multi-UE APIs"
else
  if grep -q "ModuleNotFoundError: No module named 'flask'" "$OUT/flask-routes.txt"; then
  warn "CLI Python cannot import Flask; live API tests will verify dashboard routes"
else
  fail "Flask route map missing expected APIs"
fi
fi

cat "$OUT/flask-routes.txt"

section "4. DASHBOARD PORT / SERVER"
if curl -fsS --max-time 5 "$BASE/" > "$OUT/page.html"; then
  pass "Dashboard already reachable on $BASE"
else
  warn "Dashboard not reachable; trying to start it without killing anything"

  if command -v lsof >/dev/null 2>&1; then
    PIDS="$(lsof -t -iTCP:${PORT} -sTCP:LISTEN 2>/dev/null || true)"
  else
    PIDS="$(ss -ltnp 2>/dev/null | sed -n "s/.*:${PORT} .*pid=\([0-9]\+\).*/\1/p" | sort -u || true)"
  fi

  if [ -n "${PIDS:-}" ]; then
    fail "Port $PORT is already used by PID(s): $PIDS, but dashboard did not answer correctly"
  else
    nohup env ORAN_DASHBOARD_PORT="$PORT" ./run-web-dashboard.sh > "$OUT/dashboard-start.log" 2>&1 &
    sleep 5
    if curl -fsS --max-time 10 "$BASE/" > "$OUT/page.html"; then
      pass "Dashboard started and reachable"
    else
      fail "Dashboard failed to start"
      tail -80 "$OUT/dashboard-start.log" 2>/dev/null || true
    fi
  fi
fi

section "5. FRONTEND SECTION CHECKS"
python3 - "$OUT/page.html" <<'PY' > "$OUT/frontend-check.txt"
import sys
from pathlib import Path

html = Path(sys.argv[1]).read_text(errors="ignore")

checks = [
    ("Radio / Modulation Profile Control", ["Radio / Modulation Profile Control", "Radio Profile Results / Comparison", "Radio Profile Logs"]),
    ("End-to-End UE Validation Scenarios", ["End-to-End UE Validation Scenarios", "Run Connectivity", "Run All"]),
    ("Real S-NSSAI Slice Traffic - Phase 3", ["Real S-NSSAI Slice Traffic - Phase 3", "Run eMBB Slice", "Run URLLC Slice", "Run mMTC Slice", "Run V2X Slice"]),
    ("RAN/Core pods tables", ["RAN Pods", "Core Pods"]),
    ("Real-Time Multi-UE Data Transfer", ["Real-Time Multi-UE Data Transfer", "Total Download RX", "Active UE Metrics"]),
    ("Evidence panels", ["Latest Action Output", "Recent Evidence Runs"]),
    ("Lower Mixed-DU handover table", ["mixedDuLowerHandoverSection", "Refresh DU Status", "Run Mixed-DU Validation", "mixedDuTableBody"]),
    ("Multi-UE Control eMBB", ["Multi-UE Control", "eMBB Parallel Realistic Scenarios", "Run selected scenarios"]),
]

failed = 0
for name, markers in checks:
    missing = [m for m in markers if m not in html]
    if missing:
        print(f"[FAIL] {name}: missing {missing}")
        failed += 1
    else:
        print(f"[PASS] {name}")

legacy_markers = [
    "Check F1 Status",
    "runF1HandoverButton",
    "F1 Handover Readiness",
]

legacy_found = [m for m in legacy_markers if m in html]
if legacy_found:
    print(f"[FAIL] Old top F1 handover section still present: {legacy_found}")
    failed += 1
else:
    print("[PASS] Old top F1 handover section not present")

print(f"RADIO_COUNT={html.count('Radio / Modulation Profile Control')}")
print(f"LOWER_HANDOVER_COUNT={html.count('mixedDuLowerHandoverSection')}")
print(f"MULTI_UE_CONTROL_COUNT={html.count('Multi-UE Control')}")

raise SystemExit(1 if failed else 0)
PY

cat "$OUT/frontend-check.txt"

if grep -q "^\[FAIL\]" "$OUT/frontend-check.txt"; then
  fail "Frontend section layout has problems"
else
  pass "Frontend section layout is clean"
fi

section "6. STATIC FILES SERVED"
curl_save "mixed-du-handover.js served" "$BASE/static/mixed-du-handover.js" "$OUT/mixed-du-handover.js" || true
curl_save "mixed-du-table.js served" "$BASE/static/mixed-du-table.js" "$OUT/mixed-du-table.js" || true
curl_save "dashboard-multi-ue.js served" "$BASE/static/dashboard-multi-ue.js" "$OUT/dashboard-multi-ue.js" || true

section "7. API READ-ONLY TESTS"
curl_save "GET /api/status" "$BASE/api/status" "$OUT/api-status.json" || true
curl_save "GET /api/ues" "$BASE/api/ues" "$OUT/api-ues.json" || true
curl_save "GET /api/ues/live_metrics" "$BASE/api/ues/live_metrics" "$OUT/api-ues-live-metrics.json" || true
curl_save "GET /api/handover/mixed-du/status" "$BASE/api/handover/mixed-du/status" "$OUT/api-handover-status.json" || true
curl_save "GET /api/radio/status" "$BASE/api/radio/status" "$OUT/api-radio-status.json" || true
curl_save "GET /api/radio/results" "$BASE/api/radio/results" "$OUT/api-radio-results.json" || true

section "8. API LOGIC CHECKS"
python3 - "$OUT" <<'PY' > "$OUT/api-logic-check.txt"
import json
import sys
from pathlib import Path

out = Path(sys.argv[1])
failed = 0

def load(name):
    p = out / name
    if not p.exists():
        print(f"[FAIL] missing {name}")
        return None
    try:
        return json.loads(p.read_text(errors="ignore"))
    except Exception as e:
        print(f"[FAIL] invalid JSON {name}: {e}")
        return None

handover = load("api-handover-status.json")
if handover:
    allowed = set(handover.get("allowed_ues", []))
    blocked = set(handover.get("blocked_ues", []))
    ues = handover.get("ues", [])
    ue1 = next((u for u in ues if u.get("name") == "ue1"), {})

    if "ue1" in allowed:
        print("[FAIL] Handover logic: ue1 is allowed to switch, but expected ue1 protected")
        failed += 1
    elif "ue1" not in blocked and ue1.get("protected") is not True:
        print("[FAIL] Handover logic: ue1 protection not visible")
        failed += 1
    else:
        print("[PASS] Handover logic: ue1 protected from lower table switching")

    if {"ue2", "ue3", "ue4", "ue5"}.issubset(allowed) or all(
        (u.get("name") in ["ue2","ue3","ue4","ue5"] and u.get("switchable")) or u.get("name") == "ue1"
        for u in ues
    ):
        print("[PASS] Handover logic: ue2-ue5 switchable")
    else:
        print("[FAIL] Handover logic: ue2-ue5 switchable state incomplete")
        failed += 1

    print(f"[INFO] Handover attached_count={handover.get('attached_count')} expected_count={handover.get('expected_count')} topology_ready={handover.get('topology_ready')} handover_ready={handover.get('handover_ready')}")

radio = load("api-radio-status.json")
if radio:
    if radio.get("ok") is True:
        print(f"[PASS] Radio API ok: profile={radio.get('active_profile')} tunnel={radio.get('tunnel_ready')} slice={radio.get('slice')}")
    else:
        print("[FAIL] Radio API returned ok=false")
        failed += 1

    if radio.get("slice") not in ("1 / 0xffffff", "1 / 16777215"):
        print(f"[WARN] Radio/slice state is not default eMBB: {radio.get('slice')}")

ues = load("api-ues.json")
if ues:
    print(f"[INFO] Multi-UE API keys: {sorted(ues.keys())}")
    print("[PASS] Multi-UE API returned JSON")

raise SystemExit(1 if failed else 0)
PY

cat "$OUT/api-logic-check.txt"

if grep -q "^\[FAIL\]" "$OUT/api-logic-check.txt"; then
  fail "API logic has problems"
else
  pass "API logic checks passed"
fi

section "9. TRAFFIC API HEALTH"
if curl -fsS --max-time 8 "$TRAFFIC_API/api/traffic/health" > "$OUT/traffic-api-health.json"; then
  pass "Traffic API reachable at $TRAFFIC_API"
  cat "$OUT/traffic-api-health.json"
else
  warn "Traffic API not reachable at $TRAFFIC_API; traffic buttons may fail until scripts/traffic/start-traffic-api.sh is running"
fi

section "10. KUBERNETES READ-ONLY PLATFORM CHECKS"
run_check "kubectl cluster reachable" kubectl get nodes

kubectl -n oran-core get pods -o wide > "$OUT/core-pods.txt" 2>&1 \
  && pass "core pods listed" || fail "core pods list failed"

kubectl -n oran-ran get pods -o wide > "$OUT/ran-pods.txt" 2>&1 \
  && pass "RAN pods listed" || fail "RAN pods list failed"

cat "$OUT/core-pods.txt"
cat "$OUT/ran-pods.txt"

kubectl -n oran-ran get endpoints oai-du0-rfsim oai-du1-rfsim -o wide > "$OUT/du-rfsim-endpoints.txt" 2>&1 \
  && pass "DU0/DU1 RFsim endpoints checked" || warn "Could not check DU0/DU1 RFsim endpoints"

cat "$OUT/du-rfsim-endpoints.txt" 2>/dev/null || true

UE1_POD="$(kubectl -n oran-ran get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
echo "UE1_POD=$UE1_POD" | tee "$OUT/ue1-pod.txt"

if [ -n "$UE1_POD" ]; then
  if kubectl -n oran-ran exec "$UE1_POD" -- ip addr show oaitun_ue1 > "$OUT/ue1-oaitun.txt" 2>&1; then
    pass "ue1 oaitun_ue1 exists"
  else
    fail "ue1 oaitun_ue1 missing"
  fi
else
  fail "ue1 running pod not found"
fi

section "11. OPTIONAL VALIDATE-E2E"
echo "Skipped by default to keep this first audit light."
echo "To run it later:"
echo "  RUN_E2E=1 scripts/dashboard/audit-dashboard-and-platform.sh"

if [ "${RUN_E2E:-0}" = "1" ]; then
  section "11B. RUNNING validate-e2e.sh"
  if bash scripts/validate-e2e.sh > "$OUT/validate-e2e.log" 2>&1; then
    pass "validate-e2e.sh passed"
  else
    fail "validate-e2e.sh failed"
  fi
  tail -120 "$OUT/validate-e2e.log"
fi

section "12. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=DASHBOARD_PLATFORM_READONLY_AUDIT_PASS"
else
  echo "VERDICT=DASHBOARD_PLATFORM_READONLY_AUDIT_HAS_FAILURES"
fi
