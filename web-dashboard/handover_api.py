import os
import subprocess
from datetime import datetime
from flask import Blueprint, jsonify

handover_bp = Blueprint("handover", __name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.abspath(os.path.join(BASE_DIR, ".."))
ACTIONS_DIR = os.path.join(BASE_DIR, "actions")


def run_action(script_name, timeout=120):
    script_path = os.path.join(ACTIONS_DIR, script_name)

    if not os.path.exists(script_path):
        return {
            "ok": False,
            "exit": 127,
            "output": "",
            "error": f"Action script not found: {script_path}",
            "time": datetime.now().isoformat(timespec="seconds"),
        }

    try:
        proc = subprocess.run(
            [script_path],
            cwd=REPO_DIR,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )

        output = proc.stdout or ""

        return {
            "ok": proc.returncode == 0,
            "exit": proc.returncode,
            "output": output,
            "time": datetime.now().isoformat(timespec="seconds"),
        }

    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "exit": 124,
            "output": exc.stdout or "",
            "error": f"Timed out after {timeout} seconds",
            "time": datetime.now().isoformat(timespec="seconds"),
        }


@handover_bp.route("/api/handover/status")
def handover_status():
    result = run_action("f1_status.sh", timeout=120)

    output = result.get("output", "")

    result["mode"] = "f1-rfsim" if "F1_TOPOLOGY=READY" in output else "unknown"
    result["topology_ready"] = "F1_TOPOLOGY=READY" in output
    result["ue_tunnel_ready"] = "UE_TUNNEL=READY" in output
    result["handover_ready"] = "F1_HANDOVER_READY=YES" in output
    result["ready"] = result["topology_ready"]
    result["label"] = "F1 RFsim handover topology"

    return jsonify(result)


@handover_bp.route("/api/handover/f1/run", methods=["POST"])
def run_f1_handover():
    result = run_action("f1_handover.sh", timeout=180)

    output = result.get("output", "")

    result["mode"] = "f1-rfsim"
    result["label"] = "F1 RFsim handover"
    result["handover_success"] = "F1_HANDOVER_RESULT=SUCCESS" in output
    result["trigger_ok"] = "TRIGGER_OK=true" in output
    result["cu_complete"] = "CU_COMPLETE=true" in output
    result["rrc_complete"] = "RRC_COMPLETE=true" in output
    result["du_cfra"] = "DU_CFRA=true" in output
    result["post_ping_ok"] = "POST_PING_OK=true" in output

    return jsonify(result)
