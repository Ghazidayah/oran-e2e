#!/usr/bin/env bash
set -euo pipefail

# O-RAN 5G Lab Dashboard installer
# Run from: ~/oran-e2e-freeze

PROJECT_ROOT="${PROJECT_ROOT:-$HOME/oran-e2e-freeze}"
DASH_DIR="$PROJECT_ROOT/web-dashboard"
RUN_ROOT="${RUN_ROOT:-$HOME/oran-proof}"
LAB_IP="${LAB_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
PORT="${PORT:-18080}"

mkdir -p "$DASH_DIR" "$DASH_DIR/templates" "$DASH_DIR/static" "$RUN_ROOT"

cat > "$DASH_DIR/requirements.txt" <<'EOF'
Flask==3.0.3
EOF

cat > "$DASH_DIR/app.py" <<'PY'
import os
import re
import json
import time
import signal
import socket
import subprocess
from pathlib import Path
from datetime import datetime
from flask import Flask, jsonify, render_template, request

APP_ROOT = Path(__file__).resolve().parent
PROJECT_ROOT = Path(os.environ.get("PROJECT_ROOT", str(APP_ROOT.parent))).expanduser()
RUN_ROOT = Path(os.environ.get("RUN_ROOT", str(Path.home() / "oran-proof"))).expanduser()
PORT = int(os.environ.get("PORT", "18080"))
HOST = os.environ.get("HOST", "0.0.0.0")

app = Flask(__name__)
RUN_ROOT.mkdir(parents=True, exist_ok=True)


def now_tag():
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def today_dir():
    d = RUN_ROOT / f"dashboard-{datetime.now().strftime('%Y%m%d')}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def run_cmd(cmd, timeout=60, cwd=None):
    cwd = cwd or PROJECT_ROOT
    started = datetime.now().isoformat(timespec="seconds")
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            cwd=str(cwd),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            executable="/bin/bash",
        )
        return {
            "ok": p.returncode == 0,
            "exit_code": p.returncode,
            "started": started,
            "finished": datetime.now().isoformat(timespec="seconds"),
            "output": p.stdout[-20000:],
        }
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or "") if isinstance(e.stdout, str) else ""
        return {
            "ok": False,
            "exit_code": 124,
            "started": started,
            "finished": datetime.now().isoformat(timespec="seconds"),
            "output": (out + f"\n[TIMEOUT after {timeout}s]")[-20000:],
        }
    except Exception as e:
        return {
            "ok": False,
            "exit_code": 1,
            "started": started,
            "finished": datetime.now().isoformat(timespec="seconds"),
            "output": f"ERROR: {e}",
        }


def save_result(name, result, extra=None):
    out_dir = today_dir() / f"{name}-{now_tag()}"
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "result.json").write_text(json.dumps({"result": result, "extra": extra or {}}, indent=2), encoding="utf-8")
    (out_dir / "output.log").write_text(result.get("output", ""), encoding="utf-8")
    return str(out_dir)


def get_lab_ip():
    env_ip = os.environ.get("LAB_IP")
    if env_ip:
        return env_ip
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def parse_validate(output):
    tunnel_ip = None
    m = re.search(r"inet\s+(10\.45\.0\.\d+/\d+)", output)
    if m:
        tunnel_ip = m.group(1)
    dn_pass = bool(re.search(r"10\.45\.0\.1[\s\S]*?0% packet loss", output))
    internet_pass = bool(re.search(r"8\.8\.8\.8[\s\S]*?0% packet loss", output))
    registration = "Registration complete" in output
    duplicated = "DUPLICATED_PDU_SESSION_ID" in output
    return {
        "ue_ip": tunnel_ip,
        "dn_gateway_ping": dn_pass,
        "internet_ping": internet_pass,
        "registration_complete": registration,
        "duplicated_pdu_session_id": duplicated,
    }


def get_pods(namespace):
    result = run_cmd(f"kubectl -n {namespace} get pods -o wide", timeout=20)
    return result


def get_current_pods():
    cmd = r'''
UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
GNB_A_POD=$(kubectl -n oran-ran get pod -o name 2>/dev/null | grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
GNB_B_POD=$(kubectl -n oran-ran get pod -o name 2>/dev/null | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
printf 'UE_POD=%s\nGNB_A_POD=%s\nGNB_B_POD=%s\n' "$UE_POD" "$GNB_A_POD" "$GNB_B_POD"
'''
    return run_cmd(cmd, timeout=20)


def ci_query(pod, port, command):
    cmd = f'''
set -e
kubectl -n oran-ran port-forward pod/{pod} {port}:9090 >/tmp/oran-dashboard-pf-{port}.log 2>&1 &
PF=$!
sleep 3
set +e
timeout 4 bash -lc 'printf "{command}\\r\\n" | nc 127.0.0.1 {port}'
RC=$?
kill "$PF" 2>/dev/null || true
wait "$PF" 2>/dev/null || true
exit $RC
'''
    return run_cmd(cmd, timeout=15)


def ci_ownership():
    pods_text = get_current_pods()["output"]
    pods = {}
    for line in pods_text.splitlines():
        if "=" in line:
            k, v = line.strip().split("=", 1)
            pods[k] = v
    out = {"pods": pods, "gnb_a": {}, "gnb_b": {}}
    if pods.get("GNB_A_POD"):
        out["gnb_a"]["rnti"] = ci_query(pods["GNB_A_POD"], 19090, "ci get_single_rnti")
        out["gnb_a"]["du"] = ci_query(pods["GNB_A_POD"], 19090, "ci fetch_du_by_ue_id 1")
    if pods.get("GNB_B_POD"):
        out["gnb_b"]["rnti"] = ci_query(pods["GNB_B_POD"], 19092, "ci get_single_rnti")
        out["gnb_b"]["du"] = ci_query(pods["GNB_B_POD"], 19092, "ci fetch_du_by_ue_id 1")
    return out


def summarize_ownership(ci):
    a_text = (ci.get("gnb_a", {}).get("rnti", {}).get("output", "") + "\n" + ci.get("gnb_a", {}).get("du", {}).get("output", ""))
    b_text = (ci.get("gnb_b", {}).get("rnti", {}).get("output", "") + "\n" + ci.get("gnb_b", {}).get("du", {}).get("output", ""))
    def owns(text):
        return "single UE RNTI" in text and "connected to ue_id 1" in text
    if owns(a_text) and not owns(b_text):
        return "gNB-A owns UE"
    if owns(b_text) and not owns(a_text):
        return "gNB-B owns UE"
    if owns(a_text) and owns(b_text):
        return "Ambiguous: both gNBs report UE"
    return "No clean CI owner"


@app.route("/")
def index():
    return render_template("index.html", lab_ip=get_lab_ip(), port=PORT)


@app.route("/api/status")
def api_status():
    core = get_pods("oran-core")
    ran = get_pods("oran-ran")
    pods = get_current_pods()
    ci = ci_ownership()
    status = {
        "time": datetime.now().isoformat(timespec="seconds"),
        "lab_ip": get_lab_ip(),
        "core_ok": core["ok"] and "Running" in core["output"],
        "ran_ok": ran["ok"] and "Running" in ran["output"],
        "core_pods": core,
        "ran_pods": ran,
        "current_pods": pods,
        "ci": ci,
        "ownership": summarize_ownership(ci),
    }
    return jsonify(status)


@app.route("/api/validate", methods=["POST"])
def api_validate():
    result = run_cmd("timeout 300 ./scripts/validate-e2e.sh", timeout=330)
    parsed = parse_validate(result["output"])
    evidence_dir = save_result("validate-e2e", result, parsed)
    return jsonify({"result": result, "parsed": parsed, "evidence_dir": evidence_dir})


@app.route("/api/recovery", methods=["POST"])
def api_recovery():
    cmd = "./scripts/deploy-ran.sh && sleep 120 && timeout 300 ./scripts/validate-e2e.sh"
    result = run_cmd(cmd, timeout=700)
    parsed = parse_validate(result["output"])
    evidence_dir = save_result("recovery", result, parsed)
    return jsonify({"result": result, "parsed": parsed, "evidence_dir": evidence_dir})


@app.route("/api/logs")
def api_logs():
    target = request.args.get("target", "amf")
    since = request.args.get("since", "10m")
    allowed = {
        "amf": "kubectl -n oran-core logs deploy/open5gs-amf --since={since}",
        "smf": "kubectl -n oran-core logs deploy/open5gs-smf --since={since}",
        "upf": "kubectl -n oran-core logs deploy/open5gs-upf --since={since}",
        "gnb-a": r"GNB_A=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2); kubectl -n oran-ran logs $GNB_A --since={since}",
        "gnb-b": r"GNB_B=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2); kubectl -n oran-ran logs $GNB_B --since={since}",
        "ue": r"UE=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}'); kubectl -n oran-ran logs $UE --since={since}",
    }
    if target not in allowed:
        return jsonify({"ok": False, "output": "Unknown log target"}), 400
    safe_since = re.sub(r"[^0-9smhd]", "", since) or "10m"
    result = run_cmd(allowed[target].format(since=safe_since), timeout=30)
    return jsonify(result)


@app.route("/api/handover", methods=["POST"])
def api_handover():
    body = request.get_json(force=True)
    direction = body.get("direction")
    if direction not in {"a2b", "b2a"}:
        return jsonify({"ok": False, "error": "direction must be a2b or b2a"}), 400

    pods_text = get_current_pods()["output"]
    pods = {}
    for line in pods_text.splitlines():
        if "=" in line:
            k, v = line.strip().split("=", 1)
            pods[k] = v

    if direction == "a2b":
        source = pods.get("GNB_A_POD")
        target = pods.get("GNB_B_POD")
        port = 19090
        cmd_text = "ci trigger_n2_ho 1,1"
        label = "serial-a-to-b"
    else:
        source = pods.get("GNB_B_POD")
        target = pods.get("GNB_A_POD")
        port = 19092
        cmd_text = "ci trigger_n2_ho 0,1"
        label = "serial-b-to-a"

    if not source or not target:
        return jsonify({"ok": False, "error": "Could not resolve gNB pods", "pods": pods}), 500

    evidence = today_dir() / f"{label}-{now_tag()}"
    evidence.mkdir(parents=True, exist_ok=True)

    script = f'''
set +e
UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{{.items[0].metadata.name}}')
echo "SOURCE={source}" | tee "{evidence}/00-pods.txt"
echo "TARGET={target}" | tee -a "{evidence}/00-pods.txt"
echo "UE=$UE_POD" | tee -a "{evidence}/00-pods.txt"

kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 10.45.0.1' > "{evidence}/01-ue-continuous-ping.log" 2>&1 &
PING_PID=$!
kubectl -n oran-ran logs "{source}" --since=5s -f > "{evidence}/02-source.log" 2>&1 &
SRC_LOG_PID=$!
kubectl -n oran-ran logs "{target}" --since=5s -f > "{evidence}/03-target.log" 2>&1 &
TGT_LOG_PID=$!
kubectl -n oran-core logs deploy/open5gs-amf --since=5s -f > "{evidence}/04-amf.log" 2>&1 &
AMF_LOG_PID=$!

kubectl -n oran-ran port-forward pod/{source} {port}:9090 > "{evidence}/05-portforward.log" 2>&1 &
PF=$!
sleep 5
printf "{cmd_text}\\r\\n" | nc 127.0.0.1 {port} | tee "{evidence}/06-trigger-output.txt"
sleep 45
kill "$PF" "$PING_PID" "$SRC_LOG_PID" "$TGT_LOG_PID" "$AMF_LOG_PID" 2>/dev/null || true

kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip addr show oaitun_ue1 || true; echo "----- PING DN GW -----"; ping -I oaitun_ue1 -c 5 10.45.0.1 || true; echo "----- PING INTERNET -----"; ping -I oaitun_ue1 -c 4 8.8.8.8 || true' > "{evidence}/07-ue-post-state.txt" 2>&1

grep -RInE 'trigger_n2_ho|triggered N2 HO|handover|N2|HO|Msg3|WAIT_Msg3|RA failed|Registration|DUPLICATED|error|fail' "{evidence}" > "{evidence}/08-classification-grep.txt" 2>/dev/null || true
'''
    result = run_cmd(script, timeout=120)
    ci = ci_ownership()
    classification_text = ""
    grep_file = evidence / "08-classification-grep.txt"
    if grep_file.exists():
        classification_text = grep_file.read_text(encoding="utf-8", errors="ignore")[-12000:]

    failed_ra = "RA failed at state WAIT_Msg3" in classification_text
    trigger_seen = "triggered N2 HO" in classification_text or "trigger_n2_ho" in classification_text
    owner = summarize_ownership(ci)
    parsed = {
        "direction": direction,
        "trigger_seen": trigger_seen,
        "target_ra_failed_wait_msg3": failed_ra,
        "ci_ownership_after": owner,
        "handover_success": False if failed_ra else None,
        "note": "If target RA fails or ownership remains on source, do not classify as successful N2 HO.",
    }
    (evidence / "result.json").write_text(json.dumps({"result": result, "parsed": parsed, "ci": ci}, indent=2), encoding="utf-8")
    return jsonify({"result": result, "parsed": parsed, "ci": ci, "evidence_dir": str(evidence), "classification": classification_text})


@app.route("/api/evidence")
def api_evidence():
    base = today_dir()
    items = []
    for p in sorted(base.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True)[:30]:
        if p.is_dir():
            summary = ""
            for name in ["RESULT-SUMMARY.txt", "RECOVERY2-STATUS.txt", "RECOVERY-STATUS.txt", "output.log"]:
                f = p / name
                if f.exists():
                    summary = f.read_text(encoding="utf-8", errors="ignore")[:2000]
                    break
            items.append({"name": p.name, "path": str(p), "summary": summary})
    return jsonify({"base": str(base), "items": items})


if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
PY

cat > "$DASH_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>O-RAN 5G Lab Dashboard</title>
  <link rel="stylesheet" href="/static/style.css" />
</head>
<body>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="logo">5G</div>
        <div>
          <h1>O-RAN Lab</h1>
          <p>Live E2E validation dashboard</p>
        </div>
      </div>
      <nav>
        <a href="#overview">Overview</a>
        <a href="#actions">Actions</a>
        <a href="#handover">Handover</a>
        <a href="#logs">Logs</a>
        <a href="#evidence">Evidence</a>
      </nav>
      <div class="side-note">
        <span>Access</span>
        <strong>http://{{ lab_ip }}:{{ port }}</strong>
      </div>
    </aside>

    <main>
      <section class="hero" id="overview">
        <div>
          <p class="eyebrow">O-RAN 5G End-to-End Lab</p>
          <h2>Infrastructure, UE attach, user plane, handover testing, and recovery in one interface.</h2>
          <p class="muted">This page runs real commands on the lab host and saves evidence under the dashboard proof folder.</p>
        </div>
        <button class="primary" onclick="refreshStatus()">Refresh live status</button>
      </section>

      <section class="cards">
        <div class="card"><span class="label">Core</span><strong id="coreStatus">Loading</strong><p>Open5GS namespace status</p></div>
        <div class="card"><span class="label">RAN</span><strong id="ranStatus">Loading</strong><p>gNB-A, gNB-B, UE pods</p></div>
        <div class="card"><span class="label">UE owner</span><strong id="ownerStatus">Loading</strong><p>CI ownership check</p></div>
        <div class="card"><span class="label">Last update</span><strong id="lastUpdate">-</strong><p>Dashboard status timestamp</p></div>
      </section>

      <section class="panel" id="actions">
        <div class="panel-head">
          <div><h3>E2E validation and recovery</h3><p>Run baseline checks or restore the lab after failed handover tests.</p></div>
        </div>
        <div class="action-grid">
          <button onclick="runValidate()">Run E2E validation</button>
          <button class="warning" onclick="runRecovery()">Run clean recovery</button>
        </div>
        <div id="validationSummary" class="summary"></div>
        <pre id="validationOutput" class="terminal">No validation run yet.</pre>
      </section>

      <section class="panel" id="handover">
        <div class="panel-head">
          <div><h3>Serial N2 handover validation</h3><p>These actions can disturb the lab. Use only when you want to capture handover evidence.</p></div>
        </div>
        <div class="action-grid">
          <button class="danger" onclick="runHandover('a2b')">Test A -> B handover</button>
          <button class="danger" onclick="runHandover('b2a')">Test B -> A handover</button>
        </div>
        <div id="handoverSummary" class="summary"></div>
        <pre id="handoverOutput" class="terminal">No handover run yet.</pre>
      </section>

      <section class="panel" id="logs">
        <div class="panel-head">
          <div><h3>Live logs</h3><p>Quick view for AMF, SMF, UPF, gNBs and UE.</p></div>
          <select id="logTarget" onchange="loadLogs()">
            <option value="amf">AMF</option>
            <option value="smf">SMF</option>
            <option value="upf">UPF</option>
            <option value="gnb-a">gNB-A</option>
            <option value="gnb-b">gNB-B</option>
            <option value="ue">UE</option>
          </select>
        </div>
        <button onclick="loadLogs()">Load logs</button>
        <pre id="logOutput" class="terminal">Choose a log target.</pre>
      </section>

      <section class="panel" id="evidence">
        <div class="panel-head">
          <div><h3>Evidence folders</h3><p>Recent dashboard-generated proof artifacts.</p></div>
          <button onclick="loadEvidence()">Refresh evidence</button>
        </div>
        <div id="evidenceList" class="evidence-list"></div>
      </section>
    </main>
  </div>
  <script src="/static/app.js"></script>
</body>
</html>
HTML

cat > "$DASH_DIR/static/style.css" <<'CSS'
:root {
  --bg: #08111f;
  --panel: rgba(15, 23, 42, 0.92);
  --card: rgba(30, 41, 59, 0.85);
  --border: rgba(148, 163, 184, 0.22);
  --text: #e5e7eb;
  --muted: #94a3b8;
  --good: #22c55e;
  --bad: #ef4444;
  --warn: #f59e0b;
  --accent: #38bdf8;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: radial-gradient(circle at top left, #12355c, transparent 35%), var(--bg);
  color: var(--text);
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
.shell { display: grid; grid-template-columns: 280px 1fr; min-height: 100vh; }
.sidebar { padding: 28px; border-right: 1px solid var(--border); background: rgba(2, 6, 23, 0.75); position: sticky; top: 0; height: 100vh; }
.brand { display: flex; gap: 14px; align-items: center; margin-bottom: 34px; }
.logo { width: 54px; height: 54px; border-radius: 18px; display: grid; place-items: center; background: linear-gradient(135deg, #38bdf8, #22c55e); color: #020617; font-weight: 900; }
h1, h2, h3, p { margin-top: 0; }
h1 { font-size: 22px; margin-bottom: 4px; }
.brand p, .muted, .panel p, .card p { color: var(--muted); }
nav { display: grid; gap: 10px; }
nav a { color: var(--text); text-decoration: none; padding: 12px 14px; border-radius: 12px; background: rgba(15, 23, 42, 0.7); border: 1px solid transparent; }
nav a:hover { border-color: var(--accent); }
.side-note { position: absolute; bottom: 28px; left: 28px; right: 28px; color: var(--muted); overflow-wrap: anywhere; }
.side-note strong { display: block; color: var(--accent); margin-top: 6px; }
main { padding: 34px; max-width: 1280px; width: 100%; }
.hero { display: flex; justify-content: space-between; gap: 24px; align-items: center; padding: 34px; border: 1px solid var(--border); border-radius: 28px; background: linear-gradient(135deg, rgba(56, 189, 248, 0.16), rgba(34, 197, 94, 0.08)); box-shadow: 0 24px 80px rgba(0,0,0,0.25); }
.eyebrow { color: var(--accent); text-transform: uppercase; letter-spacing: .14em; font-size: 12px; font-weight: 800; }
h2 { font-size: clamp(28px, 4vw, 52px); line-height: 1.02; margin-bottom: 16px; }
.cards { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin: 22px 0; }
.card, .panel { background: var(--card); border: 1px solid var(--border); border-radius: 22px; padding: 22px; box-shadow: 0 18px 60px rgba(0,0,0,0.18); }
.card strong { display: block; font-size: 26px; margin: 12px 0 8px; }
.label { color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: .1em; }
.panel { margin: 22px 0; }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 20px; margin-bottom: 14px; }
.action-grid { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 14px; }
button, select { border: 1px solid var(--border); border-radius: 14px; background: #0f172a; color: var(--text); padding: 12px 16px; font-weight: 800; cursor: pointer; }
button:hover { border-color: var(--accent); transform: translateY(-1px); }
button.primary { background: linear-gradient(135deg, #38bdf8, #22c55e); color: #020617; border: 0; }
button.warning { background: rgba(245, 158, 11, 0.16); border-color: rgba(245, 158, 11, 0.55); }
button.danger { background: rgba(239, 68, 68, 0.13); border-color: rgba(239, 68, 68, 0.55); }
.terminal { background: #020617; color: #d1d5db; padding: 18px; border-radius: 18px; min-height: 140px; max-height: 470px; overflow: auto; border: 1px solid var(--border); white-space: pre-wrap; }
.summary { display: grid; gap: 10px; margin: 14px 0; }
.badge { display: inline-flex; align-items: center; gap: 8px; padding: 9px 12px; border-radius: 999px; background: rgba(148, 163, 184, 0.12); border: 1px solid var(--border); width: fit-content; }
.badge.good { color: var(--good); border-color: rgba(34,197,94,.5); }
.badge.bad { color: var(--bad); border-color: rgba(239,68,68,.5); }
.badge.warn { color: var(--warn); border-color: rgba(245,158,11,.5); }
.evidence-list { display: grid; gap: 12px; }
.evidence-item { padding: 16px; border: 1px solid var(--border); border-radius: 16px; background: rgba(15, 23, 42, 0.7); }
.evidence-item code { color: var(--accent); overflow-wrap: anywhere; }
@media (max-width: 1000px) {
  .shell { grid-template-columns: 1fr; }
  .sidebar { position: static; height: auto; }
  .side-note { position: static; margin-top: 24px; }
  .cards { grid-template-columns: repeat(2, 1fr); }
  .hero { flex-direction: column; align-items: flex-start; }
}
@media (max-width: 640px) {
  main, .sidebar { padding: 20px; }
  .cards { grid-template-columns: 1fr; }
}
CSS

cat > "$DASH_DIR/static/app.js" <<'JS'
const $ = (id) => document.getElementById(id);

function badge(text, type = "") {
  return `<span class="badge ${type}">${text}</span>`;
}

function setLoading(id, text) {
  $(id).textContent = text;
}

async function jsonFetch(url, options = {}) {
  const res = await fetch(url, options);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return await res.json();
}

async function refreshStatus() {
  setLoading("coreStatus", "Checking");
  setLoading("ranStatus", "Checking");
  setLoading("ownerStatus", "Checking");
  try {
    const data = await jsonFetch("/api/status");
    $("coreStatus").textContent = data.core_ok ? "Running" : "Check needed";
    $("ranStatus").textContent = data.ran_ok ? "Running" : "Check needed";
    $("ownerStatus").textContent = data.ownership || "Unknown";
    $("lastUpdate").textContent = data.time || "-";
  } catch (e) {
    $("coreStatus").textContent = "Error";
    $("ranStatus").textContent = "Error";
    $("ownerStatus").textContent = e.message;
  }
}

function validationBadges(parsed, result) {
  const parts = [];
  parts.push(badge(`Exit code: ${result.exit_code}`, result.ok ? "good" : "bad"));
  parts.push(badge(`UE IP: ${parsed.ue_ip || "not found"}`, parsed.ue_ip ? "good" : "warn"));
  parts.push(badge(`DN gateway ping: ${parsed.dn_gateway_ping ? "PASS" : "FAIL"}`, parsed.dn_gateway_ping ? "good" : "bad"));
  parts.push(badge(`Internet ping: ${parsed.internet_ping ? "PASS" : "FAIL"}`, parsed.internet_ping ? "good" : "bad"));
  parts.push(badge(`Registration: ${parsed.registration_complete ? "complete" : "not seen"}`, parsed.registration_complete ? "good" : "warn"));
  if (parsed.duplicated_pdu_session_id) parts.push(badge("Duplicated PDU session warning", "warn"));
  return parts.join("");
}

async function runValidate() {
  $("validationSummary").innerHTML = badge("Running E2E validation...", "warn");
  $("validationOutput").textContent = "Running ./scripts/validate-e2e.sh ...";
  try {
    const data = await jsonFetch("/api/validate", { method: "POST" });
    $("validationSummary").innerHTML = validationBadges(data.parsed, data.result) + badge(`Evidence: ${data.evidence_dir}`, "");
    $("validationOutput").textContent = data.result.output || "No output";
    refreshStatus();
    loadEvidence();
  } catch (e) {
    $("validationSummary").innerHTML = badge(`Error: ${e.message}`, "bad");
  }
}

async function runRecovery() {
  const ok = confirm("This will run deploy-ran.sh, wait, then validate E2E. Continue?");
  if (!ok) return;
  $("validationSummary").innerHTML = badge("Running recovery...", "warn");
  $("validationOutput").textContent = "Running recovery. This can take several minutes...";
  try {
    const data = await jsonFetch("/api/recovery", { method: "POST" });
    $("validationSummary").innerHTML = validationBadges(data.parsed, data.result) + badge(`Evidence: ${data.evidence_dir}`, "");
    $("validationOutput").textContent = data.result.output || "No output";
    refreshStatus();
    loadEvidence();
  } catch (e) {
    $("validationSummary").innerHTML = badge(`Error: ${e.message}`, "bad");
  }
}

async function runHandover(direction) {
  const label = direction === "a2b" ? "A -> B" : "B -> A";
  const ok = confirm(`This will trigger ${label} N2 handover and may dirty the lab state. Continue?`);
  if (!ok) return;
  $("handoverSummary").innerHTML = badge(`Running ${label} handover test...`, "warn");
  $("handoverOutput").textContent = "Capturing logs, triggering handover, waiting for result...";
  try {
    const data = await jsonFetch("/api/handover", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ direction })
    });
    const p = data.parsed;
    const success = p.handover_success === true;
    const failed = p.handover_success === false;
    $("handoverSummary").innerHTML = [
      badge(`${label} trigger: ${p.trigger_seen ? "seen" : "not seen"}`, p.trigger_seen ? "good" : "bad"),
      badge(`Target RA WAIT_Msg3: ${p.target_ra_failed_wait_msg3 ? "FAILED" : "not detected"}`, p.target_ra_failed_wait_msg3 ? "bad" : "warn"),
      badge(`CI after: ${p.ci_ownership_after}`, failed ? "bad" : "warn"),
      badge(`Evidence: ${data.evidence_dir}`)
    ].join("");
    $("handoverOutput").textContent = data.classification || data.result.output || "No classification output";
    refreshStatus();
    loadEvidence();
  } catch (e) {
    $("handoverSummary").innerHTML = badge(`Error: ${e.message}`, "bad");
  }
}

async function loadLogs() {
  const target = $("logTarget").value;
  $("logOutput").textContent = "Loading logs...";
  try {
    const data = await jsonFetch(`/api/logs?target=${encodeURIComponent(target)}&since=10m`);
    $("logOutput").textContent = data.output || "No logs";
  } catch (e) {
    $("logOutput").textContent = `Error: ${e.message}`;
  }
}

async function loadEvidence() {
  const box = $("evidenceList");
  box.innerHTML = "Loading evidence...";
  try {
    const data = await jsonFetch("/api/evidence");
    if (!data.items.length) {
      box.innerHTML = "No evidence generated yet.";
      return;
    }
    box.innerHTML = data.items.map(item => `
      <div class="evidence-item">
        <strong>${item.name}</strong><br>
        <code>${item.path}</code>
        <pre class="terminal">${(item.summary || "No summary").replace(/[<>&]/g, c => ({"<":"&lt;", ">":"&gt;", "&":"&amp;"}[c]))}</pre>
      </div>
    `).join("");
  } catch (e) {
    box.innerHTML = `Error: ${e.message}`;
  }
}

refreshStatus();
loadEvidence();
JS

cat > "$DASH_DIR/run-dashboard.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
python3 -m venv .venv
. .venv/bin/activate
pip install -q -r requirements.txt
export PROJECT_ROOT="${PROJECT_ROOT:-$HOME/oran-e2e-freeze}"
export RUN_ROOT="${RUN_ROOT:-$HOME/oran-proof}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-18080}"
python app.py
EOF
chmod +x "$DASH_DIR/run-dashboard.sh"

cat > "$DASH_DIR/README.md" <<EOF
# O-RAN 5G Lab Dashboard

Start:

\`\`\`bash
cd $DASH_DIR
./run-dashboard.sh
\`\`\`

Open:

\`\`\`text
http://$LAB_IP:$PORT
\`\`\`

Environment overrides:

\`\`\`bash
PROJECT_ROOT=$PROJECT_ROOT RUN_ROOT=$RUN_ROOT PORT=$PORT ./run-dashboard.sh
\`\`\`
EOF

cat > "$PROJECT_ROOT/run-web-dashboard.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$DASH_DIR"
exec ./run-dashboard.sh
EOF
chmod +x "$PROJECT_ROOT/run-web-dashboard.sh"

echo "Dashboard installed in: $DASH_DIR"
echo "Start it with: $PROJECT_ROOT/run-web-dashboard.sh"
echo "Open: http://$LAB_IP:$PORT"
