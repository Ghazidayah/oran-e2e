#!/usr/bin/env bash

ue_selector_for_deployment() {
  local ns="${1:-oran-ran}"
  local dep="${2:-oai-nr-ue}"

  kubectl -n "$ns" get deploy "$dep" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d=json.load(sys.stdin)
    labels=d.get("spec",{}).get("selector",{}).get("matchLabels",{})
    print(",".join([f"{k}={v}" for k,v in labels.items()]))
except Exception:
    print("")
'
}

ue_pod_for_deployment() {
  local ns="${1:-oran-ran}"
  local dep="${2:-oai-nr-ue}"
  local selector=""

  selector="$(ue_selector_for_deployment "$ns" "$dep")"

  if [ -z "$selector" ]; then
    echo ""
    return
  fi

  kubectl -n "$ns" get pods -l "$selector" -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d=json.load(sys.stdin)
    for p in d.get("items", []):
        name=p.get("metadata",{}).get("name","")
        phase=p.get("status",{}).get("phase","")
        deletion=p.get("metadata",{}).get("deletionTimestamp")
        if phase=="Running" and not deletion:
            print(name)
            break
except Exception:
    pass
'
}

ue_tunnel_ip_for_pod() {
  local ns="${1:-oran-ran}"
  local pod="${2:-}"

  if [ -z "$pod" ]; then
    echo ""
    return
  fi

  kubectl -n "$ns" exec "$pod" -- bash -lc \
    'ip -4 addr show oaitun_ue1 2>/dev/null | awk "/inet /{print \$2; exit}"' 2>/dev/null
}

ue_serveraddr_from_cm() {
  local ns="${1:-oran-ran}"
  local cm="${2:-oai-nrue-config}"

  kubectl -n "$ns" get cm "$cm" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
    | python3 -c '
import sys, re
text=sys.stdin.read()
m=re.search(r"serveraddr\s*=\s*\"([^\"]+)\"", text)
if not m:
    m=re.search(r"serveraddr\s*=\s*([A-Za-z0-9_.-]+)", text)
print(m.group(1) if m else "")
'
}

wait_exact_ue_tunnel() {
  local ns="${1:-oran-ran}"
  local dep="${2:-oai-nr-ue}"
  local timeout="${3:-240}"
  local i=0
  local pod=""
  local tun=""

  while [ "$i" -lt "$timeout" ]; do
    pod="$(ue_pod_for_deployment "$ns" "$dep")"
    tun="$(ue_tunnel_ip_for_pod "$ns" "$pod")"

    if [ -n "$pod" ] && [ -n "$tun" ]; then
      echo "$pod|$tun"
      return 0
    fi

    sleep 2
    i=$((i+2))
  done

  echo "|"
  return 1
}

# ---------------------------------------------------------------------------
# Rate helpers shared by the slicing and FSPL scripts.
# tc is given rates in kbit/s so that small values (1.05 Mbit/s, 35 kbit/s)
# are not rounded down to whole Mbit/s.
# ---------------------------------------------------------------------------

# rate_kbit <percent> <ceiling_mbit>  ->  prints "<N>kbit" (never below 1kbit)
rate_kbit() {
  awk -v pct="$1" -v ceil="$2" 'BEGIN{
    k = pct * ceil * 10;            # pct/100 * ceil(Mbit) * 1000 = pct*ceil*10 kbit
    n = int(k + 0.5); if (n < 1) n = 1;
    printf "%dkbit", n }'
}

# tc_rate_to_kbit "<text printed by tc, e.g. 1050Kbit or 35Mbit>" -> integer kbit
tc_rate_to_kbit() {
  awk -v s="$1" 'BEGIN{
    if (match(s, /[0-9]+(\.[0-9]+)?/) == 0) { print ""; exit }
    v = substr(s, RSTART, RLENGTH) + 0; u = tolower(substr(s, RSTART + RLENGTH));
    if (u ~ /^gbit/) v *= 1000000; else if (u ~ /^mbit/) v *= 1000;
    else if (u ~ /^kbit/) v *= 1; else if (u ~ /^bit/) v /= 1000; else { print ""; exit }
    printf "%d", v + 0.5 }'
}

# tc_verify_rate <ns> <pod> <expected_kbit>
# Reads the rate really installed on the tbf of both the tunnel (upload) and
# ifb_ue1 (download), and checks it matches the expected one within 2%.
# Prints one line per interface; returns 0 only if both match.
tc_verify_rate() {
  local ns="$1" pod="$2" expected="$3" dev out got diff tol ok=0
  for dev in oaitun_ue1 ifb_ue1; do
    out="$(kubectl -n "$ns" exec "$pod" -- tc qdisc show dev "$dev" 2>/dev/null \
            | grep -m1 ' tbf ' | grep -oE 'rate [0-9.]+[A-Za-z]+' | head -1 | awk '{print $2}')"
    got="$(tc_rate_to_kbit "$out")"
    if [ -z "$got" ]; then
      echo "  check $dev: no tbf rate found (expected ${expected}kbit)"; ok=1; continue
    fi
    diff=$(( got > expected ? got - expected : expected - got ))
    tol=$(( expected / 50 )); [ "$tol" -lt 1 ] && tol=1
    if [ "$diff" -le "$tol" ]; then
      echo "  check $dev: applied=${got}kbit expected=${expected}kbit OK"
    else
      echo "  check $dev: applied=${got}kbit expected=${expected}kbit MISMATCH"; ok=1
    fi
  done
  return $ok
}
