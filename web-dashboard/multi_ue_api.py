import json
import shlex
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
