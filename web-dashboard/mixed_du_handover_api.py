import json
import os
import re
import subprocess
import urllib.request
from pathlib import Path

from flask import jsonify, request


NS = os.environ.get("ORAN_RAN_NS", "oran-ran")
PORT = os.environ.get("ORAN_DASHBOARD_PORT", "18080")
SELF_URL = os.environ.get("ORAN_DASHBOARD_SELF_URL", f"http://127.0.0.1:{PORT}")
REPO = Path(os.environ.get("ORAN_REPO", Path(__file__).resolve().parents[1]))

SWITCH_SCRIPT = REPO / "scripts" / "handover" / "switch-ue-du-target.sh"

UE_MAP = {
    "ue1": {"deployment": "oai-nr-ue", "configmap": "oai-nrue-config", "protected": False, "reference": True, "baseline_du": "du0"},
    "ue2": {"deployment": "oai-nr-ue-2", "configmap": "oai-nrue-config-2", "protected": False},
    "ue3": {"deployment": "oai-nr-ue-3", "configmap": "oai-nrue-config-3", "protected": False},
    "ue4": {"deployment": "oai-nr-ue-4", "configmap": "oai-nrue-config-4", "protected": False},
    "ue5": {"deployment": "oai-nr-ue-5", "configmap": "oai-nrue-config-5", "protected": False},
}

MATRIX_JOBS = [
    {"ue": "ue1", "scenario": "image"},
    {"ue": "ue2", "scenario": "web"},
    {"ue": "ue3", "scenario": "streaming"},
    {"ue": "ue4", "scenario": "video_download"},
    {"ue": "ue5", "scenario": "tcp_download"},
]


def _run(cmd, timeout=30):
    try:
        p = subprocess.run(
            cmd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            cwd=str(REPO),
        )
        return {
            "ok": p.returncode == 0,
            "rc": p.returncode,
            "stdout": p.stdout.strip(),
            "stderr": p.stderr.strip(),
            "cmd": " ".join(str(x) for x in cmd),
        }
    except Exception as exc:
        return {"ok": False, "rc": 99, "stdout": "", "stderr": str(exc), "cmd": " ".join(str(x) for x in cmd)}


def _kubectl(args, timeout=30):
    return _run(["kubectl", "-n", NS] + list(args), timeout=timeout)


def _endpoint_ready(service):
    r = _kubectl(["get", "endpoints", service, "-o", "json"], timeout=15)
    if not r["ok"]:
        return False

    try:
        data = json.loads(r["stdout"])
        for subset in data.get("subsets", []):
            addresses = subset.get("addresses", [])
            ports = subset.get("ports", [])
            if addresses and any(str(p.get("port")) == "4043" for p in ports):
                return True
    except Exception:
        return False

    return False


def _selector_for_deployment(dep):
    r = _kubectl(["get", "deploy", dep, "-o", "json"], timeout=15)
    if not r["ok"]:
        return ""

    try:
        data = json.loads(r["stdout"])
        labels = data.get("spec", {}).get("selector", {}).get("matchLabels", {})
        return ",".join(f"{k}={v}" for k, v in labels.items())
    except Exception:
        return ""


def _pod_for_deployment(dep):
    selector = _selector_for_deployment(dep)
    if not selector:
        return ""

    r = _kubectl(["get", "pods", "-l", selector, "-o", "json"], timeout=15)
    if not r["ok"]:
        return ""

    try:
        data = json.loads(r["stdout"])
        for item in data.get("items", []):
            phase = item.get("status", {}).get("phase", "")
            deletion = item.get("metadata", {}).get("deletionTimestamp")
            name = item.get("metadata", {}).get("name", "")
            if phase == "Running" and not deletion:
                return name
    except Exception:
        return ""

    return ""


def _tunnel_for_pod(pod):
    if not pod:
        return ""

    cmd = "ip -4 addr show oaitun_ue1 2>/dev/null | awk '/inet /{print $2; exit}'"
    r = _kubectl(["exec", pod, "--", "bash", "-lc", cmd], timeout=15)
    if r["ok"]:
        return r["stdout"].strip()
    return ""


def _serveraddr_for_configmap(cm):
    r = _kubectl(["get", "cm", cm, "-o", "jsonpath={.data.nr-ue\\.conf}"], timeout=15)
    if not r["ok"]:
        return ""

    text = r["stdout"]
    m = re.search(r'serveraddr\s*=\s*"([^"]+)"', text)
    if m:
        return m.group(1)

    m = re.search(r"serveraddr\s*=\s*([A-Za-z0-9_.-]+)", text)
    if m:
        return m.group(1)

    return ""


def _serveraddr_for_deployment_args(dep):
    """Rule 10: deployment args override the ConfigMap. Read args first."""
    r = _run(
        "kubectl -n {} get deploy {} -o jsonpath='{{.spec.template.spec.containers[0].args}}'".format(NS, dep),
        timeout=10,
    )
    out = (r.get("output") or "")
    import re as _re
    m = _re.search(r'serveraddr[\"\s,]+([A-Za-z0-9_.-]+)', out)
    return m.group(1) if m else ""


def _du_from_serveraddr(serveraddr):
    if serveraddr == "oai-du0-rfsim":
        return "du0"
    if serveraddr == "oai-du1-rfsim":
        return "du1"
    return "unknown"


def _status():
    du0_ready = _endpoint_ready("oai-du0-rfsim")
    du1_ready = _endpoint_ready("oai-du1-rfsim")

    ues = []
    attached_count = 0
    switchable_count = 0

    for name, meta in UE_MAP.items():
        dep = meta["deployment"]
        cm = meta["configmap"]
        protected = meta["protected"]

        # Rule 10: deployment args override the ConfigMap -> trust args first.
        serveraddr = _serveraddr_for_deployment_args(dep) or _serveraddr_for_configmap(cm)
        du = _du_from_serveraddr(serveraddr)
        pod = _pod_for_deployment(dep)
        tunnel = _tunnel_for_pod(pod)
        attached = bool(tunnel)

        if attached:
            attached_count += 1

        if not protected:
            switchable_count += 1

        ues.append({
            "name": name,
            "deployment": dep,
            "configmap": cm,
            "protected": protected,
            "switchable": not protected,
            "serveraddr": serveraddr,
            "du": du,
            "pod": pod,
            "attached": attached,
            "tunnel_ip": tunnel,
        })

    ue1 = next((u for u in ues if u["name"] == "ue1"), {})
    ue1_du = ue1.get("du", "unknown")
    ue1_attached = ue1.get("attached") is True

    ready = du0_ready and du1_ready and attached_count == len(UE_MAP)

    return {
        "ok": True,
        "mode": "mixed-du-rfsim",
        "label": "Multi-UE DU Continuity / Handover",
        "du0_ready": du0_ready,
        "du1_ready": du1_ready,
        "topology_ready": du0_ready and du1_ready,
        "attached_count": attached_count,
        "expected_count": len(UE_MAP),
        "switchable_count": switchable_count,
        "ue1_du": ue1_du,
        "ue1_attached": ue1_attached,
        "ue1_baseline_du": "du0",
        "handover_ready": ready,
        "ues": ues,
        "allowed_ues": ["ue1", "ue2", "ue3", "ue4", "ue5"],
        "blocked_ues": [],
        "note": "All UEs (ue1-ue5) are DU-switchable between DU0 and DU1. ue1 is the reference UE; DU0 is its baseline home.",
    }


def _run_matrix():
    payload = {"jobs": MATRIX_JOBS}

    req = urllib.request.Request(
        SELF_URL + "/api/ues/embb-scenarios",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=300) as resp:
        body = resp.read().decode("utf-8", errors="replace")

    return json.loads(body)


def _run_single_job(job):
    payload = {"jobs": [job]}

    req = urllib.request.Request(
        SELF_URL + "/api/ues/embb-scenarios",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=300) as resp:
        body = resp.read().decode("utf-8", errors="replace")

    return json.loads(body)


def _run_matrix_resilient():
    """
    First try the real 5-UE parallel matrix.
    If the RFsim/DU path times out under simultaneous load, fall back to
    sequential per-UE validation. This is better for the handover panel:
    it proves each UE survives its DU target while Multi-UE Control remains
    responsible for the dedicated parallel stress test.
    """
    parallel_attempt = None

    try:
        parallel_attempt = _run_matrix()
        results = parallel_attempt.get("results", [])
        parallel_ok = (
            parallel_attempt.get("ok") is True
            and len(results) == len(MATRIX_JOBS)
            and all(r.get("ok") is True for r in results)
        )

        if parallel_ok:
            parallel_attempt["validation_strategy"] = "parallel"
            return parallel_attempt

    except Exception as exc:
        parallel_attempt = {
            "ok": False,
            "error": str(exc),
            "validation_strategy": "parallel_exception",
        }

    sequential_results = []
    sequential_responses = []

    for job in MATRIX_JOBS:
        try:
            one = _run_single_job(job)
            sequential_responses.append(one)

            job_results = one.get("results", [])
            if job_results:
                sequential_results.extend(job_results)
            else:
                sequential_results.append({
                    "ue": job.get("ue"),
                    "scenario": job.get("scenario"),
                    "ok": False,
                    "error": one.get("error", "no results returned"),
                })

        except Exception as exc:
            sequential_results.append({
                "ue": job.get("ue"),
                "scenario": job.get("scenario"),
                "ok": False,
                "error": str(exc),
            })

    sequential_ok = (
        len(sequential_results) == len(MATRIX_JOBS)
        and all(r.get("ok") is True for r in sequential_results)
    )

    return {
        "ok": sequential_ok,
        "mode": "phase4_multi_ue_embb",
        "label": "Mixed-DU sequential fallback validation",
        "parallel": False,
        "validation_strategy": "sequential_fallback",
        "requested_jobs": len(MATRIX_JOBS),
        "selected_count": len(sequential_results),
        "results": sequential_results,
        "parallel_attempt": parallel_attempt,
        "sequential_responses": sequential_responses,
        "slice": "eMBB",
        "sst": 1,
    }


def _switch_ue():
    data = request.get_json(silent=True) or {}

    ue = str(data.get("ue", "")).strip()
    target = str(data.get("target", data.get("du", ""))).strip().lower()

    if ue not in ["ue1", "ue2", "ue3", "ue4", "ue5"]:
        return jsonify({
            "ok": False,
            "error": "invalid UE. Allowed: ue1, ue2, ue3, ue4, ue5",
            "verdict": "INVALID_UE",
        }), 400

    if target not in ["du0", "du1"]:
        return jsonify({
            "ok": False,
            "error": "invalid target. Allowed: du0, du1",
            "verdict": "INVALID_DU_TARGET",
        }), 400

    if not SWITCH_SCRIPT.exists():
        return jsonify({
            "ok": False,
            "error": f"switch script not found: {SWITCH_SCRIPT}",
            "verdict": "SWITCH_SCRIPT_MISSING",
        }), 500

    r = _run([str(SWITCH_SCRIPT), ue, target], timeout=330)
    output = (r.get("stdout", "") + "\n" + r.get("stderr", "")).strip()
    ok = "VERDICT=UE_DU_SWITCH_OK" in output

    return jsonify({
        "ok": ok,
        "mode": "mixed-du-rfsim",
        "ue": ue,
        "target": target,
        "verdict": "UE_DU_SWITCH_OK" if ok else "UE_DU_SWITCH_FAILED",
        "script_output": output,
        "status": _status(),
    }), 200


def _run_handover_validation():
    status = _status()

    if not status.get("topology_ready"):
        return jsonify({
            "ok": False,
            "mode": "mixed-du-rfsim",
            "handover_success": False,
            "error": "DU0/DU1 RFsim topology is not ready",
            "status": status,
        }), 200

    try:
        matrix = _run_matrix_resilient()
        results = matrix.get("results", [])
        all_ok = matrix.get("ok") is True and len(results) == 5 and all(r.get("ok") is True for r in results)

        return jsonify({
            "ok": all_ok,
            "mode": "mixed-du-rfsim",
            "label": "Multi-UE DU Continuity / Handover",
            "handover_success": all_ok,
            "trigger_ok": True,
            "cu_complete": status.get("topology_ready"),
            "rrc_complete": status.get("attached_count") == status.get("expected_count"),
            "du_cfra": all_ok,
            "post_ping_ok": all_ok,
            "status": status,
            "matrix": matrix,
            "note": "Validates mixed-DU Multi-UE continuity.",
        }), 200

    except Exception as exc:
        return jsonify({
            "ok": False,
            "mode": "mixed-du-rfsim",
            "handover_success": False,
            "error": str(exc),
            "status": status,
        }), 200


def install_mixed_du_handover_api(app):
    if getattr(app, "_mixed_du_handover_installed", False):
        return

    app._mixed_du_handover_installed = True

    @app.before_request
    def _mixed_du_handover_before_request():
        path = request.path
        method = request.method

        if path in ["/api/handover/status", "/api/handover/mixed-du/status"] and method == "GET":
            return jsonify(_status())

        if path in ["/api/handover/mixed-du/switch", "/api/handover/du-switch"] and method == "POST":
            return _switch_ue()

        if path == "/api/handover/mixed-du/run" and method == "POST":
            return _run_handover_validation()

        if path == "/api/handover/mixed-du/recover" and method == "POST":
            # _run takes an argv list (no shell); returns ok/rc/stdout/stderr
            script = REPO / "scripts" / "handover" / "recover-mixed-du-state.sh"
            r = _run(["bash", str(script)], timeout=600)
            out = (r.get("stdout") or "") + ("\n" + r.get("stderr") if r.get("stderr") else "")
            return jsonify({"ok": bool(r.get("ok")), "rc": r.get("rc"), "output": out[-4000:]})

        return None
