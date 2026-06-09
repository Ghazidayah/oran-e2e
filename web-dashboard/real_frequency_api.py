import json
import os
import re
import subprocess
import time
from pathlib import Path

from flask import Blueprint, jsonify, request

real_freq_bp = Blueprint("real_freq_bp", __name__)

REPO = Path(os.environ.get("ORAN_REPO", Path(__file__).resolve().parents[1]))
SCRIPT = REPO / "scripts" / "frequency" / "switch-ue-actual-frequency-retune-du-aware.sh"
SCRIPT_N28 = REPO / "scripts" / "frequency" / "validate-n28-700-on-du0.sh"
RESULTS_FILE = Path(__file__).resolve().with_name("real-frequency-results.json")
KPI_RESULTS_FILE = Path(__file__).resolve().with_name("freq-kpi-results.json")

# Selectable retune profiles (n78-current kept internally for restore only)
PROFILES = {
    "n78-current": {
        "freq_mhz": 3319.68,
        "band": "n78",
        "description": "Baseline n78 — SSB 621312, PointA 620040",
        "ssb": "621312",
        "pointa": "620040",
    },
    "n78-raster-high": {
        "freq_mhz": 3321.12,
        "band": "n78",
        "description": "n78 raster-high — SSB 621408, PointA 620136",
        "ssb": "621408",
        "pointa": "620136",
    },
    "n78-3500": {
        "freq_mhz": 3499.68,
        "band": "n78",
        "description": "n78 3500 MHz — SSB 633312, PointA 632040",
        "ssb": "633312",
        "pointa": "632040",
    },
    "n78-cband-3780": {
        "freq_mhz": 3779.04,
        "band": "n78",
        "description": "n78 C-band 3780 MHz — SSB 651936, PointA 650664",
        "ssb": "651936",
        "pointa": "650664",
    },
    "n41-2600": {
        "freq_mhz": 2593.35,
        "band": "n41",
        "description": "n41 2600 MHz — SSB 518670, PointA 514854 (validated 2026-06-04)",
        "ssb": "518670",
        "pointa": "514854",
    },
    "n28-700": {
        "freq_mhz": 781.25,
        "band": "n28 FDD",
        "description": "[EXPERIMENTAL] n28 700 MHz FDD — cell+sync+RACH Msg2 OK; Msg3 blocked by OAI RFsim FDD (no data tunnel)",
        "ssb": "156250",
        "pointa": "N/A (full FDD conf swap)",
        "experimental": True,
    },
}


# Representative tc netem profiles per band — EMULATED, not measured from RFsim
BAND_NETEM = {
    "n78-3500": {
        "delay": "2ms", "jitter": "1ms", "loss": "0.5%", "rate": "44mbit",
        "label": "C-band 3500 MHz (TDD)",
    },
    "n78-cband-3780": {
        "delay": "2ms", "jitter": "1ms", "loss": "0.8%", "rate": "40mbit",
        "label": "C-band 3780 MHz (TDD)",
    },
    "n41-2600": {
        "delay": "6ms", "jitter": "1ms", "loss": "0.2%", "rate": "28mbit",
        "label": "Mid-band 2600 MHz (TDD)",
    },
    "n28-700": {
        "delay": "20ms", "jitter": "3ms", "loss": "0.1%", "rate": "15mbit",
        "label": "Low-band 700 MHz FDD",
    },
}


def _default_results():
    return {
        "ok": True,
        "active_profile": "n78-current",
        "profiles": PROFILES,
        "rows": [],
    }


def _load_results():
    if not RESULTS_FILE.exists():
        data = _default_results()
        _save_results(data)
        return data
    try:
        data = json.loads(RESULTS_FILE.read_text())
    except Exception:
        data = _default_results()
    data.setdefault("ok", True)
    data.setdefault("active_profile", "n78-current")
    data.setdefault("profiles", PROFILES)
    data.setdefault("rows", [])
    return data


def _save_results(data):
    data["profiles"] = PROFILES
    RESULTS_FILE.write_text(json.dumps(data, indent=2, sort_keys=True))


def _run(profile, timeout=900):
    if profile not in PROFILES and profile not in ("status", "restore", "n28-700-restore"):
        return {"ok": False, "returncode": 2, "output": f"Unknown real-frequency profile: {profile}"}

    # n28-700 uses a full FDD conf-file swap via a separate script
    if profile == "n28-700":
        cmd = ["bash", str(SCRIPT_N28), "apply"]
    elif profile == "n28-700-restore":
        cmd = ["bash", str(SCRIPT_N28), "restore"]
    else:
        cmd = ["bash", str(SCRIPT), profile]

    proc = subprocess.run(
        cmd,
        cwd=str(REPO),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    return {
        "returncode": proc.returncode,
        "ok": proc.returncode == 0,
        "output": proc.stdout,
    }


def _parse_carrier_keys(output):
    keys = {}
    for key in ["absoluteFrequencySSB", "dl_frequencyBand", "dl_absoluteFrequencyPointA",
                "dl_carrierBandwidth", "ul_frequencyBand", "ul_carrierBandwidth"]:
        m = re.search(rf"\b{re.escape(key)}\b\s*=\s*([^;\n]+)", output or "")
        if m:
            keys[key] = m.group(1).strip()
    du_deploy = re.search(r"DU_DEPLOY=(\S+)", output or "")
    du_cm = re.search(r"DU_CM=(\S+)", output or "")
    ue_deploy = re.search(r"UE_DEPLOY=(\S+)", output or "")
    verdict = re.search(r"VERDICT=(\S+)", output or "")
    tunnel = "yes" if "oaitun_ue1" in (output or "") else "no"
    return {
        "carrier_keys": keys,
        "du_deploy": du_deploy.group(1) if du_deploy else "",
        "du_cm": du_cm.group(1) if du_cm else "",
        "ue_deploy": ue_deploy.group(1) if ue_deploy else "",
        "verdict": verdict.group(1) if verdict else "",
        "tunnel_ready": tunnel,
    }


def _upsert_row(row):
    data = _load_results()
    rows = [r for r in data.get("rows", []) if r.get("profile") != row.get("profile")]
    rows.insert(0, row)
    data["rows"] = rows[:20]
    data["active_profile"] = row.get("profile", data.get("active_profile"))
    _save_results(data)


@real_freq_bp.route("/profiles", methods=["GET"])
def profiles():
    return jsonify({"ok": True, "profiles": PROFILES})


@real_freq_bp.route("/status", methods=["GET"])
def status():
    data = _load_results()
    res = _run("status", timeout=120)
    parsed = _parse_carrier_keys(res.get("output", ""))
    return jsonify({
        "ok": res["ok"],
        "active_profile": data.get("active_profile"),
        "carrier_keys": parsed["carrier_keys"],
        "du_deploy": parsed["du_deploy"],
        "du_cm": parsed["du_cm"],
        "ue_deploy": parsed["ue_deploy"],
        "tunnel_ready": parsed["tunnel_ready"],
        "log": res.get("output", "")[-12000:],
    })


@real_freq_bp.route("/apply", methods=["POST"])
def apply():
    payload = request.get_json(silent=True) or {}
    profile = payload.get("profile", "n78-current")
    if profile not in PROFILES:
        return jsonify({"ok": False, "error": f"Unknown profile: {profile}"}), 400

    res = _run(profile, timeout=900)
    parsed = _parse_carrier_keys(res.get("output", ""))
    ok = res["ok"]

    row = {
        "profile": profile,
        "freq_mhz": PROFILES[profile]["freq_mhz"],
        "band": PROFILES[profile]["band"],
        "description": PROFILES[profile]["description"],
        "ssb": PROFILES[profile]["ssb"],
        "pointa": PROFILES[profile]["pointa"],
        "du_deploy": parsed["du_deploy"],
        "verdict": parsed["verdict"] or ("PASS" if ok else "FAIL"),
        "tunnel_ready": parsed["tunnel_ready"],
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    _upsert_row(row)

    return jsonify({
        "ok": ok,
        "profile": profile,
        "row": row,
        "log": res.get("output", "")[-18000:],
    })


@real_freq_bp.route("/restore", methods=["POST"])
def restore():
    data = _load_results()
    # If we're currently on n28-700 (FDD full conf swap), undo via the validate script
    # so the original gnb.conf is properly restored from backup — not just key-patched.
    if data.get("active_profile") == "n28-700":
        res = _run("n28-700-restore", timeout=900)
    else:
        res = _run("restore", timeout=900)

    parsed = _parse_carrier_keys(res.get("output", ""))
    ok = res["ok"]

    if ok:
        data["active_profile"] = "n78-current"
        _save_results(data)

    return jsonify({
        "ok": ok,
        "profile": "n78-current",
        "log": res.get("output", "")[-18000:],
        "verdict": parsed["verdict"],
    })


@real_freq_bp.route("/results", methods=["GET"])
def results():
    data = _load_results()
    return jsonify(data)


# ── KPI comparison helpers ──────────────────────────────────────────────────

def _get_ue_pod():
    proc = subprocess.run(
        ["kubectl", "-n", "oran-ran", "get", "pod", "-l", "app=oai-nr-ue",
         "--field-selector=status.phase=Running",
         "-o", "jsonpath={.items[0].metadata.name}"],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    return proc.stdout.strip()


def _load_kpi_results():
    if KPI_RESULTS_FILE.exists():
        try:
            return json.loads(KPI_RESULTS_FILE.read_text())
        except Exception:
            return []
    return []


def _save_kpi_result(row):
    rows = _load_kpi_results()
    rows = [r for r in rows if r.get("profile") != row.get("profile")]
    rows.insert(0, row)
    KPI_RESULTS_FILE.write_text(json.dumps(rows[:20], indent=2))


def _run_kpi_test(profile):
    if profile not in BAND_NETEM:
        return {"ok": False, "error": f"No emulation profile for: {profile}", "log": ""}

    netem = BAND_NETEM[profile]
    log = []

    pod = _get_ue_pod()
    if not pod:
        return {"ok": False, "error": "UE pod not found", "log": "UE pod not found"}
    log.append(f"UE_POD={pod}")

    chk = subprocess.run(
        ["kubectl", "-n", "oran-ran", "exec", pod, "--",
         "ip", "addr", "show", "oaitun_ue1"],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20,
    )
    if chk.returncode != 0:
        return {"ok": False, "error": "oaitun_ue1 not up", "log": "oaitun_ue1 not found in UE pod"}
    log.append("oaitun_ue1 up")

    tc_apply = (
        "tc qdisc del dev oaitun_ue1 root 2>/dev/null; "
        f"tc qdisc add dev oaitun_ue1 root netem "
        f"delay {netem['delay']} {netem['jitter']} distribution normal "
        f"loss {netem['loss']} rate {netem['rate']}"
    )

    ping_out = ""
    iperf_out = ""
    try:
        subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--", "sh", "-lc", tc_apply],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
        )
        log.append(f"netem applied: delay={netem['delay']} ±{netem['jitter']} "
                   f"loss={netem['loss']} rate={netem['rate']}")

        show = subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--",
             "tc", "qdisc", "show", "dev", "oaitun_ue1"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
        log.append(f"tc state: {show.stdout.strip()}")

        p = subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--",
             "ping", "-I", "oaitun_ue1", "-c", "20", "8.8.8.8"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
        )
        ping_out = p.stdout
        log.append("--- PING ---\n" + ping_out[-1500:])

        ienv = {**os.environ, "DURATION": "15"}
        ip = subprocess.run(
            ["bash", str(REPO / "scripts/traffic/run-iperf-tcp.sh")],
            env=ienv, cwd=str(REPO),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90,
        )
        iperf_out = ip.stdout
        log.append("--- IPERF3 ---\n" + iperf_out[-2000:])
    finally:
        subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--", "sh", "-lc",
             "tc qdisc del dev oaitun_ue1 root 2>/dev/null; true"],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        log.append("netem cleared")

    loss_m = re.search(r"(\d+(?:\.\d+)?)% packet loss", ping_out)
    rtt_m = re.search(r"rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", ping_out)
    tcp_m = re.search(r"Throughput Mbps:\s*([\d.]+)", iperf_out)
    retrans_m = re.search(r"TCP retransmits:\s*(\d+)", iperf_out)

    return {
        "ok": True,
        "profile": profile,
        "netem": f"delay {netem['delay']} ±{netem['jitter']}, loss {netem['loss']}, rate {netem['rate']}",
        "ping_loss": (loss_m.group(1) + "%") if loss_m else "?",
        "ping_avg": (rtt_m.group(2) + " ms") if rtt_m else "?",
        "ping_rtt": (f"{rtt_m.group(1)}/{rtt_m.group(2)}/{rtt_m.group(3)}/{rtt_m.group(4)} ms") if rtt_m else "?",
        "tcp_mbps": tcp_m.group(1) if tcp_m else "?",
        "retransmits": retrans_m.group(1) if retrans_m else "?",
        "log": "\n".join(log),
    }


@real_freq_bp.route("/kpi-test", methods=["POST"])
def kpi_test():
    payload = request.get_json(silent=True) or {}
    profile = payload.get("profile", "")
    if profile not in BAND_NETEM:
        return jsonify({"ok": False, "error": f"Unknown KPI profile: {profile}"}), 400

    result = _run_kpi_test(profile)
    if result.get("ok"):
        row = {
            "profile": profile,
            "freq_mhz": PROFILES.get(profile, {}).get("freq_mhz", "?"),
            "band": PROFILES.get(profile, {}).get("band", "?"),
            "netem": result["netem"],
            "ping_avg": result.get("ping_avg", "?"),
            "ping_rtt": result.get("ping_rtt", "?"),
            "ping_loss": result.get("ping_loss", "?"),
            "tcp_mbps": result.get("tcp_mbps", "?"),
            "retransmits": result.get("retransmits", "?"),
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        _save_kpi_result(row)

    return jsonify(result)


@real_freq_bp.route("/kpi-results", methods=["GET"])
def kpi_results():
    return jsonify({
        "ok": True,
        "rows": _load_kpi_results(),
        "netem_profiles": BAND_NETEM,
        "note": "KPIs are EMULATED via tc netem on oaitun_ue1. Differences come from the netem profile, not RFsim physics.",
    })
