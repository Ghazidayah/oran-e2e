#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/ci-ownership-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"
refresh_pods

echo "RUN_DIR=$RUN_DIR"
echo "UE_POD=$UE_POD" | tee "$RUN_DIR/00-pods.txt"
echo "GNB_A_POD=$GNB_A_POD" | tee -a "$RUN_DIR/00-pods.txt"
echo "GNB_B_POD=$GNB_B_POD" | tee -a "$RUN_DIR/00-pods.txt"

if [ -n "$GNB_A_POD" ]; then
  ci_check_one "$GNB_A_POD" 19090 "gnb-a" "$RUN_DIR" | tee "$RUN_DIR/01-gnb-a-ci.txt"
fi

if [ -n "$GNB_B_POD" ]; then
  ci_check_one "$GNB_B_POD" 19092 "gnb-b" "$RUN_DIR" | tee "$RUN_DIR/02-gnb-b-ci.txt"
fi

cat > "$RUN_DIR/CI-OWNERSHIP-SUMMARY.txt" <<EOF2
CI ownership check completed.

Interpretation:
- The serving gNB should normally return:
  single UE RNTI ...
  gNB_DU_id ... is connected to ue_id 1

- The non-serving gNB usually returns:
  different number of UEs
  No DU connected

Evidence saved in:
$RUN_DIR
EOF2

cat "$RUN_DIR/CI-OWNERSHIP-SUMMARY.txt"
