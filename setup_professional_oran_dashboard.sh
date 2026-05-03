#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
APP_DIR="$BASE_DIR/web-dashboard"
RUN_SCRIPT="$BASE_DIR/run-web-dashboard.sh"

mkdir -p "$APP_DIR/templates" "$APP_DIR/static" "$HOME/oran-proof/web-dashboard-runs"

cat > "$APP_DIR/requirements.txt" <<'REQ'
flask
REQ

cat > "$APP_DIR/app.py" <<'PY'
import os
import glob
import json
import time
import subprocess
from datetime import datetime
from pathlib import Path
from flask import Flask, render_template, jsonify, request

BASE_DIR = Path.home() / "oran-e2e-freeze"
PROOF_DIR = Path.home() / "oran-proof"
WEB_RUN_DIR = PROOF_DIR / "web-dashboard-runs"

LAB_IP = os.environ.get("ORAN_LAB_IP", "192.168.1.142")
GRAFANA_URL = f"http://{LAB_IP}:30300"
PROMETHEUS_URL = f"http://{LAB_IP}:30090"

app = Flask(__name__)

def run_cmd(cmd, timeout=12):
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
        return {
            "ok": p.returncode == 0,
            "exit": p.returncode,
            "output": p.stdout.strip()
        }
    except subprocess.TimeoutExpired as e:
        return {
            "ok": False,
            "exit": 124,
            "output": f"TIMEOUT after {timeout}s\n{e.stdout or ''}"
        }
    except Exception as e:
        return {
            "ok": False,
            "exit": 1,
            "output": str(e)
        }

def latest_dir(pattern):
    items = glob.glob(str(PROOF_DIR / pattern))
    items = [Path(x) for x in items if Path(x).is_dir()]
    if not items:
        return None
    return max(items, key=lambda p: p.stat().st_mtime)

def latest_file(pattern):
    items = glob.glob(str(PROOF_DIR / pattern), recursive=True)
    items = [Path(x) for x in items if Path(x).is_file()]
    if not items:
        return None
    return max(items, key=lambda p: p.stat().st_mtime)

def read_text(path, max_chars=6000):
    if not path or not Path(path).exists():
        return ""
    try:
        return Path(path).read_text(errors="replace")[-max_chars:]
    except Exception:
        return ""

def classify_summary(text):
    low = text.lower()
    if "success" in low and "validate_exit=0" in low:
        return "PASS"
    if "status:\nsuccess" in low or "status: success" in low:
        return "PASS"
    if "fail" in low or "failed" in low or "validate_exit=1" in low:
        return "FAIL"
    if "under debug" in low or "incomplete" in low:
        return "UNDER DEBUG"
    if text.strip():
        return "INFO"
    return "UNKNOWN"

def find_latest_summaries():
    summaries = {}

    e2e = latest_file("**/*validate-exit.txt")
    if e2e:
        txt = read_text(e2e, 1200)
        summaries["latest_validate_exit"] = {
            "path": str(e2e),
            "text": txt,
            "status": "PASS" if "validate_exit=0" in txt else "FAIL"
        }

    rec2 = latest_file("**/RECOVERY2-STATUS.txt")
    if rec2:
        txt = read_text(rec2)
        summaries["latest_recovery"] = {
            "path": str(rec2),
            "text": txt,
            "status": classify_summary(txt)
        }

    ho = latest_file("**/RESULT-SUMMARY.txt")
    if ho:
        txt = read_text(ho)
        summaries["latest_handover"] = {
            "path": str(ho),
            "text": txt,
            "status": classify_summary(txt)
        }

    final = latest_dir("today-*")
    summaries["latest_proof_root"] = {
        "path": str(final) if final else "Not found",
        "status": "INFO",
        "text": ""
    }

    return summaries

def get_pods(namespace):
    cmd = f"kubectl -n {namespace} get pods -o json"
    r = run_cmd(cmd, timeout=12)
    if not r["ok"]:
        return {"ok": False, "error": r["output"], "pods": []}

    try:
        data = json.loads(r["output"])
        pods = []
        for item in data.get("items", []):
            name = item["metadata"]["name"]
            phase = item["status"].get("phase", "Unknown")
            restarts = 0
            ready = 0
            total = 0

            for cs in item["status"].get("containerStatuses", []):
                total += 1
                if cs.get("ready"):
                    ready += 1
                restarts += cs.get("restartCount", 0)

            pods.append({
                "name": name,
                "phase": phase,
                "ready": f"{ready}/{total}",
                "restarts": restarts,
                "ip": item["status"].get("podIP", ""),
                "node": item["spec"].get("nodeName", "")
            })

        return {"ok": True, "pods": pods}
    except Exception as e:
        return {"ok": False, "error": str(e), "pods": []}

def get_live_lab_status():
    core = get_pods("oran-core")
    ran = get_pods("oran-ran")
    mon = get_pods("monitoring")

    core_needed = ["open5gs-amf", "open5gs-smf", "open5gs-upf"]
    ran_needed = ["oai-gnb", "oai-gnb-b", "oai-nr-ue"]

    def count_ready(pod_data, needed):
        pods = pod_data.get("pods", [])
        ready = 0
        detail = []
        for n in needed:
            match = next((p for p in pods if p["name"].startswith(n)), None)
            if match:
                is_ready = match["phase"] == "Running" and match["ready"].split("/")[0] == match["ready"].split("/")[1]
                if is_ready:
                    ready += 1
                detail.append({"component": n, "ready": is_ready, "pod": match})
            else:
                detail.append({"component": n, "ready": False, "pod": None})
        return ready, detail

    core_count, core_detail = count_ready(core, core_needed)
    ran_count, ran_detail = count_ready(ran, ran_needed)

    ue_tunnel_cmd = """
UE=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$UE" ]; then
  kubectl -n oran-ran exec "$UE" -- sh -c 'ip addr show oaitun_ue1 2>/dev/null | grep -E "inet " || true'
fi
"""
    ue_tunnel = run_cmd(ue_tunnel_cmd, timeout=15)

    gnb_owner_cmd = r"""
GNB_A=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
GNB_B=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
echo "GNB_A=$GNB_A"
echo "GNB_B=$GNB_B"
kubectl -n oran-ran logs "$GNB_A" --since=2m 2>/dev/null | egrep -i 'UE RNTI|CU-UE-ID|in-sync' | tail -n 3 || true
echo "---"
kubectl -n oran-ran logs "$GNB_B" --since=2m 2>/dev/null | egrep -i 'UE RNTI|CU-UE-ID|in-sync' | tail -n 3 || true
"""
    gnb_owner = run_cmd(gnb_owner_cmd, timeout=20)

    summaries = find_latest_summaries()

    latest_ho_status = summaries.get("latest_handover", {}).get("status", "UNKNOWN")
    latest_e2e_status = summaries.get("latest_validate_exit", {}).get("status", "UNKNOWN")

    if latest_e2e_status == "PASS":
        user_plane_status = "PASS"
    elif "inet " in ue_tunnel.get("output", ""):
        user_plane_status = "PARTIAL"
    else:
        user_plane_status = "UNKNOWN"

    return {
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "core_ready_count": core_count,
        "ran_ready_count": ran_count,
        "core_detail": core_detail,
        "ran_detail": ran_detail,
        "core_pods": core,
        "ran_pods": ran,
        "monitoring_pods": mon,
        "ue_tunnel": ue_tunnel,
        "gnb_owner": gnb_owner,
        "summaries": summaries,
        "cards": {
            "cloud": "PASS" if core.get("ok") and ran.get("ok") else "FAIL",
            "core": "PASS" if core_count == 3 else "FAIL",
            "ran": "PASS" if ran_count == 3 else "FAIL",
            "user_plane": user_plane_status,
            "handover": "UNDER DEBUG" if latest_ho_status == "FAIL" else latest_ho_status
        },
        "links": {
            "grafana": GRAFANA_URL,
            "prometheus": PROMETHEUS_URL
        }
    }

@app.route("/")
def index():
    return render_template("index.html", grafana_url=GRAFANA_URL, prometheus_url=PROMETHEUS_URL)

@app.route("/api/status")
def api_status():
    return jsonify(get_live_lab_status())

@app.route("/api/evidence")
def api_evidence():
    return jsonify(find_latest_summaries())

@app.route("/api/run/e2e", methods=["POST"])
def api_run_e2e():
    WEB_RUN_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = WEB_RUN_DIR / f"validate-e2e-{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)
    log_file = out_dir / "validate-e2e.log"
    exit_file = out_dir / "validate-exit.txt"

    cmd = f"""
set -o pipefail
timeout 300 ./scripts/validate-e2e.sh 2>&1 | tee "{log_file}"
echo "validate_exit=${{PIPESTATUS[0]}}" | tee "{exit_file}"
"""
    r = run_cmd(f"bash -lc '{cmd}'", timeout=330)
    return jsonify({
        "ok": r["ok"],
        "exit": r["exit"],
        "output": r["output"][-6000:],
        "evidence_dir": str(out_dir),
        "log_file": str(log_file),
        "exit_file": str(exit_file)
    })

@app.route("/api/run/snapshot", methods=["POST"])
def api_run_snapshot():
    WEB_RUN_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = WEB_RUN_DIR / f"snapshot-{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = f"""
kubectl get nodes -o wide > "{out_dir}/01-nodes.txt" 2>&1 || true
kubectl -n oran-core get pods -o wide > "{out_dir}/02-core-pods.txt" 2>&1 || true
kubectl -n oran-ran get pods -o wide > "{out_dir}/03-ran-pods.txt" 2>&1 || true
kubectl -n monitoring get pods -o wide > "{out_dir}/04-monitoring-pods.txt" 2>&1 || true
kubectl -n oran-ran get events --sort-by=.lastTimestamp | tail -n 80 > "{out_dir}/05-ran-events.txt" 2>&1 || true
kubectl -n oran-core get events --sort-by=.lastTimestamp | tail -n 80 > "{out_dir}/06-core-events.txt" 2>&1 || true
echo "{out_dir}"
"""
    r = run_cmd(cmd, timeout=40)
    return jsonify({
        "ok": r["ok"],
        "exit": r["exit"],
        "output": r["output"],
        "evidence_dir": str(out_dir)
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=18080)
PY

cat > "$APP_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>O-RAN 5G Lab Control Dashboard</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="logo">5G</div>
        <div>
          <h1>O-RAN Lab</h1>
          <p>Control & Validation</p>
        </div>
      </div>

      <nav>
        <a href="#overview">Overview</a>
        <a href="#topology">Topology</a>
        <a href="#validation">Validation</a>
        <a href="#handover">Handover</a>
        <a href="#evidence">Evidence</a>
        <a href="{{ grafana_url }}" target="_blank">Grafana</a>
        <a href="{{ prometheus_url }}" target="_blank">Prometheus</a>
      </nav>

      <div class="side-note">
        <strong>Status policy</strong>
        <span>Successful UE ping is not counted as successful handover unless ownership moves to the target gNB.</span>
      </div>
    </aside>

    <main>
      <header class="topbar">
        <div>
          <h2>O-RAN 5G End-to-End Lab Dashboard</h2>
          <p>Cloud-native Open5GS + OAI RAN validation interface</p>
        </div>
        <div class="top-actions">
          <button onclick="refreshAll()">Refresh</button>
          <button onclick="runSnapshot()">Capture Snapshot</button>
          <button class="primary" onclick="runE2E()">Run E2E Validation</button>
        </div>
      </header>

      <section id="overview" class="cards">
        <div class="card metric">
          <span>Infrastructure Cloud</span>
          <strong id="card-cloud">...</strong>
          <small>Kubernetes/k3s, namespaces, services</small>
        </div>
        <div class="card metric">
          <span>5G Core</span>
          <strong id="card-core">...</strong>
          <small>Open5GS AMF / SMF / UPF</small>
        </div>
        <div class="card metric">
          <span>RAN + UE</span>
          <strong id="card-ran">...</strong>
          <small>gNB-A / gNB-B / NR-UE</small>
        </div>
        <div class="card metric">
          <span>User Plane</span>
          <strong id="card-user-plane">...</strong>
          <small>UE tunnel and ping validation</small>
        </div>
        <div class="card metric danger">
          <span>N2 Handover</span>
          <strong id="card-handover">...</strong>
          <small>Strict ownership + RA/Msg3 classification</small>
        </div>
      </section>

      <section id="topology" class="panel">
        <div class="panel-title">
          <h3>Live Lab Topology</h3>
          <span id="last-update">Loading...</span>
        </div>

        <div class="topology">
          <div class="node ue">NR-UE<br><span id="ue-ip">Checking tunnel...</span></div>
          <div class="link"></div>
          <div class="node ran">gNB-A<br><span>PCI 0</span></div>
          <div class="node ran">gNB-B<br><span>PCI 1</span></div>
          <div class="link"></div>
          <div class="node core">AMF</div>
          <div class="node core">SMF</div>
          <div class="node core">UPF</div>
          <div class="link"></div>
          <div class="node dn">DN<br><span>10.45.0.1 / Internet</span></div>
        </div>
      </section>

      <section class="grid2">
        <div class="panel">
          <div class="panel-title">
            <h3>RAN Components</h3>
            <span id="ran-count">...</span>
          </div>
          <table>
            <thead><tr><th>Component</th><th>Pod</th><th>Ready</th><th>Restarts</th></tr></thead>
            <tbody id="ran-table"></tbody>
          </table>
        </div>

        <div class="panel">
          <div class="panel-title">
            <h3>5G Core Components</h3>
            <span id="core-count">...</span>
          </div>
          <table>
            <thead><tr><th>Component</th><th>Pod</th><th>Ready</th><th>Restarts</th></tr></thead>
            <tbody id="core-table"></tbody>
          </table>
        </div>
      </section>

      <section id="validation" class="grid2">
        <div class="panel">
          <div class="panel-title">
            <h3>UE Tunnel / User Plane</h3>
            <span>Live check</span>
          </div>
          <pre id="ue-tunnel">Loading...</pre>
        </div>

        <div class="panel">
          <div class="panel-title">
            <h3>Current gNB Ownership Signal</h3>
            <span>Recent logs</span>
          </div>
          <pre id="gnb-owner">Loading...</pre>
        </div>
      </section>

      <section id="handover" class="panel">
        <div class="panel-title">
          <h3>Latest Handover Classification</h3>
          <span id="ho-status">...</span>
        </div>
        <div class="explain">
          <p><strong>Engineering rule:</strong> handover is only successful when the target gNB owns the UE after trigger and target-side RA/Msg3 completes. User-plane survival alone is not enough.</p>
        </div>
        <pre id="ho-summary">Loading...</pre>
      </section>

      <section id="evidence" class="grid2">
        <div class="panel">
          <div class="panel-title">
            <h3>Latest Recovery / E2E Evidence</h3>
            <span id="recovery-status">...</span>
          </div>
          <pre id="recovery-summary">Loading...</pre>
        </div>

        <div class="panel">
          <div class="panel-title">
            <h3>Evidence Paths</h3>
            <span>Local proof folders</span>
          </div>
          <div id="evidence-paths" class="paths"></div>
        </div>
      </section>

      <section class="panel">
        <div class="panel-title">
          <h3>Action Output</h3>
          <span id="action-state">Idle</span>
        </div>
        <pre id="action-output">No action yet.</pre>
      </section>
    </main>
  </div>

  <script src="/static/app.js"></script>
</body>
</html>
HTML

cat > "$APP_DIR/static/style.css" <<'CSS'
:root {
  --bg: #07111f;
  --panel: #111c2e;
  --panel2: #17243a;
  --line: #29405f;
  --text: #e8f1ff;
  --muted: #93a8c7;
  --green: #38d996;
  --red: #ff657a;
  --yellow: #ffd166;
  --blue: #62a8ff;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: radial-gradient(circle at top left, #16385f 0, #07111f 42%, #050915 100%);
  color: var(--text);
  font-family: Inter, Arial, sans-serif;
}

.shell {
  display: grid;
  grid-template-columns: 280px 1fr;
  min-height: 100vh;
}

.sidebar {
  position: sticky;
  top: 0;
  height: 100vh;
  padding: 26px;
  background: rgba(7, 17, 31, 0.88);
  border-right: 1px solid var(--line);
  backdrop-filter: blur(16px);
}

.brand {
  display: flex;
  gap: 14px;
  align-items: center;
  margin-bottom: 34px;
}

.logo {
  width: 52px;
  height: 52px;
  border-radius: 18px;
  display: grid;
  place-items: center;
  background: linear-gradient(135deg, #62a8ff, #38d996);
  font-weight: 900;
  color: #04101f;
}

.brand h1 {
  margin: 0;
  font-size: 22px;
}

.brand p {
  margin: 4px 0 0;
  color: var(--muted);
  font-size: 13px;
}

nav {
  display: grid;
  gap: 8px;
}

nav a {
  color: var(--text);
  text-decoration: none;
  padding: 12px 14px;
  border-radius: 12px;
  background: transparent;
}

nav a:hover {
  background: var(--panel2);
}

.side-note {
  margin-top: 34px;
  padding: 16px;
  border: 1px solid var(--line);
  border-radius: 14px;
  color: var(--muted);
  font-size: 13px;
  display: grid;
  gap: 8px;
}

main {
  padding: 28px;
  overflow: hidden;
}

.topbar {
  display: flex;
  justify-content: space-between;
  gap: 20px;
  align-items: center;
  margin-bottom: 22px;
}

.topbar h2 {
  margin: 0;
  font-size: 30px;
}

.topbar p {
  margin: 8px 0 0;
  color: var(--muted);
}

.top-actions {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
}

button {
  border: 1px solid var(--line);
  background: var(--panel2);
  color: var(--text);
  border-radius: 12px;
  padding: 11px 14px;
  cursor: pointer;
  font-weight: 700;
}

button.primary {
  background: linear-gradient(135deg, #2563eb, #12b981);
  border: none;
}

button:hover {
  filter: brightness(1.12);
}

.cards {
  display: grid;
  grid-template-columns: repeat(5, minmax(160px, 1fr));
  gap: 14px;
  margin-bottom: 18px;
}

.card, .panel {
  background: rgba(17, 28, 46, 0.88);
  border: 1px solid var(--line);
  border-radius: 18px;
  box-shadow: 0 24px 70px rgba(0,0,0,0.22);
}

.card.metric {
  padding: 18px;
  min-height: 136px;
  display: grid;
  gap: 10px;
}

.card span {
  color: var(--muted);
  font-size: 13px;
  font-weight: 700;
}

.card strong {
  font-size: 28px;
}

.card small {
  color: var(--muted);
  line-height: 1.4;
}

.status-pass { color: var(--green); }
.status-fail { color: var(--red); }
.status-debug { color: var(--yellow); }
.status-info { color: var(--blue); }
.status-unknown { color: var(--muted); }

.panel {
  padding: 18px;
  margin-bottom: 18px;
}

.panel-title {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 18px;
  margin-bottom: 14px;
}

.panel-title h3 {
  margin: 0;
  font-size: 18px;
}

.panel-title span {
  color: var(--muted);
  font-size: 13px;
}

.grid2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 18px;
}

.topology {
  display: flex;
  align-items: center;
  gap: 12px;
  overflow-x: auto;
  padding: 14px 4px 4px;
}

.node {
  min-width: 130px;
  min-height: 78px;
  border-radius: 18px;
  display: grid;
  place-items: center;
  text-align: center;
  padding: 12px;
  font-weight: 800;
  border: 1px solid var(--line);
}

.node span {
  display: block;
  margin-top: 6px;
  font-size: 12px;
  font-weight: 500;
  color: var(--muted);
}

.node.ue { background: rgba(98,168,255,.18); }
.node.ran { background: rgba(56,217,150,.15); }
.node.core { background: rgba(255,209,102,.15); }
.node.dn { background: rgba(255,101,122,.14); }

.link {
  min-width: 44px;
  height: 3px;
  background: linear-gradient(90deg, var(--blue), var(--green));
  border-radius: 999px;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 13px;
}

th, td {
  padding: 11px 8px;
  border-bottom: 1px solid rgba(147,168,199,.16);
  text-align: left;
}

th {
  color: var(--muted);
}

pre {
  background: #08111f;
  border: 1px solid rgba(147,168,199,.18);
  border-radius: 14px;
  padding: 14px;
  overflow: auto;
  max-height: 360px;
  white-space: pre-wrap;
  line-height: 1.45;
  color: #d8e7ff;
}

.explain {
  border-left: 4px solid var(--yellow);
  padding: 10px 14px;
  background: rgba(255,209,102,.08);
  border-radius: 10px;
  color: var(--text);
  margin-bottom: 12px;
}

.paths {
  display: grid;
  gap: 10px;
  word-break: break-all;
  color: var(--muted);
  font-family: monospace;
}

.path-card {
  background: #08111f;
  border: 1px solid rgba(147,168,199,.18);
  border-radius: 12px;
  padding: 12px;
}

@media (max-width: 1100px) {
  .shell { grid-template-columns: 1fr; }
  .sidebar { position: relative; height: auto; }
  .cards { grid-template-columns: repeat(2, 1fr); }
  .grid2 { grid-template-columns: 1fr; }
  .topbar { flex-direction: column; align-items: flex-start; }
}
CSS

cat > "$APP_DIR/static/app.js" <<'JS'
function statusClass(value) {
  const v = (value || "").toUpperCase();
  if (v === "PASS" || v === "READY") return "status-pass";
  if (v === "FAIL") return "status-fail";
  if (v === "UNDER DEBUG" || v === "PARTIAL") return "status-debug";
  if (v === "INFO") return "status-info";
  return "status-unknown";
}

function setCard(id, value) {
  const el = document.getElementById(id);
  el.textContent = value || "UNKNOWN";
  el.className = statusClass(value);
}

function podRow(item) {
  const pod = item.pod;
  const ready = item.ready ? "READY" : "NOT READY";
  return `
    <tr>
      <td>${item.component}</td>
      <td>${pod ? pod.name : "missing"}</td>
      <td class="${statusClass(ready)}">${ready}</td>
      <td>${pod ? pod.restarts : "-"}</td>
    </tr>
  `;
}

async function refreshAll() {
  const res = await fetch("/api/status");
  const data = await res.json();

  document.getElementById("last-update").textContent = "Last update: " + data.timestamp;

  setCard("card-cloud", data.cards.cloud);
  setCard("card-core", data.cards.core);
  setCard("card-ran", data.cards.ran);
  setCard("card-user-plane", data.cards.user_plane);
  setCard("card-handover", data.cards.handover);

  document.getElementById("core-count").textContent = `${data.core_ready_count}/3 ready`;
  document.getElementById("ran-count").textContent = `${data.ran_ready_count}/3 ready`;

  document.getElementById("ran-table").innerHTML = data.ran_detail.map(podRow).join("");
  document.getElementById("core-table").innerHTML = data.core_detail.map(podRow).join("");

  const tunnel = data.ue_tunnel.output || "No tunnel output";
  document.getElementById("ue-tunnel").textContent = tunnel;
  const match = tunnel.match(/inet\s+([0-9.]+\/[0-9]+)/);
  document.getElementById("ue-ip").textContent = match ? match[1] : "No oaitun_ue1 IP";

  document.getElementById("gnb-owner").textContent = data.gnb_owner.output || "No recent gNB ownership signal";

  const ho = data.summaries.latest_handover || {};
  document.getElementById("ho-status").textContent = ho.status || "UNKNOWN";
  document.getElementById("ho-status").className = statusClass(ho.status);
  document.getElementById("ho-summary").textContent = ho.text || "No handover summary found yet.";

  const rec = data.summaries.latest_recovery || data.summaries.latest_validate_exit || {};
  document.getElementById("recovery-status").textContent = rec.status || "UNKNOWN";
  document.getElementById("recovery-status").className = statusClass(rec.status);
  document.getElementById("recovery-summary").textContent = rec.text || "No recovery or E2E summary found yet.";

  const paths = [];
  for (const [k, v] of Object.entries(data.summaries || {})) {
    paths.push(`<div class="path-card"><strong>${k}</strong><br>${v.path || ""}</div>`);
  }
  document.getElementById("evidence-paths").innerHTML = paths.join("");
}

async function runE2E() {
  const state = document.getElementById("action-state");
  const out = document.getElementById("action-output");
  state.textContent = "Running E2E validation...";
  out.textContent = "Please wait. validate-e2e.sh can take several minutes.";

  const res = await fetch("/api/run/e2e", { method: "POST" });
  const data = await res.json();

  state.textContent = data.ok ? "E2E finished" : "E2E finished with issue";
  out.textContent =
    `Evidence: ${data.evidence_dir}\n` +
    `Exit: ${data.exit}\n\n` +
    `${data.output}`;

  await refreshAll();
}

async function runSnapshot() {
  const state = document.getElementById("action-state");
  const out = document.getElementById("action-output");
  state.textContent = "Capturing snapshot...";
  out.textContent = "Collecting Kubernetes state...";

  const res = await fetch("/api/run/snapshot", { method: "POST" });
  const data = await res.json();

  state.textContent = "Snapshot complete";
  out.textContent =
    `Evidence: ${data.evidence_dir}\n` +
    `Exit: ${data.exit}\n\n` +
    `${data.output}`;

  await refreshAll();
}

refreshAll();
setInterval(refreshAll, 10000);
JS

cat > "$RUN_SCRIPT" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail

cd "$HOME/oran-e2e-freeze/web-dashboard" || exit 1

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

. .venv/bin/activate
pip install -q -r requirements.txt

export ORAN_LAB_IP="${ORAN_LAB_IP:-192.168.1.142}"

python app.py
RUN

chmod +x "$RUN_SCRIPT"

echo "Professional O-RAN dashboard installed."
echo "Start it with:"
echo "$RUN_SCRIPT"
echo "Open:"
echo "http://192.168.1.142:18080"
