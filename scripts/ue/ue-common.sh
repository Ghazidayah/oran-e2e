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

ue_slice_from_cm() {
  local ns="${1:-oran-ran}"
  local cm="${2:-oai-nrue-config}"

  kubectl -n "$ns" get cm "$cm" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
    | python3 -c '
import sys, re
text=sys.stdin.read()
sst=re.search(r"nssai_sst\s*=\s*([^;,\n}]+)", text)
sd=re.search(r"nssai_sd\s*=\s*([^;,\n}]+)", text)
sst_val = sst.group(1).strip() if sst else "unknown"
sd_val = sd.group(1).strip() if sd else "unknown"
print("nssai_sst={} nssai_sd={}".format(sst_val, sd_val))
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
