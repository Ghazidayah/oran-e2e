import os
import re
import json
import time
import subprocess
from pathlib import Path
from datetime import datetime
from flask import Flask, render_template, jsonify

BASE_DIR = Path.home() / "oran-e2e-freeze"
PROOF_DIR = Path.home() / "oran-proof"
RUNS_DIR = PROOF_DIR / "web-dashboard-runs"
RUNS_DIR.mkdir(parents=True, exist_ok=True)

LAB_IP = os.environ.get("ORAN_LAB_IP", "192.168.1.142")
GRAFANA_URL = f"http://{LAB_IP}:30300"
PROMETHEUS_URL = f"http://{LAB_IP}:30090"

app = Flask(__name__)


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
        )
        return {"ok": p.returncode == 0, "exit": p.returncode, "output": p.stdout.strip()}
    except subprocess.TimeoutExpired as e:
        out = e.stdout or ""
        if isinstance(out, bytes):
            out = out.decode(errors="ignore")
        return {"ok": False, "exit": 124, "output": out.strip() + "\nTIMEOUT"}
    except Exception as e:
        return {"ok": False, "exit": 99, "output": str(e)}


def save_run(action, cmd, timeout=120):
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = RUNS_DIR / f"{ts}-{action}"
    run_dir.mkdir(parents=True, exist_ok=True)

    result = run_cmd(cmd, timeout=timeout)
    (run_dir / "output.log").write_text(result["output"] + "\n")

    summary = {
        "time": datetime.now().isoformat(timespec="seconds"),
        "action": action,
        "ok": result["ok"],
        "exit": result["exit"],
        "run_dir": str(run_dir),
        "log_file": "output.log",
    }

    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    return jsonify({"summary": summary, "output": result["output"]})


def pod_list(namespace, pattern_text):
    raw = run_cmd(f"kubectl -n {namespace} get pods -o json 2>/dev/null", timeout=15)
    rows = []

    if not raw["output"]:
        return rows

    try:
        data = json.loads(raw["output"])
    except Exception:
        return rows

    pattern = re.compile(pattern_text)

    for item in data.get("items", []):
        meta = item.get("metadata", {})
        status = item.get("status", {})
        name = meta.get("name", "")

        if not pattern.search(name):
            continue

        cstats = status.get("containerStatuses", [])
        ready = bool(cstats) and all(c.get("ready", False) for c in cstats)
        restarts = sum(c.get("restartCount", 0) for c in cstats)

        rows.append({
            "name": name,
            "phase": status.get("phase", ""),
            "ready": ready,
            "ip": status.get("podIP", ""),
            "node": status.get("hostIP", ""),
            "restarts": restarts,
            "age": meta.get("creationTimestamp", ""),
        })

    return rows


def get_pods():
    ue = run_cmd(
        "kubectl -n oran-ran get pod -l app=oai-nr-ue "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true",
        timeout=10,
    )["output"].strip()

    gnb_a = run_cmd(
        "kubectl -n oran-ran get pod -o name 2>/dev/null | "
        "grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | "
        "head -n1 | cut -d/ -f2",
        timeout=10,
    )["output"].strip()

    gnb_b = run_cmd(
        "kubectl -n oran-ran get pod -o name 2>/dev/null | "
        "grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2",
        timeout=10,
    )["output"].strip()

    return {"ue": ue, "gnb_a": gnb_a, "gnb_b": gnb_b}


def get_ue_ip():
    ue = get_pods().get("ue", "")
    if not ue:
        return ""

    cmd = (
        f"kubectl -n oran-ran exec {ue} -- sh -c "
        "\"ip -4 addr show oaitun_ue1 2>/dev/null | awk '/inet /{print $2; exit}'\" "
        "2>/dev/null || true"
    )
    return run_cmd(cmd, timeout=10)["output"].strip()


def latest_ownership_details():
    details = {
        "serving": "unknown",
        "active_ues": 0,
        "rnti": "",
        "du_id": "",
        "source": "none",
    }

    ownership_logs = sorted(RUNS_DIR.glob("*-ownership/output.log"), reverse=True)
    if not ownership_logs:
        return details

    text = ownership_logs[0].read_text(errors="ignore")

    sections = {
        "gNB-A": re.search(r"===== gnb-a ownership check =====(.*?)(===== gnb-b ownership check =====|===== UE tunnel =====)", text, re.S),
        "gNB-B": re.search(r"===== gnb-b ownership check =====(.*?)(===== UE tunnel =====|$)", text, re.S),
    }

    for name, match in sections.items():
        if not match:
            continue

        block = match.group(1)
        rnti = re.search(r"single UE RNTI\s+([0-9a-fA-F]+)", block)
        du = re.search(r"gNB_DU_id\s+([0-9]+)\s+is connected to ue_id\s+([0-9]+)", block)

        if rnti and du:
            details.update({
                "serving": name,
                "active_ues": 1,
                "rnti": rnti.group(1),
                "du_id": du.group(1),
                "source": str(ownership_logs[0]),
            })
            return details

    return details


def guess_serving_from_logs(pods):
    a_hit = ""
    b_hit = ""

    if pods.get("gnb_a"):
        a_hit = run_cmd(
            f"kubectl -n oran-ran logs {pods['gnb_a']} --since=3m 2>/dev/null | "
            "grep -i 'UE RNTI' | tail -n1 || true",
            timeout=8,
        )["output"]

    if pods.get("gnb_b"):
        b_hit = run_cmd(
            f"kubectl -n oran-ran logs {pods['gnb_b']} --since=3m 2>/dev/null | "
            "grep -i 'UE RNTI' | tail -n1 || true",
            timeout=8,
        )["output"]

    if a_hit and not b_hit:
        return "gNB-A"
    if b_hit and not a_hit:
        return "gNB-B"
    if a_hit and b_hit:
        return "mixed"
    return "unknown"


def recent_runs():
    rows = []
    for f in sorted(RUNS_DIR.glob("*/summary.json"), reverse=True)[:12]:
        try:
            rows.append(json.loads(f.read_text()))
        except Exception:
            pass
    return rows


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def api_status():
    try:
        ran = pod_list("oran-ran", r"^(oai-gnb|oai-gnb-b|oai-nr-ue)")
        core = pod_list("oran-core", r"open5gs-(amf|smf|upf)")
        monitoring = pod_list("monitoring", r"(grafana|prometheus|alertmanager|kube-state|node-exporter|operator)")

        pods = get_pods()
        ue_ip = get_ue_ip()
        ownership = latest_ownership_details()

        serving = ownership["serving"]
        if serving == "unknown":
            serving = guess_serving_from_logs(pods)

        active_ues = ownership["active_ues"]
        if ue_ip and active_ues == 0:
            active_ues = 1

        counts = {
            "ran_ready": sum(1 for p in ran if p.get("ready")),
            "ran_total": len(ran),
            "core_ready": sum(1 for p in core if p.get("ready")),
            "core_total": len(core),
            "monitoring_ready": sum(1 for p in monitoring if p.get("ready")),
            "monitoring_total": len(monitoring),
            "active_ues": active_ues,
            "serving": serving,
        }

        return jsonify({
            "ok": True,
            "time": datetime.now().isoformat(timespec="seconds"),
            "counts": counts,
            "ownership": ownership,
            "ue_ip": ue_ip,
            "pods": pods,
            "ran": ran,
            "core": core,
            "monitoring": monitoring,
            "links": {
                "grafana": GRAFANA_URL,
                "prometheus": PROMETHEUS_URL,
            },
            "recent_runs": recent_runs(),
        })

    except Exception as e:
        return jsonify({
            "ok": False,
            "error": str(e),
            "time": datetime.now().isoformat(timespec="seconds"),
        }), 500


@app.route("/api/live_metrics")
def api_live_metrics():
    pods = get_pods()
    ue = pods.get("ue", "")

    if not ue:
        return jsonify({"ok": False, "error": "UE pod not found"})

    cmd = f"""
kubectl -n oran-ran exec {ue} -- sh -c '
ip=$(ip -4 addr show oaitun_ue1 2>/dev/null | awk "/inet /{{print \\$2; exit}}")
rx=$(cat /sys/class/net/oaitun_ue1/statistics/rx_bytes 2>/dev/null || echo 0)
tx=$(cat /sys/class/net/oaitun_ue1/statistics/tx_bytes 2>/dev/null || echo 0)
echo "$ip $rx $tx"
' 2>/dev/null || true
"""

    out1 = run_cmd(cmd, timeout=10)["output"].strip().split()
    time.sleep(1)
    out2 = run_cmd(cmd, timeout=10)["output"].strip().split()

    if len(out2) < 3:
        return jsonify({"ok": False, "error": "could not read oaitun_ue1 metrics", "ue": ue})

    ip = out2[0]
    rx2 = int(out2[1])
    tx2 = int(out2[2])

    rx_mbps = 0.0
    tx_mbps = 0.0

    if len(out1) >= 3:
        rx1 = int(out1[1])
        tx1 = int(out1[2])
        rx_mbps = max(0, (rx2 - rx1) * 8 / 1_000_000)
        tx_mbps = max(0, (tx2 - tx1) * 8 / 1_000_000)

    return jsonify({
        "ok": True,
        "time": datetime.now().isoformat(timespec="seconds"),
        "ue": ue,
        "ip": ip,
        "rx_bytes": rx2,
        "tx_bytes": tx2,
        "rx_mbps": round(rx_mbps, 3),
        "tx_mbps": round(tx_mbps, 3),
        "error": "",
    })


def action_ownership():
    cmd = r'''
set -u

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
GNB_A_POD=$(kubectl -n oran-ran get pod -o name 2>/dev/null | grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
GNB_B_POD=$(kubectl -n oran-ran get pod -o name 2>/dev/null | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)

echo "UE_POD=$UE_POD"
echo "GNB_A_POD=$GNB_A_POD"
echo "GNB_B_POD=$GNB_B_POD"
echo

check_gnb() {
  name="$1"
  pod="$2"
  port="$3"

  echo "===== $name ownership check ====="

  if [ -z "$pod" ]; then
    echo "$name pod not found"
    return 0
  fi

  kubectl -n oran-ran port-forward pod/"$pod" "$port":9090 >/tmp/oran-${name}-pf.log 2>&1 &
  PF=$!
  sleep 3

  echo "----- ci get_single_rnti -----"
  timeout 5 bash -lc "printf 'ci get_single_rnti\r\n' | nc 127.0.0.1 $port" || true

  echo
  echo "----- ci fetch_du_by_ue_id 1 -----"
  timeout 5 bash -lc "printf 'ci fetch_du_by_ue_id 1\r\n' | nc 127.0.0.1 $port" || true

  kill "$PF" >/dev/null 2>&1 || true
  wait "$PF" >/dev/null 2>&1 || true
  echo
}

check_gnb "gnb-a" "$GNB_A_POD" 19090
check_gnb "gnb-b" "$GNB_B_POD" 19092

echo "===== UE tunnel ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip -br addr show oaitun_ue1 || true' 2>/dev/null || true

exit 0
'''
    return save_run("ownership", cmd, timeout=90)


def action_ping():
    cmd = r'''
set -u
fail=0

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "UE_POD=$UE_POD"

kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "----- PING DN GW -----"
ping -I oaitun_ue1 -c 5 10.45.0.1
echo "----- PING INTERNET -----"
ping -I oaitun_ue1 -c 4 8.8.8.8
' || fail=1

exit "$fail"
'''
    return save_run("ping", cmd, timeout=120)


def action_stream():
    cmd = r'''
set -u

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "UE_POD=$UE_POD"

echo "===== before traffic ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip -s link show oaitun_ue1 || true' 2>/dev/null || true

echo
echo "===== video-like traffic simulation ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
echo "----- large packet DN gateway ping -----"
ping -I oaitun_ue1 -s 1200 -c 60 10.45.0.1 || true

echo "----- large packet internet ping -----"
ping -I oaitun_ue1 -s 1200 -c 40 8.8.8.8 || true

echo "----- HTTP download attempt -----"
if command -v curl >/dev/null 2>&1; then
  curl --interface oaitun_ue1 -L --max-time 30 -o /tmp/oran-stream-test.bin http://speedtest.tele2.net/10MB.zip || true
  ls -lh /tmp/oran-stream-test.bin 2>/dev/null || true
elif command -v wget >/dev/null 2>&1; then
  wget -T 30 -O /tmp/oran-stream-test.bin http://speedtest.tele2.net/10MB.zip || true
  ls -lh /tmp/oran-stream-test.bin 2>/dev/null || true
else
  echo "No curl/wget in UE pod. Used ping traffic only."
fi
' 2>&1 || true

echo
echo "===== after traffic ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip -s link show oaitun_ue1 || true' 2>/dev/null || true

exit 0
'''
    return save_run("stream", cmd, timeout=220)


def action_e2e():
    cmd = r'''
set -u
fail=0

echo "===== Core pods ====="
kubectl -n oran-core get pods -o wide | egrep 'open5gs-(amf|smf|upf)|NAME' || fail=1

echo
echo "===== RAN pods ====="
kubectl -n oran-ran get pods -o wide | egrep 'oai-gnb|oai-nr-ue|NAME' || fail=1

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo
echo "UE_POD=$UE_POD"

echo
echo "===== UE tunnel ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip addr show oaitun_ue1; ip route' || fail=1

echo
echo "===== DN gateway ping ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 -c 5 10.45.0.1' || fail=1

echo
echo "===== Internet ping ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 -c 4 8.8.8.8' || fail=1

exit "$fail"
'''
    return save_run("e2e", cmd, timeout=180)


def action_stop_traffic():
    return save_run("stop_traffic", "echo 'No background traffic process active.'; exit 0", timeout=10)


@app.route("/api/action/<action>", methods=["POST"])
@app.route("/api/run/<action>", methods=["POST"])
def api_action(action):
    if action == "ownership":
        return action_ownership()
    if action == "ping":
        return action_ping()
    if action == "stream":
        return action_stream()
    if action in ("throughput", "light_traffic", "heavy_traffic"):
        return action_stream()
    if action == "e2e":
        return action_e2e()
    if action == "stop_traffic":
        return action_stop_traffic()

    return save_run(action, f"echo 'Unknown action: {action}'; exit 1", timeout=5)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=18080)
