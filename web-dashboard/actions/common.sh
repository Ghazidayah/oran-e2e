#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e"
PROOF_ROOT="$HOME/oran-proof"

TODAY_DIR="$PROOF_ROOT/today-$(date +%Y%m%d)-dashboard"
mkdir -p "$TODAY_DIR"

ts() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_section() {
  echo
  echo "===== $1 ====="
  echo "time=$(ts)"
}

refresh_pods() {
  UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  GNB_A_POD=$(kubectl -n oran-ran get pod -o name 2>/dev/null | \
    grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2 || true)

  GNB_B_POD=$(kubectl -n oran-ran get pod -o name 2>/dev/null | \
    grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2 || true)

  export UE_POD GNB_A_POD GNB_B_POD
}

ci_check_one() {
  local pod="$1"
  local port="$2"
  local label="$3"
  local outdir="$4"

  log_section "$label CI ownership"

  kubectl -n oran-ran port-forward pod/"$pod" "$port":9090 \
    > "$outdir/portforward-$label.log" 2>&1 &
  local pf_pid=$!

  sleep 3

  echo "----- ci get_single_rnti -----"
  timeout 3 bash -lc "printf 'ci get_single_rnti\r\n' | nc 127.0.0.1 $port" || true

  echo "----- ci fetch_du_by_ue_id 1 -----"
  timeout 3 bash -lc "printf 'ci fetch_du_by_ue_id 1\r\n' | nc 127.0.0.1 $port" || true

  kill "$pf_pid" 2>/dev/null || true
  sleep 1
}
