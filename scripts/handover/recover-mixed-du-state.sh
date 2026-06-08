#!/usr/bin/env bash
set +e
set +u

echo "============================================================"
echo " Recover ue3/ue4/ue5 on DU1 and rerun Mixed-DU validation"
echo " ue1 restored to baseline DU0"
echo " SAFE MODE: no exit 1"
echo "============================================================"

REPO="${REPO:-$HOME/oran-e2e-freeze}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
DASH="${DASH:-http://127.0.0.1:$PORT}"
STAMP="$(date +%Y%m%d-%H%M%S)"
PROOF_DIR="$HOME/oran-proof/recover-ue3-ue4-ue5-mixed-du-$STAMP"

mkdir -p "$PROOF_DIR"

cd "$REPO" || {
  echo "FAIL: could not cd to $REPO"
}

save_status() {
  name="$1"
  out="$PROOF_DIR/$name.json"

  curl -sS "$DASH/api/handover/mixed-du/status" > "$out"

  echo
  echo "----- $name -----"
  python3 - "$out" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("mode:", d.get("mode"))
print("du0_ready:", d.get("du0_ready"))
print("du1_ready:", d.get("du1_ready"))
print("attached:", d.get("attached_count"), "/", d.get("expected_count"))
print("ue1_du:", d.get("ue1_du"))
print("handover_ready:", d.get("handover_ready"))
for u in d.get("ues", []):
    print(
        u.get("name"),
        "du=", u.get("du"),
        "protected=", u.get("protected"),
        "tunnel=", u.get("tunnel_ip"),
        "pod=", u.get("pod"),
    )
PY
}

switch_to_du1() {
  ue="$1"
  out="$PROOF_DIR/switch-$ue-du1.json"

  echo
  echo "============================================================"
  echo "Switch/recover $ue -> DU1"
  echo "============================================================"

  curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"ue\":\"$ue\",\"target\":\"du1\"}" \
    "$DASH/api/handover/mixed-du/switch" > "$out"

  python3 - "$out" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("ok:", d.get("ok"))
print("verdict:", d.get("verdict"))
print("ue:", d.get("ue"))
print("target:", d.get("target"))
print()
print((d.get("script_output") or "")[-2000:])
PY
}

run_one_traffic() {
  ue="$1"
  scenario="$2"
  out="$PROOF_DIR/traffic-$ue-$scenario.json"

  echo
  echo "Traffic test: $ue / $scenario"

  curl -sS \
    -H "Content-Type: application/json" \
    -X POST \
    -d "{\"jobs\":[{\"ue\":\"$ue\",\"scenario\":\"$scenario\"}]}" \
    "$DASH/api/ues/embb-scenarios" > "$out"

  python3 - "$out" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("top_ok:", d.get("ok"))
print("mode:", d.get("mode"))
for r in d.get("results", []):
    print(
        r.get("ue"),
        r.get("scenario"),
        "ok=", r.get("ok"),
        "tunnel=", r.get("tunnel_ip"),
        "pod=", r.get("pod"),
    )
PY
}

echo
echo "1) Current status"
save_status "01-status-before"

echo
echo "2) Restore ue1 to baseline DU0"
UE1_OUT="$PROOF_DIR/02-ue1-restore-du0.json"

curl -sS \
  -H "Content-Type: application/json" \
  -X POST \
  -d '{"ue":"ue1","target":"du0"}' \
  "$DASH/api/handover/mixed-du/switch" > "$UE1_OUT"

python3 - "$UE1_OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("ok:", d.get("ok"))
print("verdict:", d.get("verdict"))
PY

echo
echo "3) Recover missing switchable UEs to DU1"
switch_to_du1 ue3
save_status "03-status-after-ue3-du1"
run_one_traffic ue3 streaming

switch_to_du1 ue4
save_status "04-status-after-ue4-du1"
run_one_traffic ue4 video_download

switch_to_du1 ue5
save_status "05-status-after-ue5-du1"
run_one_traffic ue5 tcp_download

echo
echo "4) Final full Mixed-DU validation"
RUN_OUT="$PROOF_DIR/06-final-mixed-du-run.json"

curl -sS -X POST "$DASH/api/handover/mixed-du/run" > "$RUN_OUT"

python3 - "$RUN_OUT" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print("ok:", d.get("ok"))
print("handover_success:", d.get("handover_success"))
print("mode:", d.get("mode"))
m=d.get("matrix", {})
print("matrix_ok:", m.get("ok"))
print("validation_strategy:", m.get("validation_strategy"))
print("requested_jobs:", m.get("requested_jobs"))
print("selected_count:", m.get("selected_count"))
for r in m.get("results", []):
    print(
        r.get("ue"),
        r.get("scenario"),
        "ok=", r.get("ok"),
        "tunnel=", r.get("tunnel_ip"),
        "pod=", r.get("pod"),
        "error=", r.get("error"),
    )
PY

OK="$(python3 - "$RUN_OUT" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1]))
    m=d.get("matrix", {})
    results=m.get("results", [])
    ok = (
        d.get("ok") is True
        and d.get("handover_success") is True
        and len(results) == 5
        and all(r.get("ok") is True for r in results)
    )
    print("true" if ok else "false")
except Exception:
    print("false")
PY
)"

echo
echo "5) Final status"
save_status "07-status-final"

echo
echo "6) Final verdict"
echo "Proof dir: $PROOF_DIR"

if [ "$OK" = "true" ]; then
  echo "VERDICT=MIXED_DU_RECOVERY_AND_VALIDATION_OK"
  echo "RESULT=ue3/ue4/ue5 recovered on DU1; ue1 on baseline DU0; full Mixed-DU validation passed"
else
  echo "VERDICT=MIXED_DU_RECOVERY_STILL_NEEDS_CHECK"
  echo "Check proof dir: $PROOF_DIR"
fi

echo "============================================================"
echo " Done"
echo "============================================================"
