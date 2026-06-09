import json
import os
import re
import subprocess
from pathlib import Path

from flask import Blueprint, jsonify, request


radio_bp = Blueprint("radio_profile", __name__)

REPO = Path(os.environ.get("ORAN_REPO", Path.home() / "oran-e2e-freeze"))
RESULTS_FILE = REPO / "web-dashboard" / "radio-profile-results.json"
LOG_ROOT = Path.home() / "oran-proof"

PROFILE_MCS = {
    "scheduler-auto":   {"max_mcs": "none", "qm": "adaptive", "mod": "adaptive AMC (reaches 64QAM under load)"},
    "qpsk-robust":      {"max_mcs": "4",    "qm": "2",        "mod": "QPSK (forced)"},
    "qam16-balanced":   {"max_mcs": "13",   "qm": "4",        "mod": "16QAM (forced)"},
    "qam64-throughput": {"max_mcs": "28",   "qm": "6",        "mod": "64QAM (forced)"},
    "qam256-max":       {"max_mcs": "28",   "qm": "6",        "mod": "256QAM requested; UE-cap-limited to 64QAM"},
    "qpsk-stress":      {"max_mcs": "2",    "qm": "2",        "mod": "QPSK low (calibration)"},
}


def _run(cmd, timeout=240):
    try:
        p = subprocess.run(
            cmd,
            cwd=str(REPO),
            shell=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        return {"ok": p.returncode == 0, "rc": p.returncode, "output": p.stdout[-20000:]}
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout or ""
        if isinstance(out, bytes):
            out = out.decode(errors="ignore")
        return {"ok": False, "rc": 124, "output": out[-20000:] + "\nTIMEOUT"}
    except Exception as exc:
        return {"ok": False, "rc": 99, "output": str(exc)}


def _keyvals(text):
    data = {}
    for line in text.splitlines():
        line = line.strip()
        if "=" in line and not line.startswith("+"):
            k, v = line.split("=", 1)
            if k and len(k) < 90:
                data[k.strip()] = v.strip()
    return data


def _detect_profile(kv):
    cap = kv.get("dl_max_mcs", "").strip()
    mapping = {"none(adaptive)": "scheduler-auto", "4": "qpsk-robust",
               "13": "qam16-balanced", "28": "qam64-throughput", "2": "qpsk-stress"}
    return mapping.get(cap, f"max_mcs={cap}" if cap else "unknown")


def _load_rows():
    if RESULTS_FILE.exists():
        try:
            return json.loads(RESULTS_FILE.read_text())
        except Exception:
            return []
    return []


def _save_row(row):
    rows = _load_rows()
    rows = [r for r in rows if r.get("profile") != row.get("profile")]
    rows.insert(0, row)
    rows = rows[:50]
    RESULTS_FILE.write_text(json.dumps(rows, indent=2))
    return rows


def _parse_kpis(text, profile):
    row = {
        "profile": profile,
        "max_mcs": PROFILE_MCS.get(profile, {}).get("max_mcs", "unknown"),
        "modulation": PROFILE_MCS.get(profile, {}).get("mod", "unknown"),
        "tcp_mbps": "—",
        "retransmits": "—",
        "ping_avg_ms": "—",
        "image_mbps": "—",
        "verdict": "UNKNOWN",
    }

    rtts = re.findall(r"rtt min/avg/max/mdev = [0-9.]+/([0-9.]+)/", text)
    if rtts:
        row["ping_avg_ms"] = rtts[-1]

    image = re.search(r'"throughput_mbps"\s*:\s*([0-9.]+)', text)
    if image:
        row["image_mbps"] = image.group(1)

    tcp = re.search(r"Throughput Mbps:\s*([0-9.]+)", text)
    if tcp:
        row["tcp_mbps"] = tcp.group(1)

    retrans = re.search(r"TCP retransmits:\s*([0-9]+)", text)
    if retrans:
        row["retransmits"] = retrans.group(1)

    verdicts = re.findall(r"VERDICT=([A-Z0-9_]+)", text)
    if verdicts:
        row["verdict"] = verdicts[-1]

    return row


@radio_bp.get("/status")
def radio_status():
    r = _run("scripts/radio/switch-ue-modulation-profile-du-aware.sh ue1 status", timeout=90)
    kv = _keyvals(r["output"])

    tunnel = _run(
        """
UE_POD="$(kubectl -n oran-ran get pod -l app=oai-nr-ue --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
echo "UE_POD=$UE_POD"
if [ -n "$UE_POD" ]; then
  kubectl -n oran-ran exec "$UE_POD" -- ip addr show oaitun_ue1 >/dev/null 2>&1 && echo "TUNNEL_READY=yes" || echo "TUNNEL_READY=no"
  kubectl -n oran-ran exec "$UE_POD" -- sh -lc 'tc qdisc show dev oaitun_ue1 2>/dev/null || true'
else
  echo "TUNNEL_READY=no"
fi
""",
        timeout=40,
    )
    tv = _keyvals(tunnel["output"])
    profile = _detect_profile(kv)

    return jsonify({
        "ok": r["ok"],
        "active_profile": profile,
        "active_du_cm": kv.get("ACTIVE_DU_CM", "unknown"),
        "active_du_deploy": kv.get("ACTIVE_DU_DEPLOY", "unknown"),
        "serveraddr": kv.get("serveraddr", "unknown"),
        "slice": f"{kv.get('nssai_sst', 'unknown')} / {kv.get('nssai_sd', 'unknown')}",
        "tunnel_ready": tv.get("TUNNEL_READY", "unknown"),
        "ue_pod": tv.get("UE_POD", "unknown"),
        "modulation": PROFILE_MCS.get(profile, {}).get("mod", "unknown"),
        "max_mcs": PROFILE_MCS.get(profile, {}).get("max_mcs", "unknown"),
        "log": r["output"] + "\n" + tunnel["output"],
    })


@radio_bp.post("/apply")
def radio_apply():
    body = request.get_json(silent=True) or {}
    profile = body.get("profile", "")
    ue = body.get("ue", "ue1")

    if profile not in PROFILE_MCS:
        return jsonify({"ok": False, "error": f"Unsupported profile: {profile}"}), 400
    if ue != "ue1":
        return jsonify({"ok": False, "error": f"Only ue1 is supported, got: {ue}"}), 400

    cmd = (
        f"scripts/radio/switch-ue-modulation-profile-du-aware.sh {ue} {profile} --apply && "
        "scripts/validate-e2e.sh"
    )
    r = _run(cmd, timeout=420)
    row = _parse_kpis(r["output"], profile)
    row["verdict"] = "PASS" if r["ok"] else "FAIL"
    _save_row(row)

    return jsonify({"ok": r["ok"], "profile": profile, "ue": ue, "row": row, "log": r["output"]})


@radio_bp.post("/kpi-test")
def radio_kpi_test():
    body = request.get_json(silent=True) or {}
    profile = body.get("profile", "")
    ue = body.get("ue", "ue1")

    if profile not in PROFILE_MCS:
        return jsonify({"ok": False, "error": f"Unsupported profile: {profile}"}), 400
    if ue != "ue1":
        return jsonify({"ok": False, "error": f"Only ue1 is supported, got: {ue}"}), 400

    cmd = (
        f"scripts/radio/switch-ue-modulation-profile-du-aware.sh {ue} {profile} --apply && "
        "scripts/validate-e2e.sh && "
        "scripts/traffic/run-image-download.sh && "
        "scripts/traffic/run-iperf-tcp.sh"
    )
    r = _run(cmd, timeout=720)
    row = _parse_kpis(r["output"], profile)
    row["verdict"] = "PASS" if r["ok"] else "FAIL"
    rows = _save_row(row)

    return jsonify({"ok": r["ok"], "profile": profile, "ue": ue, "row": row, "rows": rows, "log": r["output"]})


@radio_bp.post("/restore")
def radio_restore():
    cmd = "scripts/radio/switch-ue-modulation-profile-du-aware.sh ue1 scheduler-auto --apply && scripts/validate-e2e.sh"
    r = _run(cmd, timeout=420)
    row = _parse_kpis(r["output"], "scheduler-auto")
    row["verdict"] = "PASS" if r["ok"] else "FAIL"
    _save_row(row)

    return jsonify({"ok": r["ok"], "profile": "scheduler-auto", "row": row, "log": r["output"]})


@radio_bp.get("/logs")
def radio_logs():
    r = _run(
        """
LATEST="$(find "$HOME/oran-proof" -maxdepth 2 -type f \\( -name 'run.log' -o -name 'verdict.txt' -o -name 'summary.txt' -o -name 'output.txt' \\) 2>/dev/null | sort | tail -n 10)"
for f in $LATEST; do
  echo "===== $f ====="
  tail -n 100 "$f"
  echo
done
""",
        timeout=80,
    )
    return jsonify({"ok": r["ok"], "log": r["output"]})


@radio_bp.get("/results")
def radio_results():
    return jsonify({
        "ok": True,
        "rows": _load_rows(),
        "profile_mcs": PROFILE_MCS,
        "note": "Real forced MCS per profile via --MACRLCs.[0].dl/ul_max_mcs on the active DU, verified by Qm in DU logs. 256QAM is UE-capability-limited (UE does not advertise pdsch-256QAM-FR1) so qam256-max effectively reaches 64QAM.",
    })
