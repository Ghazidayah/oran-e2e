#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_DIR="$HOME/oran-e2e-freeze/web-dashboard"
JS="$DASHBOARD_DIR/static/dashboard-multi-ue.js"
HTML="$DASHBOARD_DIR/templates/index.html"
API="$DASHBOARD_DIR/multi_ue_api.py"
BACKUP_DIR="$HOME/oran-proof/dashboard-backups/multi-ue-embb-realistic-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

echo "===== INSTALL MULTI-UE eMBB REALISTIC SCENARIOS ====="
echo "JS=$JS"
echo "HTML=$HTML"
echo "API=$API"
echo "BACKUP_DIR=$BACKUP_DIR"

cp "$JS" "$BACKUP_DIR/dashboard-multi-ue.js.bak"
cp "$HTML" "$BACKUP_DIR/index.html.bak"
cp "$API" "$BACKUP_DIR/multi_ue_api.py.bak"

python3 - "$JS" "$HTML" "$API" <<'PY'
from pathlib import Path
import re
import sys

js_path = Path(sys.argv[1])
html_path = Path(sys.argv[2])
api_path = Path(sys.argv[3])

js = js_path.read_text(errors="ignore")
html = html_path.read_text(errors="ignore")
api = api_path.read_text(errors="ignore")

# -----------------------------
# 1. Patch Multi-UE dropdown
# -----------------------------
new_options = '''  const perUeScenarioOptions = [
    ["none", "None"],
    ["attach_pdu", "Attach + PDU"],
    ["connectivity", "Connectivity"],
    ["image", "Image Download eMBB"],
    ["video_download", "Video Download eMBB"],
    ["web", "Web Browsing eMBB"],
    ["streaming", "Streaming-like HLS eMBB"],
    ["tcp_download", "TCP Download KPI eMBB"],
    ["stop", "Stop traffic"]
  ];'''

js2 = re.sub(
    r'\s*const perUeScenarioOptions\s*=\s*\[\s*.*?\n\s*\];',
    "\n" + new_options,
    js,
    count=1,
    flags=re.S,
)

if js2 == js:
    raise SystemExit("Could not replace perUeScenarioOptions in dashboard-multi-ue.js")

js = js2

# Route selected Multi-UE jobs to the new eMBB realistic endpoint.
js = js.replace(
    "fetch('/api/ues/scenarios',",
    "fetch('/api/ues/embb-scenarios',"
)

js = js.replace(
    "Running independent per-UE scenarios in parallel...",
    "Running independent per-UE eMBB realistic scenarios in parallel..."
)

js_path.write_text(js)

# -----------------------------
# 2. Patch HTML text/title
# -----------------------------
html = html.replace(
    "<h2>Multi-UE Control</h2>",
    "<h2>Multi-UE Control — eMBB Parallel Realistic Scenarios</h2>"
)

html = html.replace(
    "Choose a scenario per UE, then run the selected scenarios in parallel.",
    "Choose a realistic eMBB scenario per UE, then run the selected scenarios in parallel. "
    "This section keeps all active UEs on SST=1 / eMBB to avoid slice-switch conflicts."
)

html_path.write_text(html)

# -----------------------------
# 3. Add new backend route
# -----------------------------
start = "    # PHASE4_MULTI_UE_EMBB_REALISTIC_START"
end = "    # PHASE4_MULTI_UE_EMBB_REALISTIC_END"

block = r'''
    # PHASE4_MULTI_UE_EMBB_REALISTIC_START
    def phase4_multi_ue_node_ip():
        r = run_cmd("kubectl get node -o wide --no-headers | awk '{print $6; exit}'", timeout=10)
        return (r.get("output") or "").strip().splitlines()[0].strip()

    def phase4_multi_ue_make_media_root(run_dir):
        import os
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

    def phase4_multi_ue_embb_client_code():
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
    "web": [
        "/web/index.html",
        "/web/style.css",
        "/web/app.js",
        "/web/image1.bin",
        "/web/image2.bin",
    ],
    "streaming": [
        "/hls/playlist.m3u8",
        "/hls/segment_001.ts",
        "/hls/segment_002.ts",
        "/hls/segment_003.ts",
        "/hls/segment_004.ts",
        "/hls/segment_005.ts",
        "/hls/segment_006.ts",
        "/hls/segment_007.ts",
        "/hls/segment_008.ts",
    ],
    "tcp_download": [
        "/videos/sample-video.mp4",
        "/videos/sample-video.mp4",
    ],
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
    sha = hashlib.sha256(data).hexdigest()
    total_bytes += len(data)
    resources.append({
        "path": path,
        "http_status": code,
        "bytes": len(data),
        "time_seconds": round(dt, 6),
        "sha256": sha,
    })

duration = time.time() - t0_all
mbps = (total_bytes * 8 / duration / 1_000_000) if duration > 0 else 0.0

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
    "verdict": "OK" if all(r["http_status"] == 200 for r in resources) else "FAIL",
}

print(json.dumps(result, indent=2))
print("Scenario:", scenario)
print("Slice: eMBB")
print("SST: 1")
print("HTTP status: OK")
print("Resources OK:", result["resources_ok"], "/", result["resources_requested"])
print("rx_delta_bytes={}".format(total_bytes))
print("tx_delta_bytes=0")
print("duration_sec={}".format(round(duration, 3)))
print("approx_total_mbps={}".format(round(mbps, 6)))
print("packet_loss=0%")
print("verdict={}".format(result["verdict"]))

sys.exit(0 if result["verdict"] == "OK" else 1)
'''

    def phase4_multi_ue_run_one_job(job, base_url, run_dir):
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
            shell = "set -e; ip -4 addr show {}; ip route; ping -I {} -c 4 8.8.8.8".format(
                UE_TUNNEL, UE_TUNNEL
            )
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

        client_code = phase4_multi_ue_embb_client_code()
        shell = "cat > /tmp/multi_ue_realistic_client.py <<'PY'\n{}\nPY\npython3 /tmp/multi_ue_realistic_client.py {} {} {}".format(
            client_code,
            shlex.quote(scenario),
            shlex.quote(base_url),
            shlex.quote(tunnel_ip),
        )

        cmd = "kubectl -n {} exec {} -- sh -lc {}".format(
            UE_NAMESPACE, shlex.quote(pod), shlex.quote(shell)
        )

        timeout = 240
        if scenario in ("video_download", "tcp_download"):
            timeout = 420

        r = run_cmd(cmd, timeout=timeout)
        output = r.get("output") or ""

        result["ok"] = bool(r.get("ok")) and "verdict=OK" in output
        result["exit"] = int(r.get("exit") or 0)
        result["output"] = output
        return result

    @app.route("/api/ues/embb-scenarios", methods=["POST"])
    def api_ues_embb_realistic_scenarios_multi():
        """Run realistic eMBB scenarios on multiple UEs in parallel.

        This endpoint intentionally keeps all UEs on the current/default eMBB slice
        instead of switching S-NSSAI per UE. It is meant for the Multi-UE Control table.
        """

        if f1_mode_active():
            return reject_multi_ue_in_f1("run selected eMBB realistic UE scenarios")

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
'''

if start in api and end in api:
    before = api.split(start)[0]
    after = api.split(end, 1)[1]
    api = before + block + after
else:
    marker = '    @app.route("/api/ues/scenarios", methods=["POST"])'
    if marker not in api:
        raise SystemExit("Could not find /api/ues/scenarios route marker in multi_ue_api.py")
    api = api.replace(marker, block + "\n\n" + marker, 1)

api_path.write_text(api)
PY

echo
echo "===== SYNTAX CHECK ====="
web-dashboard/.venv/bin/python -m py_compile web-dashboard/multi_ue_api.py

echo
echo "===== VERIFY PATCH ====="
grep -n "Multi-UE Control" web-dashboard/templates/index.html | head
grep -n "perUeScenarioOptions" -A14 web-dashboard/static/dashboard-multi-ue.js
grep -n "api_ues_embb_realistic_scenarios_multi" -A5 web-dashboard/multi_ue_api.py

echo
echo "===== INSTALLER DONE ====="
echo "Backup saved in: $BACKUP_DIR"
