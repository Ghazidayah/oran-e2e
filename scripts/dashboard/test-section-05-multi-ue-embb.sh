#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-05-multi-ue-embb-$TS"
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

  if [ -z "$url" ] || [ -z "$file" ]; then
    fail "$name missing url/file argument"
    return 1
  fi

  echo "--- GET $url"
  if curl -fsS --max-time 120 "$url" > "$file"; then
    python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null || true
    head -120 "${file}.pretty" 2>/dev/null || head -80 "$file"
    pass "$name"
    return 0
  else
    fail "$name"
    return 1
  fi
}

json_post() {
  local name="${1:-POST}"
  local url="${2:-}"
  local body="${3:-{}}"
  local file="${4:-}"
  local timeout="${5:-1200}"

  if [ -z "$url" ] || [ -z "$file" ]; then
    fail "$name missing url/file argument"
    return 1
  fi

  echo "--- POST $url"
  echo "$body" | tee "${file}.payload"

  if curl -fsS --max-time "$timeout" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$body" \
    "$url" > "$file"; then

    python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null || true
    head -180 "${file}.pretty" 2>/dev/null || head -120 "$file"
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
echo "Output=$OUT"
date -Iseconds | tee "$OUT/date.txt"
git branch --show-current 2>/dev/null | tee "$OUT/git-branch.txt" || true
git rev-parse HEAD 2>/dev/null | tee "$OUT/git-head.txt" || true
git status --short 2>/dev/null | tee "$OUT/git-status.txt" || true

section "1. PREFLIGHT"
curl -fsS --max-time 20 "$BASE/" > "$OUT/dashboard.html" \
  && pass "dashboard page reachable" \
  || fail "dashboard page not reachable"

for marker in \
  "Multi-UE Control" \
  "eMBB Parallel Realistic Scenarios" \
  "Real-Time Multi-UE Data Transfer"
do
  if grep -q "$marker" "$OUT/dashboard.html"; then
    pass "UI marker present: $marker"
  else
    fail "UI marker missing: $marker"
  fi
done

echo "--- Route/code check for correct Multi-UE endpoint"
grep -R "/api/ues/embb-scenarios" -n \
  web-dashboard/multi_ue_api.py \
  web-dashboard/static/dashboard-multi-ue.js \
  > "$OUT/embb-route-grep.txt" 2>&1 || true

cat "$OUT/embb-route-grep.txt"

if grep -q "/api/ues/embb-scenarios" "$OUT/embb-route-grep.txt"; then
  pass "correct /api/ues/embb-scenarios route referenced in code"
else
  fail "correct /api/ues/embb-scenarios route not found in code"
fi

json_get "GET /api/ues before" "$BASE/api/ues" "$OUT/api-ues-before.json"
json_get "GET handover status before" "$BASE/api/handover/mixed-du/status" "$OUT/handover-before.json"

section "2. RECOVER SWITCHABLE UEs TO DU1"
echo "Target design:"
echo "  ue1 -> DU0 protected"
echo "  ue2 -> DU1"
echo "  ue3 -> DU1"
echo "  ue4 -> DU1"
echo "  ue5 -> DU1"

for ue in ue2 ue3 ue4 ue5; do
  file="$OUT/switch-${ue}-du1.json"

  if json_post \
    "switch $ue to du1" \
    "$BASE/api/handover/mixed-du/switch" \
    "{\"ue\":\"$ue\",\"target\":\"du1\"}" \
    "$file" \
    900; then

    ok="$(python3 - "$file" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    print("true" if d.get("ok") is True or d.get("verdict") == "UE_DU_SWITCH_OK" else "false")
except Exception:
    print("false")
PY
)"
    if [ "$ok" = "true" ]; then
      pass "$ue switched/attached on DU1"
    else
      fail "$ue switch response not OK"
    fi
  fi
done

json_get "GET handover status after recovery" "$BASE/api/handover/mixed-du/status" "$OUT/handover-after-recovery.json"

python3 - "$OUT/handover-after-recovery.json" > "$OUT/recovery-analysis.txt" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("attached_count=", d.get("attached_count"))
print("expected_count=", d.get("expected_count"))
print("handover_ready=", d.get("handover_ready"))
print("topology_ready=", d.get("topology_ready"))
print("blocked_ues=", d.get("blocked_ues"))
print("allowed_ues=", d.get("allowed_ues"))

for ue in d.get("ues", []):
    print(
        ue.get("name"),
        "attached=", ue.get("attached"),
        "du=", ue.get("du"),
        "serveraddr=", ue.get("serveraddr"),
        "tunnel=", ue.get("tunnel_ip"),
        "protected=", ue.get("protected"),
    )

if d.get("attached_count") == 5 and d.get("expected_count") == 5:
    print("[PASS] attached 5 / 5 after recovery")
else:
    print("[FAIL] not attached 5 / 5 after recovery")

if "ue1" in d.get("blocked_ues", []) and all(u in d.get("allowed_ues", []) for u in ["ue2","ue3","ue4","ue5"]):
    print("[PASS] protection model correct")
else:
    print("[FAIL] protection model incorrect")
PY

cat "$OUT/recovery-analysis.txt"

if grep -q "\[FAIL\]" "$OUT/recovery-analysis.txt"; then
  fail "recovery analysis has failures"
else
  pass "recovery analysis passed"
fi

section "3. RUN CORRECT MULTI-UE eMBB MATRIX"
cat > "$OUT/embb-payload.json" <<'JSON'
{
  "jobs": [
    {"ue":"ue1","scenario":"image"},
    {"ue":"ue2","scenario":"web"},
    {"ue":"ue3","scenario":"streaming"},
    {"ue":"ue4","scenario":"video_download"},
    {"ue":"ue5","scenario":"tcp_download"}
  ]
}
JSON

payload="$(cat "$OUT/embb-payload.json")"

if json_post \
  "POST /api/ues/embb-scenarios" \
  "$BASE/api/ues/embb-scenarios" \
  "$payload" \
  "$OUT/embb-scenarios-result.json" \
  1800; then

  python3 - "$OUT/embb-scenarios-result.json" > "$OUT/embb-analysis.txt" <<'PY'
import json, sys

d=json.load(open(sys.argv[1]))

print("ok=", d.get("ok"))
print("mode=", d.get("mode"))
print("slice=", d.get("slice"))
print("sst=", d.get("sst"))
print("selected_count=", d.get("selected_count"))

text=json.dumps(d, indent=2)
for ue in ["ue1","ue2","ue3","ue4","ue5"]:
    print(f"{ue}_mentioned=", ue in text)

for key in ["image", "web", "streaming", "video_download", "tcp_download"]:
    print(f"{key}_mentioned=", key in text)

if d.get("ok") is True:
    print("[PASS] Multi-UE eMBB endpoint returned ok=true")
else:
    print("[FAIL] Multi-UE eMBB endpoint did not return ok=true")

bad_words = ["unknown eMBB scenario", "error", "failed", "traceback"]
lower=text.lower()
if any(w in lower for w in bad_words):
    print("[WARN] Response contains possible failure/error words")
PY

  cat "$OUT/embb-analysis.txt"

  if grep -q "\[FAIL\]" "$OUT/embb-analysis.txt"; then
    fail "eMBB matrix response has failures"
  else
    pass "eMBB matrix response has no hard failures"
  fi

  if grep -q "\[WARN\]" "$OUT/embb-analysis.txt"; then
    warn "eMBB matrix response contains warning words"
  fi
fi

section "4. POST-RUN STATUS"
json_get "GET /api/ues after eMBB matrix" "$BASE/api/ues" "$OUT/api-ues-after.json"
json_get "GET live metrics after eMBB matrix" "$BASE/api/ues/live_metrics" "$OUT/live-after.json"
json_get "GET handover status after eMBB matrix" "$BASE/api/handover/mixed-du/status" "$OUT/handover-after.json"

python3 - "$OUT/api-ues-after.json" "$OUT/live-after.json" "$OUT/handover-after.json" > "$OUT/post-analysis.txt" <<'PY'
import json, sys

ues=json.load(open(sys.argv[1]))
live=json.load(open(sys.argv[2]))
handover=json.load(open(sys.argv[3]))

print("api_ues_running_count=", ues.get("running_count"))
print("api_ues_attached_count=", ues.get("attached_count"))
print("live_active_count=", live.get("active_count"))
print("handover_attached_count=", handover.get("attached_count"))
print("handover_expected_count=", handover.get("expected_count"))
print("handover_ready=", handover.get("handover_ready"))

if ues.get("running_count") == 5:
    print("[PASS] five UE deployments running")
else:
    print("[FAIL] not five UE deployments running")

if ues.get("attached_count") == 5 or handover.get("attached_count") == 5 or live.get("active_count") == 5:
    print("[PASS] five UEs attached/active according to at least one dashboard view")
else:
    print("[FAIL] five UEs not attached/active")

if "ue1" in handover.get("blocked_ues", []) and all(u in handover.get("allowed_ues", []) for u in ["ue2","ue3","ue4","ue5"]):
    print("[PASS] ue1 protected and ue2-ue5 switchable")
else:
    print("[FAIL] protection model wrong")
PY

cat "$OUT/post-analysis.txt"

if grep -q "\[FAIL\]" "$OUT/post-analysis.txt"; then
  fail "post-run analysis has failures"
else
  pass "post-run analysis passed"
fi

section "5. FINAL UE1 BASELINE VALIDATION"
if bash scripts/validate-e2e.sh > "$OUT/validate-final.log" 2>&1; then
  pass "validate-e2e passed after Multi-UE eMBB"
else
  fail "validate-e2e failed after Multi-UE eMBB"
fi
tail -120 "$OUT/validate-final.log"

section "6. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_05_MULTI_UE_EMBB_PASS"
else
  echo "VERDICT=SECTION_05_MULTI_UE_EMBB_HAS_FAILURES"
fi
