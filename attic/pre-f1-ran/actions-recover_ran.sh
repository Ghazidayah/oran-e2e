#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/recover-ran-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"

log_section "Run deploy-ran.sh"
./scripts/deploy-ran.sh 2>&1 | tee "$RUN_DIR/01-deploy-ran.txt"

log_section "Wait for attach/session"
sleep 120

log_section "Validate E2E after RAN recovery"
set +e
timeout 300 ./scripts/validate-e2e.sh 2>&1 | tee "$RUN_DIR/02-validate-e2e.txt"
VALIDATE_EXIT=${PIPESTATUS[0]}
set -e

echo "validate_exit=$VALIDATE_EXIT" | tee "$RUN_DIR/03-validate-exit.txt"

if [ "$VALIDATE_EXIT" -eq 0 ]; then
  STATUS="SUCCESS - RAN recovery restored E2E baseline."
else
  STATUS="INCOMPLETE - RAN recovery did not restore E2E baseline."
fi

cat > "$RUN_DIR/RAN-RECOVERY-SUMMARY.txt" <<EOF2
RAN recovery result

Status:
$STATUS

Evidence:
- deploy-ran.sh completed
- validate_exit=$VALIDATE_EXIT

Evidence saved in:
$RUN_DIR
EOF2

cat "$RUN_DIR/RAN-RECOVERY-SUMMARY.txt"
exit "$VALIDATE_EXIT"
