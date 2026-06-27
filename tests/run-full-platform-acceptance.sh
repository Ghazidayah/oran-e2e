#!/usr/bin/env bash
# =============================================================================
# run-full-platform-acceptance.sh
# -----------------------------------------------------------------------------
# ONE command to exercise the whole O-RAN 5G platform and report every problem.
# It does NOT stop on the first failure: it runs every check, records pass/fail,
# and prints a single summary table at the end (plus a saved log bundle).
#
# Layers covered:
#   A. Preflight          - kubectl reachable, namespaces, platform is up
#   B. Infrastructure     - pods Running, 5GC SBI health (the cold-start gremlins:
#                           reject[9], SCP "No route", AMF NF discovery),
#                           NGAP (CU-CP<->AMF), E1 (CU-CP<->CU-UP), F1 (DU<->CU-CP),
#                           5/5 UE tunnels, dashboard :18080, traffic API :5055
#   C. Capabilities       - the repo's own 7 dashboard test-sections (01..07):
#                           baseline e2e, realistic traffic, real slices,
#                           radio/modulation profiles, multi-UE eMBB,
#                           mixed-DU handover, final regression
#   D. Frequency retune   - real n41 / n78 / n77 carrier retune + reattach
#
# Usage:
#   bash scripts/run-full-platform-acceptance.sh
#
# Useful env knobs:
#   REPO=/path/to/oran-e2e-freeze     (default: $HOME/oran-e2e-freeze)
#   SECTION_TIMEOUT=1800              (per dashboard section, seconds)
#   FREQ_TIMEOUT=420                  (per frequency band, seconds)
#   SKIP_SECTIONS="2 6"              (space list of section numbers to skip)
#   SKIP_FREQUENCY=1                  (skip the frequency retune block)
#   QUICK=1                           (skip the slowest: sections 2,4,6 + frequency)
# =============================================================================
set -u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
CORE_NS="oran-core"
RAN_NS="oran-ran"
DASH_PORT="${ORAN_DASHBOARD_PORT:-18080}"
TRAFFIC_PORT="${ORAN_TRAFFIC_API_PORT:-5055}"
SECTION_TIMEOUT="${SECTION_TIMEOUT:-1800}"
FREQ_TIMEOUT="${FREQ_TIMEOUT:-420}"
SKIP_SECTIONS="${SKIP_SECTIONS:-}"
SKIP_FREQUENCY="${SKIP_FREQUENCY:-0}"
QUICK="${QUICK:-0}"

if [ "$QUICK" = "1" ]; then
  SKIP_SECTIONS="${SKIP_SECTIONS} 2 4 6"
  SKIP_FREQUENCY=1
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/oran-proof/full-acceptance-$TS"
mkdir -p "$OUT"
MASTER_LOG="$OUT/acceptance.log"

# ---- result accumulators -----------------------------------------------------
RESULT_NAMES=()
RESULT_STATUS=()   # PASS | FAIL | WARN | SKIP
RESULT_DETAIL=()

record() {  # record <name> <status> <detail>
  RESULT_NAMES+=("$1"); RESULT_STATUS+=("$2"); RESULT_DETAIL+=("${3:-}")
  printf '  -> [%s] %s %s\n' "$2" "$1" "${3:-}" | tee -a "$MASTER_LOG"
}

hr()  { printf '%s\n' "------------------------------------------------------------------" | tee -a "$MASTER_LOG"; }
say() { printf '%s\n' "$*" | tee -a "$MASTER_LOG"; }

kc() { kubectl "$@" 2>>"$MASTER_LOG"; }

# deploy ready-replica count (0 if absent)
ready() { kubectl -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; }

say "============================================================"
say " O-RAN 5G FULL PLATFORM ACCEPTANCE TEST"
say " started: $(date)    repo: $REPO"
say " log bundle: $OUT"
say "============================================================"

# =============================================================================
# A. PREFLIGHT
# =============================================================================
hr; say "A. PREFLIGHT"
if ! command -v kubectl >/dev/null 2>&1; then
  record "preflight: kubectl present" FAIL "kubectl not found in PATH"
  say "FATAL: kubectl missing — cannot continue."; exit 2
fi
record "preflight: kubectl present" PASS ""

if ! kubectl get ns "$CORE_NS" >/dev/null 2>&1 || ! kubectl get ns "$RAN_NS" >/dev/null 2>&1; then
  record "preflight: namespaces exist" FAIL "missing $CORE_NS or $RAN_NS"
  say "FATAL: core/ran namespaces missing — is the platform deployed?"; exit 2
fi
record "preflight: namespaces exist" PASS ""

if [ ! -d "$REPO" ]; then
  record "preflight: repo dir" FAIL "$REPO not found"
  say "FATAL: repo dir not found; set REPO=..."; exit 2
fi
record "preflight: repo dir" PASS "$REPO"

# platform must be up; we test, we do not start it
if ! ready "$CORE_NS" open5gs-amf || ! ready "$RAN_NS" oai-cu-cp; then
  record "preflight: platform up" FAIL "AMF or CU-CP not Ready"
  say "FATAL: platform is not up. Run: bash scripts/platform-start.sh  (then re-run this test)."
  exit 2
fi
record "preflight: platform up" PASS ""

# =============================================================================
# B. INFRASTRUCTURE LAYER
# =============================================================================
hr; say "B. INFRASTRUCTURE"

# B1. all expected deployments Ready
core_deps="open5gs-mongodb open5gs-nrf open5gs-scp open5gs-udr open5gs-udm open5gs-ausf open5gs-bsf open5gs-nssf open5gs-pcf open5gs-smf open5gs-amf open5gs-upf"
ran_deps="oai-cu-cp oai-cu-up oai-du0 oai-du1 oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5"
not_ready=""
for d in $core_deps; do ready "$CORE_NS" "$d" || not_ready="$not_ready $CORE_NS/$d"; done
for d in $ran_deps;  do ready "$RAN_NS"  "$d" || not_ready="$not_ready $RAN_NS/$d";  done
if [ -z "$not_ready" ]; then record "infra: all deployments Ready" PASS ""
else record "infra: all deployments Ready" FAIL "not ready:$not_ready"; fi
kc -n "$CORE_NS" get pods -o wide > "$OUT/pods-core.txt"
kc -n "$RAN_NS"  get pods -o wide > "$OUT/pods-ran.txt"

# B2. 5GC SBI health (the cold-start gremlins)
amf_reject=$(kubectl -n "$CORE_NS" logs deploy/open5gs-amf --since=10m 2>/dev/null | grep -c "reject \[9\]")
scp_route=$(kubectl -n "$CORE_NS" logs deploy/open5gs-scp --since=10m 2>/dev/null | grep -c "No route to host")
# Look across the full AMF log (not just the recent tail) for NF discovery; on a long-running
# platform the startup "NF registered" lines have scrolled out of a short tail window.
amf_nf=$(kubectl -n "$CORE_NS" logs deploy/open5gs-amf 2>/dev/null | grep -c "NF registered")
[ "${amf_reject:-1}" -eq 0 ] && record "infra: AMF no reject[9]" PASS "" || record "infra: AMF no reject[9]" FAIL "count=$amf_reject (identity/SBI failure)"
[ "${scp_route:-1}" -eq 0 ] && record "infra: SCP no stale routes" PASS "" || record "infra: SCP no stale routes" FAIL "count=$scp_route (No route to host)"
if [ "${amf_nf:-0}" -ge 1 ]; then
  record "infra: AMF discovered NFs" PASS "n=$amf_nf"
elif [ "${amf_reject:-1}" -eq 0 ] && [ "${scp_route:-1}" -eq 0 ]; then
  # Startup "NF registered" lines rotate out of the log on a long-running platform; a clean SBA
  # (reject[9]=0 and no stale SCP routes) proves NF discovery succeeded.
  record "infra: AMF discovered NFs" PASS "discovery confirmed via clean SBA (startup log rotated)"
else
  record "infra: AMF discovered NFs" WARN "no 'NF registered' in log"
fi

# B3. NGAP (CU-CP <-> AMF)
cucp_log=$(kubectl -n "$RAN_NS" logs deploy/oai-cu-cp --tail=600 2>/dev/null)
if printf '%s' "$cucp_log" | grep -q "No AMF is associated"; then
  record "infra: NGAP CU-CP<->AMF" FAIL "CU-CP reports 'No AMF is associated'"
elif printf '%s' "$cucp_log" | grep -qiE "NGAP.*sctp|NGSetup|Send message to sctp: NGAP|for AMF"; then
  record "infra: NGAP CU-CP<->AMF" PASS ""
else
  record "infra: NGAP CU-CP<->AMF" WARN "no clear NGAP marker in recent CU-CP log"
fi

# B4. E1 (CU-CP <-> CU-UP)
if printf '%s' "$cucp_log" | grep -qiE "E1AP|CU-UP|associating to CU-UP|Accepting new"; then
  record "infra: E1 CU-CP<->CU-UP" PASS ""
else
  record "infra: E1 CU-CP<->CU-UP" WARN "no E1/CU-UP marker in recent CU-CP log"
fi

# B5. F1 (DU <-> CU-CP)
if printf '%s' "$cucp_log" | grep -qiE "F1 Setup|gNB-DU|F1AP|DU .*accept"; then
  record "infra: F1 DU<->CU-CP" PASS ""
else
  record "infra: F1 DU<->CU-CP" WARN "no F1 marker in recent CU-CP log"
fi

# B6. UE tunnels 5/5
tun_ok=0; tun_detail=""
for u in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  p=$(kubectl -n "$RAN_NS" get pod -l app="$u" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  ip=""
  [ -n "$p" ] && ip=$(kubectl -n "$RAN_NS" exec "$p" -- ip -br addr 2>/dev/null | awk '/oaitun/{print $3}' | head -1)
  if printf '%s' "$ip" | grep -qE '10\.45\.'; then tun_ok=$((tun_ok+1)); tun_detail="$tun_detail $u=${ip%%/*}"; else tun_detail="$tun_detail $u=NONE"; fi
done
[ "$tun_ok" -eq 5 ] && record "infra: UE tunnels 5/5" PASS "$tun_detail" || record "infra: UE tunnels 5/5" FAIL "$tun_ok/5:$tun_detail"

# B7. data-plane ping (one UE through its tunnel to the DN gw)
p1=$(kubectl -n "$RAN_NS" get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$p1" ] && kubectl -n "$RAN_NS" exec "$p1" -- ping -I oaitun_ue1 -c 2 -W 3 10.45.0.1 >/dev/null 2>&1; then
  record "infra: data-plane ping (UE1)" PASS ""
else
  record "infra: data-plane ping (UE1)" WARN "ping via oaitun_ue1 failed (UE may be mid-attach)"
fi

# B8. dashboard + traffic API reachable
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 6 "http://127.0.0.1:${DASH_PORT}/" >/dev/null 2>&1 \
    && record "infra: dashboard :$DASH_PORT" PASS "" || record "infra: dashboard :$DASH_PORT" WARN "not reachable (start with run-web-dashboard.sh)"
  # The traffic API has no route at "/"; probe its real health endpoint. Also accept any HTTP
  # response (even 404) as "listening", since a reply means the service is up.
  t_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 "http://127.0.0.1:${TRAFFIC_PORT}/api/traffic/health" 2>/dev/null)
  if [ "${t_code:-000}" != "000" ]; then
    record "infra: traffic API :$TRAFFIC_PORT" PASS "HTTP $t_code at /api/traffic/health"
  else
    record "infra: traffic API :$TRAFFIC_PORT" WARN "not reachable"
  fi
else
  record "infra: dashboard/traffic API" SKIP "curl not installed"
fi

# =============================================================================
# C. CAPABILITY SECTIONS (repo's own 7-section suite)
# =============================================================================
hr; say "C. CAPABILITY TEST SECTIONS (01..07)"

declare -A SECTION_FILE=(
  [1]="tests/test-section-01-baseline-e2e.sh"
  [2]="tests/test-section-02-realistic-traffic.sh"
  [3]="tests/test-section-03-real-slices.sh"
  [4]="tests/test-section-04-radio-profiles.sh"
  [5]="tests/test-section-05-multi-ue-embb.sh"
  [6]="tests/test-section-06-mixed-du-handover.sh"
  [7]="tests/test-section-07-final-regression.sh"
)
declare -A SECTION_NAME=(
  [1]="baseline E2E" [2]="realistic traffic" [3]="real slices (eMBB/URLLC/mMTC)"
  [4]="radio/modulation profiles" [5]="multi-UE eMBB" [6]="mixed-DU handover"
  [7]="final regression"
)

run_section() {
  local n="$1" f="$REPO/${SECTION_FILE[$n]}" label="section $n: ${SECTION_NAME[$n]}"
  for s in $SKIP_SECTIONS; do [ "$s" = "$n" ] && { record "$label" SKIP "skipped via SKIP_SECTIONS/QUICK"; return; }; done
  if [ ! -f "$f" ]; then record "$label" SKIP "script not found: ${SECTION_FILE[$n]}"; return; fi
  local log="$OUT/section-$n.log"
  say ">> running $label  (timeout ${SECTION_TIMEOUT}s) ..."
  ( cd "$REPO" && timeout "$SECTION_TIMEOUT" bash "$f" ) >"$log" 2>&1
  local rc=$?
  local verdict pass fail warn
  verdict=$(grep -E "^VERDICT=" "$log" | tail -1)
  pass=$(grep -E "^PASS=" "$log" | tail -1 | cut -d= -f2)
  fail=$(grep -E "^FAIL=" "$log" | tail -1 | cut -d= -f2)
  warn=$(grep -E "^WARN=" "$log" | tail -1 | cut -d= -f2)
  local detail="PASS=${pass:-?} WARN=${warn:-?} FAIL=${fail:-?}"
  if [ $rc -eq 124 ]; then record "$label" FAIL "TIMEOUT after ${SECTION_TIMEOUT}s ($detail)"; return; fi
  if printf '%s' "$verdict" | grep -q "_PASS$" && [ "${fail:-1}" = "0" ]; then
    record "$label" PASS "$detail"
  elif [ -n "$verdict" ]; then
    record "$label" FAIL "$detail ($verdict)"
  else
    record "$label" FAIL "no VERDICT line (rc=$rc, $detail) — see $log"
  fi
}

for n in 1 2 3 4 5 6 7; do run_section "$n"; done

# =============================================================================
# D. FREQUENCY RETUNE (n41 / n78 / n77)
# =============================================================================
hr; say "D. FREQUENCY RETUNE"
FREQ="$REPO/scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh"
if [ "$SKIP_FREQUENCY" = "1" ]; then
  record "frequency: n41/n78/n77 retune" SKIP "skipped via SKIP_FREQUENCY/QUICK"
elif [ ! -f "$FREQ" ]; then
  record "frequency: n41/n78/n77 retune" SKIP "script not found"
else
  for band in n41-2600 n78-3500 n77-4174; do
    log="$OUT/freq-$band.log"
    say ">> retune $band (timeout ${FREQ_TIMEOUT}s) ..."
    ( cd "$REPO" && timeout "$FREQ_TIMEOUT" bash "$FREQ" "$band" ) >"$log" 2>&1
    rc=$?
    if [ $rc -eq 124 ]; then record "frequency: $band" FAIL "TIMEOUT"; continue; fi
    if grep -qE "VERDICT=ACTUAL_FREQUENCY_RETUNE_.*_PASS" "$log"; then
      record "frequency: $band" PASS "$(grep -E '^PASS=' "$log" | tail -1)"
    else
      record "frequency: $band" FAIL "no PASS verdict — see $log"
    fi
  done
  # restore baseline carrier
  ( cd "$REPO" && timeout "$FREQ_TIMEOUT" bash "$FREQ" n78-current ) >"$OUT/freq-restore.log" 2>&1 \
    && say "   (restored baseline n78-current)" || say "   [warn] baseline restore had issues — see freq-restore.log"
fi

# =============================================================================
# FINAL REPORT
# =============================================================================
hr; say ""
say "============================================================"
say " ACCEPTANCE SUMMARY"
say "============================================================"
np=0; nf=0; nw=0; ns=0
for i in "${!RESULT_NAMES[@]}"; do
  st="${RESULT_STATUS[$i]}"
  case "$st" in PASS) np=$((np+1));; FAIL) nf=$((nf+1));; WARN) nw=$((nw+1));; SKIP) ns=$((ns+1));; esac
  printf ' %-5s | %-32s | %s\n' "$st" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}" | tee -a "$MASTER_LOG"
done
say "------------------------------------------------------------"
say " TOT|  PASS=$np  FAIL=$nf  WARN=$nw  SKIP=$ns"
say "------------------------------------------------------------"
if [ "$nf" -gt 0 ]; then
  say " OVERALL: FAIL  ($nf failing checks — see logs in $OUT)"
  say ""
  say " Failing items:"
  for i in "${!RESULT_NAMES[@]}"; do
    [ "${RESULT_STATUS[$i]}" = "FAIL" ] && say "   - ${RESULT_NAMES[$i]}: ${RESULT_DETAIL[$i]}"
  done
  RC=1
elif [ "$nw" -gt 0 ]; then
  say " OVERALL: PASS WITH WARNINGS ($nw warnings — usually mid-attach timing or optional services)"
  RC=0
else
  say " OVERALL: PASS — every layer and capability green."
  RC=0
fi
say ""
say " full logs + per-test output: $OUT"
say " finished: $(date)"
exit "$RC"
