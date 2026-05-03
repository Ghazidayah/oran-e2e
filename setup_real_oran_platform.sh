#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
APP_DIR="$BASE_DIR/web-dashboard"
RUN_SCRIPT="$BASE_DIR/run-web-dashboard.sh"
STOP_SCRIPT="$BASE_DIR/stop-web-dashboard.sh"

mkdir -p "$APP_DIR/templates" "$HOME/oran-proof/web-dashboard-runs"

cat > "$APP_DIR/requirements.txt" <<'REQ'
Flask
REQ

cat > "$APP_DIR/app.py" <<'PY'
import os
import re
import json
import time
import shlex
import random
import signal
import subprocess
from pathlib import Path
from datetime import datetime
from flask import Flask, render_template, jsonify, send_from_directory

BASE_DIR = Path.home() / "oran-e2e-freeze"
PROOF_DIR = Path.home() / "oran-proof"
RUNS_DIR = PROOF_DIR / "web-dashboard-runs"
RUNS_DIR.mkdir(parents=True, exist_ok=True)

LAB_IP = os.environ.get("ORAN_LAB_IP", "192.168.1.142")
APP_PORT = int(os.environ.get("ORAN_DASHBOARD_PORT", "18080"))
GRAFANA_URL = f"http://{LAB_IP}:30300"
PROMETHEUS_URL = f"http://{LAB_IP}:30090"

LAST_OWNERSHIP_FILE = RUNS_DIR / "last-ownership.json"
TRAFFIC_PROCS = {}

app = Flask(__name__)

def now_id():
    return datetime.now().strftime("%Y%m%d-%H%M%S")

def run_cmd(cmd, timeout=20):
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            cwd=str(BASE_DIR),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            executable="/bin/bash",
        )
        return {"ok": p.returncode == 0, "exit": p.returncode, "output": p.stdout.strip()}
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        return {"ok": False, "exit": 124, "output": str(out).strip() + "\nTIMEOUT"}

def kpods(namespace):
    r = run_cmd(f"kubectl -n {shlex.quote(namespace)} get pods -o json", timeout=12)
    if not r["ok"]:
        return []
    try:
        return json.loads(r["output"]).get("items", [])
    except Exception:
        return []

def pod_ready(item):
    statuses = item.get("status", {}).get("containerStatuses", [])
    if not statuses:
        return False
    return all(s.get("ready", False) for s in statuses)

def pod_row(item):
    meta = item.get("metadata", {})
    status = item.get("status", {})
    cs = status.get("containerStatuses", [])
    restarts = sum(c.get("restartCount", 0) for c in cs)
    return {
        "name": meta.get("name", ""),
        "phase": status.get("phase", ""),
        "ready": pod_ready(item),
        "ip": status.get("podIP", ""),
        "node": status.get("hostIP", ""),
        "restarts": restarts,
        "age": meta.get("creationTimestamp", "")
    }

def find_ran_pods():
    items = kpods("oran-ran")
    gnb_a = ""
    gnb_b = ""
    ue = ""

    for p in items:
        name = p.get("metadata", {}).get("name", "")
        if name.startswith("oai-gnb-b-"):
            gnb_b = name
        elif name.startswith("oai-gnb-"):
            gnb_a = name
        elif name.startswith("oai-nr-ue-"):
            ue = name

    return gnb_a, gnb_b, ue

def find_ue_pod():
    return find_ran_pods()[2]

def exec_in_ue(script, timeout=90):
    ue = find_ue_pod()
    if not ue:
        return {"ok": False, "exit": 1, "output": "No UE pod found"}
    cmd = f"kubectl -n oran-ran exec {shlex.quote(ue)} -- sh -lc {shlex.quote(script)}"
    return run_cmd(cmd, timeout=timeout)

def get_ue_tunnel():
    r = exec_in_ue("ip -o -4 addr show oaitun_ue1 2>/dev/null || true", timeout=10)
    out = r["output"]
    m = re.search(r"inet\s+([0-9.]+/\d+)", out)
    return {
        "present": "oaitun_ue1" in out,
        "ip": m.group(1) if m else "",
        "raw": out
    }

def parse_ping_loss(output):
    m = re.search(r"(\d+(?:\.\d+)?)%\s+packet loss", output)
    return m.group(1) + "%" if m else "unknown"

def parse_throughput(output):
    m = re.search(r"speed_download_Bps=([0-9.]+)", output)
    if not m:
        return "unknown"
    bps = float(m.group(1)) * 8.0
    mbps = bps / 1000000.0
    return f"{mbps:.2f} Mbps"

def create_run_dir(action):
    d = RUNS_DIR / f"{now_id()}-{action}"
    d.mkdir(parents=True, exist_ok=True)
    return d

def save_result(run_dir, action, result, extra=None):
    out_file = run_dir / "output.log"
    out_file.write_text(result.get("output", ""), encoding="utf-8", errors="ignore")
    summary = {
        "action": action,
        "time": datetime.now().isoformat(timespec="seconds"),
        "ok": result.get("ok", False),
        "exit": result.get("exit", -1),
        "run_dir": str(run_dir),
        "log_file": "output.log",
        "extra": extra or {}
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary

def latest_summaries(limit=8):
    rows = []
    for d in sorted(RUNS_DIR.glob("*"), reverse=True):
        s = d / "summary.json"
        if s.exists():
            try:
                rows.append(json.loads(s.read_text()))
            except Exception:
                pass
        if len(rows) >= limit:
            break
    return rows

def load_last_ownership():
    if not LAST_OWNERSHIP_FILE.exists():
        return {}
    try:
        return json.loads(LAST_OWNERSHIP_FILE.read_text())
    except Exception:
        return {}

def run_ci_for_gnb(pod_name, label):
    if not pod_name:
        return {"label": label, "pod": "", "ok": False, "output": "pod not found"}

    local_port = random.randint(21000, 25000)
    pf_log = f"/tmp/oran_pf_{local_port}.log"

    script = f"""
set +e
kubectl -n oran-ran port-forward pod/{shlex.quote(pod_name)} {local_port}:9090 > {pf_log} 2>&1 &
PF=$!
sleep 3
echo "POD={pod_name}"
echo "----- ci get_single_rnti -----"
timeout 4 bash -lc 'printf "ci get_single_rnti\\r\\n" | nc 127.0.0.1 {local_port}'
echo "----- ci fetch_du_by_ue_id 1 -----"
timeout 4 bash -lc 'printf "ci fetch_du_by_ue_id 1\\r\\n" | nc 127.0.0.1 {local_port}'
kill "$PF" 2>/dev/null || true
sleep 1
"""
    r = run_cmd(script, timeout=18)
    return {
        "label": label,
        "pod": pod_name,
        "ok": r["ok"],
        "exit": r["exit"],
        "output": r["output"]
    }

def ownership_summary(data):
    owner = "unknown"
    active = 0
    for key in ["gnb_a", "gnb_b"]:
        out = data.get(key, {}).get("output", "")
        if "single UE RNTI" in out and "connected to ue_id 1" in out:
            active += 1
            owner = key.replace("_", "-").upper()
    return {"active_ues": active, "serving": owner}

@app.route("/")
def index():
    return render_template(
        "index.html",
        grafana_url=GRAFANA_URL,
        prometheus_url=PROMETHEUS_URL,
        lab_ip=LAB_IP
    )

@app.route("/api/status")
def api_status():
    ran_items = kpods("oran-ran")
    core_items = kpods("oran-core")
    mon_items = kpods("monitoring")

    ran = [pod_row(x) for x in ran_items if x.get("metadata", {}).get("name", "").startswith(("oai-gnb", "oai-nr-ue"))]
    core = [pod_row(x) for x in core_items if x.get("metadata", {}).get("name", "").startswith(("open5gs-amf", "open5gs-smf", "open5gs-upf"))]
    mon = [pod_row(x) for x in mon_items]

    gnb_a, gnb_b, ue = find_ran_pods()
    tunnel = get_ue_tunnel()
    own = load_last_ownership()
    own_sum = ownership_summary(own)

    return jsonify({
        "time": datetime.now().isoformat(timespec="seconds"),
        "links": {
            "grafana": GRAFANA_URL,
            "prometheus": PROMETHEUS_URL
        },
        "pods": {
            "gnb_a": gnb_a,
            "gnb_b": gnb_b,
            "ue": ue
        },
        "ran": ran,
        "core": core,
        "monitoring": mon,
        "counts": {
            "ran_ready": sum(1 for x in ran if x["ready"]),
            "ran_total": len(ran),
            "core_ready": sum(1 for x in core if x["ready"]),
            "core_total": len(core),
            "monitoring_ready": sum(1 for x in mon if x["ready"]),
            "monitoring_total": len(mon),
            "active_ues": own_sum["active_ues"],
            "serving": own_sum["serving"]
        },
        "ue_tunnel": tunnel,
        "traffic_active": list(TRAFFIC_PROCS.keys()),
        "recent_runs": latest_summaries(6)
    })

@app.route("/api/ownership", methods=["POST"])
def api_ownership():
    run_dir = create_run_dir("ci-ownership")
    gnb_a, gnb_b, ue = find_ran_pods()

    data = {
        "time": datetime.now().isoformat(timespec="seconds"),
        "ue": ue,
        "gnb_a": run_ci_for_gnb(gnb_a, "gNB-A"),
        "gnb_b": run_ci_for_gnb(gnb_b, "gNB-B")
    }

    LAST_OWNERSHIP_FILE.write_text(json.dumps(data, indent=2), encoding="utf-8")
    out = json.dumps(data, indent=2)
    summary = save_result(run_dir, "ci-ownership", {"ok": True, "exit": 0, "output": out}, ownership_summary(data))
    return jsonify({"summary": summary, "ownership": data})

@app.route("/api/action/<action>", methods=["POST"])
def api_action(action):
    run_dir = create_run_dir(action)

    if action == "health":
        cmd = """
echo "===== RAN pods ====="
kubectl -n oran-ran get pods -o wide
echo
echo "===== Core pods ====="
kubectl -n oran-core get pods -o wide
echo
echo "===== Monitoring pods ====="
kubectl -n monitoring get pods -o wide || true
echo
echo "===== Services ====="
kubectl -n monitoring get svc -o wide || true
"""
        r = run_cmd(cmd, timeout=40)
        summary = save_result(run_dir, action, r)
        return jsonify({"summary": summary})

    if action == "validate":
        r = run_cmd("timeout 300 ./scripts/validate-e2e.sh", timeout=330)
        summary = save_result(run_dir, action, r)
        return jsonify({"summary": summary})

    if action == "ping":
        script = """
echo "===== UE tunnel ====="
ip addr show oaitun_ue1 || true
echo
echo "===== Ping DN gateway ====="
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
echo
echo "===== Ping internet ====="
ping -I oaitun_ue1 -c 4 8.8.8.8 || true
"""
        r = exec_in_ue(script, timeout=60)
        extra = {"packet_loss": parse_ping_loss(r["output"])}
        summary = save_result(run_dir, action, r, extra)
        return jsonify({"summary": summary})

    if action == "throughput":
        script = """
echo "===== Throughput download test over oaitun_ue1 ====="
echo "Target: Cloudflare speed test, 10 MB"
if command -v curl >/dev/null 2>&1; then
  curl -4 -L --interface oaitun_ue1 --connect-timeout 15 --max-time 90 \
    -o /dev/null \
    -w "http_code=%{http_code}\\ntime_total=%{time_total}\\nspeed_download_Bps=%{speed_download}\\nsize_download=%{size_download}\\n" \
    "https://speed.cloudflare.com/__down?bytes=10000000"
elif command -v wget >/dev/null 2>&1; then
  time wget -O /dev/null "https://speed.cloudflare.com/__down?bytes=10000000"
else
  echo "Neither curl nor wget is available inside the UE pod."
  exit 2
fi
"""
        r = exec_in_ue(script, timeout=120)
        extra = {"throughput": parse_throughput(r["output"])}
        summary = save_result(run_dir, action, r, extra)
        return jsonify({"summary": summary})

    if action == "video_stream":
        script = """
echo "===== Video-like stream test over oaitun_ue1 ====="
echo "Target: controlled 50 MB HTTP download"
if command -v curl >/dev/null 2>&1; then
  curl -4 -L --interface oaitun_ue1 --connect-timeout 15 --max-time 180 \
    -o /dev/null \
    -w "http_code=%{http_code}\\ntime_total=%{time_total}\\nspeed_download_Bps=%{speed_download}\\nsize_download=%{size_download}\\n" \
    "https://speed.cloudflare.com/__down?bytes=50000000"
else
  echo "curl is not available inside the UE pod."
  exit 2
fi
"""
        r = exec_in_ue(script, timeout=220)
        extra = {"throughput": parse_throughput(r["output"])}
        summary = save_result(run_dir, action, r, extra)
        return jsonify({"summary": summary})

    if action in ["start_light", "start_heavy"]:
        ue = find_ue_pod()
        if not ue:
            r = {"ok": False, "exit": 1, "output": "No UE pod found"}
            summary = save_result(run_dir, action, r)
            return jsonify({"summary": summary})

        tag = "light" if action == "start_light" else "heavy"
        log_file = run_dir / f"{tag}-traffic.log"

        if action == "start_light":
            loop = f"""
while true; do
  echo "===== $(date) light traffic ====="
  kubectl -n oran-ran exec {shlex.quote(ue)} -- sh -lc 'ping -I oaitun_ue1 -c 3 10.45.0.1 || true'
  sleep 5
done
"""
        else:
            loop = f"""
while true; do
  echo "===== $(date) heavy traffic ====="
  kubectl -n oran-ran exec {shlex.quote(ue)} -- sh -lc 'curl -4 -L --interface oaitun_ue1 --connect-timeout 15 --max-time 120 -o /dev/null -w "speed_download_Bps=%{{speed_download}}\\n" "https://speed.cloudflare.com/__down?bytes=25000000" || true'
  sleep 2
done
"""
        f = open(log_file, "a")
        proc = subprocess.Popen(loop, shell=True, cwd=str(BASE_DIR), stdout=f, stderr=subprocess.STDOUT, executable="/bin/bash", preexec_fn=os.setsid)
        TRAFFIC_PROCS[tag] = proc
        r = {"ok": True, "exit": 0, "output": f"Started {tag} traffic with local PID {proc.pid}. Log: {log_file}"}
        summary = save_result(run_dir, action, r, {"pid": proc.pid, "traffic": tag})
        return jsonify({"summary": summary})

    if action == "stop_traffic":
        stopped = []
        for tag, proc in list(TRAFFIC_PROCS.items()):
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                stopped.append({"tag": tag, "pid": proc.pid})
            except Exception:
                pass
            TRAFFIC_PROCS.pop(tag, None)
        r = {"ok": True, "exit": 0, "output": json.dumps({"stopped": stopped}, indent=2)}
        summary = save_result(run_dir, action, r, {"stopped": stopped})
        return jsonify({"summary": summary})

    r = {"ok": False, "exit": 1, "output": f"Unknown action: {action}"}
    summary = save_result(run_dir, action, r)
    return jsonify({"summary": summary}), 400

@app.route("/api/runs")
def api_runs():
    return jsonify(latest_summaries(20))

@app.route("/logs/<path:run_name>/<path:file_name>")
def logs(run_name, file_name):
    return send_from_directory(RUNS_DIR / run_name, file_name)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=APP_PORT)
PY

cat > "$APP_DIR/templates/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>O-RAN Lab Control Platform</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg: #07111f;
      --panel: #101c2e;
      --panel2: #16243a;
      --line: #263954;
      --text: #e6edf7;
      --muted: #90a4bd;
      --green: #49e58c;
      --red: #ff6473;
      --orange: #ffb454;
      --blue: #57a7ff;
      --purple: #b58cff;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background:
        radial-gradient(circle at top left, rgba(42, 126, 255, 0.18), transparent 34rem),
        radial-gradient(circle at top right, rgba(73, 229, 140, 0.12), transparent 32rem),
        var(--bg);
      color: var(--text);
      font-family: Inter, Arial, sans-serif;
    }
    header {
      padding: 26px 34px;
      border-bottom: 1px solid var(--line);
      background: rgba(7, 17, 31, 0.86);
      position: sticky;
      top: 0;
      z-index: 10;
      backdrop-filter: blur(8px);
    }
    .topbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 18px;
      flex-wrap: wrap;
    }
    h1 { margin: 0; font-size: 28px; letter-spacing: -0.03em; }
    .sub { color: var(--muted); margin-top: 8px; }
    main { padding: 26px 34px 50px; max-width: 1560px; margin: auto; }
    .buttons { display: flex; gap: 10px; flex-wrap: wrap; }
    button, a.btn {
      border: 1px solid var(--line);
      background: linear-gradient(180deg, #1a2a43, #101c2e);
      color: var(--text);
      padding: 10px 13px;
      border-radius: 12px;
      cursor: pointer;
      text-decoration: none;
      font-weight: 700;
      font-size: 13px;
    }
    button:hover, a.btn:hover { border-color: var(--blue); }
    button.primary { background: linear-gradient(180deg, #2767c7, #174681); }
    button.danger { background: linear-gradient(180deg, #6e2330, #43131c); }
    .grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px; }
    .grid2 { display: grid; grid-template-columns: 1.2fr 1fr; gap: 16px; }
    .grid3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
    .card {
      background: rgba(16, 28, 46, 0.92);
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 18px;
      box-shadow: 0 18px 40px rgba(0,0,0,0.22);
      overflow: hidden;
    }
    .card h2 { margin: 0 0 12px; font-size: 18px; }
    .metric { font-size: 42px; font-weight: 800; letter-spacing: -0.04em; }
    .label { color: var(--muted); font-size: 13px; margin-top: 5px; }
    .ok { color: var(--green); }
    .bad { color: var(--red); }
    .warn { color: var(--orange); }
    .blue { color: var(--blue); }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 6px 10px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: #0b1626;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
    .dot.ok { background: var(--green); }
    .dot.bad { background: var(--red); }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align: left; padding: 9px 8px; border-bottom: 1px solid rgba(38, 57, 84, 0.8); }
    th { color: var(--muted); font-weight: 700; }
    pre {
      background: #06101d;
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 14px;
      max-height: 360px;
      overflow: auto;
      white-space: pre-wrap;
      color: #cfe2ff;
    }
    .section { margin-top: 18px; }
    .arch {
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      gap: 12px;
      align-items: stretch;
    }
    .node {
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 14px;
      background: #0b1626;
      min-height: 116px;
    }
    .node strong { display: block; margin-bottom: 8px; color: #fff; }
    .node span { color: var(--muted); font-size: 13px; line-height: 1.5; }
    .flow {
      text-align: center;
      color: var(--blue);
      font-weight: 800;
      padding-top: 38px;
    }
    .small { font-size: 12px; color: var(--muted); }
    .actionbar {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 12px;
    }
    .action {
      background: #0b1626;
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 15px;
    }
    .action p { color: var(--muted); margin: 8px 0 14px; font-size: 13px; min-height: 36px; }
    @media (max-width: 1100px) {
      .grid, .grid2, .grid3, .actionbar, .arch { grid-template-columns: 1fr; }
      .flow { padding-top: 0; }
    }
  </style>
</head>
<body>
<header>
  <div class="topbar">
    <div>
      <h1>O-RAN Lab Control Platform</h1>
      <div class="sub">Live validation dashboard for Open5GS, OAI RAN, UE tunnel, traffic, and handover readiness.</div>
    </div>
    <div class="buttons">
      <button class="primary" onclick="refreshStatus()">Reload status</button>
      <a class="btn" href="{{ grafana_url }}" target="_blank">Open Grafana</a>
      <a class="btn" href="{{ prometheus_url }}" target="_blank">Open Prometheus</a>
    </div>
  </div>
</header>

<main>
  <div class="grid">
    <div class="card">
      <h2>5G Core</h2>
      <div class="metric" id="coreMetric">-</div>
      <div class="label">AMF / SMF / UPF ready</div>
    </div>
    <div class="card">
      <h2>RAN + UE</h2>
      <div class="metric" id="ranMetric">-</div>
      <div class="label">gNB-A / gNB-B / NR-UE ready</div>
    </div>
    <div class="card">
      <h2>Active UE</h2>
      <div class="metric" id="ueMetric">-</div>
      <div class="label" id="servingGnb">Serving gNB unknown</div>
    </div>
    <div class="card">
      <h2>UE Tunnel</h2>
      <div class="metric" id="tunMetric">-</div>
      <div class="label" id="tunIp">oaitun_ue1</div>
    </div>
  </div>

  <div class="section card">
    <h2>Validation Control Buttons</h2>
    <div class="actionbar">
      <div class="action">
        <strong>CI ownership check</strong>
        <p>Checks which gNB currently owns UE ID 1 using OAI CI commands.</p>
        <button onclick="runOwnership()">Run ownership</button>
      </div>
      <div class="action">
        <strong>E2E validation</strong>
        <p>Runs your freeze-pack validate-e2e.sh script and stores evidence.</p>
        <button onclick="runAction('validate')">Run E2E</button>
      </div>
      <div class="action">
        <strong>Ping test</strong>
        <p>Tests DN gateway and internet through oaitun_ue1.</p>
        <button onclick="runAction('ping')">Run ping</button>
      </div>
      <div class="action">
        <strong>Throughput test</strong>
        <p>Downloads test data through the UE tunnel and estimates Mbps.</p>
        <button onclick="runAction('throughput')">Run throughput</button>
      </div>
      <div class="action">
        <strong>Video-like stream</strong>
        <p>Runs a larger controlled 50 MB download through the UE tunnel.</p>
        <button onclick="runAction('video_stream')">Run stream test</button>
      </div>
      <div class="action">
        <strong>Light traffic</strong>
        <p>Starts continuous low-rate traffic for stability observation.</p>
        <button onclick="runAction('start_light')">Start light</button>
      </div>
      <div class="action">
        <strong>Heavy traffic</strong>
        <p>Starts repeated larger downloads. Use only for stress testing.</p>
        <button onclick="runAction('start_heavy')">Start heavy</button>
      </div>
      <div class="action">
        <strong>Stop traffic</strong>
        <p>Stops background traffic started from this dashboard session.</p>
        <button class="danger" onclick="runAction('stop_traffic')">Stop traffic</button>
      </div>
    </div>
  </div>

  <div class="section grid2">
    <div class="card">
      <h2>RAN Pods</h2>
      <table>
        <thead><tr><th>Pod</th><th>Ready</th><th>IP</th><th>Restarts</th></tr></thead>
        <tbody id="ranTable"></tbody>
      </table>
    </div>
    <div class="card">
      <h2>Core Pods</h2>
      <table>
        <thead><tr><th>Pod</th><th>Ready</th><th>IP</th><th>Restarts</th></tr></thead>
        <tbody id="coreTable"></tbody>
      </table>
    </div>
  </div>

  <div class="section card">
    <h2>Architecture</h2>
    <div class="arch">
      <div class="node">
        <strong>Cloud Infrastructure</strong>
        <span>K3s Kubernetes node<br>Multus N2/N3 networks<br>Monitoring namespace</span>
      </div>
      <div class="flow">N2 / N3</div>
      <div class="node">
        <strong>5G Core</strong>
        <span>Open5GS AMF<br>Open5GS SMF<br>Open5GS UPF<br>DNN: oai</span>
      </div>
      <div class="flow">NGAP / GTP-U</div>
      <div class="node">
        <strong>RAN and UE</strong>
        <span>OAI gNB-A PCI 0<br>OAI gNB-B PCI 1<br>OAI NR-UE<br>RFsim socket</span>
      </div>
    </div>
    <div class="small" style="margin-top: 14px;">
      Current project state: E2E baseline is recoverable. N2 handover trigger path works, but true handover is still under debug because target-side RA/Msg3 fails.
    </div>
  </div>

  <div class="section grid2">
    <div class="card">
      <h2>Latest Action Output</h2>
      <pre id="console">Ready.</pre>
    </div>
    <div class="card">
      <h2>Recent Evidence Runs</h2>
      <table>
        <thead><tr><th>Time</th><th>Action</th><th>Status</th><th>Extra</th></tr></thead>
        <tbody id="runsTable"></tbody>
      </table>
    </div>
  </div>
</main>

<script>
async function refreshStatus() {
  const r = await fetch('/api/status');
  const s = await r.json();

  document.getElementById('coreMetric').textContent = `${s.counts.core_ready}/${s.counts.core_total}`;
  document.getElementById('ranMetric').textContent = `${s.counts.ran_ready}/${s.counts.ran_total}`;
  document.getElementById('ueMetric').textContent = s.counts.active_ues;
  document.getElementById('servingGnb').textContent = `Serving: ${s.counts.serving}`;
  document.getElementById('tunMetric').textContent = s.ue_tunnel.present ? 'UP' : 'DOWN';
  document.getElementById('tunMetric').className = s.ue_tunnel.present ? 'metric ok' : 'metric bad';
  document.getElementById('tunIp').textContent = s.ue_tunnel.ip || 'No UE tunnel IP detected';

  fillTable('ranTable', s.ran);
  fillTable('coreTable', s.core);
  fillRuns(s.recent_runs);
}

function fillTable(id, rows) {
  const el = document.getElementById(id);
  el.innerHTML = rows.map(p => `
    <tr>
      <td>${p.name}</td>
      <td>${p.ready ? '<span class="ok">READY</span>' : '<span class="bad">NOT READY</span>'}</td>
      <td>${p.ip || '-'}</td>
      <td>${p.restarts}</td>
    </tr>
  `).join('');
}

function fillRuns(rows) {
  const el = document.getElementById('runsTable');
  el.innerHTML = rows.map(x => `
    <tr>
      <td>${x.time || '-'}</td>
      <td>${x.action || '-'}</td>
      <td>${x.ok ? '<span class="ok">PASS</span>' : '<span class="bad">FAIL</span>'}</td>
      <td><span class="small">${JSON.stringify(x.extra || {})}</span></td>
    </tr>
  `).join('');
}

async function runAction(action) {
  document.getElementById('console').textContent = `Running ${action}...`;
  const r = await fetch(`/api/action/${action}`, {method: 'POST'});
  const data = await r.json();
  document.getElementById('console').textContent = JSON.stringify(data, null, 2);
  await refreshStatus();
}

async function runOwnership() {
  document.getElementById('console').textContent = 'Running CI ownership check...';
  const r = await fetch('/api/ownership', {method: 'POST'});
  const data = await r.json();
  document.getElementById('console').textContent = JSON.stringify(data.ownership, null, 2);
  await refreshStatus();
}

refreshStatus();
setInterval(refreshStatus, 10000);
</script>
</body>
</html>
HTML

cat > "$RUN_SCRIPT" <<'RUN'
#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$HOME/oran-e2e-freeze"
APP_DIR="$BASE_DIR/web-dashboard"
PORT="${ORAN_DASHBOARD_PORT:-18080}"

cd "$APP_DIR"

if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi

. .venv/bin/activate
pip install -q -r requirements.txt

echo "Starting O-RAN Lab Control Platform..."
echo "Open: http://192.168.1.142:${PORT}"
python3 app.py
RUN

cat > "$STOP_SCRIPT" <<'STOP'
#!/usr/bin/env bash
set +e
pkill -f "web-dashboard/app.py" 2>/dev/null || true
if command -v fuser >/dev/null 2>&1; then
  fuser -k 18080/tcp 2>/dev/null || true
fi
echo "Stopped O-RAN dashboard processes on port 18080 if they were running."
STOP

chmod +x "$RUN_SCRIPT" "$STOP_SCRIPT"

echo "Real O-RAN platform installed."
echo "Stop old server:"
echo "$STOP_SCRIPT"
echo "Start platform:"
echo "$RUN_SCRIPT"
echo "Open:"
echo "http://192.168.1.142:18080"
