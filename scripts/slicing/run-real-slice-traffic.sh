#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-}"

BASE="${BASE:-$HOME/oran-proof/phase3-real-slice-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"

mkdir -p "$DIR"

case "$PROFILE" in
  embb)
    SST="1"
    LABEL="eMBB"
    SCENARIOS=("image" "video" "web" "streaming" "iperf-tcp")
    ;;
  urllc)
    SST="2"
    LABEL="URLLC"
    SCENARIOS=("udp")
    ;;
  mmtc)
    SST="3"
    LABEL="mMTC"
    SCENARIOS=("mmtc-udp")
    ;;
  *)
    echo "Usage: $0 embb|urllc|mmtc"
    exit 1
    ;;
esac

echo "===== REAL SLICE TRAFFIC RUNNER ====="
echo "PROFILE=$PROFILE"
echo "LABEL=$LABEL"
echo "SST=$SST"
echo "DIR=$DIR"

restore_default() {
  echo
  echo "===== RESTORE DEFAULT eMBB SST=1 ====="
  scripts/slicing/switch-ue-slice.sh 1 0xffffff || true
}

trap restore_default EXIT

echo
echo "===== 1. SWITCH UE TO REAL SLICE $LABEL SST=$SST ====="
scripts/slicing/switch-ue-slice.sh "$SST" 0xffffff | tee "$DIR/switch-sst${SST}.log"

echo
echo "===== 2. VALIDATE SLICE TUNNEL ====="
scripts/slicing/validate-current-slice.sh | tee "$DIR/validate-sst${SST}.log"

echo
echo "===== 3. APPLY PHASE 4 SLICE RESOURCE PROFILE ====="
scripts/slicing/apply-slice-resource-profile.sh "$PROFILE" | tee "$DIR/resource-profile-${PROFILE}.log"

run_scenario() {
  local scenario="$1"

  echo
  echo "===== RUN SCENARIO $scenario ON SLICE $LABEL SST=$SST WITH PHASE 4 RESOURCE PROFILE ====="

  case "$scenario" in
    image)
      scripts/traffic/run-image-download.sh 2>&1 | tee "$DIR/image.log"
      ;;
    video)
      scripts/traffic/run-video-download.sh 2>&1 | tee "$DIR/video.log"
      ;;
    web)
      scripts/traffic/run-web-browsing.sh 2>&1 | tee "$DIR/web.log"
      ;;
    streaming)
      scripts/traffic/run-streaming-like.sh 2>&1 | tee "$DIR/streaming.log"
      ;;
    iperf-tcp)
      scripts/traffic/run-iperf-tcp.sh 2>&1 | tee "$DIR/iperf-tcp.log"
      ;;
    udp)
      scripts/traffic/run-udp-traffic.sh 2>&1 | tee "$DIR/udp.log"
      ;;
    mmtc-udp)
      COUNT=300 SIZE=128 INTERVAL=0.05 scripts/traffic/run-udp-traffic.sh 2>&1 | tee "$DIR/mmtc-udp.log"
      ;;
    *)
      echo "[FAIL] Unknown scenario $scenario"
      return 1
      ;;
  esac
}

FAIL=0

for scenario in "${SCENARIOS[@]}"; do
  run_scenario "$scenario" || FAIL=1
done

echo
echo "===== CREATE SUMMARY ====="
{
  echo "Real Slice Traffic Validation"
  echo "Profile: $PROFILE"
  echo "Label: $LABEL"
  echo "SST: $SST"
  echo "DNN: oai"
  echo "SD: 0xffffff"
  echo "Run ID: $RUN_ID"
  echo "Proof directory: $DIR"
  echo
  echo "Scenarios:"
  for s in "${SCENARIOS[@]}"; do
    echo "- $s"
  done
  echo
  if [ "$FAIL" -eq 0 ]; then
    echo "VERDICT=OK"
  else
    echo "VERDICT=FAIL"
  fi
} | tee "$DIR/summary.txt"

if [ "$FAIL" -eq 0 ]; then
  echo "===== REAL SLICE TRAFFIC OK ====="
  exit 0
else
  echo "===== REAL SLICE TRAFFIC FAILED ====="
  exit 1
fi
