#!/usr/bin/env python3
import os
import json
import time
import uuid
import subprocess
import threading
from pathlib import Path
from flask import Flask, jsonify, request

REPO = Path.home() / "oran-e2e-freeze"
PROOF = Path.home() / "oran-proof" / "phase2-traffic-api"
PROOF.mkdir(parents=True, exist_ok=True)

SCENARIOS = {
    "image": {
        "label": "Image Download",
        "script": "scripts/traffic/run-image-download.sh",
    },
    "iperf-tcp": {
        "label": "iperf3 TCP Throughput",
        "script": "scripts/traffic/run-iperf-tcp.sh",
    },
    "udp": {
        "label": "Custom UDP Jitter/Loss",
        "script": "scripts/traffic/run-udp-traffic.sh",
    },
    "video": {
        "label": "Video Download",
        "script": "scripts/traffic/run-video-download.sh",
    },
    "web": {
        "label": "Web Browsing",
        "script": "scripts/traffic/run-web-browsing.sh",
    },
    "streaming": {
        "label": "Streaming-like HLS",
        "script": "scripts/traffic/run-streaming-like.sh",
    },
    "run-all": {
        "label": "Run All Realistic Traffic",
        "script": "scripts/traffic/run-all-realistic-traffic.sh",
    },
}

JOBS = {}
LOCK = threading.Lock()

app = Flask(__name__)


@app.after_request
def add_cors_headers(response):
    response.headers["Access-Control-Allow-Origin"] = "*"
    response.headers["Access-Control-Allow-Methods"] = "GET,POST,OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return response


@app.route("/api/traffic/health", methods=["GET"])
def health():
    return jsonify({
        "ok": True,
        "service": "phase2-traffic-api",
        "repo": str(REPO),
        "proof": str(PROOF),
        "time": time.strftime("%Y-%m-%d %H:%M:%S"),
    })


@app.route("/api/traffic/scenarios", methods=["GET"])
def scenarios():
    return jsonify({
        "ok": True,
        "scenarios": [
            {"id": key, "label": val["label"], "script": val["script"]}
            for key, val in SCENARIOS.items()
        ],
    })


def run_job(job_id, scenario_id, script_path, env_extra=None):
    job_dir = PROOF / job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    log_file = job_dir / "output.log"
    summary_file = job_dir / "summary.json"

    with LOCK:
        JOBS[job_id]["status"] = "running"
        JOBS[job_id]["started_at"] = time.strftime("%Y-%m-%d %H:%M:%S")

    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    if env_extra:
        env.update(env_extra)

    try:
        proc = subprocess.run(
            ["bash", str(script_path)],
            cwd=str(REPO),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=900,
            env=env,
        )

        output = proc.stdout or ""
        log_file.write_text(output)

        status = "ok" if proc.returncode == 0 else "failed"
        ok = proc.returncode == 0

        summary = {
            "ok": ok,
            "status": status,
            "exit": proc.returncode,
            "job_id": job_id,
            "scenario": scenario_id,
            "script": str(script_path),
            "job_dir": str(job_dir),
            "log_file": str(log_file),
            "finished_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="ignore")
        log_file.write_text(output + "\nTIMEOUT\n")

        summary = {
            "ok": False,
            "status": "timeout",
            "exit": 124,
            "job_id": job_id,
            "scenario": scenario_id,
            "script": str(script_path),
            "job_dir": str(job_dir),
            "log_file": str(log_file),
            "finished_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    except Exception as exc:
        log_file.write_text(str(exc) + "\n")
        summary = {
            "ok": False,
            "status": "error",
            "exit": 99,
            "job_id": job_id,
            "scenario": scenario_id,
            "script": str(script_path),
            "job_dir": str(job_dir),
            "log_file": str(log_file),
            "error": str(exc),
            "finished_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    summary_file.write_text(json.dumps(summary, indent=2))

    with LOCK:
        JOBS[job_id].update(summary)


@app.route("/api/traffic/run/<scenario_id>", methods=["POST", "OPTIONS"])
def run_scenario(scenario_id):
    if request.method == "OPTIONS":
        return jsonify({"ok": True})

    if scenario_id not in SCENARIOS:
        return jsonify({"ok": False, "error": f"Unknown scenario: {scenario_id}"}), 404

    script = REPO / SCENARIOS[scenario_id]["script"]
    if not script.exists():
        return jsonify({"ok": False, "error": f"Script not found: {script}"}), 404

    job_id = time.strftime("%Y%m%d-%H%M%S") + "-" + scenario_id + "-" + uuid.uuid4().hex[:6]

    with LOCK:
        JOBS[job_id] = {
            "ok": None,
            "status": "queued",
            "job_id": job_id,
            "scenario": scenario_id,
            "label": SCENARIOS[scenario_id]["label"],
            "script": str(script),
            "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    thread = threading.Thread(target=run_job, args=(job_id, scenario_id, script), daemon=True)
    thread.start()

    return jsonify({
        "ok": True,
        "started": True,
        "job_id": job_id,
        "scenario": scenario_id,
        "label": SCENARIOS[scenario_id]["label"],
    })


@app.route("/api/traffic/jobs", methods=["GET"])
def list_jobs():
    with LOCK:
        jobs = list(JOBS.values())
    jobs.sort(key=lambda item: item.get("created_at", ""), reverse=True)
    return jsonify({"ok": True, "jobs": jobs[:30]})


@app.route("/api/traffic/jobs/<job_id>", methods=["GET"])
def get_job(job_id):
    with LOCK:
        job = JOBS.get(job_id)

    if not job:
        summary_file = PROOF / job_id / "summary.json"
        if summary_file.exists():
            job = json.loads(summary_file.read_text())
        else:
            return jsonify({"ok": False, "error": "job not found"}), 404

    log_file = Path(job.get("log_file", PROOF / job_id / "output.log"))
    output = ""
    if log_file.exists():
        output = log_file.read_text(errors="ignore")[-20000:]

    return jsonify({
        "ok": True,
        "job": job,
        "output": output,
    })


if __name__ == "__main__":
    host = os.environ.get("TRAFFIC_API_HOST", "0.0.0.0")
    port = int(os.environ.get("TRAFFIC_API_PORT", "5055"))
    app.run(host=host, port=port)
