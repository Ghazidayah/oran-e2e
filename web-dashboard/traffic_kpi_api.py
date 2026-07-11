import re
import json
import pathlib
from flask import Blueprint, jsonify

traffic_kpi_bp = Blueprint("traffic_kpi", __name__)

PROOF = pathlib.Path.home() / "oran-proof" / "phase2-traffic-api"

SCENARIO_LABELS = {
    "image": "Image Download",
    "iperf-tcp": "iperf3 TCP Throughput",
    "udp": "Custom UDP Jitter/Loss",
    "video": "Video Download",
    "web": "Web Browsing",
    "streaming": "Streaming-like HLS",
    "run-all": "Run All Realistic Traffic",
}


def _parse_kpis(text):
    def last(pattern, cast=str):
        m = re.findall(pattern, text)
        if not m:
            return None
        try:
            return cast(m[-1])
        except Exception:
            return None

    def first_non_none(*values):
        for v in values:
            if v is not None:
                return v
        return None

    k = {}
    k["verdict"] = last(r'(?:Verdict|"verdict"):\s*"?([A-Za-z_]+)"?')

    k["throughput_mbps"] = first_non_none(
        last(r'(?:Average throughput|Throughput) Mbps:\s*([0-9.]+)', float),
        last(r'"throughput_mbps":\s*([0-9.]+)', float),
    )

    k["loss_pct"] = last(r'Packet loss percent:\s*([0-9.]+)', float)
    k["retransmits"] = last(r'TCP retransmits:\s*([0-9]+)', int)
    k["jitter_ms"] = last(r'Estimated jitter ms:\s*([0-9.]+)', float)

    checksum = last(r'(?:Checksum OK|"checksum_ok"):\s*(True|true|False|false)')
    seg_ok = last(r'Segments OK:\s*([0-9]+)', int)
    seg_req = last(r'Segments requested:\s*([0-9]+)', int)
    res_ok = last(r'Resources OK:\s*([0-9]+)', int)
    res_req = last(r'Resources requested:\s*([0-9]+)', int)
    if seg_ok is not None and seg_req is not None:
        k["integrity"] = f"{seg_ok}/{seg_req} segments"
    elif res_ok is not None and res_req is not None:
        k["integrity"] = f"{res_ok}/{res_req} resources"
    elif checksum is not None:
        k["integrity"] = "checksum " + ("OK" if checksum.lower() == "true" else "FAIL")
    elif k["loss_pct"] is not None:
        k["integrity"] = f"{k['loss_pct']}% loss"
    elif k["retransmits"] is not None:
        k["integrity"] = f"{k['retransmits']} retrans"
    else:
        k["integrity"] = "-"

    k["time_s"] = first_non_none(
        last(r'(?:Duration seconds|Transfer time seconds|Page load time seconds|Total time seconds):\s*([0-9.]+)', float),
        last(r'"(?:time_seconds|duration_seconds)":\s*([0-9.]+)', float),
    )

    k["bytes"] = first_non_none(
        last(r'(?:Bytes received|Downloaded bytes|Total bytes|Total segment bytes|Expected size):\s*([0-9]+)', int),
        last(r'"(?:downloaded_bytes|bytes_received)":\s*([0-9]+)', int),
    )

    return k


@traffic_kpi_bp.route("/api/e2e-kpi/results", methods=["GET"])
def e2e_kpi_results():
    latest = {}
    try:
        for d in sorted(PROOF.iterdir()):
            sf = d / "summary.json"
            if not sf.is_file():
                continue
            try:
                job = json.loads(sf.read_text())
            except Exception:
                continue
            scen = job.get("scenario", "")
            if not scen:
                continue
            latest[scen] = job
    except Exception:
        pass

    rows = []
    for scen, job in latest.items():
        log_file = pathlib.Path(job.get("log_file", ""))
        output = log_file.read_text(errors="ignore")[-30000:] if log_file.is_file() else ""
        kpis = _parse_kpis(output)
        rows.append({
            "scenario": scen,
            "label": SCENARIO_LABELS.get(scen, scen),
            "status": job.get("status", "?"),
            "exit": job.get("exit"),
            "finished_at": job.get("finished_at", ""),
            **kpis,
        })
    rows.sort(key=lambda r: r.get("scenario", ""))
    return jsonify({"ok": True, "rows": rows})
