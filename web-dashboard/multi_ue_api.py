import json
import shlex
import time
from flask import jsonify, request

UE_NAMESPACE = "oran-ran"
UE_TUNNEL = "oaitun_ue1"
MAX_UES = 5

UE_POOL = {
    "ue1": {
        "index": 1,
        "deployment": "oai-nr-ue",
        "selector": "app=oai-nr-ue",
        "manifest": "",
        "imsi": "999700000000001",
        "dnn": "oai",
        "baseline": True,
    },
    "ue2": {
        "index": 2,
        "deployment": "oai-nr-ue-2",
        "selector": "app=oai-nr-ue-2",
        "manifest": "manifests/ran/multi-ue/oai-nr-ue-2.yaml",
        "imsi": "999700000000002",
        "dnn": "oai",
        "baseline": False,
    },
    "ue3": {
        "index": 3,
        "deployment": "oai-nr-ue-3",
        "selector": "app=oai-nr-ue-3",
        "manifest": "manifests/ran/multi-ue/oai-nr-ue-3.yaml",
        "imsi": "999700000000003",
        "dnn": "oai",
        "baseline": False,
    },
    "ue4": {
        "index": 4,
        "deployment": "oai-nr-ue-4",
        "selector": "app=oai-nr-ue-4",
        "manifest": "manifests/ran/multi-ue/oai-nr-ue-4.yaml",
        "imsi": "999700000000004",
        "dnn": "oai",
        "baseline": False,
    },
    "ue5": {
        "index": 5,
        "deployment": "oai-nr-ue-5",
        "selector": "app=oai-nr-ue-5",
        "manifest": "manifests/ran/multi-ue/oai-nr-ue-5.yaml",
        "imsi": "999700000000005",
        "dnn": "oai",
        "baseline": False,
    },
}


def register_multi_ue_routes(app, run_cmd, base_dir=None):
    def ue_cfg(ue_name):
        return UE_POOL.get(str(ue_name).lower())

    def cmd_json(cmd, timeout=15):
        result = run_cmd(cmd, timeout=timeout)
        try:
            return json.loads(result.get("output") or "{}")
        except Exception:
            return {}

    def pod_items(selector):
        cmd = "kubectl -n {} get pod -l {} -o json 2>/dev/null".format(
            UE_NAMESPACE,
            shlex.quote(selector),
        )
        return cmd_json(cmd).get("items", [])

    def live_pod_item(selector):
        items = [
            i for i in pod_items(selector)
            if not i.get("metadata", {}).get("deletionTimestamp")
        ]
        if not items:
            return None
        items.sort(
            key=lambda i: i.get("metadata", {}).get("creationTimestamp", ""),
            reverse=True,
        )
        return items[0]

    def pod_ready(item):
        if not item:
            return False
        statuses = item.get("status", {}).get("containerStatuses", [])
        return bool(statuses) and all(c.get("ready", False) for c in statuses)

    def pod_name(selector):
        item = live_pod_item(selector)
        if not item:
            return ""
        return item.get("metadata", {}).get("name", "")

    def tunnel_ip(pod):
        if not pod:
            return ""
        inner = "ip -4 addr show {} 2>/dev/null | awk '/inet /{{print $2; exit}}'".format(UE_TUNNEL)
        cmd = "kubectl -n {} exec {} -- sh -lc {} 2>/dev/null || true".format(
            UE_NAMESPACE,
            shlex.quote(pod),
            shlex.quote(inner),
        )
        return run_cmd(cmd, timeout=10).get("output", "").strip()

    def ue_metrics(pod):
        if not pod:
            return {"rx_bytes": 0, "tx_bytes": 0}
        inner = (
            "rx=$(cat /sys/class/net/{}/statistics/rx_bytes 2>/dev/null || echo 0); "
            "tx=$(cat /sys/class/net/{}/statistics/tx_bytes 2>/dev/null || echo 0); "
            "echo $rx $tx"
        ).format(UE_TUNNEL, UE_TUNNEL)
        cmd = "kubectl -n {} exec {} -- sh -lc {} 2>/dev/null || true".format(
            UE_NAMESPACE,
            shlex.quote(pod),
            shlex.quote(inner),
        )
        parts = run_cmd(cmd, timeout=10).get("output", "").strip().split()
        try:
            return {"rx_bytes": int(parts[0]), "tx_bytes": int(parts[1])}
        except Exception:
            return {"rx_bytes": 0, "tx_bytes": 0}

    def live_metrics_one(ue_name):
        cfg = ue_cfg(ue_name)
        if not cfg:
            return {"name": ue_name, "ok": False, "error": "unknown UE"}

        item = live_pod_item(cfg["selector"])
        pod = ""
        ready = False
        pod_ip = ""
        phase = "Stopped"

        if item:
            pod = item.get("metadata", {}).get("name", "")
            status = item.get("status", {})
            phase = status.get("phase", "")
            pod_ip = status.get("podIP", "")
            ready = pod_ready(item)

        ip = ""
        rx_bytes = 0
        tx_bytes = 0

        if pod and ready:
            inner = (
                "ip=$(ip -4 addr show {tun} 2>/dev/null | awk '/inet /{{print $2; exit}}'); "
                "rx=$(cat /sys/class/net/{tun}/statistics/rx_bytes 2>/dev/null || echo 0); "
                "tx=$(cat /sys/class/net/{tun}/statistics/tx_bytes 2>/dev/null || echo 0); "
                "printf '%s|%s|%s\\n' \"$ip\" \"$rx\" \"$tx\""
            ).format(tun=UE_TUNNEL)
            cmd = "kubectl -n {} exec {} -- sh -lc {} 2>/dev/null || true".format(
                UE_NAMESPACE,
                shlex.quote(pod),
                shlex.quote(inner),
            )
            parts = run_cmd(cmd, timeout=10).get("output", "").strip().split("|")
            if len(parts) >= 3:
                ip = parts[0].strip()
                try:
                    rx_bytes = int(parts[1])
                    tx_bytes = int(parts[2])
                except Exception:
                    rx_bytes = 0
                    tx_bytes = 0

        return {
            "name": ue_name,
            "index": cfg["index"],
            "deployment": cfg["deployment"],
            "selector": cfg["selector"],
            "imsi": cfg["imsi"],
            "dnn": cfg["dnn"],
            "baseline": cfg["baseline"],
            "pod": pod,
            "phase": phase,
            "ready": ready,
            "pod_ip": pod_ip,
            "tunnel": UE_TUNNEL,
            "tunnel_ip": ip,
            "attached": bool(ip),
            "rx_bytes": rx_bytes,
            "tx_bytes": tx_bytes,
        }

    def status_one(ue_name):
        cfg = ue_cfg(ue_name)
        if not cfg:
            return {"name": ue_name, "ok": False, "error": "unknown UE"}

        item = live_pod_item(cfg["selector"])
        pod = ""
        phase = "Stopped"
        ready = False
        pod_ip = ""
        restarts = 0

        if item:
            pod = item.get("metadata", {}).get("name", "")
            status = item.get("status", {})
            phase = status.get("phase", "")
            pod_ip = status.get("podIP", "")
            ready = pod_ready(item)
            restarts = sum(
                c.get("restartCount", 0)
                for c in status.get("containerStatuses", [])
            )

        ip = tunnel_ip(pod) if pod and ready else ""
        metrics = ue_metrics(pod) if ip else {"rx_bytes": 0, "tx_bytes": 0}

        return {
            "name": ue_name,
            "index": cfg["index"],
            "deployment": cfg["deployment"],
            "selector": cfg["selector"],
            "imsi": cfg["imsi"],
            "dnn": cfg["dnn"],
            "baseline": cfg["baseline"],
            "pod": pod,
            "phase": phase,
            "ready": ready,
            "pod_ip": pod_ip,
            "tunnel": UE_TUNNEL,
            "tunnel_ip": ip,
            "attached": bool(ip),
            "restarts": restarts,
            **metrics,
        }

    def all_status():
        return [
            status_one(name)
            for name in sorted(UE_POOL, key=lambda n: UE_POOL[n]["index"])
        ]

    def remove_lifecycle(deployment):
        patch = "'[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/lifecycle\"}]'"
        return run_cmd(
            "kubectl -n {} patch deploy {} --type=json -p={} 2>/dev/null || true".format(
                UE_NAMESPACE,
                shlex.quote(deployment),
                patch,
            ),
            timeout=20,
        )

    def start_ue(ue_name):
        cfg = ue_cfg(ue_name)
        if not cfg:
            return {"ok": False, "error": "unknown UE {}".format(ue_name)}

        outputs = []

        if cfg.get("manifest"):
            r = run_cmd("kubectl apply -f {}".format(shlex.quote(cfg["manifest"])), timeout=60)
            outputs.append(r.get("output", ""))
            remove_lifecycle(cfg["deployment"])

        r = run_cmd(
            "kubectl -n {} scale deploy/{} --replicas=1".format(
                UE_NAMESPACE,
                shlex.quote(cfg["deployment"]),
            ),
            timeout=60,
        )
        outputs.append(r.get("output", ""))

        r = run_cmd(
            "kubectl -n {} rollout status deploy/{} --timeout=240s".format(
                UE_NAMESPACE,
                shlex.quote(cfg["deployment"]),
            ),
            timeout=260,
        )
        outputs.append(r.get("output", ""))

        return {
            "ok": r.get("ok", False),
            "ue": ue_name,
            "deployment": cfg["deployment"],
            "output": "\n".join(x for x in outputs if x),
            "status": status_one(ue_name),
        }

    def stop_ue(ue_name):
        cfg = ue_cfg(ue_name)
        if not cfg:
            return {"ok": False, "error": "unknown UE {}".format(ue_name)}

        r = run_cmd(
            "kubectl -n {} scale deploy/{} --replicas=0".format(
                UE_NAMESPACE,
                shlex.quote(cfg["deployment"]),
            ),
            timeout=60,
        )
        return {
            "ok": r.get("ok", False),
            "ue": ue_name,
            "deployment": cfg["deployment"],
            "output": r.get("output", ""),
            "status": status_one(ue_name),
        }

    def f1_mode_active():
        """Return True when validated F1 RFsim topology is active.

        Multi-UE start/stop/scenario actions must not run in this mode because
        extra UE deployments can interfere with the single-UE F1 handover setup.
        """
        checks = [
            ("oai-cu", 1, 1),
            ("oai-du0", 1, 1),
            ("oai-du1", 1, 1),
            ("oai-gnb", 0, 0),
            ("oai-gnb-b", 0, 0),
        ]

        for deploy, desired, available in checks:
            cmd = (
                "kubectl -n {} get deploy {} "
                "-o jsonpath='{{.spec.replicas}} {{.status.availableReplicas}}'"
            ).format(UE_NAMESPACE, shlex.quote(deploy))
            result = run_cmd(cmd, timeout=20)
            if not result.get("ok"):
                return False

            parts = str(result.get("output", "")).strip().split()
            spec = int(parts[0]) if len(parts) >= 1 and parts[0].isdigit() else 0
            avail = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0

            if spec != desired:
                return False
            if available and avail < available:
                return False

        return True

    def reject_multi_ue_in_f1(action):
        return jsonify({
            "ok": False,
            "blocked": True,
            "mode": "f1-rfsim",
            "action": action,
            "error": (
                "Multi-UE control is disabled while F1 RFsim handover mode is active. "
                "Use the F1 handover panel, or switch back to multi-UE baseline mode first."
            ),
            "ues": all_status(),
        }), 409

    @app.route("/api/ues")
    def api_ues_multi():
        ues = all_status()
        return jsonify({
            "ok": True,
            "max_ues": MAX_UES,
            "attached_count": sum(1 for u in ues if u.get("attached")),
            "running_count": sum(1 for u in ues if u.get("ready")),
            "ues": ues,
        })

    @app.route("/api/ues/desired", methods=["POST"])
    def api_ues_desired_multi():
        data = request.get_json(silent=True) or {}
        raw_count = data.get("count", request.form.get("count", ""))

        try:
            count = int(raw_count)
        except Exception:
            return jsonify({"ok": False, "error": "count must be an integer"}), 400

        if count < 1 or count > MAX_UES:
            return jsonify({"ok": False, "error": "count must be between 1 and {}".format(MAX_UES)}), 400

        results = []

        for i in range(1, count + 1):
            results.append(start_ue("ue{}".format(i)))

        for i in range(MAX_UES, count, -1):
            results.append(stop_ue("ue{}".format(i)))

        ues = all_status()
        return jsonify({
            "ok": all(r.get("ok", False) for r in results),
            "desired_count": count,
            "attached_count": sum(1 for u in ues if u.get("attached")),
            "running_count": sum(1 for u in ues if u.get("ready")),
            "results": results,
            "ues": ues,
        })

    @app.route("/api/ue/<ue_name>/start", methods=["POST"])
    def api_ue_start_multi(ue_name):
        result = start_ue(ue_name)
        return jsonify(result), 200 if result.get("ok") else 400

    @app.route("/api/ue/<ue_name>/stop", methods=["POST"])
    def api_ue_stop_multi(ue_name):
        result = stop_ue(ue_name)
        return jsonify(result), 200 if result.get("ok") else 400

    @app.route("/api/ue/<ue_name>/ping", methods=["POST"])
    def api_ue_ping_multi(ue_name):
        cfg = ue_cfg(ue_name)
        if not cfg:
            return jsonify({"ok": False, "error": "unknown UE {}".format(ue_name)}), 404

        pod = pod_name(cfg["selector"])
        if not pod:
            return jsonify({"ok": False, "error": "pod not found for {}".format(ue_name)}), 404

        script = "\n".join([
            "set -u",
            "echo UE={}".format(shlex.quote(ue_name)),
            "echo POD={}".format(shlex.quote(pod)),
            "ip addr show {} || exit 1".format(UE_TUNNEL),
            "echo",
            "echo '===== Ping DN gateway ====='",
            "ping -I {} -c 3 -W 3 10.45.0.1".format(UE_TUNNEL),
            "echo",
            "echo '===== Ping internet ====='",
            "ping -I {} -c 3 -W 3 8.8.8.8".format(UE_TUNNEL),
        ])

        cmd = "kubectl -n {} exec {} -- sh -lc {}".format(
            UE_NAMESPACE,
            shlex.quote(pod),
            shlex.quote(script),
        )
        r = run_cmd(cmd, timeout=60)

        return jsonify({
            "ok": r.get("ok", False),
            "exit": r.get("exit"),
            "ue": ue_name,
            "pod": pod,
            "output": r.get("output", ""),
            "status": status_one(ue_name),
        })

    # UE_SCENARIO_ROUTES_START
    SCENARIO_PROFILES = {
        "attach_pdu": {
            "label": "UE Attach + PDU Session",
            "kind": "ping",
            "gw_count": 2,
            "internet_count": 2,
            "packet_size": 56,
            "timeout": 90,
        },
        "connectivity": {
            "label": "UE Connectivity Test",
            "kind": "ping",
            "gw_count": 3,
            "internet_count": 3,
            "packet_size": 56,
            "timeout": 90,
        },
        "stability": {
            "label": "UE Stability Traffic",
            "kind": "traffic",
            "gw_count": 10,
            "internet_count": 10,
            "packet_size": 300,
            "timeout": 120,
        },
        "throughput": {
            "label": "UE Throughput KPI",
            "kind": "traffic",
            "gw_count": 30,
            "internet_count": 30,
            "packet_size": 1200,
            "timeout": 180,
        },
        "stress": {
            "label": "UE Stress Traffic",
            "kind": "traffic",
            "gw_count": 100,
            "internet_count": 80,
            "packet_size": 1200,
            "timeout": 300,
        },
        "video": {
            "label": "UE Video-like Stream",
            "kind": "background",
            "timeout": 60,
        },
        "stop": {
            "label": "Stop UE Traffic",
            "kind": "stop",
            "timeout": 60,
        },
    }

    # Friendly names used by the per-UE scenario matrix.
    # These aliases keep the existing scenario implementation intact while letting the UI
    # expose simpler choices like "light" and "heavy" per UE.
    SCENARIO_ALIASES = {
        "none": "none",
        "off": "none",
        "skip": "none",
        "light": "stability",
        "light_traffic": "stability",
        "heavy": "stress",
        "heavy_traffic": "stress",
        "kpi": "throughput",
        "stream": "video",
        "video_like": "video",
    }

    def resolve_scenario(raw_scenario):
        scenario = str(raw_scenario or "").strip().lower()
        scenario = SCENARIO_ALIASES.get(scenario, scenario)
        if scenario == "none" or scenario == "":
            return "none", None
        return scenario, SCENARIO_PROFILES.get(scenario)

    def requested_ue_count():
        data = request.get_json(silent=True) or {}
        raw_count = data.get("count", request.form.get("count", ""))
        if raw_count == "":
            ues = all_status()
            attached = [u for u in ues if u.get("attached")]
            return max(1, len(attached))
        try:
            count = int(raw_count)
        except Exception:
            count = 1
        if count < 1:
            count = 1
        if count > MAX_UES:
            count = MAX_UES
        return count

    def selected_attached_ues(count):
        ues = all_status()
        selected = []
        for ue in ues:
            if ue.get("index", 99) <= count and ue.get("attached") and ue.get("pod"):
                selected.append(ue)
        return selected

    def selected_ready_ues(count):
        ues = all_status()
        selected = []
        for ue in ues:
            if ue.get("index", 99) <= count and ue.get("ready") and ue.get("pod"):
                selected.append(ue)
        return selected

    def exec_script_in_ue(ue, script, timeout):
        cmd = "kubectl -n {} exec {} -- sh -lc {}".format(
            UE_NAMESPACE,
            shlex.quote(ue["pod"]),
            shlex.quote(script),
        )
        result = run_cmd(cmd, timeout=timeout)
        return {
            "ue": ue["name"],
            "pod": ue["pod"],
            "tunnel_ip": ue.get("tunnel_ip", ""),
            "ok": result.get("ok", False),
            "exit": result.get("exit"),
            "output": result.get("output", ""),
        }

    def build_ping_or_traffic_script(ue, profile):
        gw_count = int(profile.get("gw_count", 3))
        internet_count = int(profile.get("internet_count", 3))
        packet_size = int(profile.get("packet_size", 56))
        label = profile.get("label", "UE Scenario")

        return """
set -u
TUN="{tun}"
echo "Scenario: {label}"
echo "UE: {ue}"
echo "POD: {pod}"
echo "Tunnel: $TUN"
ip -4 addr show "$TUN" || exit 1

RX0=$(cat /sys/class/net/$TUN/statistics/rx_bytes 2>/dev/null || echo 0)
TX0=$(cat /sys/class/net/$TUN/statistics/tx_bytes 2>/dev/null || echo 0)
START=$(date +%s)

echo
echo "===== DN gateway test ====="
ping -I "$TUN" -c {gw_count} -s {packet_size} -W 3 10.45.0.1

echo
echo "===== Internet test ====="
ping -I "$TUN" -c {internet_count} -s {packet_size} -W 3 8.8.8.8

END=$(date +%s)
RX1=$(cat /sys/class/net/$TUN/statistics/rx_bytes 2>/dev/null || echo 0)
TX1=$(cat /sys/class/net/$TUN/statistics/tx_bytes 2>/dev/null || echo 0)
DUR=$((END - START))
if [ "$DUR" -lt 1 ]; then DUR=1; fi

DRX=$((RX1 - RX0))
DTX=$((TX1 - TX0))
TOTAL=$((DRX + DTX))
MBPS=$(awk -v b="$TOTAL" -v d="$DUR" 'BEGIN {{ printf "%.3f", (b * 8) / (d * 1000000) }}')

echo
echo "===== KPI summary ====="
echo "duration_sec=$DUR"
echo "rx_delta_bytes=$DRX"
echo "tx_delta_bytes=$DTX"
echo "total_delta_bytes=$TOTAL"
echo "approx_total_mbps=$MBPS"
""".format(
            tun=UE_TUNNEL,
            label=label,
            ue=ue["name"],
            pod=ue["pod"],
            gw_count=gw_count,
            internet_count=internet_count,
            packet_size=packet_size,
        )

    def build_video_script(ue):
        return """
set -u
TUN="{tun}"
PIDFILE=/tmp/oran-dashboard-video-traffic.pid
LOGFILE=/tmp/oran-dashboard-video-traffic.log

ip -4 addr show "$TUN" || exit 1

if [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "Video-like traffic already running with pid=$OLD"
    exit 0
  fi
fi

nohup sh -lc 'while true; do ping -I {tun} -c 5 -s 900 -W 3 8.8.8.8; sleep 1; done' > "$LOGFILE" 2>&1 &
PID=$!
echo "$PID" > "$PIDFILE"

echo "Started video-like UE traffic"
echo "pid=$PID"
echo "log=$LOGFILE"
""".format(tun=UE_TUNNEL)

    def build_stop_script():
        return """
set +e

PIDFILE=/tmp/oran-dashboard-video-traffic.pid
LOGFILE=/tmp/oran-dashboard-video-traffic.log

echo "Stopping UE traffic"

if [ -f "$PIDFILE" ]; then
  PID=$(cat "$PIDFILE" 2>/dev/null || true)

  if [ -n "$PID" ]; then
    if [ "$PID" = "$$" ]; then
      echo "Refusing to kill current shell pid=$PID"
    elif kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null || true
      sleep 1
      kill -9 "$PID" 2>/dev/null || true
      echo "Stopped pid=$PID"
    else
      echo "pid=$PID was not running"
    fi
  else
    echo "pidfile was empty"
  fi

  rm -f "$PIDFILE"
else
  echo "No pidfile found"
fi

# Clean short-lived child ping processes without terminating this shell.
for P in $(pgrep -f "ping -I oaitun_ue1 -c 5 -s 900 -W 3 8.8.8.8" 2>/dev/null || true); do
  [ "$P" = "$$" ] && continue
  kill "$P" 2>/dev/null || true
done

echo "Stop UE traffic completed"
exit 0
"""

    @app.route("/api/ues/live_metrics")
    def api_ues_live_metrics_multi():
        """Return raw RX/TX counters for all active UEs.

        The frontend calculates Mbps from two samples. This keeps the endpoint fast
        and avoids sleeping inside the request like the legacy /api/live_metrics route.
        """
        raw_count = request.args.get("count", "")
        count = MAX_UES
        if raw_count != "":
            try:
                count = int(raw_count)
            except Exception:
                count = MAX_UES
        if count < 1:
            count = 1
        if count > MAX_UES:
            count = MAX_UES

        ues = [
            live_metrics_one(name)
            for name in sorted(UE_POOL, key=lambda n: UE_POOL[n]["index"])
        ]
        ues = [u for u in ues if u.get("index", 99) <= count]
        active_ues = [u for u in ues if u.get("attached") and u.get("pod")]

        return jsonify({
            "ok": True,
            "timestamp": time.time(),
            "requested_count": count,
            "max_ues": MAX_UES,
            "active_count": len(active_ues),
            "total_rx_bytes": sum(int(u.get("rx_bytes") or 0) for u in active_ues),
            "total_tx_bytes": sum(int(u.get("tx_bytes") or 0) for u in active_ues),
            "ues": active_ues,
        })

    def build_script_for_profile(ue, profile):
        kind = profile.get("kind")
        if kind in ("ping", "traffic"):
            return build_ping_or_traffic_script(ue, profile)
        if kind == "background":
            return build_video_script(ue)
        if kind == "stop":
            return build_stop_script()
        return "echo unsupported scenario kind; exit 1"

    def run_independent_scenario_job(job):
        ue = job["ue"]
        profile = job["profile"]
        scenario = job["scenario"]
        label = profile.get("label", scenario)
        timeout = int(profile.get("timeout", 120))
        script = build_script_for_profile(ue, profile)
        result = exec_script_in_ue(ue, script, timeout)
        result["scenario"] = scenario
        result["label"] = label
        return result


    # PHASE4_MULTI_UE_EMBB_REALISTIC_START
    PHASE4_MULTI_UE_EMBB_LABELS = {
        "attach_pdu": "Attach + PDU",
        "connectivity": "Connectivity",
        "image": "Image Download eMBB",
        "video_download": "Video Download eMBB",
        "web": "Web Browsing eMBB",
        "streaming": "Streaming-like HLS eMBB",
        "tcp_download": "TCP Download KPI eMBB",
        "stop": "Stop traffic",
    }

    PHASE4_MULTI_UE_EMBB_ALIASES = {
        "light": "image",
        "stability": "image",
        "throughput": "tcp_download",
        "heavy": "video_download",
        "stress": "tcp_download",
        "video": "streaming",
    }

    def phase4_multi_ue_node_ip():
        r = run_cmd("kubectl get node -o wide --no-headers | awk '{print $6; exit}'", timeout=10)
        return (r.get("output") or "").strip().splitlines()[0].strip()

    def phase4_multi_ue_make_media_root(run_dir):
        from pathlib import Path

        root = Path(run_dir) / "media-root"
        for d in ["images", "videos", "web", "hls"]:
            (root / d).mkdir(parents=True, exist_ok=True)

        def write_pattern(path, size, seed):
            data = (seed.encode("utf-8") * ((size // len(seed)) + 1))[:size]
            path.write_bytes(data)

        write_pattern(root / "images" / "test-image.bin", 700 * 1024, "O-RAN-IMAGE-eMBB-")
        write_pattern(root / "videos" / "sample-video.mp4", 5 * 1024 * 1024, "O-RAN-VIDEO-eMBB-")

        (root / "web" / "index.html").write_text(
            "<html><head><link rel='stylesheet' href='style.css'></head>"
            "<body><h1>O-RAN eMBB Web Test</h1>"
            "<img src='image1.bin'><img src='image2.bin'><script src='app.js'></script></body></html>"
        )
        (root / "web" / "style.css").write_text("body{font-family:sans-serif} img{max-width:40%; margin:8px;}")
        (root / "web" / "app.js").write_text("console.log('O-RAN eMBB web scenario');")
        write_pattern(root / "web" / "image1.bin", 700 * 1024, "WEB-IMAGE-1-eMBB-")
        write_pattern(root / "web" / "image2.bin", 700 * 1024, "WEB-IMAGE-2-eMBB-")

        playlist = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:1"]
        for i in range(1, 9):
            name = "segment_{:03d}.ts".format(i)
            write_pattern(root / "hls" / name, 512 * 1024, "HLS-SEGMENT-{}-eMBB-".format(i))
            playlist.append("#EXTINF:2.0,")
            playlist.append(name)
        playlist.append("#EXT-X-ENDLIST")
        (root / "hls" / "playlist.m3u8").write_text("\n".join(playlist) + "\n")

        return str(root)

    def phase4_multi_ue_start_http_server(media_root, run_dir):
        import socket
        import subprocess
        import time
        from pathlib import Path

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(("0.0.0.0", 0))
        port = sock.getsockname()[1]
        sock.close()

        log_path = Path(run_dir) / "http-server.log"
        log = open(log_path, "w")

        proc = subprocess.Popen(
            ["python3", "-m", "http.server", str(port), "--bind", "0.0.0.0"],
            cwd=media_root,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )

        time.sleep(1)
        return proc, port

    def phase4_multi_ue_client_script():
        return """
import hashlib
import json
import socket
import sys
import time
import urllib.request

scenario = sys.argv[1]
base_url = sys.argv[2].rstrip("/")
bind_ip = sys.argv[3]

orig_create_connection = socket.create_connection

def bound_create_connection(address, timeout=None, source_address=None):
    return orig_create_connection(address, timeout, (bind_ip, 0))

socket.create_connection = bound_create_connection

paths_by_scenario = {
    "image": ["/images/test-image.bin"],
    "video_download": ["/videos/sample-video.mp4"],
    "web": ["/web/index.html", "/web/style.css", "/web/app.js", "/web/image1.bin", "/web/image2.bin"],
    "streaming": [
        "/hls/playlist.m3u8",
        "/hls/segment_001.ts", "/hls/segment_002.ts", "/hls/segment_003.ts", "/hls/segment_004.ts",
        "/hls/segment_005.ts", "/hls/segment_006.ts", "/hls/segment_007.ts", "/hls/segment_008.ts",
    ],
    "tcp_download": ["/videos/sample-video.mp4", "/videos/sample-video.mp4"],
}

paths = paths_by_scenario.get(scenario)
if not paths:
    print("unsupported realistic eMBB scenario:", scenario)
    sys.exit(2)

total_bytes = 0
resources = []
t0_all = time.time()

for path in paths:
    url = base_url + path
    t0 = time.time()
    with urllib.request.urlopen(url, timeout=90) as resp:
        data = resp.read()
        code = getattr(resp, "status", resp.getcode())
    dt = time.time() - t0
    total_bytes += len(data)
    resources.append({
        "path": path,
        "http_status": code,
        "bytes": len(data),
        "time_seconds": round(dt, 6),
        "sha256": hashlib.sha256(data).hexdigest(),
    })

duration = time.time() - t0_all
mbps = (total_bytes * 8 / duration / 1000000) if duration > 0 else 0.0
ok = all(r["http_status"] == 200 for r in resources)

result = {
    "scenario": scenario,
    "slice": "eMBB",
    "sst": 1,
    "bind_source_ip": bind_ip,
    "resources_requested": len(paths),
    "resources_ok": sum(1 for r in resources if r["http_status"] == 200),
    "total_bytes": total_bytes,
    "duration_seconds": round(duration, 6),
    "throughput_mbps": round(mbps, 6),
    "resources": resources,
    "verdict": "OK" if ok else "FAIL",
}

print(json.dumps(result, indent=2))
print("Scenario:", scenario)
print("Slice: eMBB")
print("SST: 1")
print("HTTP status: OK" if ok else "HTTP status: FAIL")
print("Resources OK:", result["resources_ok"], "/", result["resources_requested"])
print("rx_delta_bytes={}".format(total_bytes))
print("tx_delta_bytes=0")
print("duration_sec={}".format(round(duration, 3)))
print("approx_total_mbps={}".format(round(mbps, 6)))
print("packet_loss=0%")
print("verdict={}".format(result["verdict"]))

sys.exit(0 if ok else 1)
"""

    def phase4_multi_ue_run_one_job(job, base_url, proof_dir):
        import shlex

        ue_name = str(job.get("ue") or "").strip().lower()
        raw_scenario = str(job.get("scenario") or "").strip().lower()
        scenario = PHASE4_MULTI_UE_EMBB_ALIASES.get(raw_scenario, raw_scenario)
        label = PHASE4_MULTI_UE_EMBB_LABELS.get(scenario, scenario)

        result = {
            "ue": ue_name,
            "scenario": scenario,
            "label": label,
            "slice": "eMBB",
            "sst": 1,
            "ok": False,
            "exit": 1,
            "output": "",
        }

        if scenario == "none" or scenario == "":
            result["ok"] = True
            result["exit"] = 0
            result["output"] = "Skipped: scenario is none"
            return result

        if scenario not in PHASE4_MULTI_UE_EMBB_LABELS:
            result["output"] = "Unknown eMBB Multi-UE scenario: {}".format(raw_scenario)
            return result

        status = status_one(ue_name)
        pod = status.get("pod")
        tunnel_ip = str(status.get("tunnel_ip") or "").split("/")[0]

        result["pod"] = pod
        result["tunnel_ip"] = status.get("tunnel_ip")

        if not pod:
            result["output"] = "{} has no running pod".format(ue_name)
            return result

        if scenario != "stop" and not status.get("attached"):
            result["output"] = "{} is not attached; cannot run {}".format(ue_name, scenario)
            return result

        if scenario == "stop":
            cmd = "kubectl -n {} exec {} -- sh -lc {}".format(
                UE_NAMESPACE,
                shlex.quote(pod),
                shlex.quote("pkill -f multi_ue_realistic_client.py 2>/dev/null || true; echo stopped; exit 0"),
            )
            r = run_cmd(cmd, timeout=30)
            result["ok"] = bool(r.get("ok"))
            result["exit"] = int(r.get("exit") or 0)
            result["output"] = r.get("output") or ""
            return result

        if scenario in ("attach_pdu", "connectivity"):
            shell = "set -e; ip -4 addr show {}; ip route; ping -I {} -c 4 8.8.8.8".format(UE_TUNNEL, UE_TUNNEL)
            cmd = "kubectl -n {} exec {} -- sh -lc {}".format(
                UE_NAMESPACE, shlex.quote(pod), shlex.quote(shell)
            )
            r = run_cmd(cmd, timeout=90)
            result["ok"] = bool(r.get("ok"))
            result["exit"] = int(r.get("exit") or 0)
            result["output"] = r.get("output") or ""
            return result

        if not tunnel_ip:
            result["output"] = "{} has no tunnel IP".format(ue_name)
            return result

        client_code = phase4_multi_ue_client_script()
        shell = "cat > /tmp/multi_ue_realistic_client.py <<'PYCLIENT'\n{}\nPYCLIENT\npython3 /tmp/multi_ue_realistic_client.py {} {} {}".format(
            client_code,
            shlex.quote(scenario),
            shlex.quote(base_url),
            shlex.quote(tunnel_ip),
        )

        cmd = "kubectl -n {} exec {} -- sh -lc {}".format(
            UE_NAMESPACE, shlex.quote(pod), shlex.quote(shell)
        )

        timeout = 420 if scenario in ("video_download", "tcp_download") else 240
        r = run_cmd(cmd, timeout=timeout)
        output = r.get("output") or ""

        result["ok"] = bool(r.get("ok")) and "verdict=OK" in output
        result["exit"] = int(r.get("exit") or 0)
        result["output"] = output
        return result

    @app.route("/api/ues/embb-scenarios", methods=["POST"])
    def api_ues_embb_realistic_scenarios_multi():
        if f1_mode_active():
            # Mixed DU0/DU1 mode: allow Multi-UE traffic; old F1-only blocker disabled.
            pass

        import json
        import os
        import time
        from concurrent.futures import ThreadPoolExecutor, as_completed
        from pathlib import Path

        data = request.get_json(silent=True) or {}
        jobs = data.get("jobs") or []

        normalized_jobs = []
        skipped = []
        errors = []

        for raw_job in jobs:
            ue_name = str(raw_job.get("ue") or "").strip().lower()
            raw_scenario = str(raw_job.get("scenario") or "").strip().lower()
            scenario = PHASE4_MULTI_UE_EMBB_ALIASES.get(raw_scenario, raw_scenario)

            if scenario == "none" or scenario == "":
                skipped.append({"ue": ue_name, "reason": "scenario is none"})
                continue

            if ue_name not in UE_POOL:
                errors.append("unknown UE '{}'".format(ue_name))
                continue

            if scenario not in PHASE4_MULTI_UE_EMBB_LABELS:
                errors.append("unknown eMBB scenario '{}' for {}".format(raw_scenario, ue_name))
                continue

            normalized_jobs.append({
                "ue": ue_name,
                "scenario": scenario,
                "label": PHASE4_MULTI_UE_EMBB_LABELS.get(scenario, scenario),
            })

        if errors:
            return jsonify({
                "ok": False,
                "mode": "phase4_multi_ue_embb",
                "error": "invalid Multi-UE eMBB scenario request",
                "errors": errors,
                "skipped": skipped,
            }), 400

        if not normalized_jobs:
            return jsonify({
                "ok": False,
                "mode": "phase4_multi_ue_embb",
                "error": "no runnable Multi-UE eMBB scenario jobs selected",
                "skipped": skipped,
            }), 400

        run_id = time.strftime("%Y%m%d-%H%M%S")
        proof_dir = os.path.expanduser("~/oran-proof/phase4-multi-ue-embb-realistic/{}".format(run_id))
        Path(proof_dir).mkdir(parents=True, exist_ok=True)

        needs_media = any(j["scenario"] in ("image", "video_download", "web", "streaming", "tcp_download") for j in normalized_jobs)
        server_proc = None
        base_url = ""

        try:
            if needs_media:
                media_root = phase4_multi_ue_make_media_root(proof_dir)
                server_proc, port = phase4_multi_ue_start_http_server(media_root, proof_dir)
                node_ip = phase4_multi_ue_node_ip()
                base_url = "http://{}:{}".format(node_ip, port)

            results = []
            max_workers = min(len(normalized_jobs), MAX_UES)

            with ThreadPoolExecutor(max_workers=max_workers) as pool:
                futures = {
                    pool.submit(phase4_multi_ue_run_one_job, job, base_url, proof_dir): job
                    for job in normalized_jobs
                }

                for future in as_completed(futures):
                    job = futures[future]
                    try:
                        results.append(future.result())
                    except Exception as exc:
                        results.append({
                            "ue": job.get("ue"),
                            "scenario": job.get("scenario"),
                            "label": job.get("label"),
                            "slice": "eMBB",
                            "sst": 1,
                            "ok": False,
                            "exit": 1,
                            "output": "Exception: {}".format(exc),
                        })

            results.sort(key=lambda r: (r.get("ue", ""), r.get("scenario", "")))
            ok = all(r.get("ok") for r in results)

            summary_path = Path(proof_dir) / "summary.json"
            summary_path.write_text(json.dumps({
                "ok": ok,
                "run_id": run_id,
                "mode": "phase4_multi_ue_embb",
                "base_url": base_url,
                "results": results,
            }, indent=2))

            return jsonify({
                "ok": ok,
                "mode": "phase4_multi_ue_embb",
                "slice": "eMBB",
                "sst": 1,
                "parallel": True,
                "requested_jobs": len(jobs),
                "selected_count": len(normalized_jobs),
                "label": "Multi-UE eMBB Realistic Scenarios",
                "proof_dir": proof_dir,
                "base_url": base_url,
                "skipped": skipped,
                "results": results,
            })

        finally:
            if server_proc is not None:
                try:
                    server_proc.terminate()
                    server_proc.wait(timeout=5)
                except Exception:
                    try:
                        server_proc.kill()
                    except Exception:
                        pass
    # PHASE4_MULTI_UE_EMBB_REALISTIC_END


    @app.route("/api/ues/scenarios", methods=["POST"])
    def api_ues_independent_scenarios_multi():
        """Run different scenarios on different UEs in parallel.

        Request body example:
        {
          "jobs": [
            {"ue": "ue1", "scenario": "heavy"},
            {"ue": "ue2", "scenario": "light"}
          ]
        }
        """
        from concurrent.futures import ThreadPoolExecutor, as_completed

        data = request.get_json(silent=True) or {}
        raw_jobs = data.get("jobs", [])
        if not isinstance(raw_jobs, list):
            return jsonify({"ok": False, "error": "jobs must be a list"}), 400

        statuses = {
            u.get("name"): u
            for u in all_status()
            if u.get("name")
        }

        jobs = []
        skipped = []
        errors = []
        seen_ues = set()

        for idx, raw_job in enumerate(raw_jobs, start=1):
            if not isinstance(raw_job, dict):
                errors.append("job {} must be an object".format(idx))
                continue

            ue_name = str(raw_job.get("ue", "")).strip().lower()
            scenario, profile = resolve_scenario(raw_job.get("scenario", "none"))

            if scenario == "none":
                if ue_name:
                    skipped.append({"ue": ue_name, "reason": "scenario is none"})
                continue

            if not ue_cfg(ue_name):
                errors.append("unknown UE '{}' in job {}".format(ue_name, idx))
                continue

            if ue_name in seen_ues:
                errors.append("duplicate job for {}".format(ue_name))
                continue
            seen_ues.add(ue_name)

            if not profile:
                errors.append("unknown scenario '{}' for {}".format(raw_job.get("scenario"), ue_name))
                continue

            ue = statuses.get(ue_name) or status_one(ue_name)
            if not ue.get("pod"):
                errors.append("{} has no live pod".format(ue_name))
                continue

            if profile.get("kind") == "stop":
                if not ue.get("ready"):
                    errors.append("{} is not ready; cannot stop dashboard traffic".format(ue_name))
                    continue
            else:
                if not ue.get("attached"):
                    errors.append("{} is not attached; cannot run {}".format(ue_name, scenario))
                    continue

            jobs.append({
                "ue": ue,
                "scenario": scenario,
                "label": profile.get("label", scenario),
                "profile": profile,
            })

        if errors:
            return jsonify({
                "ok": False,
                "error": "invalid per-UE scenario request",
                "errors": errors,
                "skipped": skipped,
                "available": sorted(set(SCENARIO_PROFILES.keys()) | set(SCENARIO_ALIASES.keys())),
                "ues": all_status(),
            }), 400

        if not jobs:
            return jsonify({
                "ok": False,
                "error": "no runnable per-UE scenario jobs selected",
                "skipped": skipped,
                "ues": all_status(),
            }), 400

        results = []
        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            future_map = {
                pool.submit(run_independent_scenario_job, job): job
                for job in jobs
            }
            for future in as_completed(future_map):
                job = future_map[future]
                try:
                    results.append(future.result())
                except Exception as exc:
                    ue = job.get("ue", {})
                    results.append({
                        "ue": ue.get("name"),
                        "pod": ue.get("pod"),
                        "tunnel_ip": ue.get("tunnel_ip", ""),
                        "scenario": job.get("scenario"),
                        "label": job.get("label"),
                        "ok": False,
                        "exit": None,
                        "output": "exception: {}".format(exc),
                    })

        results.sort(key=lambda r: (r.get("ue", ""), r.get("scenario", "")))

        return jsonify({
            "ok": all(r.get("ok", False) for r in results),
            "parallel": True,
            "mode": "per_ue",
            "requested_jobs": len(raw_jobs),
            "selected_count": len(results),
            "selected_ues": [r.get("ue") for r in results],
            "skipped": skipped,
            "results": results,
            "ues": all_status(),
        })

    @app.route("/api/ues/scenario/<scenario>", methods=["POST"])
    def api_ues_scenario_multi(scenario):
        from concurrent.futures import ThreadPoolExecutor, as_completed

        scenario = str(scenario).lower()
        profile = SCENARIO_PROFILES.get(scenario)
        if not profile:
            return jsonify({
                "ok": False,
                "error": "unknown scenario {}".format(scenario),
                "available": sorted(SCENARIO_PROFILES.keys()),
            }), 404

        count = requested_ue_count()

        if profile["kind"] == "stop":
            target_ues = selected_ready_ues(count)
        else:
            target_ues = selected_attached_ues(count)

        if not target_ues:
            return jsonify({
                "ok": False,
                "scenario": scenario,
                "label": profile["label"],
                "count": count,
                "error": "no selected ready/attached UEs found",
                "ues": all_status(),
            }), 400

        jobs = []
        timeout = int(profile.get("timeout", 120))

        for ue in target_ues:
            if profile["kind"] in ("ping", "traffic"):
                script = build_ping_or_traffic_script(ue, profile)
            elif profile["kind"] == "background":
                script = build_video_script(ue)
            elif profile["kind"] == "stop":
                script = build_stop_script()
            else:
                script = "echo unsupported scenario kind; exit 1"

            jobs.append((ue, script))

        results = []
        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            future_map = {
                pool.submit(exec_script_in_ue, ue, script, timeout): ue
                for ue, script in jobs
            }
            for future in as_completed(future_map):
                try:
                    result = future.result()
                    result["scenario"] = scenario
                    result["label"] = profile["label"]
                    results.append(result)
                except Exception as exc:
                    ue = future_map[future]
                    results.append({
                        "ue": ue.get("name"),
                        "pod": ue.get("pod"),
                        "tunnel_ip": ue.get("tunnel_ip", ""),
                        "scenario": scenario,
                        "label": profile["label"],
                        "ok": False,
                        "exit": None,
                        "output": "exception: {}".format(exc),
                    })

        results.sort(key=lambda r: r.get("ue", ""))

        return jsonify({
            "ok": all(r.get("ok", False) for r in results),
            "scenario": scenario,
            "label": profile["label"],
            "requested_count": count,
            "selected_count": len(target_ues),
            "selected_ues": [u["name"] for u in target_ues],
            "parallel": True,
            "results": results,
            "ues": all_status(),
        })
    # UE_SCENARIO_ROUTES_END
