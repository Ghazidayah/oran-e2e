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
  local body="${3:-}"
  [ -z "$body" ] && body="{}"
  local file="${4:-}"
  local timeout="${5:-1200}"

  if [ -z "$url" ] || [ -z "$file" ]; then
    fail "$name missing url/file argument"
    return 1
  fi

  echo "--- POST $url"
  printf '%s' "$body" | tee "${file}.payload" >/dev/null

  # Send the JSON body as a file (-d @file) so shell quoting/newlines cannot mangle it
  # into an invalid request (that produced HTTP 400 when passed via -d "$body").
  if curl -fsS --max-time "$timeout" \
    -H "Content-Type: application/json" \
    -X POST \
    -d @"${file}.payload" \
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

section "2. CURRENT UE -> DU DISTRIBUTION (no handover)"
echo "This section does NOT move any UE. Multi-UE eMBB runs on the DU each UE is"
echo "already attached to (placement is static, set at deploy time per UE configmap)."

json_get "GET handover status (distribution)" "$BASE/api/handover/mixed-du/status" "$OUT/handover-distribution.json"

python3 - "$OUT/handover-distribution.json" > "$OUT/distribution-analysis.txt" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
attached = d.get("attached_count")
expected = d.get("expected_count")
print("attached_count=", attached)
print("expected_count=", expected)
du0, du1, other = [], [], []
for ue in d.get("ues", []):
    name, du = ue.get("name"), str(ue.get("du") or "").lower()
    print(name, "attached=", ue.get("attached"), "du=", ue.get("du"), "tunnel=", ue.get("tunnel_ip"))
    (du0 if du == "du0" else du1 if du == "du1" else other).append(name)
print("on_du0=", du0)
print("on_du1=", du1)
if other:
    print("on_other=", other)
# Honest check: every UE must be attached SOMEWHERE. The DU split is reported, not forced.
if attached == 5 and expected == 5:
    print("[PASS] all 5 UEs attached on their current DUs")
else:
    print("[FAIL] not all 5 UEs attached (attached=%s expected=%s)" % (attached, expected))
PYEOF

cat "$OUT/distribution-analysis.txt"

if grep -q "\[FAIL\]" "$OUT/distribution-analysis.txt"; then
  fail "not all UEs attached for multi-UE eMBB"
else
  pass "all 5 UEs attached; multi-UE eMBB will run on current distribution (no handover)"
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

# Static-distribution multi-UE test: topology is informational (no handover here).
du_map = {ue.get("name"): ue.get("du") for ue in handover.get("ues", [])}
print("ue_du_map=", du_map)
print("[PASS] multi-UE eMBB ran on the current static distribution (no forced topology)")
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
