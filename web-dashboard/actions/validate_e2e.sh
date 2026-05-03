#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/e2e-validation-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"

log_section "Run validate-e2e.sh"
set +e
timeout 300 ./scripts/validate-e2e.sh 2>&1 | tee "$RUN_DIR/01-validate-e2e.txt"
VALIDATE_EXIT=${PIPESTATUS[0]}
set -e

echo "validate_exit=$VALIDATE_EXIT" | tee "$RUN_DIR/02-validate-exit.txt"

if [ "$VALIDATE_EXIT" -eq 0 ]; then
  STATUS="PASS - E2E baseline is working."
else
  STATUS="FAIL - E2E baseline validation failed."
fi

cat > "$RUN_DIR/E2E-VALIDATION-SUMMARY.txt" <<EOF2
E2E validation result

Status:
$STATUS

Evidence:
- validate_exit=$VALIDATE_EXIT
- Full output: $RUN_DIR/01-validate-e2e.txt

Evidence saved in:
$RUN_DIR
EOF2

cat "$RUN_DIR/E2E-VALIDATION-SUMMARY.txt"
exit "$VALIDATE_EXIT"
