import os
import re
import json
import time
import subprocess
from pathlib import Path
from datetime import datetime
from flask import Flask, render_template, jsonify
from multi_ue_api import register_multi_ue_routes
from handover_api import handover_bp
from radio_profile_api import radio_bp
from real_frequency_api import real_freq_bp

BASE_DIR = Path.home() / "oran-e2e-freeze"
PROOF_DIR = Path.home() / "oran-proof"
RUNS_DIR = PROOF_DIR / "web-dashboard-runs"
RUNS_DIR.mkdir(parents=True, exist_ok=True)

LAB_IP = os.environ.get("ORAN_LAB_IP", "192.168.1.142")
GRAFANA_URL = f"http://{LAB_IP}:30300/d/oran-5g-lab-ops/o-ran-5g-lab-operations-dashboard?orgId=1&from=now-1h&to=now&timezone=browser&var-datasource=prometheus&refresh=10s"
PROMETHEUS_URL = f"http://{LAB_IP}:30090"

app = Flask(__name__)
app.register_blueprint(real_freq_bp, url_prefix="/api/real-frequency")
app.register_blueprint(handover_bp)


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
    return jsonify({
        "ok": result["ok"],
        "exit": result["exit"],
        "action": action,
        "summary": summary,
        "output": result["output"],
    })


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

    # New F1-split format: "Active serving DU : oai-du0" / "oai-du1"
    du_match = re.search(r"Active serving DU\s*:\s*(oai-du[01]|unknown)", text)
    if du_match:
        du_name = du_match.group(1)
        serving = "DU0" if du_name == "oai-du0" else "DU1" if du_name == "oai-du1" else "unknown"
        tunnel_up = ">>> SERVING UE1 <<<" in text
        details.update({
            "serving": serving,
            "active_ues": 1 if tunnel_up else 0,
            "du_id": du_name,
            "source": str(ownership_logs[0]),
        })
        return details

    # Legacy format fallback (gNB-A / gNB-B)
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
    # Prefer reading UE1 serveraddr (fast, no log scrape needed)
    serveraddr = run_cmd(
        "kubectl -n oran-ran get cm oai-nrue-config "
        "-o jsonpath='{.data.nr-ue\\.conf}' 2>/dev/null "
        "| sed -n 's/.*serveraddr[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' | head -1 || true",
        timeout=8,
    )["output"].strip()
    if "du0" in serveraddr or serveraddr == "server":
        return "DU0"
    if "du1" in serveraddr:
        return "DU1"

    # Fallback: check DU logs for recent RNTI activity
    du0_hit = run_cmd(
        "kubectl -n oran-ran logs -l app=oai-du0 --since=3m 2>/dev/null "
        "| grep -i 'RNTI' | tail -n1 || true",
        timeout=8,
    )["output"]
    du1_hit = run_cmd(
        "kubectl -n oran-ran logs -l app=oai-du1 --since=3m 2>/dev/null "
        "| grep -i 'RNTI' | tail -n1 || true",
        timeout=8,
    )["output"]

    if du0_hit and not du1_hit:
        return "DU0"
    if du1_hit and not du0_hit:
        return "DU1"
    if du0_hit and du1_hit:
        return "DU0+DU1"
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


def active_multi_ue_tunnel_count():
    """Count attached UEs by checking oaitun_ue1 in UE1-UE5 pods."""
    selectors = ["app=oai-nr-ue"] + [f"app=oai-nr-ue-{i}" for i in range(2, 6)]
    count = 0

    for selector in selectors:
        try:
            pods_raw = subprocess.check_output([
                "kubectl", "-n", "oran-ran", "get", "pod",
                "-l", selector,
                "--field-selector=status.phase=Running",
                "-o", "json",
            ], text=True, timeout=10)
            pods = json.loads(pods_raw).get("items", [])
        except Exception:
            continue

        if not pods:
            continue

        pod = pods[0].get("metadata", {}).get("name", "")
        if not pod:
            continue

        try:
            tunnel = subprocess.run([
                "kubectl", "-n", "oran-ran", "exec", pod, "--",
                "sh", "-lc",
                "ip -4 addr show oaitun_ue1 2>/dev/null | grep -q 'inet '",
            ], text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            if tunnel.returncode == 0:
                count += 1
        except Exception:
            continue

    return count


@app.route("/api/status")
def api_status():
    try:
        ran = pod_list("oran-ran", r"^(oai-cu|oai-du|oai-gnb|oai-gnb-b|oai-nr-ue)")  # F1 split: CU/DUs were missing
        core = pod_list("oran-core", r"open5gs-(amf|smf|upf)")
        monitoring = pod_list("monitoring", r"(grafana|prometheus|alertmanager|kube-state|node-exporter|operator)")

        pods = get_pods()
        ue_ip = get_ue_ip()
        ownership = latest_ownership_details()

        serving = ownership["serving"]
        if serving == "unknown":
            serving = guess_serving_from_logs(pods)

        active_ues = max(ownership["active_ues"], active_multi_ue_tunnel_count())
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
RAN_NS="oran-ran"

# Determine UE1 active DU from serveraddr in ConfigMap
SERVERADDR=$(kubectl -n "$RAN_NS" get cm oai-nrue-config \
  -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
  | sed -n 's/.*serveraddr[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

if [ -z "$SERVERADDR" ]; then
  SERVERADDR=$(kubectl -n "$RAN_NS" get deploy oai-nr-ue -o json 2>/dev/null \
    | python3 -c '
import json,sys
a=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["args"]
print(a[a.index("--rfsimulator.serveraddr")+1] if "--rfsimulator.serveraddr" in a else "")
' 2>/dev/null || true)
fi

case "$SERVERADDR" in
  oai-du0-rfsim|server) ACTIVE_DU="oai-du0" ;;
  oai-du1-rfsim)        ACTIVE_DU="oai-du1" ;;
  *) ACTIVE_DU="unknown" ;;
esac

echo "UE1 serveraddr    : ${SERVERADDR:-not found}"
echo "Active serving DU : $ACTIVE_DU"
echo ""

# UE1 pod and tunnel
UE_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-nr-ue \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "UE1 pod           : ${UE_POD:-NOT FOUND}"
if [ -n "$UE_POD" ]; then
  TUNNEL=$(kubectl -n "$RAN_NS" exec "$UE_POD" -- \
    sh -c 'ip -br addr show oaitun_ue1 2>/dev/null || echo NONE' 2>/dev/null || echo NONE)
  echo "UE1 oaitun_ue1    : $TUNNEL"
fi
echo ""

# DU0
echo "===== DU0 (oai-du0) ====="
DU0_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-du0 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
DU0_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-du0 \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "Pod    : ${DU0_POD:-NOT FOUND}  Phase: $DU0_PHASE"
if [ "$ACTIVE_DU" = "oai-du0" ]; then
  echo "Status : >>> SERVING UE1 <<<"
  if [ -n "$DU0_POD" ]; then
    echo "--- UE activity (DU0 last 60s) ---"
    kubectl -n "$RAN_NS" logs "$DU0_POD" --since=60s 2>/dev/null \
      | grep -E "RNTI|UE.*connect|RRC.*Reconfig|Qm [0-9]|dlsch_rounds" \
      | tail -12 || echo "(no recent UE activity)"
  fi
else
  echo "Status : not serving UE1"
fi
echo ""

# DU1
echo "===== DU1 (oai-du1) ====="
DU1_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-du1 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
DU1_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-du1 \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "Pod    : ${DU1_POD:-NOT FOUND}  Phase: $DU1_PHASE"
if [ "$ACTIVE_DU" = "oai-du1" ]; then
  echo "Status : >>> SERVING UE1 <<<"
  if [ -n "$DU1_POD" ]; then
    echo "--- UE activity (DU1 last 60s) ---"
    kubectl -n "$RAN_NS" logs "$DU1_POD" --since=60s 2>/dev/null \
      | grep -E "RNTI|UE.*connect|RRC.*Reconfig|Qm [0-9]|dlsch_rounds" \
      | tail -12 || echo "(no recent UE activity)"
  fi
else
  echo "Status : not serving UE1"
fi
echo ""

# CU (split: CU-CP + CU-UP)
echo "===== CU-CP (oai-cu-cp) ====="
CUCP_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-cp \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
CUCP_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-cp \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "Pod    : ${CUCP_POD:-NOT FOUND}  Phase: $CUCP_PHASE"
echo "===== CU-UP (oai-cu-up) ====="
CUUP_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-up \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
CUUP_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-up \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "Pod    : ${CUUP_POD:-NOT FOUND}  Phase: $CUUP_PHASE"
echo ""

echo "VERDICT=SERVING_DU_CHECK_DONE"
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
kubectl -n oran-ran get pods -o wide | egrep 'oai-cu|oai-du|oai-gnb|oai-nr-ue|NAME' || fail=1

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


def action_report():
    cmd = r'''
set -u
RAN_NS="oran-ran"
CORE_NS="oran-core"
SEP="─────────────────────────────────────────────────────────"

echo "╔══════════════════════════════════════════════════════╗"
echo "║      O-RAN F1-Split Lab — Platform Analysis          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "Generated : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Host      : $(hostname)  /  kernel $(uname -r)"
echo "PLMN      : 999/70   DNN: oai   AMF: 10.10.0.101:38412"
echo ""

echo "$SEP"
echo "1. KUBERNETES NODE"
echo "$SEP"
kubectl get nodes -o wide 2>/dev/null || echo "(kubectl error)"
echo ""
echo "Resource usage:"
kubectl top nodes 2>/dev/null || echo "(metrics-server not available)"
echo ""
echo "Disk:"
df -h / /var/lib 2>/dev/null | tail -n+1 || true
echo ""

echo "$SEP"
echo "2. POD HEALTH SUMMARY"
echo "$SEP"
echo "--- Core (oran-core) ---"
kubectl -n "$CORE_NS" get pods -o wide 2>/dev/null || echo "(error)"
echo ""
echo "--- RAN (oran-ran) ---"
kubectl -n "$RAN_NS" get pods -o wide 2>/dev/null || echo "(error)"
echo ""
echo "--- Monitoring (monitoring) ---"
kubectl -n monitoring get pods --no-headers 2>/dev/null \
  | awk '{printf "  %-45s %s/%s\n", $1, $2, $3}' | head -12 || echo "(error)"
echo ""

echo "$SEP"
echo "3. F1-SPLIT RAN TOPOLOGY"
echo "$SEP"

CUCP_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-cp \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
CUCP_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-cp \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "CU-CP: ${CUCP_POD:-NOT FOUND}  [$CUCP_PHASE]"
CUUP_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-up \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
CUUP_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-cu-up \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "CU-UP: ${CUUP_POD:-NOT FOUND}  [$CUUP_PHASE]"

DU0_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-du0 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
DU0_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-du0 \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
DU0_MCS=$(kubectl -n "$RAN_NS" get deploy oai-du0 -o json 2>/dev/null \
  | python3 -c '
import json,sys
a=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["args"]
v=a[a.index("--MACRLCs.[0].dl_max_mcs")+1] if "--MACRLCs.[0].dl_max_mcs" in a else "none(adaptive)"
print(v)' 2>/dev/null || echo "?")
echo "DU0 : ${DU0_POD:-NOT FOUND}  [$DU0_PHASE]  dl_max_mcs=$DU0_MCS"

DU1_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-du1 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
DU1_PHASE=$(kubectl -n "$RAN_NS" get pod -l app=oai-du1 \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
DU1_MCS=$(kubectl -n "$RAN_NS" get deploy oai-du1 -o json 2>/dev/null \
  | python3 -c '
import json,sys
a=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["args"]
v=a[a.index("--MACRLCs.[0].dl_max_mcs")+1] if "--MACRLCs.[0].dl_max_mcs" in a else "none(adaptive)"
print(v)' 2>/dev/null || echo "?")
echo "DU1 : ${DU1_POD:-NOT FOUND}  [$DU1_PHASE]  dl_max_mcs=$DU1_MCS"
echo ""

echo "$SEP"
echo "4. UE1 — SERVING DU + USER PLANE"
echo "$SEP"

SERVERADDR=$(kubectl -n "$RAN_NS" get cm oai-nrue-config \
  -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
  | sed -n 's/.*serveraddr[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
case "$SERVERADDR" in
  oai-du0-rfsim|server) ACTIVE_DU="oai-du0 (DU0)" ;;
  oai-du1-rfsim)        ACTIVE_DU="oai-du1 (DU1)" ;;
  *) ACTIVE_DU="unknown (serveraddr=${SERVERADDR:-empty})" ;;
esac
echo "UE1 serveraddr  : ${SERVERADDR:-not found}"
echo "Active serving  : $ACTIVE_DU"
echo ""

UE_POD=$(kubectl -n "$RAN_NS" get pod -l app=oai-nr-ue \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "UE1 pod         : ${UE_POD:-NOT FOUND}"
if [ -n "$UE_POD" ]; then
  TUNNEL=$(kubectl -n "$RAN_NS" exec "$UE_POD" -- \
    sh -c 'ip -br addr show oaitun_ue1 2>/dev/null || echo NONE' 2>/dev/null || echo NONE)
  echo "oaitun_ue1      : $TUNNEL"
  echo ""
  echo "--- UE1 ping: DN gateway (10.45.0.1) ---"
  kubectl -n "$RAN_NS" exec "$UE_POD" -- \
    ping -I oaitun_ue1 -c 4 -W 2 10.45.0.1 2>/dev/null || echo "FAIL"
  echo ""
  echo "--- UE1 ping: Internet (8.8.8.8) ---"
  kubectl -n "$RAN_NS" exec "$UE_POD" -- \
    ping -I oaitun_ue1 -c 4 -W 2 8.8.8.8 2>/dev/null || echo "FAIL"
else
  echo "oaitun_ue1      : NO POD — skipping pings"
fi
echo ""

echo "$SEP"
echo "5. ALL UE TUNNEL STATUS (UE1–UE5)"
echo "$SEP"
for app in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  pod=$(kubectl -n "$RAN_NS" get pod -l app="$app" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$pod" ]; then
    tun=$(kubectl -n "$RAN_NS" exec "$pod" -- \
      sh -c 'ip -br addr show | grep oaitun || echo NO_TUNNEL' 2>/dev/null || echo NO_TUNNEL)
    echo "$app ($pod): $tun"
  else
    echo "$app: pod not running"
  fi
done
echo ""

echo "$SEP"
echo "6. SERVING DU — RECENT UE ACTIVITY"
echo "$SEP"
case "$SERVERADDR" in
  oai-du0-rfsim|server) ACTIVE_DU_APP="oai-du0"; ACTIVE_DU_POD="$DU0_POD" ;;
  oai-du1-rfsim)        ACTIVE_DU_APP="oai-du1"; ACTIVE_DU_POD="$DU1_POD" ;;
  *) ACTIVE_DU_APP=""; ACTIVE_DU_POD="" ;;
esac
if [ -n "$ACTIVE_DU_POD" ]; then
  echo "Serving DU pod: $ACTIVE_DU_POD (last 90s)"
  kubectl -n "$RAN_NS" logs "$ACTIVE_DU_POD" --since=90s 2>/dev/null \
    | grep -E "RNTI|Qm [0-9]|dlsch_rounds|RRC.*Reconfig|UE.*connect" \
    | tail -20 || echo "(no matching log lines)"
else
  echo "(could not determine serving DU pod)"
fi
echo ""

echo "$SEP"
echo "7. CORE NETWORK"
echo "$SEP"
AMF_POD=$(kubectl -n "$CORE_NS" get pod -l app=open5gs-amf \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "--- AMF ($AMF_POD) — last registrations ---"
if [ -n "$AMF_POD" ]; then
  kubectl -n "$CORE_NS" logs "$AMF_POD" --tail=200 2>/dev/null \
    | grep -E "Registration.Complete|InitialContext|PDU.Session|IMSI|NGAP" \
    | tail -15 || echo "(no matching lines)"
  echo ""
  echo "AMF NGAP socket:"
  kubectl -n "$CORE_NS" exec "$AMF_POD" -- \
    ss -lnp 2>/dev/null | grep 38412 || echo "(not found)"
else
  echo "AMF pod not found"
fi
echo ""

SMF_POD=$(kubectl -n "$CORE_NS" get pod -l app=open5gs-smf \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "--- SMF ($SMF_POD) — active PDU sessions ---"
if [ -n "$SMF_POD" ]; then
  kubectl -n "$CORE_NS" logs "$SMF_POD" --tail=200 2>/dev/null \
    | grep -E "PDU.Session.Establishment|10\.45\.0\.|DNN|IMSI|Create.Session" \
    | tail -15 || echo "(no matching lines)"
else
  echo "SMF pod not found"
fi
echo ""

UPF_POD=$(kubectl -n "$CORE_NS" get pod -l app=open5gs-upf \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
echo "--- UPF ($UPF_POD) — GTP-U socket ---"
if [ -n "$UPF_POD" ]; then
  kubectl -n "$CORE_NS" exec "$UPF_POD" -- \
    ss -lunp 2>/dev/null | grep -E '2152|8805' || echo "(GTP-U socket not found)"
else
  echo "UPF pod not found"
fi
echo ""

echo "$SEP"
echo "8. RECENT RUN HISTORY"
echo "$SEP"
find "$HOME/oran-proof" -maxdepth 3 -name summary.json 2>/dev/null \
  | sort -r | head -10 \
  | xargs -I{} python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(f"  {d.get(\"time\",\"?\"):<22} {d.get(\"action\",\"?\"):<18} {d.get(\"status\",\"?\")}")
except: pass
' {} 2>/dev/null || echo "(no run history)"
echo ""

echo "$SEP"
echo "VERDICT=REPORT_DONE"
'''
    return save_run("report", cmd, timeout=180)


def action_traffic_profile(action_name, gw_count, internet_count, packet_size, http_timeout):
    timeout = int(gw_count) + int(internet_count) + int(http_timeout) + 90

    cmd = f'''
set -u

echo "PROFILE={action_name}"
echo "GW_COUNT={gw_count}"
echo "INTERNET_COUNT={internet_count}"
echo "PACKET_SIZE={packet_size}"
echo "HTTP_TIMEOUT={http_timeout}"
echo

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{{.items[0].metadata.name}}' 2>/dev/null || true)
echo "UE_POD=$UE_POD"

if [ -z "$UE_POD" ]; then
  echo "UE pod not found"
  exit 1
fi

echo
echo "===== before traffic ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip -s link show oaitun_ue1 || true' 2>/dev/null || true

echo
echo "===== DN gateway traffic ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 -s {packet_size} -c {gw_count} 10.45.0.1' || true

echo
echo "===== internet traffic ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ping -I oaitun_ue1 -s {packet_size} -c {internet_count} 8.8.8.8' || true

echo
echo "===== HTTP download attempt ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
if command -v curl >/dev/null 2>&1; then
  timeout {http_timeout} curl --interface oaitun_ue1 -L --max-time {http_timeout} -o /tmp/oran-traffic-test.bin http://speedtest.tele2.net/10MB.zip || true
  ls -lh /tmp/oran-traffic-test.bin 2>/dev/null || true
elif command -v wget >/dev/null 2>&1; then
  timeout {http_timeout} wget -T {http_timeout} -O /tmp/oran-traffic-test.bin http://speedtest.tele2.net/10MB.zip || true
  ls -lh /tmp/oran-traffic-test.bin 2>/dev/null || true
else
  echo "No curl/wget in UE pod. Used ping traffic only."
fi
' 2>&1 || true

echo
echo "===== after traffic ====="
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip -s link show oaitun_ue1 || true' 2>/dev/null || true

exit 0
'''
    return save_run(action_name, cmd, timeout=timeout)


@app.route("/api/action/<action>", methods=["POST"])
@app.route("/api/run/<action>", methods=["POST"])
def api_action(action):
    if action == "ownership":
        return action_ownership()
    if action == "ping":
        return action_ping()
    if action == "stream":
        return action_stream()
    if action == "light_traffic":
        return action_traffic_profile("light_traffic", gw_count=10, internet_count=10, packet_size=300, http_timeout=8)
    if action == "throughput":
        return action_traffic_profile("throughput", gw_count=30, internet_count=30, packet_size=1200, http_timeout=15)
    if action == "heavy_traffic":
        return action_traffic_profile("heavy_traffic", gw_count=100, internet_count=80, packet_size=1200, http_timeout=30)
    if action == "report":
        return action_report()
    if action == "e2e":
        return action_e2e()
    if action == "stop_traffic":
        return action_stop_traffic()

    return save_run(action, f"echo 'Unknown action: {action}'; exit 1", timeout=5)


REAL_SLICE_PROFILES = {
    "embb":  {"sst": 1, "label": "eMBB",  "desc": "SST=1 — image, video, web, streaming, iperf TCP"},
    "urllc": {"sst": 2, "label": "URLLC", "desc": "SST=2 — UDP jitter/loss"},
    "mmtc":  {"sst": 3, "label": "mMTC",  "desc": "SST=3 — IoT-style small UDP"},
}

SLICE_TC_PROFILE = {
    "embb":  "15mbit / 256kb / 50ms",
    "urllc": "20mbit / 64kb / 5ms",
    "mmtc":  "2mbit / 32kb / 100ms",
}

REAL_SLICE_RESULTS_FILE = BASE_DIR / "web-dashboard" / "real-slice-results.json"


def _load_slice_rows():
    if REAL_SLICE_RESULTS_FILE.exists():
        try:
            return json.loads(REAL_SLICE_RESULTS_FILE.read_text())
        except Exception:
            return []
    return []


def _save_slice_row(row):
    rows = _load_slice_rows()
    rows = [r for r in rows if r.get("profile") != row.get("profile")]
    rows.insert(0, row)
    rows = rows[:20]
    REAL_SLICE_RESULTS_FILE.write_text(json.dumps(rows, indent=2))
    return rows


def _parse_slice_output(text, profile):
    info = REAL_SLICE_PROFILES.get(profile, {})
    row = {
        "profile":      profile,
        "label":        info.get("label", profile),
        "sst":          info.get("sst", "?"),
        "sd":           "0xffffff",
        "granted_sst":  "—",
        "tunnel_ip":    "—",
        "ping_avg_ms":  "—",
        "loss_pct":     "—",
        "tcp_mbps":     "—",
        "retransmits":  "—",
        "udp_loss_pct": "—",
        "udp_jitter_ms":"—",
        "tc_profile":   SLICE_TC_PROFILE.get(profile, "—"),
        "verdict":      "UNKNOWN",
        "time":         datetime.now().isoformat(timespec="seconds"),
    }

    # Split at RESTORE DEFAULT so the SST=1 restore step doesn't pollute parsing
    pre_restore = text.split("===== RESTORE DEFAULT")[0]

    # Granted SST (first occurrence = target switch, not restore)
    m = re.search(r"AMF granted: SST=(\d+)", pre_restore)
    if m:
        row["granted_sst"] = m.group(1)

    # Tunnel IP (first occurrence = target switch)
    m = re.search(r"Tunnel ready: pod=\S+ tunnel=(\S+)", pre_restore)
    if m:
        row["tunnel_ip"] = m.group(1).split("/")[0]

    # Ping avg and loss from validate-current-slice.sh (it runs ping -c 4)
    m = re.search(r"rtt min/avg/max/mdev = [0-9.]+/([0-9.]+)/", pre_restore)
    if m:
        row["ping_avg_ms"] = m.group(1)
    m = re.search(r"(\d+)% packet loss", pre_restore)
    if m:
        row["loss_pct"] = m.group(1) + "%"

    # TCP KPIs (eMBB only)
    m = re.search(r"Throughput Mbps: ([0-9.]+)", pre_restore)
    if m:
        row["tcp_mbps"] = m.group(1)
    m = re.search(r"TCP retransmits: (\d+)", pre_restore)
    if m:
        row["retransmits"] = m.group(1)

    # UDP KPIs (URLLC/mMTC)
    m = re.search(r"Packet loss percent: ([0-9.]+)", pre_restore)
    if m:
        row["udp_loss_pct"] = m.group(1) + "%"
    m = re.search(r"Estimated jitter ms: ([0-9.]+)", pre_restore)
    if m:
        row["udp_jitter_ms"] = m.group(1)

    # Verdict: switch outcome takes precedence over overall run outcome
    switch_ok = "VERDICT=REAL_SLICE_SWITCH_OK" in pre_restore
    switch_mismatch = "VERDICT=GRANTED_SLICE_MISMATCH" in pre_restore
    overall_ok = "VERDICT=OK\n" in pre_restore or pre_restore.rstrip().endswith("VERDICT=OK")
    overall_fail = "VERDICT=FAIL\n" in pre_restore or pre_restore.rstrip().endswith("VERDICT=FAIL")

    if switch_mismatch:
        row["verdict"] = "GRANTED_SLICE_MISMATCH"
    elif switch_ok and overall_ok:
        row["verdict"] = "PASS"
    elif switch_ok and overall_fail:
        row["verdict"] = "TRAFFIC_FAIL"
    elif switch_ok:
        row["verdict"] = "REAL_SLICE_SWITCH_OK"
    else:
        # Extract first non-trivial VERDICT line from pre-restore section
        verdicts = re.findall(r"VERDICT=([A-Z_]+)", pre_restore)
        if verdicts:
            row["verdict"] = verdicts[0]

    return row


@app.route("/api/real-slice/results", methods=["GET"])
def api_real_slice_results():
    return jsonify({"ok": True, "rows": _load_slice_rows()})


@app.route("/api/real-slice/<profile>", methods=["POST"])
def api_real_slice(profile):
    if profile not in REAL_SLICE_PROFILES:
        return jsonify({"ok": False, "error": f"Unknown slice profile: {profile}. Use: {list(REAL_SLICE_PROFILES)}"}), 400

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = RUNS_DIR / f"{ts}-real-slice-{profile}"
    run_dir.mkdir(parents=True, exist_ok=True)

    result = run_cmd(f"scripts/slicing/run-real-slice-traffic.sh {profile}", timeout=600)
    (run_dir / "output.log").write_text(result["output"] + "\n")

    row = _parse_slice_output(result["output"], profile)
    _save_slice_row(row)

    summary = {
        "time": datetime.now().isoformat(timespec="seconds"),
        "action": f"real-slice-{profile}",
        "ok": result["ok"],
        "exit": result["exit"],
        "run_dir": str(run_dir),
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2))

    return jsonify({
        "ok": result["ok"],
        "exit": result["exit"],
        "action": f"real-slice-{profile}",
        "summary": summary,
        "output": result["output"],
        "row": row,
    })


register_multi_ue_routes(app, run_cmd, BASE_DIR)


# BEGIN MIXED-DU HANDOVER API
try:
    from mixed_du_handover_api import install_mixed_du_handover_api
    install_mixed_du_handover_api(app)
    print("[dashboard] Mixed-DU handover API installed")
except Exception as exc:
    print(f"[dashboard] Mixed-DU handover API not installed: {exc}")
# END MIXED-DU HANDOVER API




# BEGIN RADIO PROFILE API BLUEPRINT
app.register_blueprint(radio_bp, url_prefix="/api/radio")
print("[dashboard] Radio profile blueprint installed at /api/radio")
# END RADIO PROFILE API BLUEPRINT

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=18080)
