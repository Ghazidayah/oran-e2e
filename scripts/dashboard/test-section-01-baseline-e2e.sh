#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
TRAFFIC_API="${TRAFFIC_API:-http://127.0.0.1:5055}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-01-baseline-e2e-$TS"
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

curl_json() {
  local name="$1"
  local url="$2"
  local file="$3"

  echo "--- GET $url"
  if curl -fsS --max-time 30 "$url" > "$file"; then
    if python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null; then
      pass "$name"
      head -80 "${file}.pretty"
      return 0
    else
      fail "$name returned invalid JSON"
      head -40 "$file"
      return 1
    fi
  else
    fail "$name failed"
    return 1
  fi
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

section "1. DASHBOARD AND API HEALTH"
curl_json "Dashboard /api/status" "$BASE/api/status" "$OUT/api-status.json"
curl_json "Dashboard /api/ues" "$BASE/api/ues" "$OUT/api-ues.json"
curl_json "Dashboard /api/ues/live_metrics" "$BASE/api/ues/live_metrics" "$OUT/api-ues-live-metrics.json"
curl_json "Radio /api/radio/status" "$BASE/api/radio/status" "$OUT/api-radio-status.json"
curl_json "Handover /api/handover/mixed-du/status" "$BASE/api/handover/mixed-du/status" "$OUT/api-handover-status.json"
curl_json "Traffic API health" "$TRAFFIC_API/api/traffic/health" "$OUT/traffic-api-health.json"

section "2. DASHBOARD FRONTEND MARKERS"
if curl -fsS --max-time 20 "$BASE/" > "$OUT/dashboard.html"; then
  pass "Dashboard page reachable"
else
  fail "Dashboard page not reachable"
fi

for marker in \
  "Radio / Modulation Profile Control" \
  "End-to-End UE Validation Scenarios" \
  "Real S-NSSAI Slice Traffic" \
  "Real-Time Multi-UE Data Transfer" \
  "mixedDuLowerHandoverSection" \
  "Multi-UE Control"
do
  if grep -q "$marker" "$OUT/dashboard.html"; then
    pass "UI marker present: $marker"
  else
    fail "UI marker missing: $marker"
  fi
done

if grep -qE "Check F1 Status|runF1HandoverButton|F1 Handover Readiness" "$OUT/dashboard.html"; then
  fail "Old top F1 handover UI still present"
else
  pass "Old top F1 handover UI removed"
fi

section "3. KUBERNETES CORE/RAN STATE"
if kubectl get nodes -o wide > "$OUT/kubectl-nodes.txt" 2>&1; then
  pass "kubectl nodes OK"
else
  fail "kubectl nodes failed"
fi
cat "$OUT/kubectl-nodes.txt"

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
  fail "some core pods not healthy"
  echo "$BAD_CORE"
fi

if [ -z "$BAD_RAN" ]; then
  pass "all RAN pods Running/Completed"
else
  fail "some RAN pods not healthy"
  echo "$BAD_RAN"
fi

section "4. DU RFsim ENDPOINTS"
if kubectl -n oran-ran get endpoints oai-du0-rfsim oai-du1-rfsim -o wide > "$OUT/du-rfsim-endpoints.txt" 2>&1; then
  pass "DU0/DU1 RFsim endpoints exist"
else
  fail "DU0/DU1 RFsim endpoints missing"
fi
cat "$OUT/du-rfsim-endpoints.txt"

section "5. UE1 TUNNEL AND ROUTE"
UE1_POD="$(kubectl -n oran-ran get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
echo "UE1_POD=$UE1_POD" | tee "$OUT/ue1-pod.txt"

if [ -n "$UE1_POD" ]; then
  if kubectl -n oran-ran exec "$UE1_POD" -- ip addr show oaitun_ue1 > "$OUT/ue1-oaitun.txt" 2>&1; then
    pass "ue1 oaitun_ue1 exists"
    cat "$OUT/ue1-oaitun.txt"
  else
    fail "ue1 oaitun_ue1 missing"
    cat "$OUT/ue1-oaitun.txt"
  fi

  kubectl -n oran-ran exec "$UE1_POD" -- ip route > "$OUT/ue1-route.txt" 2>&1 \
    && pass "ue1 route readable" || fail "ue1 route read failed"
  cat "$OUT/ue1-route.txt"
else
  fail "ue1 running pod not found"
fi

section "6. validate-e2e.sh"
if bash scripts/validate-e2e.sh > "$OUT/validate-e2e.log" 2>&1; then
  pass "validate-e2e.sh passed"
else
  fail "validate-e2e.sh failed"
fi
tail -160 "$OUT/validate-e2e.log"

section "7. BASELINE LOGIC SUMMARY"
python3 - "$OUT" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])

def load(name):
    p = out / name
    try:
        return json.loads(p.read_text())
    except Exception:
        return {}

status = load("api-status.json")
radio = load("api-radio-status.json")
handover = load("api-handover-status.json")
ues = load("api-ues.json")

print("dashboard_ok=", status.get("ok"))
print("radio_ok=", radio.get("ok"))
print("radio_profile=", radio.get("active_profile"))
print("radio_tunnel_ready=", radio.get("tunnel_ready"))
print("radio_slice=", radio.get("slice"))
print("handover_ok=", handover.get("ok"))
print("handover_ue1_blocked=", "ue1" in handover.get("blocked_ues", []))
print("handover_allowed_ues=", handover.get("allowed_ues"))
print("multi_ue_attached_count=", ues.get("attached_count"))
print("multi_ue_running_count=", ues.get("running_count"))
PY

section "8. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_01_BASELINE_E2E_PASS"
else
  echo "VERDICT=SECTION_01_BASELINE_E2E_HAS_FAILURES"
fi
