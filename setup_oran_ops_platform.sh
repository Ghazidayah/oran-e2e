#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
APP_DIR="$BASE_DIR/web-dashboard"
SCRIPT_DIR="$APP_DIR/actions"
RUN_SCRIPT="$BASE_DIR/run-web-dashboard.sh"

mkdir -p "$APP_DIR/templates" "$APP_DIR/static" "$SCRIPT_DIR" "$HOME/oran-proof/web-dashboard-runs"

cat > "$APP_DIR/requirements.txt" <<'REQ'
flask
REQ

cat > "$SCRIPT_DIR/common.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
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
SH

cat > "$SCRIPT_DIR/collect_snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/snapshot-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"

log_section "Snapshot directory"
echo "$RUN_DIR"

log_section "Kubernetes node"
kubectl get nodes -o wide | tee "$RUN_DIR/01-nodes.txt"

log_section "RAN pods"
kubectl -n oran-ran get pods -o wide | tee "$RUN_DIR/02-ran-pods.txt"

log_section "Core pods"
kubectl -n oran-core get pods -o wide | tee "$RUN_DIR/03-core-pods.txt"

log_section "Monitoring pods"
kubectl -n monitoring get pods -o wide | tee "$RUN_DIR/04-monitoring-pods.txt" || true

log_section "Services"
kubectl -n oran-ran get svc -o wide | tee "$RUN_DIR/05-ran-services.txt"
kubectl -n oran-core get svc -o wide | tee "$RUN_DIR/06-core-services.txt"
kubectl -n monitoring get svc -o wide | tee "$RUN_DIR/07-monitoring-services.txt" || true

refresh_pods

echo "UE_POD=$UE_POD" | tee "$RUN_DIR/08-current-pods.txt"
echo "GNB_A_POD=$GNB_A_POD" | tee -a "$RUN_DIR/08-current-pods.txt"
echo "GNB_B_POD=$GNB_B_POD" | tee -a "$RUN_DIR/08-current-pods.txt"

log_section "UE tunnel state"
if [ -n "$UE_POD" ]; then
  kubectl -n oran-ran exec "$UE_POD" -- sh -c '
    ip addr show oaitun_ue1 || true
    echo "----- routes -----"
    ip route || true
    echo "----- ping DN gateway -----"
    ping -I oaitun_ue1 -c 3 10.45.0.1 || true
    echo "----- ping internet -----"
    ping -I oaitun_ue1 -c 3 8.8.8.8 || true
  ' | tee "$RUN_DIR/09-ue-tunnel.txt"
fi

log_section "Recent gNB-A radio state"
if [ -n "$GNB_A_POD" ]; then
  kubectl -n oran-ran logs "$GNB_A_POD" --since=5m | \
    egrep -i 'UE RNTI|CU-UE-ID|in-sync|RRCSetup|RRCSetupComplete|InitialContext|PDU|handover|error|fail' | \
    tail -n 120 | tee "$RUN_DIR/10-gnb-a-radio.txt" || true
fi

log_section "Recent gNB-B radio state"
if [ -n "$GNB_B_POD" ]; then
  kubectl -n oran-ran logs "$GNB_B_POD" --since=5m | \
    egrep -i 'UE RNTI|CU-UE-ID|in-sync|RRCSetup|RRCSetupComplete|InitialContext|PDU|handover|error|fail' | \
    tail -n 120 | tee "$RUN_DIR/11-gnb-b-radio.txt" || true
fi

log_section "AMF view"
kubectl -n oran-core logs deploy/open5gs-amf --since=10m | \
  egrep -i 'gNB-N2|InitialUEMessage|Registration complete|PDU|DNN|imsi|error|fail' | \
  tail -n 160 | tee "$RUN_DIR/12-amf.txt" || true

log_section "SMF view"
kubectl -n oran-core logs deploy/open5gs-smf --since=10m | \
  egrep -i 'imsi|DNN|10.45.0|IPv4|PFCP|session|error|fail' | \
  tail -n 120 | tee "$RUN_DIR/13-smf.txt" || true

log_section "UPF view"
kubectl -n oran-core logs deploy/open5gs-upf --since=10m | \
  egrep -i 'gtp_connect|10.20.0|PFCP|Invalid packet|error|fail' | \
  tail -n 120 | tee "$RUN_DIR/14-upf.txt" || true

cat > "$RUN_DIR/SNAPSHOT-SUMMARY.txt" <<EOF2
O-RAN lab evidence snapshot

Status:
Snapshot completed.

Saved in:
$RUN_DIR

Contains:
- Kubernetes node state
- RAN/Core/Monitoring pods and services
- UE tunnel state
- DN gateway and internet ping checks
- gNB-A/gNB-B radio logs
- AMF/SMF/UPF recent logs
EOF2

log_section "Snapshot complete"
cat "$RUN_DIR/SNAPSHOT-SUMMARY.txt"
SH

cat > "$SCRIPT_DIR/ci_ownership.sh" <<'SH'
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
SH

cat > "$SCRIPT_DIR/validate_e2e.sh" <<'SH'
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
SH

cat > "$SCRIPT_DIR/recover_ran.sh" <<'SH'
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
SH

cat > "$SCRIPT_DIR/recover_full.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/recover-full-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"

log_section "prepare-network"
./scripts/prepare-network.sh 2>&1 | tee "$RUN_DIR/01-prepare-network.txt"

log_section "deploy-core"
./scripts/deploy-core.sh 2>&1 | tee "$RUN_DIR/02-deploy-core.txt"

log_section "deploy-ran"
./scripts/deploy-ran.sh 2>&1 | tee "$RUN_DIR/03-deploy-ran.txt"

log_section "Wait for attach/session"
sleep 120

log_section "Validate E2E after full recovery"
set +e
timeout 300 ./scripts/validate-e2e.sh 2>&1 | tee "$RUN_DIR/04-validate-e2e.txt"
VALIDATE_EXIT=${PIPESTATUS[0]}
set -e

echo "validate_exit=$VALIDATE_EXIT" | tee "$RUN_DIR/05-validate-exit.txt"

if [ "$VALIDATE_EXIT" -eq 0 ]; then
  STATUS="SUCCESS - Full recovery restored E2E baseline."
else
  STATUS="INCOMPLETE - Full recovery did not restore E2E baseline."
fi

cat > "$RUN_DIR/FULL-RECOVERY-SUMMARY.txt" <<EOF2
Full recovery result

Status:
$STATUS

Evidence:
- prepare-network.sh completed
- deploy-core.sh completed
- deploy-ran.sh completed
- validate_exit=$VALIDATE_EXIT

Evidence saved in:
$RUN_DIR
EOF2

cat "$RUN_DIR/FULL-RECOVERY-SUMMARY.txt"
exit "$VALIDATE_EXIT"
SH

cat > "$SCRIPT_DIR/ho_a_to_b.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/serial-a-to-b-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"
refresh_pods

echo "RUN_DIR=$RUN_DIR" | tee "$RUN_DIR/00-path.txt"
echo "UE=$UE_POD" | tee "$RUN_DIR/01-pods.txt"
echo "GNB_A_SOURCE=$GNB_A_POD" | tee -a "$RUN_DIR/01-pods.txt"
echo "GNB_B_TARGET=$GNB_B_POD" | tee -a "$RUN_DIR/01-pods.txt"

log_section "Pre-check source gNB-A"
ci_check_one "$GNB_A_POD" 19090 "source-gnb-a" "$RUN_DIR" | tee "$RUN_DIR/02-source-gnb-a-ci.txt"

log_section "Pre-check target gNB-B"
ci_check_one "$GNB_B_POD" 19092 "target-gnb-b" "$RUN_DIR" | tee "$RUN_DIR/03-target-gnb-b-ci.txt"

log_section "Start live captures"
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 10.45.0.1' > "$RUN_DIR/04-ue-continuous-ping.log" 2>&1 &
PING_PID=$!

kubectl -n oran-ran logs "$GNB_A_POD" --since=5s -f > "$RUN_DIR/05-source-gnb-a.log" 2>&1 &
LOG_A_PID=$!

kubectl -n oran-ran logs "$GNB_B_POD" --since=5s -f > "$RUN_DIR/06-target-gnb-b.log" 2>&1 &
LOG_B_PID=$!

kubectl -n oran-core logs deploy/open5gs-amf --since=5s -f > "$RUN_DIR/07-amf.log" 2>&1 &
LOG_AMF_PID=$!

kubectl -n oran-core logs deploy/open5gs-smf --since=5s -f > "$RUN_DIR/08-smf.log" 2>&1 &
LOG_SMF_PID=$!

kubectl -n oran-core logs deploy/open5gs-upf --since=5s -f > "$RUN_DIR/09-upf.log" 2>&1 &
LOG_UPF_PID=$!

kubectl -n oran-ran port-forward pod/"$GNB_A_POD" 19090:9090 > "$RUN_DIR/10-portforward-trigger.log" 2>&1 &
PF_PID=$!

sleep 5

log_section "Trigger A to B N2 HO"
timeout 5 bash -lc 'printf "ci trigger_n2_ho 1,1\r\n" | nc 127.0.0.1 19090' | tee "$RUN_DIR/11-ho-trigger-output.txt" || true

sleep 45

kill "$PF_PID" "$PING_PID" "$LOG_A_PID" "$LOG_B_PID" "$LOG_AMF_PID" "$LOG_SMF_PID" "$LOG_UPF_PID" 2>/dev/null || true
sleep 2

log_section "Post-HO UE state"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "----- routes -----"
ip route || true
echo "----- ping DN gateway -----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
echo "----- ping internet -----"
ping -I oaitun_ue1 -c 4 8.8.8.8 || true
' | tee "$RUN_DIR/12-ue-post-state.txt"

log_section "Post-HO CI source gNB-A"
ci_check_one "$GNB_A_POD" 19090 "post-source-gnb-a" "$RUN_DIR" | tee "$RUN_DIR/13-post-source-ci.txt"

log_section "Post-HO CI target gNB-B"
ci_check_one "$GNB_B_POD" 19092 "post-target-gnb-b" "$RUN_DIR" | tee "$RUN_DIR/14-post-target-ci.txt"

log_section "Classification grep"
grep -RInE 'ci trigger_n2_ho|triggered N2 HO|handover|N2|HO|RRCReconfiguration|RRCSetup|RRCSetupComplete|Msg3|WAIT_Msg3|RA failed|InitialUEMessage|Registration|Path|UE Context|DUPLICATED|connection refused|accepted|error|fail' \
"$RUN_DIR" 2>/dev/null | tee "$RUN_DIR/15-classification-grep.txt" || true

cat > "$RUN_DIR/RESULT-SUMMARY.txt" <<EOF2
Serial A -> B N2 handover validation

Result:
Needs review. Expected successful HO requires target gNB-B ownership after trigger.

Success criteria:
- Source gNB-A accepts trigger.
- Target gNB-B completes RA/Msg3.
- Target gNB-B owns ue_id 1 after trigger.
- UE user-plane remains alive.
- No dirty state: different number of UEs / No DU connected on target after HO means failure.

Evidence saved in:
$RUN_DIR

Fast checks:
- Trigger output: $RUN_DIR/11-ho-trigger-output.txt
- Target logs: $RUN_DIR/06-target-gnb-b.log
- Post target CI: $RUN_DIR/14-post-target-ci.txt
- UE state: $RUN_DIR/12-ue-post-state.txt
- Grep: $RUN_DIR/15-classification-grep.txt
EOF2

cat "$RUN_DIR/RESULT-SUMMARY.txt"
SH

cat > "$SCRIPT_DIR/ho_b_to_a.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

RUN_DIR="$TODAY_DIR/serial-b-to-a-$(date +%H%M%S)"
mkdir -p "$RUN_DIR"

cd "$BASE_DIR"
refresh_pods

echo "RUN_DIR=$RUN_DIR" | tee "$RUN_DIR/00-path.txt"
echo "UE=$UE_POD" | tee "$RUN_DIR/01-pods.txt"
echo "GNB_B_SOURCE=$GNB_B_POD" | tee -a "$RUN_DIR/01-pods.txt"
echo "GNB_A_TARGET=$GNB_A_POD" | tee -a "$RUN_DIR/01-pods.txt"

log_section "Pre-check source gNB-B"
ci_check_one "$GNB_B_POD" 19092 "source-gnb-b" "$RUN_DIR" | tee "$RUN_DIR/02-source-gnb-b-ci.txt"

log_section "Pre-check target gNB-A"
ci_check_one "$GNB_A_POD" 19090 "target-gnb-a" "$RUN_DIR" | tee "$RUN_DIR/03-target-gnb-a-ci.txt"

log_section "Start live captures"
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 10.45.0.1' > "$RUN_DIR/04-ue-continuous-ping.log" 2>&1 &
PING_PID=$!

kubectl -n oran-ran logs "$GNB_B_POD" --since=5s -f > "$RUN_DIR/05-source-gnb-b.log" 2>&1 &
LOG_B_PID=$!

kubectl -n oran-ran logs "$GNB_A_POD" --since=5s -f > "$RUN_DIR/06-target-gnb-a.log" 2>&1 &
LOG_A_PID=$!

kubectl -n oran-core logs deploy/open5gs-amf --since=5s -f > "$RUN_DIR/07-amf.log" 2>&1 &
LOG_AMF_PID=$!

kubectl -n oran-core logs deploy/open5gs-smf --since=5s -f > "$RUN_DIR/08-smf.log" 2>&1 &
LOG_SMF_PID=$!

kubectl -n oran-core logs deploy/open5gs-upf --since=5s -f > "$RUN_DIR/09-upf.log" 2>&1 &
LOG_UPF_PID=$!

kubectl -n oran-ran port-forward pod/"$GNB_B_POD" 19092:9090 > "$RUN_DIR/10-portforward-trigger.log" 2>&1 &
PF_PID=$!

sleep 5

log_section "Trigger B to A N2 HO"
timeout 5 bash -lc 'printf "ci trigger_n2_ho 0,1\r\n" | nc 127.0.0.1 19092' | tee "$RUN_DIR/11-ho-trigger-output.txt" || true

sleep 45

kill "$PF_PID" "$PING_PID" "$LOG_A_PID" "$LOG_B_PID" "$LOG_AMF_PID" "$LOG_SMF_PID" "$LOG_UPF_PID" 2>/dev/null || true
sleep 2

log_section "Post-HO UE state"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "----- routes -----"
ip route || true
echo "----- ping DN gateway -----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
echo "----- ping internet -----"
ping -I oaitun_ue1 -c 4 8.8.8.8 || true
' | tee "$RUN_DIR/12-ue-post-state.txt"

log_section "Post-HO CI source gNB-B"
ci_check_one "$GNB_B_POD" 19092 "post-source-gnb-b" "$RUN_DIR" | tee "$RUN_DIR/13-post-source-ci.txt"

log_section "Post-HO CI target gNB-A"
ci_check_one "$GNB_A_POD" 19090 "post-target-gnb-a" "$RUN_DIR" | tee "$RUN_DIR/14-post-target-ci.txt"

log_section "Classification grep"
grep -RInE 'ci trigger_n2_ho|triggered N2 HO|handover|N2|HO|RRCReconfiguration|RRCSetup|RRCSetupComplete|Msg3|WAIT_Msg3|RA failed|InitialUEMessage|Registration|Path|UE Context|DUPLICATED|connection refused|accepted|error|fail' \
"$RUN_DIR" 2>/dev/null | tee "$RUN_DIR/15-classification-grep.txt" || true

cat > "$RUN_DIR/RESULT-SUMMARY.txt" <<EOF2
Serial B -> A N2 handover validation

Result:
Needs review. Expected successful HO requires target gNB-A ownership after trigger.

Success criteria:
- Source gNB-B accepts trigger.
- Target gNB-A completes RA/Msg3.
- Target gNB-A owns ue_id 1 after trigger.
- UE user-plane remains alive.
- No dirty state: different number of UEs / No DU connected on target after HO means failure.

Evidence saved in:
$RUN_DIR

Fast checks:
- Trigger output: $RUN_DIR/11-ho-trigger-output.txt
- Target logs: $RUN_DIR/06-target-gnb-a.log
- Post target CI: $RUN_DIR/14-post-target-ci.txt
- UE state: $RUN_DIR/12-ue-post-state.txt
- Grep: $RUN_DIR/15-classification-grep.txt
EOF2

cat "$RUN_DIR/RESULT-SUMMARY.txt"
SH

chmod +x "$SCRIPT_DIR"/*.sh

cat > "$APP_DIR/app.py" <<'PY'
import json
import os
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path
from flask import Flask, jsonify, render_template, request

BASE_DIR = Path.home() / "oran-e2e-freeze"
APP_DIR = BASE_DIR / "web-dashboard"
ACTION_DIR = APP_DIR / "actions"
PROOF_DIR = Path.home() / "oran-proof"
JOB_ROOT = PROOF_DIR / "web-dashboard-runs"
JOB_DB = JOB_ROOT / "jobs.json"

LAB_IP = os.environ.get("ORAN_LAB_IP", "192.168.1.142")
GRAFANA_URL = f"http://{LAB_IP}:30300"
PROMETHEUS_URL = f"http://{LAB_IP}:30090"

app = Flask(__name__)

ACTIONS = {
    "snapshot": {
        "label": "Collect Evidence Snapshot",
        "script": "collect_snapshot.sh",
        "danger": False,
    },
    "ci": {
        "label": "Check CI UE Ownership",
        "script": "ci_ownership.sh",
        "danger": False,
    },
    "validate": {
        "label": "Run E2E Validation",
        "script": "validate_e2e.sh",
        "danger": False,
    },
    "ho_a_to_b": {
        "label": "Test N2 HO A to B",
        "script": "ho_a_to_b.sh",
        "danger": True,
    },
    "ho_b_to_a": {
        "label": "Test N2 HO B to A",
        "script": "ho_b_to_a.sh",
        "danger": True,
    },
    "recover_ran": {
        "label": "Recover RAN Baseline",
        "script": "recover_ran.sh",
        "danger": True,
    },
    "recover_full": {
        "label": "Full Lab Recovery",
        "script": "recover_full.sh",
        "danger": True,
    },
}

def now():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def load_jobs():
    JOB_ROOT.mkdir(parents=True, exist_ok=True)
    if JOB_DB.exists():
        try:
            return json.loads(JOB_DB.read_text())
        except Exception:
            return []
    return []

def save_jobs(jobs):
    JOB_ROOT.mkdir(parents=True, exist_ok=True)
    JOB_DB.write_text(json.dumps(jobs, indent=2))

def pid_running(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False

def refresh_job_states():
    jobs = load_jobs()
    changed = False
    for j in jobs:
        if j.get("status") == "running":
            pid = j.get("pid")
            if not pid_running(pid):
                log_path = Path(j["log"])
                text = log_path.read_text(errors="ignore") if log_path.exists() else ""
                if "validate_exit=0" in text or "SUCCESS" in text or "PASS" in text:
                    j["status"] = "finished"
                elif "FAIL" in text or "validate_exit=1" in text or "INCOMPLETE" in text:
                    j["status"] = "failed"
                else:
                    j["status"] = "finished"
                j["ended_at"] = now()
                changed = True
    if changed:
        save_jobs(jobs)
    return jobs

def run_cmd(cmd, timeout=10):
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            cwd=str(BASE_DIR),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired as e:
        return 124, (e.stdout or "") + "\nTIMEOUT"

def kubectl_json(cmd):
    code, out = run_cmd(cmd, timeout=12)
    if code != 0:
        return None, out
    try:
        return json.loads(out), None
    except Exception as e:
        return None, str(e)

def pod_ready(pod):
    statuses = pod.get("status", {}).get("containerStatuses", []) or []
    if not statuses:
        return False
    return all(c.get("ready") for c in statuses)

def restart_count(pod):
    statuses = pod.get("status", {}).get("containerStatuses", []) or []
    return sum(int(c.get("restartCount", 0)) for c in statuses)

def summarize_pods(namespace):
    data, err = kubectl_json(f"kubectl -n {namespace} get pods -o json")
    rows = []
    if not data:
        return rows, err
    for item in data.get("items", []):
        rows.append({
            "name": item["metadata"]["name"],
            "namespace": namespace,
            "phase": item.get("status", {}).get("phase", "Unknown"),
            "ready": pod_ready(item),
            "restarts": restart_count(item),
            "age": item.get("metadata", {}).get("creationTimestamp", ""),
            "ip": item.get("status", {}).get("podIP", ""),
        })
    return rows, None

def latest_files(pattern, limit=8):
    files = sorted(PROOF_DIR.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    return [{"path": str(p), "name": p.name, "mtime": datetime.fromtimestamp(p.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")} for p in files[:limit]]

def tail_file(path, lines=180):
    p = Path(path)
    if not p.exists():
        return ""
    text = p.read_text(errors="ignore").splitlines()
    return "\n".join(text[-lines:])

@app.route("/")
def index():
    return render_template(
        "index.html",
        grafana_url=GRAFANA_URL,
        prometheus_url=PROMETHEUS_URL,
        actions=ACTIONS,
    )

@app.route("/api/status")
def api_status():
    ran, ran_err = summarize_pods("oran-ran")
    core, core_err = summarize_pods("oran-core")
    mon, mon_err = summarize_pods("monitoring")

    core_names = ["open5gs-amf", "open5gs-smf", "open5gs-upf"]
    ran_names = ["oai-gnb", "oai-gnb-b", "oai-nr-ue"]

    core_ready = [
        p for p in core
        if any(p["name"].startswith(n) for n in core_names) and p["ready"]
    ]
    ran_ready = [
        p for p in ran
        if any(p["name"].startswith(n) for n in ran_names) and p["ready"]
    ]

    jobs = refresh_job_states()
    current = next((j for j in jobs if j.get("status") == "running"), None)
    latest = jobs[0] if jobs else None

    return jsonify({
        "time": now(),
        "links": {
            "grafana": GRAFANA_URL,
            "prometheus": PROMETHEUS_URL,
        },
        "summary": {
            "core_ready_count": len(core_ready),
            "ran_ready_count": len(ran_ready),
            "monitoring_ready_count": len([p for p in mon if p["ready"]]),
            "job_running": bool(current),
            "latest_job": latest,
        },
        "pods": {
            "ran": ran,
            "core": core,
            "monitoring": mon,
        },
        "errors": {
            "ran": ran_err,
            "core": core_err,
            "monitoring": mon_err,
        },
        "evidence": {
            "summaries": latest_files("today-*/**/*SUMMARY*.txt", 10),
            "results": latest_files("today-*/**/RESULT-SUMMARY.txt", 10),
        }
    })

@app.route("/api/jobs")
def api_jobs():
    return jsonify(refresh_job_states()[:20])

@app.route("/api/jobs/start", methods=["POST"])
def api_start_job():
    data = request.get_json(force=True) or {}
    action = data.get("action")

    if action not in ACTIONS:
        return jsonify({"ok": False, "error": "Unknown action"}), 400

    jobs = refresh_job_states()
    running = next((j for j in jobs if j.get("status") == "running"), None)
    if running:
        return jsonify({"ok": False, "error": "Another job is already running", "job": running}), 409

    action_meta = ACTIONS[action]
    job_id = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + action
    job_dir = JOB_ROOT / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    log_path = job_dir / "job.log"

    script_path = ACTION_DIR / action_meta["script"]

    log_fh = open(log_path, "w")
    log_fh.write(f"Job: {action_meta['label']}\n")
    log_fh.write(f"Started: {now()}\n")
    log_fh.write(f"Script: {script_path}\n")
    log_fh.write("=" * 80 + "\n")
    log_fh.flush()

    p = subprocess.Popen(
        ["bash", str(script_path)],
        cwd=str(BASE_DIR),
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        preexec_fn=os.setsid,
    )

    job = {
        "id": job_id,
        "action": action,
        "label": action_meta["label"],
        "status": "running",
        "pid": p.pid,
        "started_at": now(),
        "log": str(log_path),
    }

    jobs.insert(0, job)
    save_jobs(jobs)

    return jsonify({"ok": True, "job": job})

@app.route("/api/jobs/stop", methods=["POST"])
def api_stop_job():
    jobs = refresh_job_states()
    running = next((j for j in jobs if j.get("status") == "running"), None)
    if not running:
        return jsonify({"ok": False, "error": "No running job"}), 404

    try:
        os.killpg(os.getpgid(int(running["pid"])), signal.SIGTERM)
    except Exception:
        pass

    running["status"] = "stopped"
    running["ended_at"] = now()
    save_jobs(jobs)
    return jsonify({"ok": True, "job": running})

@app.route("/api/jobs/<job_id>/log")
def api_job_log(job_id):
    jobs = refresh_job_states()
    job = next((j for j in jobs if j["id"] == job_id), None)
    if not job:
        return jsonify({"ok": False, "error": "Job not found"}), 404
    return jsonify({"ok": True, "job": job, "log": tail_file(job["log"], 260)})

@app.route("/api/jobs/current")
def api_current_job():
    jobs = refresh_job_states()
    job = next((j for j in jobs if j.get("status") == "running"), None)
    if not job and jobs:
        job = jobs[0]
    if not job:
        return jsonify({"ok": True, "job": None, "log": ""})
    return jsonify({"ok": True, "job": job, "log": tail_file(job["log"], 260)})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("ORAN_DASHBOARD_PORT", "18080")))
PY

cat > "$APP_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>O-RAN Lab Control Platform</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div class="layout">
    <aside class="sidebar">
      <div class="brand">
        <div class="logo">5G</div>
        <div>
          <h1>O-RAN Lab</h1>
          <p>Control Platform</p>
        </div>
      </div>

      <nav>
        <a href="#overview">Overview</a>
        <a href="#actions">Test Console</a>
        <a href="#pods">Pods</a>
        <a href="#logs">Job Logs</a>
        <a href="{{ grafana_url }}" target="_blank">Open Grafana</a>
        <a href="{{ prometheus_url }}" target="_blank">Open Prometheus</a>
      </nav>

      <div class="side-note">
        <strong>Rule:</strong>
        HO success is only valid when target gNB owns UE after trigger.
      </div>
    </aside>

    <main>
      <section class="hero" id="overview">
        <div>
          <p class="eyebrow">Cloud-native Open5GS + OAI RAN</p>
          <h2>O-RAN 5G End-to-End Lab Platform</h2>
          <p class="muted">Run validations, collect proof, inspect pod health, and preserve handover evidence from one web interface.</p>
        </div>
        <div class="hero-actions">
          <button onclick="refreshStatus()" class="btn">Reload Status</button>
          <a class="btn ghost" href="{{ grafana_url }}" target="_blank">Grafana</a>
          <a class="btn ghost" href="{{ prometheus_url }}" target="_blank">Prometheus</a>
        </div>
      </section>

      <section class="cards">
        <div class="card metric">
          <span>5G Core</span>
          <strong id="coreReady">-</strong>
          <p>AMF / SMF / UPF ready count</p>
        </div>
        <div class="card metric">
          <span>RAN + UE</span>
          <strong id="ranReady">-</strong>
          <p>gNB-A / gNB-B / NR-UE ready count</p>
        </div>
        <div class="card metric">
          <span>Monitoring</span>
          <strong id="monReady">-</strong>
          <p>Grafana / Prometheus stack pods</p>
        </div>
        <div class="card metric">
          <span>Job State</span>
          <strong id="jobState">-</strong>
          <p id="jobName">No active job</p>
        </div>
      </section>

      <section class="panel" id="actions">
        <div class="panel-head">
          <div>
            <h3>Test and Operations Console</h3>
            <p>Buttons run real lab commands and save evidence under ~/oran-proof.</p>
          </div>
          <button class="btn small" onclick="refreshStatus()">Reload</button>
        </div>

        <div class="action-grid">
          <button class="action safe" onclick="startJob('snapshot')">
            <b>Collect Snapshot</b>
            <span>Pods, services, UE tunnel, AMF/SMF/UPF logs</span>
          </button>

          <button class="action safe" onclick="startJob('ci')">
            <b>Check UE Ownership</b>
            <span>CI RNTI and DU mapping on gNB-A/gNB-B</span>
          </button>

          <button class="action safe" onclick="startJob('validate')">
            <b>Run E2E Validation</b>
            <span>Runs scripts/validate-e2e.sh and stores result</span>
          </button>

          <button class="action danger" onclick="startJob('ho_a_to_b', true)">
            <b>Test HO A -> B</b>
            <span>Source gNB-A PCI 0 to target gNB-B PCI 1</span>
          </button>

          <button class="action danger" onclick="startJob('ho_b_to_a', true)">
            <b>Test HO B -> A</b>
            <span>Source gNB-B PCI 1 to target gNB-A PCI 0</span>
          </button>

          <button class="action warn" onclick="startJob('recover_ran', true)">
            <b>Recover RAN</b>
            <span>Runs deploy-ran.sh then validates baseline</span>
          </button>

          <button class="action warn" onclick="startJob('recover_full', true)">
            <b>Full Recovery</b>
            <span>Network + core + RAN recovery then validation</span>
          </button>

          <button class="action stop" onclick="stopJob()">
            <b>Stop Running Job</b>
            <span>Stops the active dashboard-launched job</span>
          </button>
        </div>
      </section>

      <section class="grid2" id="pods">
        <div class="panel">
          <h3>RAN Pod Readiness</h3>
          <div class="table-wrap">
            <table>
              <thead><tr><th>Pod</th><th>Ready</th><th>Restarts</th><th>IP</th></tr></thead>
              <tbody id="ranPods"></tbody>
            </table>
          </div>
        </div>

        <div class="panel">
          <h3>Core Pod Readiness</h3>
          <div class="table-wrap">
            <table>
              <thead><tr><th>Pod</th><th>Ready</th><th>Restarts</th><th>IP</th></tr></thead>
              <tbody id="corePods"></tbody>
            </table>
          </div>
        </div>
      </section>

      <section class="grid2">
        <div class="panel">
          <h3>Latest Evidence Files</h3>
          <div id="evidenceList" class="evidence"></div>
        </div>

        <div class="panel">
          <h3>Job History</h3>
          <div id="jobHistory" class="history"></div>
        </div>
      </section>

      <section class="panel" id="logs">
        <div class="panel-head">
          <div>
            <h3>Live Job Log</h3>
            <p>Updates automatically while a test is running.</p>
          </div>
          <button class="btn small" onclick="refreshCurrentJob()">Reload Log</button>
        </div>
        <pre id="logBox">No job log yet.</pre>
      </section>
    </main>
  </div>

  <script src="/static/app.js"></script>
</body>
</html>
HTML

cat > "$APP_DIR/static/style.css" <<'CSS'
:root {
  --bg: #08111f;
  --panel: #111c2f;
  --panel2: #16243a;
  --text: #e6eefc;
  --muted: #8da2c0;
  --line: #263957;
  --green: #5ff2a0;
  --red: #ff6b6b;
  --yellow: #ffd166;
  --blue: #6ea8fe;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background:
    radial-gradient(circle at top left, rgba(31, 81, 255, .22), transparent 35%),
    linear-gradient(135deg, #050a13 0%, #0c1728 100%);
  color: var(--text);
  font-family: Inter, Arial, sans-serif;
}

.layout {
  display: grid;
  grid-template-columns: 280px 1fr;
  min-height: 100vh;
}

.sidebar {
  border-right: 1px solid var(--line);
  background: rgba(9, 16, 29, .88);
  backdrop-filter: blur(10px);
  padding: 24px;
  position: sticky;
  top: 0;
  height: 100vh;
}

.brand {
  display: flex;
  gap: 14px;
  align-items: center;
  margin-bottom: 34px;
}

.logo {
  width: 54px;
  height: 54px;
  border-radius: 18px;
  display: grid;
  place-items: center;
  font-weight: 900;
  background: linear-gradient(135deg, #36d1dc, #5b86e5);
  color: white;
}

.brand h1 {
  margin: 0;
  font-size: 22px;
}

.brand p {
  margin: 4px 0 0;
  color: var(--muted);
}

nav {
  display: grid;
  gap: 10px;
}

nav a {
  color: var(--text);
  text-decoration: none;
  padding: 12px 14px;
  border-radius: 12px;
  background: rgba(255,255,255,.03);
  border: 1px solid transparent;
}

nav a:hover {
  border-color: var(--line);
  background: rgba(255,255,255,.07);
}

.side-note {
  margin-top: 28px;
  padding: 16px;
  border-radius: 14px;
  color: var(--muted);
  background: rgba(255, 209, 102, .08);
  border: 1px solid rgba(255, 209, 102, .2);
  line-height: 1.5;
}

main {
  padding: 28px;
  max-width: 1500px;
  width: 100%;
}

.hero {
  display: flex;
  justify-content: space-between;
  gap: 24px;
  padding: 30px;
  border: 1px solid var(--line);
  border-radius: 24px;
  background: linear-gradient(135deg, rgba(22,36,58,.95), rgba(17,28,47,.8));
  box-shadow: 0 24px 60px rgba(0,0,0,.28);
}

.eyebrow {
  margin: 0 0 10px;
  color: var(--green);
  font-weight: 700;
  letter-spacing: .04em;
  text-transform: uppercase;
  font-size: 13px;
}

h2 {
  font-size: 36px;
  margin: 0;
}

.muted {
  color: var(--muted);
}

.hero-actions {
  display: flex;
  align-items: start;
  gap: 10px;
  flex-wrap: wrap;
}

.btn {
  border: none;
  color: #06111f;
  background: var(--green);
  padding: 12px 16px;
  border-radius: 12px;
  font-weight: 800;
  cursor: pointer;
  text-decoration: none;
  display: inline-block;
}

.btn.ghost {
  color: var(--text);
  background: transparent;
  border: 1px solid var(--line);
}

.btn.small {
  padding: 9px 12px;
}

.cards {
  margin-top: 22px;
  display: grid;
  grid-template-columns: repeat(4, minmax(180px, 1fr));
  gap: 16px;
}

.card, .panel {
  background: rgba(17, 28, 47, .88);
  border: 1px solid var(--line);
  border-radius: 20px;
  box-shadow: 0 18px 45px rgba(0,0,0,.22);
}

.metric {
  padding: 22px;
}

.metric span {
  color: var(--muted);
  font-size: 14px;
}

.metric strong {
  display: block;
  font-size: 46px;
  margin: 12px 0 8px;
}

.metric p {
  margin: 0;
  color: var(--muted);
}

.panel {
  margin-top: 18px;
  padding: 22px;
}

.panel-head {
  display: flex;
  justify-content: space-between;
  gap: 16px;
  align-items: start;
}

.panel h3 {
  margin: 0 0 6px;
}

.panel p {
  margin: 0;
  color: var(--muted);
}

.action-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
  gap: 14px;
  margin-top: 18px;
}

.action {
  text-align: left;
  padding: 18px;
  border-radius: 18px;
  border: 1px solid var(--line);
  background: var(--panel2);
  color: var(--text);
  cursor: pointer;
  min-height: 116px;
}

.action:hover {
  transform: translateY(-1px);
  border-color: var(--blue);
}

.action b {
  display: block;
  font-size: 17px;
  margin-bottom: 8px;
}

.action span {
  color: var(--muted);
  line-height: 1.4;
}

.action.safe { border-left: 5px solid var(--green); }
.action.danger { border-left: 5px solid var(--red); }
.action.warn { border-left: 5px solid var(--yellow); }
.action.stop { border-left: 5px solid #b084ff; }

.grid2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 18px;
}

.table-wrap {
  overflow: auto;
  margin-top: 12px;
}

table {
  width: 100%;
  border-collapse: collapse;
  min-width: 520px;
}

th, td {
  padding: 11px;
  border-bottom: 1px solid var(--line);
  text-align: left;
  font-size: 14px;
}

th {
  color: var(--muted);
  font-weight: 700;
}

.badge {
  display: inline-block;
  padding: 4px 9px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 800;
}

.badge.ok { background: rgba(95,242,160,.16); color: var(--green); }
.badge.bad { background: rgba(255,107,107,.16); color: var(--red); }
.badge.run { background: rgba(110,168,254,.16); color: var(--blue); }

.evidence, .history {
  display: grid;
  gap: 10px;
  margin-top: 14px;
  max-height: 260px;
  overflow: auto;
}

.item {
  padding: 12px;
  border: 1px solid var(--line);
  border-radius: 12px;
  background: rgba(255,255,255,.03);
}

.item strong {
  display: block;
  margin-bottom: 4px;
}

.item code {
  color: var(--muted);
  font-size: 12px;
}

pre {
  min-height: 360px;
  max-height: 620px;
  overflow: auto;
  padding: 18px;
  border-radius: 16px;
  border: 1px solid var(--line);
  background: #050a13;
  color: #c8e6ff;
  line-height: 1.45;
  white-space: pre-wrap;
}

@media (max-width: 1000px) {
  .layout { grid-template-columns: 1fr; }
  .sidebar { position: relative; height: auto; }
  .cards { grid-template-columns: repeat(2, 1fr); }
  .grid2 { grid-template-columns: 1fr; }
  .hero { flex-direction: column; }
}
CSS

cat > "$APP_DIR/static/app.js" <<'JS'
let currentJobId = null;

function badge(ok) {
  return ok ? '<span class="badge ok">READY</span>' : '<span class="badge bad">NOT READY</span>';
}

function statusBadge(status) {
  if (status === "running") return '<span class="badge run">RUNNING</span>';
  if (status === "failed") return '<span class="badge bad">FAILED</span>';
  if (status === "stopped") return '<span class="badge bad">STOPPED</span>';
  return '<span class="badge ok">FINISHED</span>';
}

async function refreshStatus() {
  const res = await fetch("/api/status");
  const data = await res.json();

  document.getElementById("coreReady").textContent = data.summary.core_ready_count + "/3";
  document.getElementById("ranReady").textContent = data.summary.ran_ready_count + "/3";
  document.getElementById("monReady").textContent = data.summary.monitoring_ready_count;

  if (data.summary.job_running) {
    document.getElementById("jobState").textContent = "RUNNING";
    document.getElementById("jobName").textContent = data.summary.latest_job.label;
  } else if (data.summary.latest_job) {
    document.getElementById("jobState").textContent = data.summary.latest_job.status.toUpperCase();
    document.getElementById("jobName").textContent = data.summary.latest_job.label;
  } else {
    document.getElementById("jobState").textContent = "IDLE";
    document.getElementById("jobName").textContent = "No jobs yet";
  }

  fillPods("ranPods", data.pods.ran);
  fillPods("corePods", data.pods.core);
  fillEvidence(data.evidence.summaries);
  refreshJobs();
  refreshCurrentJob();
}

function fillPods(id, pods) {
  const el = document.getElementById(id);
  el.innerHTML = "";
  pods.forEach(p => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${p.name}</td>
      <td>${badge(p.ready)}</td>
      <td>${p.restarts}</td>
      <td>${p.ip || "-"}</td>
    `;
    el.appendChild(tr);
  });
}

function fillEvidence(items) {
  const el = document.getElementById("evidenceList");
  el.innerHTML = "";
  if (!items || items.length === 0) {
    el.innerHTML = '<div class="item">No evidence summaries found yet.</div>';
    return;
  }
  items.slice(0, 8).forEach(x => {
    const div = document.createElement("div");
    div.className = "item";
    div.innerHTML = `<strong>${x.name}</strong><code>${x.path}</code><br><small>${x.mtime}</small>`;
    el.appendChild(div);
  });
}

async function refreshJobs() {
  const res = await fetch("/api/jobs");
  const jobs = await res.json();
  const el = document.getElementById("jobHistory");
  el.innerHTML = "";
  if (!jobs || jobs.length === 0) {
    el.innerHTML = '<div class="item">No dashboard jobs yet.</div>';
    return;
  }
  jobs.slice(0, 10).forEach(j => {
    const div = document.createElement("div");
    div.className = "item";
    div.onclick = () => loadJobLog(j.id);
    div.innerHTML = `<strong>${j.label} ${statusBadge(j.status)}</strong><code>${j.id}</code><br><small>${j.started_at}</small>`;
    el.appendChild(div);
  });
}

async function startJob(action, danger=false) {
  if (danger) {
    const ok = confirm(
      "This action changes the lab state or may make the RAN dirty.\n\n" +
      "Evidence will be saved under ~/oran-proof.\n\n" +
      "Continue?"
    );
    if (!ok) return;
  }

  const res = await fetch("/api/jobs/start", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({action})
  });

  const data = await res.json();

  if (!data.ok) {
    alert(data.error || "Could not start job");
    return;
  }

  currentJobId = data.job.id;
  document.getElementById("logBox").textContent = "Started job: " + data.job.label + "\nWaiting for log...";
  refreshStatus();
}

async function stopJob() {
  const ok = confirm("Stop the running dashboard job?");
  if (!ok) return;

  const res = await fetch("/api/jobs/stop", {method: "POST"});
  const data = await res.json();

  if (!data.ok) {
    alert(data.error || "No running job");
  }

  refreshStatus();
}

async function refreshCurrentJob() {
  const res = await fetch("/api/jobs/current");
  const data = await res.json();
  if (!data.job) {
    document.getElementById("logBox").textContent = "No job log yet.";
    return;
  }
  currentJobId = data.job.id;
  document.getElementById("logBox").textContent = data.log || "No log output yet.";
}

async function loadJobLog(jobId) {
  const res = await fetch(`/api/jobs/${jobId}/log`);
  const data = await res.json();
  if (data.ok) {
    currentJobId = jobId;
    document.getElementById("logBox").textContent = data.log || "No log output.";
  }
}

refreshStatus();
setInterval(refreshStatus, 10000);
setInterval(refreshCurrentJob, 3000);
JS

cat > "$RUN_SCRIPT" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
APP_DIR="$BASE_DIR/web-dashboard"

cd "$APP_DIR"

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

source .venv/bin/activate
pip install -q -r requirements.txt

export ORAN_LAB_IP="${ORAN_LAB_IP:-192.168.1.142}"
export ORAN_DASHBOARD_PORT="${ORAN_DASHBOARD_PORT:-18080}"

python app.py
SH

chmod +x "$RUN_SCRIPT"

echo "O-RAN Operations Platform installed."
echo "Start it with:"
echo "$RUN_SCRIPT"
echo
echo "Open:"
echo "http://192.168.1.142:18080"
