#!/usr/bin/env bash
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-platform-functional-tests/section-06-mixed-du-handover-$TS"
mkdir -p "$OUT"

# Tear down any residual per-UE tc/netem (e.g. mMTC 1000ms delay from the slice
# section) so it cannot stall UE rollouts/attach during the DU switches below.
echo "[section6] clearing residual netem on all UEs before handover tests"
for _u in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  _p=$(kubectl -n oran-ran get pod -l app=$_u -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$_p" ] && kubectl -n oran-ran exec "$_p" -- sh -lc 'tc qdisc del dev oaitun_ue1 root 2>/dev/null; tc qdisc del dev oaitun_ue1 ingress 2>/dev/null; ip link del ifb_ue1 2>/dev/null; true' 2>/dev/null
done

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
  local name="$1"
  local url="$2"
  local file="$3"

  echo "--- GET $url"
  if curl -fsS --max-time 90 "$url" > "$file"; then
    python3 -m json.tool "$file" > "${file}.pretty" 2>/dev/null || true
    head -140 "${file}.pretty" 2>/dev/null || head -100 "$file"
    pass "$name"
    return 0
  else
    fail "$name"
    return 1
  fi
}

post_json_file() {
  local name="$1"
  local url="$2"
  local payload_file="$3"
  local out_file="$4"
  local timeout="${5:-1200}"

  echo "--- POST $url"
  echo "--- payload:"
  cat "$payload_file"

  http_code="$(
    curl -sS --max-time "$timeout" \
      -H "Content-Type: application/json" \
      -X POST \
      --data-binary @"$payload_file" \
      -o "$out_file" \
      -w "%{http_code}" \
      "$url" || echo "curl_failed"
  )"

  echo
  echo "HTTP_CODE=$http_code"
  python3 -m json.tool "$out_file" > "${out_file}.pretty" 2>/dev/null || true
  head -180 "${out_file}.pretty" 2>/dev/null || head -120 "$out_file"

  if [ "$http_code" = "200" ]; then
    pass "$name"
    return 0
  else
    warn "$name returned HTTP $http_code"
    return 1
  fi
}

check_ue_du() {
  local status_file="$1"
  local ue="$2"
  local expected_du="$3"
  local expected_server="$4"

  python3 - "$status_file" "$ue" "$expected_du" "$expected_server" <<'PY'
import json, sys

path, ue_name, expected_du, expected_server = sys.argv[1:5]
d = json.load(open(path))
ue = next((x for x in d.get("ues", []) if x.get("name") == ue_name), None)

if not ue:
    print(f"[FAIL] {ue_name} missing")
    raise SystemExit(1)

print(f"{ue_name}: attached={ue.get('attached')} du={ue.get('du')} serveraddr={ue.get('serveraddr')} tunnel={ue.get('tunnel_ip')} protected={ue.get('protected')}")

ok = True
if ue.get("attached") is not True:
    print(f"[FAIL] {ue_name} not attached")
    ok = False
if ue.get("du") != expected_du:
    print(f"[FAIL] {ue_name} expected du={expected_du}, got {ue.get('du')}")
    ok = False
if ue.get("serveraddr") != expected_server:
    print(f"[FAIL] {ue_name} expected serveraddr={expected_server}, got {ue.get('serveraddr')}")
    ok = False
if not ue.get("tunnel_ip"):
    print(f"[FAIL] {ue_name} tunnel_ip empty")
    ok = False

if ok:
    print(f"[PASS] {ue_name} is attached on {expected_du}")

raise SystemExit(0 if ok else 1)
PY
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

section "1. FRONTEND / UI STRUCTURE CHECK"
if curl -fsS --max-time 20 "$BASE/" > "$OUT/dashboard.html"; then
  pass "dashboard page reachable"
else
  fail "dashboard page not reachable"
fi

for marker in \
  "mixedDuLowerHandoverSection" \
  "DU Continuity / Handover" \
  "Refresh DU Status" \
  "Run Mixed-DU Validation" \
  "mixedDuTableBody"
do
  if grep -q "$marker" "$OUT/dashboard.html"; then
    pass "handover UI marker present: $marker"
  else
    fail "handover UI marker missing: $marker"
  fi
done

if grep -qE "Check F1 Status|runF1HandoverButton|F1 Handover Readiness" "$OUT/dashboard.html"; then
  fail "old top F1 handover card still present"
else
  pass "old top F1 handover card is absent"
fi

if curl -fsS --max-time 20 "$BASE/static/mixed-du-table.js" > "$OUT/mixed-du-table.js"; then
  pass "mixed-du-table.js served"
else
  fail "mixed-du-table.js not served"
fi

for marker in \
  "/api/handover/mixed-du/status" \
  "/api/handover/mixed-du/switch" \
  "/api/handover/mixed-du/run"
do
  if grep -q "$marker" "$OUT/mixed-du-table.js"; then
    pass "mixed-du-table.js uses $marker"
  else
    fail "mixed-du-table.js missing $marker"
  fi
done

section "2. PREFLIGHT HANDOVER STATUS"
json_get "handover status before" "$BASE/api/handover/mixed-du/status" "$OUT/status-before.json"

python3 - "$OUT/status-before.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("attached_count=", d.get("attached_count"))
print("expected_count=", d.get("expected_count"))
print("handover_ready=", d.get("handover_ready"))
print("blocked_ues=", d.get("blocked_ues"))
print("allowed_ues=", d.get("allowed_ues"))

assert d.get("attached_count") == 5, d.get("attached_count")
assert d.get("expected_count") == 5, d.get("expected_count")
assert d.get("handover_ready") is True, d.get("handover_ready")
# Current design: all 5 UEs are DU-switchable; ue1 is the reference (DU0 baseline), not blocked.
assert all(u in d.get("allowed_ues", []) for u in ["ue1","ue2","ue3","ue4","ue5"])
assert d.get("blocked_ues", []) == [], d.get("blocked_ues")

print("PASS: preflight Mixed-DU topology is ready")
PY

if [ "$?" -eq 0 ]; then
  pass "preflight Mixed-DU topology ready"
else
  fail "preflight Mixed-DU topology not ready"
fi

section "3. UE1 DU-SWITCH TEST: ue1 -> DU1 -> DU0 (reference UE, DU0 baseline)"
cat > "$OUT/switch-ue1-du1.json" <<'JSON'
{"ue":"ue1","target":"du1"}
JSON

if post_json_file \
  "switch ue1 to du1" \
  "$BASE/api/handover/mixed-du/switch" \
  "$OUT/switch-ue1-du1.json" \
  "$OUT/switch-ue1-du1-response.json" \
  900; then

  python3 - "$OUT/switch-ue1-du1-response.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict") == "UE_DU_SWITCH_OK", d.get("verdict")
print("PASS: ue1 DU1 switch response OK")
PY

  if [ "$?" -eq 0 ]; then
    pass "ue1 switched to DU1"
  else
    fail "ue1 DU1 switch response invalid"
  fi
else
  fail "ue1 DU1 switch request failed"
fi

json_get "status after ue1 -> du1" "$BASE/api/handover/mixed-du/status" "$OUT/status-after-ue1-du1.json"
if check_ue_du "$OUT/status-after-ue1-du1.json" "ue1" "du1" "oai-du1-rfsim"; then
  pass "ue1 on DU1 after switch"
else
  fail "ue1 not on DU1 after switch"
fi

# restore ue1 to its baseline home DU0
cat > "$OUT/switch-ue1-du0.json" <<'JSON'
{"ue":"ue1","target":"du0"}
JSON

if post_json_file \
  "restore ue1 to du0" \
  "$BASE/api/handover/mixed-du/switch" \
  "$OUT/switch-ue1-du0.json" \
  "$OUT/switch-ue1-du0-response.json" \
  900; then

  python3 - "$OUT/switch-ue1-du0-response.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict") == "UE_DU_SWITCH_OK", d.get("verdict")
print("PASS: ue1 restore-to-DU0 response OK")
PY

  if [ "$?" -eq 0 ]; then
    pass "ue1 restored to DU0"
  else
    fail "ue1 restore-to-DU0 response invalid"
  fi
else
  fail "ue1 restore-to-DU0 request failed"
fi

json_get "status after ue1 -> du0" "$BASE/api/handover/mixed-du/status" "$OUT/status-after-ue1-du0.json"
if check_ue_du "$OUT/status-after-ue1-du0.json" "ue1" "du0" "oai-du0-rfsim"; then
  pass "ue1 restored to DU0 baseline"
else
  fail "ue1 did not return to DU0"
fi

section "4. SWITCH ue2 DU1 -> DU0"
cat > "$OUT/switch-ue2-du0.json" <<'JSON'
{"ue":"ue2","target":"du0"}
JSON

if post_json_file \
  "switch ue2 to du0" \
  "$BASE/api/handover/mixed-du/switch" \
  "$OUT/switch-ue2-du0.json" \
  "$OUT/switch-ue2-du0-response.json" \
  900; then

  python3 - "$OUT/switch-ue2-du0-response.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict") == "UE_DU_SWITCH_OK", d.get("verdict")
print("PASS: ue2 DU0 switch response OK")
PY
  [ "$?" -eq 0 ] && pass "ue2 DU0 switch response validated" || fail "ue2 DU0 switch response invalid"
fi

json_get "status after ue2 -> du0" "$BASE/api/handover/mixed-du/status" "$OUT/status-after-ue2-du0.json"
if check_ue_du "$OUT/status-after-ue2-du0.json" "ue2" "du0" "oai-du0-rfsim"; then
  pass "ue2 attached on DU0"
else
  fail "ue2 DU0 status invalid"
fi

section "5. TRAFFIC ON ue2 AFTER DU0 SWITCH"
cat > "$OUT/ue2-web-payload.json" <<'JSON'
{
  "jobs": [
    {"ue":"ue2","scenario":"web"}
  ]
}
JSON

if post_json_file \
  "ue2 web traffic after DU0 switch" \
  "$BASE/api/ues/embb-scenarios" \
  "$OUT/ue2-web-payload.json" \
  "$OUT/ue2-web-after-du0.json" \
  900; then

  python3 - "$OUT/ue2-web-after-du0.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("selected_count") == 1, d.get("selected_count")
r=d.get("results", [])[0]
assert r.get("ue") == "ue2", r
assert r.get("ok") is True, r
assert r.get("exit") == 0, r
print("PASS: ue2 web traffic OK after DU0 switch")
PY
  [ "$?" -eq 0 ] && pass "ue2 traffic OK after DU0 switch" || fail "ue2 traffic failed after DU0 switch"
fi

section "6. SWITCH ue2 DU0 -> DU1 RESTORE"
cat > "$OUT/switch-ue2-du1.json" <<'JSON'
{"ue":"ue2","target":"du1"}
JSON

if post_json_file \
  "switch ue2 back to du1" \
  "$BASE/api/handover/mixed-du/switch" \
  "$OUT/switch-ue2-du1.json" \
  "$OUT/switch-ue2-du1-response.json" \
  900; then

  python3 - "$OUT/switch-ue2-du1-response.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("ok") is True, d
assert d.get("verdict") == "UE_DU_SWITCH_OK", d.get("verdict")
print("PASS: ue2 DU1 restore response OK")
PY
  [ "$?" -eq 0 ] && pass "ue2 DU1 restore response validated" || fail "ue2 DU1 restore response invalid"
fi

json_get "status after ue2 -> du1 restore" "$BASE/api/handover/mixed-du/status" "$OUT/status-after-ue2-du1.json"
if check_ue_du "$OUT/status-after-ue2-du1.json" "ue2" "du1" "oai-du1-rfsim"; then
  pass "ue2 restored to DU1"
else
  fail "ue2 DU1 restore status invalid"
fi

section "7. RUN FULL MIXED-DU VALIDATION BUTTON/BACKEND"
if curl -fsS --max-time 1800 \
  -X POST \
  "$BASE/api/handover/mixed-du/run" \
  > "$OUT/mixed-du-run.json"; then
  pass "POST /api/handover/mixed-du/run returned HTTP 200"
  python3 -m json.tool "$OUT/mixed-du-run.json" > "$OUT/mixed-du-run.pretty" 2>/dev/null || true
  head -220 "$OUT/mixed-du-run.pretty" 2>/dev/null || head -160 "$OUT/mixed-du-run.json"
else
  fail "POST /api/handover/mixed-du/run failed"
fi

python3 - "$OUT/mixed-du-run.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))

print("ok=", d.get("ok"))
print("handover_success=", d.get("handover_success"))
print("cu_complete=", d.get("cu_complete"))
print("du_cfra=", d.get("du_cfra"))
print("trigger_ok=", d.get("trigger_ok"))
print("matrix_ok=", (d.get("matrix") or {}).get("ok"))

ok = (
    d.get("ok") is True
    and d.get("handover_success") is True
    and d.get("cu_complete") is True
    and d.get("du_cfra") is True
    and (d.get("matrix") or {}).get("ok") is True
)

if ok:
    print("PASS: full Mixed-DU validation OK")
else:
    print("FAIL: full Mixed-DU validation not OK")
    raise SystemExit(1)
PY

if [ "$?" -eq 0 ]; then
  pass "full Mixed-DU validation OK"
else
  fail "full Mixed-DU validation failed"
fi

section "8. FINAL TOPOLOGY AND UE1 BASELINE"
json_get "final handover status" "$BASE/api/handover/mixed-du/status" "$OUT/status-final.json"

python3 - "$OUT/status-final.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))

assert d.get("attached_count") == 5, d.get("attached_count")
assert d.get("handover_ready") is True, d.get("handover_ready")

expected = {
    "ue1": ("du0", "oai-du0-rfsim", False),
    "ue2": ("du1", "oai-du1-rfsim", False),
    "ue3": ("du1", "oai-du1-rfsim", False),
    "ue4": ("du1", "oai-du1-rfsim", False),
    "ue5": ("du1", "oai-du1-rfsim", False),
}

ues = {u["name"]: u for u in d.get("ues", [])}
for name, (du, server, protected) in expected.items():
    u=ues[name]
    print(name, u.get("attached"), u.get("du"), u.get("serveraddr"), u.get("tunnel_ip"), "protected=", u.get("protected"))
    assert u.get("attached") is True
    assert u.get("du") == du
    assert u.get("serveraddr") == server
    assert bool(u.get("protected")) == protected
    assert u.get("tunnel_ip")

print("PASS: final topology is expected")
PY

if [ "$?" -eq 0 ]; then
  pass "final topology correct"
else
  fail "final topology incorrect"
fi

if bash scripts/validate-e2e.sh > "$OUT/validate-final.log" 2>&1; then
  pass "final validate-e2e passed"
else
  fail "final validate-e2e failed"
fi
tail -120 "$OUT/validate-final.log"

section "9. SUMMARY"
echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT=SECTION_06_MIXED_DU_HANDOVER_PASS"
else
  echo "VERDICT=SECTION_06_MIXED_DU_HANDOVER_HAS_FAILURES"
fi
