#!/usr/bin/env bash
# test-all-scenarios.sh — run every Phase-2 realistic-traffic scenario in sequence
# against the traffic API (:5055) and print each result. Read-only w.r.t. the
# cluster (scenarios only generate traffic through the UE tunnel). Safe to re-run.
#
# Usage:
#   scripts/traffic/test-all-scenarios.sh            # individual scenarios (skip run-all)
#   scripts/traffic/test-all-scenarios.sh --with-all # also run the bundled run-all suite
#   scripts/traffic/test-all-scenarios.sh --only run-all

set -uo pipefail

API="${TRAFFIC_API:-http://127.0.0.1:5055}"
REPO="${REPO:-$HOME/oran-e2e}"
POLL_MAX="${POLL_MAX:-120}"
POLL_INT=3

SCENARIOS=(iperf-tcp udp image video web streaming)
WITH_ALL=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --with-all) WITH_ALL=1 ;;
    --only) ONLY="$2"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  shift
done
[ -n "$ONLY" ] && SCENARIOS=("$ONLY")

if ! curl -s -o /dev/null --max-time 3 "$API/api/traffic/health"; then
  echo ">> Traffic API not responding at $API — starting it..."
  "$REPO/scripts/traffic/start-traffic-api.sh" >/dev/null 2>&1
  sleep 4
fi
health="$(curl -s --max-time 5 "$API/api/traffic/health")"
if [ -z "$health" ]; then
  echo "FATAL: traffic API still not reachable at $API. Start it manually:"
  echo "  ./scripts/traffic/start-traffic-api.sh"
  exit 1
fi
echo "Traffic API health: $health"
echo

declare -A RESULT_STATUS
run_one() {
  local s="$1"
  echo "=================================================================="
  echo " SCENARIO: $s"
  echo "=================================================================="
  local start jid
  start="$(curl -s -X POST "$API/api/traffic/run/$s")"
  jid="$(echo "$start" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('job_id',''))
except: print('')" 2>/dev/null)"

  if [ -z "$jid" ]; then
    echo "  ERROR: failed to start. Response: $start"
    RESULT_STATUS[$s]="start-failed"
    return
  fi
  echo "  job_id=$jid  polling (max $((POLL_MAX*POLL_INT))s)..."

  local i resp status
  for i in $(seq 1 "$POLL_MAX"); do
    sleep "$POLL_INT"
    resp="$(curl -s "$API/api/traffic/jobs/$jid")"
    status="$(echo "$resp" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('job',{}).get('status','?'))
except: print('?')" 2>/dev/null)"
    case "$status" in
      ok|failed|timeout|error)
        RESULT_STATUS[$s]="$status"
        echo "  STATUS=$status"
        echo "$resp" | python3 -c "import sys,json
d=json.load(sys.stdin); j=d.get('job',{})
print('  exit:', j.get('exit'))
print('  proof:', j.get('job_dir') or j.get('log_file') or '-')
print('  ----- output tail -----')
out=d.get('output','') or ''
print('\n'.join('  '+l for l in out.strip().splitlines()[-25:]))" 2>/dev/null
        echo
        return ;;
    esac
  done
  RESULT_STATUS[$s]="still-running"
  echo "  STILL RUNNING after poll window — check $API/api/traffic/jobs/$jid"
  echo
}

for s in "${SCENARIOS[@]}"; do
  run_one "$s"
done

if [ "$WITH_ALL" = 1 ] && [ -z "$ONLY" ]; then
  echo ">> Running the bundled run-all suite (this is the heaviest one)..."
  POLL_MAX=200 run_one "run-all"
fi

echo "=================================================================="
echo " SUMMARY"
echo "=================================================================="
fail=0
for s in "${SCENARIOS[@]}" $([ "$WITH_ALL" = 1 ] && [ -z "$ONLY" ] && echo run-all); do
  st="${RESULT_STATUS[$s]:-not-run}"
  printf "  %-12s %s\n" "$s" "$st"
  [ "$st" = "ok" ] || fail=1
done
echo
[ "$fail" = 0 ] && echo "VERDICT=ALL_OK" || echo "VERDICT=SOME_FAILED (see above)"
