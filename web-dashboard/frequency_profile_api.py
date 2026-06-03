import json
import os
import re
import subprocess
import time
import urllib.request
from pathlib import Path

from flask import Blueprint, jsonify, request

frequency_bp = Blueprint("frequency_bp", __name__)

REPO = Path(os.environ.get("ORAN_REPO", Path(__file__).resolve().parents[1]))
SCRIPT = REPO / "scripts" / "frequency" / "switch-ue-frequency-profile-du-aware.sh"
RESULTS_FILE = Path(__file__).resolve().with_name("frequency-profile-results.json")
DASHBOARD_PORT = os.environ.get("ORAN_DASHBOARD_PORT", "18080")
LOCAL_BASE = f"http://127.0.0.1:{DASHBOARD_PORT}"

PROFILES = {
    "low-band-700": {
        "freq_mhz": 700,
        "band_label": "low-band-coverage",
        "description": "Coverage-band 700 MHz model",
        "expected": "Stable coverage, medium throughput",
        "rf_values": "enB0 14/-8, ue0 14/-6",
        "tc_cmd": "rate 22mbit delay 5ms 1ms loss 0%",
    },
    "mid-band-3500": {
        "freq_mhz": 3500,
        "band_label": "mid-band-n78",
        "description": "Baseline n78-like 3.5 GHz model",
        "expected": "Balanced baseline throughput",
        "rf_values": "enB0 20/-4, ue0 20/-2",
        "tc_cmd": "clear",
    },
    "cband-3800": {
        "freq_mhz": 3800,
        "band_label": "cband-upper-mid",
        "description": "Upper mid-band 3.8 GHz model",
        "expected": "Good throughput, slightly higher loss than 3.5 GHz",
        "rf_values": "enB0 23/-2, ue0 23/0",
        "tc_cmd": "rate 36mbit delay 3ms 1ms loss 0%",
    },
    "mmwave-28000-los": {
        "freq_mhz": 28000,
        "band_label": "mmwave-los",
        "description": "28 GHz mmWave line-of-sight model",
        "expected": "High throughput if LOS",
        "rf_values": "enB0 28/-4, ue0 28/-2",
        "tc_cmd": "rate 70mbit delay 1ms 0ms loss 0%",
    },
    "mmwave-28000-nlos": {
        "freq_mhz": 28000,
        "band_label": "mmwave-nlos",
        "description": "28 GHz mmWave NLOS/blockage model",
        "expected": "Lower throughput, higher latency",
        "rf_values": "enB0 55/20, ue0 55/22",
        "tc_cmd": "rate 10mbit delay 35ms 10ms loss 1%",
    },
}


def _default_results():
    return {
        "ok": True,
        "active_profile": "mid-band-3500",
        "note": (
            "Frequency control is implemented as a frequency-channel profile: "
            "RFsim channel metadata plus tc/netem shaping. Arbitrary NR carrier retune is not enabled yet."
        ),
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
    data.setdefault("active_profile", "mid-band-3500")
    data.setdefault("note", _default_results()["note"])
    data.setdefault("profiles", PROFILES)
    data.setdefault("rows", [])
    return data


def _save_results(data):
    data["profiles"] = PROFILES
    RESULTS_FILE.write_text(json.dumps(data, indent=2, sort_keys=True))


def _run(cmd, timeout=900):
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


def _run_frequency(profile, mode="--apply", timeout=900):
    if profile == "restore":
        profile = "mid-band-3500"
    if profile not in PROFILES and profile != "status":
        return {
            "ok": False,
            "returncode": 2,
            "output": f"Unknown frequency profile: {profile}",
        }
    return _run(["bash", str(SCRIPT), profile, mode], timeout=timeout)


def _latest_result_json_from_output(output):
    m = re.findall(r"Proof:\s*(/[^ \n\r]+)", output or "")
    if m:
        p = Path(m[-1]) / "result.json"
        if p.exists():
            try:
                return json.loads(p.read_text())
            except Exception:
                pass

    roots = sorted(Path.home().glob("oran-proof/frequency-profile-control-du-aware/*/result.json"))
    if roots:
        try:
            return json.loads(roots[-1].read_text())
        except Exception:
            pass

    return {}


def _parse_status_output(output):
    enb_ploss = re.search(r"rfsimu_channel_enB0_ploss_dB=([^\n]+)", output or "")
    enb_noise = re.search(r"rfsimu_channel_enB0_noise_power_dB=([^\n]+)", output or "")
    ue_ploss = re.search(r"rfsimu_channel_ue0_ploss_dB=([^\n]+)", output or "")
    ue_noise = re.search(r"rfsimu_channel_ue0_noise_power_dB=([^\n]+)", output or "")
    serveraddr = re.search(r"serveraddr=([^\n]+)", output or "")

    rf_values = "unknown"
    if enb_ploss and enb_noise and ue_ploss and ue_noise:
        rf_values = (
            f"enB0 {enb_ploss.group(1).strip()}/{enb_noise.group(1).strip()}, "
            f"ue0 {ue_ploss.group(1).strip()}/{ue_noise.group(1).strip()}"
        )

    qdisc_lines = [line for line in (output or "").splitlines() if line.startswith("qdisc ")]
    qdisc = qdisc_lines[-1] if qdisc_lines else ""
    tunnel_ready = "yes" if "oaitun_ue1" in (output or "") else "no"

    return {
        "serveraddr": serveraddr.group(1).strip() if serveraddr else "unknown",
        "rf_values": rf_values,
        "qdisc": qdisc,
        "tunnel_ready": tunnel_ready,
    }


def _infer_profile(rf_values, qdisc, stored_active):
    if "55/20" in rf_values and "55/22" in rf_values:
        return "mmwave-28000-nlos"
    if "14/-8" in rf_values and "14/-6" in rf_values:
        return "low-band-700"
    if "23/-2" in rf_values and "23/0" in rf_values:
        return "cband-3800"
    if "28/-4" in rf_values and "28/-2" in rf_values:
        return "mmwave-28000-los"
    if "20/-4" in rf_values and "20/-2" in rf_values and "netem" not in qdisc:
        return "mid-band-3500"
    return stored_active or "unknown"


def _extract_mbps_from_embb_result(data):
    try:
        r = data.get("results", [{}])[0]
        out = r.get("output", "")
        first = out.split("\nScenario:")[0]
        try:
            inner = json.loads(first)
            if inner.get("throughput_mbps") is not None:
                return str(inner.get("throughput_mbps"))
        except Exception:
            pass

        for pat in [
            r"throughput_mbps[\"']?\s*[:=]\s*([0-9.]+)",
            r"approx_total_mbps=([0-9.]+)",
            r"Average throughput Mbps:\s*([0-9.]+)",
        ]:
            m = re.search(pat, out)
            if m:
                return m.group(1)
    except Exception:
        pass
    return ""


def _call_embb_scenario(scenario, timeout=900):
    body = json.dumps({"jobs": [{"ue": "ue1", "scenario": scenario}]}).encode()
    req = urllib.request.Request(
        f"{LOCAL_BASE}/api/ues/embb-scenarios",
        data=body,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        text = resp.read().decode()
    data = json.loads(text)
    return data


def _parse_ping_avg(validate_output):
    m = re.search(r"rtt min/avg/max/mdev = [0-9.]+/([0-9.]+)/", validate_output or "")
    return m.group(1) if m else ""


def _upsert_row(row):
    data = _load_results()
    rows = [r for r in data.get("rows", []) if r.get("profile") != row.get("profile")]
    rows.insert(0, row)
    data["rows"] = rows[:30]
    data["active_profile"] = row.get("profile", data.get("active_profile"))
    _save_results(data)


@frequency_bp.route("/profiles", methods=["GET"])
def profiles():
    return jsonify({"ok": True, "profiles": PROFILES})


@frequency_bp.route("/status", methods=["GET"])
def status():
    data = _load_results()
    res = _run_frequency("status", "--apply", timeout=120)
    parsed = _parse_status_output(res.get("output", ""))
    active = _infer_profile(parsed["rf_values"], parsed["qdisc"], data.get("active_profile"))

    profile_meta = PROFILES.get(active, {})
    return jsonify({
        "ok": res["ok"],
        "active_profile": active,
        "freq_mhz": profile_meta.get("freq_mhz"),
        "band_label": profile_meta.get("band_label"),
        "description": profile_meta.get("description"),
        "expected": profile_meta.get("expected"),
        "serveraddr": parsed["serveraddr"],
        "rf_values": parsed["rf_values"],
        "qdisc": parsed["qdisc"],
        "tunnel_ready": parsed["tunnel_ready"],
        "log": res.get("output", "")[-12000:],
        "note": data.get("note"),
    })


@frequency_bp.route("/apply", methods=["POST"])
def apply():
    payload = request.get_json(silent=True) or {}
    profile = payload.get("profile", "mid-band-3500")

    res = _run_frequency(profile, "--apply", timeout=900)
    result = _latest_result_json_from_output(res.get("output", ""))
    ok = bool(res["ok"] and result.get("ok", True))

    if ok:
        data = _load_results()
        data["active_profile"] = profile
        _save_results(data)

    return jsonify({
        "ok": ok,
        "profile": profile,
        "result": result,
        "log": res.get("output", "")[-18000:],
    })


@frequency_bp.route("/restore", methods=["POST"])
def restore():
    res = _run_frequency("mid-band-3500", "--apply", timeout=900)
    result = _latest_result_json_from_output(res.get("output", ""))
    ok = bool(res["ok"] and result.get("ok", True))

    if ok:
        data = _load_results()
        data["active_profile"] = "mid-band-3500"
        _save_results(data)

    return jsonify({
        "ok": ok,
        "profile": "mid-band-3500",
        "result": result,
        "log": res.get("output", "")[-18000:],
    })


@frequency_bp.route("/kpi-test", methods=["POST"])
def kpi_test():
    payload = request.get_json(silent=True) or {}
    profile = payload.get("profile", "mid-band-3500")

    apply_res = _run_frequency(profile, "--apply", timeout=900)
    apply_result = _latest_result_json_from_output(apply_res.get("output", ""))

    validate = _run(["bash", "scripts/validate-e2e.sh"], timeout=240)
    ping_avg_ms = _parse_ping_avg(validate.get("output", ""))

    image_data = {}
    tcp_data = {}
    image_mbps = ""
    tcp_mbps = ""

    try:
        image_data = _call_embb_scenario("image", timeout=900)
        image_mbps = _extract_mbps_from_embb_result(image_data)
    except Exception as e:
        image_data = {"ok": False, "error": str(e)}

    try:
        tcp_data = _call_embb_scenario("tcp_download", timeout=900)
        tcp_mbps = _extract_mbps_from_embb_result(tcp_data)
    except Exception as e:
        tcp_data = {"ok": False, "error": str(e)}

    ok = bool(
        apply_res["ok"]
        and validate["ok"]
        and image_data.get("ok") is True
        and tcp_data.get("ok") is True
    )

    meta = PROFILES.get(profile, {})
    row = {
        "profile": profile,
        "freq_mhz": meta.get("freq_mhz"),
        "band_label": meta.get("band_label"),
        "description": meta.get("description"),
        "rf_values": apply_result.get("rf_values", meta.get("rf_values")),
        "tc_cmd": apply_result.get("tc_cmd", meta.get("tc_cmd")),
        "ping_avg_ms": ping_avg_ms,
        "image_mbps": image_mbps,
        "tcp_mbps": tcp_mbps,
        "verdict": "PASS" if ok else "FAIL",
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "proof_dir": apply_result.get("proof_dir", ""),
    }

    _upsert_row(row)

    return jsonify({
        "ok": ok,
        "profile": profile,
        "row": row,
        "apply_result": apply_result,
        "image": image_data,
        "tcp": tcp_data,
        "validate_tail": validate.get("output", "")[-6000:],
    })


@frequency_bp.route("/results", methods=["GET"])
def results():
    data = _load_results()
    return jsonify(data)
