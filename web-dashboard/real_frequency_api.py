import json
import math
import os
import re
import subprocess
import time
from pathlib import Path

from flask import Blueprint, jsonify, request

from settings import PROOF_DIR, REPO

real_freq_bp = Blueprint("real_freq_bp", __name__)

SCRIPT = REPO / "scripts" / "frequency" / "switch-ue-actual-frequency-retune-du-aware.sh"
RESULTS_FILE = Path(__file__).resolve().with_name("real-frequency-results.json")
KPI_RESULTS_FILE = Path(__file__).resolve().with_name("freq-kpi-results.json")

# Selectable retune profiles (n78-3500 is the baseline carrier the platform starts on)
PROFILES = {
    "n78-3500": {
        "freq_mhz": 3499.68,
        "band": "n78",
        "description": "Baseline n78 3500 MHz, SSB 633312, PointA 632040",
        "ssb": "633312",
        "pointa": "632040",
    },
    "n41-2600": {
        "freq_mhz": 2593.35,
        "band": "n41",
        "description": "n41 2600 MHz, SSB 518670, PointA 514854",
        "ssb": "518670",
        "pointa": "514854",
    },
    "n77-4174": {
        "freq_mhz": 4173.60,
        "band": "n77",
        "description": "n77 4174 MHz, SSB 678240, PointA 676968",
        "ssb": "678240",
        "pointa": "676968",
    },
}


# Representative tc netem profiles per band - EMULATED, not measured from RFsim
def _ceiling_mbit():
    """Plafond reel = debit DL TCP non-capped (UE1 isole). AUTO-MESURE par
    scripts/traffic/measure-ceiling.sh, qui ecrit ~/oran-proof/ceiling-mbit.txt.
    Ne PAS hardcoder. Ancienne mesure (en UL): ~36. A refaire en DL. Fallback 33 = filet
    de securite seulement (si la calibration n'a jamais tourne)."""
    try:
        return int((PROOF_DIR / "ceiling-mbit.txt").read_text().strip())
    except Exception:
        return 33


_CEIL = _ceiling_mbit()


def _rate_kbit(fraction):
    """Rate string for tc in kbit (not rounded down to whole Mbit/s)."""
    return f"{max(1, int(round(fraction * _CEIL * 1000)))}kbit"

# Le pourcentage de chaque bande est calcule (loi de Shannon), rien n'est ecrit en dur:
#   dPL = 20*log10(f_cible/f_ref)            (la distance s'elimine)
#   SNR_cible = SNR_ref - dPL  (dB)           SNR_ref = variable SNR_REF, 20 dB par defaut
#   K = log2(1+SNR_cible) / log2(1+SNR_ref)   (SNR en lineaire, la largeur de bande s'elimine)
# Le resultat est un debit MODELISE, pas la mesure d'un canal radio reel.
# Debit par bande = % du plafond mesure, DECROISSANT avec la frequence: une bande
# plus haute subit plus d'attenuation (path loss) -> moins de debit, a budget radio
# egal. RFsim n'a PAS de modele de propagation: ce profil est EMULE (tc netem rate)
# pour illustrer la tendance physique d'un deploiement reel; le retuning de porteuse,
# lui, est REEL (changement d'ARFCN + re-validation E2E).
# IMPORTANT: chaque cap (70/50/30%) est pose SOUS le plafond mesure -> le netem est
# la contrainte qui MORD -> debit mesure ~= cap, donc reproductible et attribuable a
# l'emulation (et non au bruit RFsim). Plafond AUTO-MESURE (UE1 isole, ~36 le 06-30):
# caps ~25/18/10 mbit, tous < plafond -> n41 > n78 > n77, descente monotone.
# La latence n'est PAS differenciee par bande: physiquement elle ne depend pas de
# la bande -> on ne faconne que le debit; le ping reflete la base RFsim (~15ms),
# identique pour toutes les bandes.
F_REF_MHZ = 2593.35  # n41, porteuse de reference
try:
    SNR_REF_DB = float(os.environ.get("SNR_REF", "20"))
except ValueError:
    SNR_REF_DB = 20.0


def _band_k(freq_mhz):
    """Return (dPL dB, SNR cible dB, K, pourcentage entier) pour une porteuse en MHz."""
    dpl = 20.0 * math.log10(freq_mhz / F_REF_MHZ)
    snr_t = SNR_REF_DB - dpl
    k = math.log(1.0 + 10.0 ** (snr_t / 10.0)) / math.log(1.0 + 10.0 ** (SNR_REF_DB / 10.0))
    return dpl, snr_t, k, int(k * 100 + 0.5)


def _band_netem(profile, label):
    """Cap d'une bande, calcule par la loi de Shannon."""
    dpl, snr_t, k, pct = _band_k(PROFILES[profile]["freq_mhz"])
    return {
        "pct": pct, "rate": _rate_kbit(pct / 100.0),
        "k": round(k, 2), "dpl_db": round(dpl, 2), "snr_db": round(snr_t, 2),
        "label": f"{label} - Shannon K={k:.2f}",
    }


BAND_NETEM = {
    "n41-2600": _band_netem("n41-2600", "Mid-band 2600 MHz (TDD)"),
    "n78-3500": _band_netem("n78-3500", "C-band 3500 MHz (TDD)"),
    "n77-4174": _band_netem("n77-4174", "Upper C-band 4174 MHz (TDD)"),
}

# KPI measurement target: UPF DN gateway (in 5G data path, ~15ms RFsim base RTT).
# Never use an internet target: ~60-90ms internet RTT swamps the emulated deltas.
# Rate caps sit BELOW the measured uncapped RFsim TCP floor (~17 Mbps in UL; to be
# re-measured now that TCP is download) AND below each band's real per-band rate, so the
# netem cap is the binding constraint -> measured ~= cap and band ordering is a
# reproducible monotone DESCENT (n41 > n78 > n77), not RFsim noise. Throughput is
# DOWNLOAD (iperf3 -R: host node sends, UE receives); the cap is applied on both
# directions (netem on oaitun_ue1 egress, ifb_ue1 mirror for ingress).
KPI_PING_TARGET = "10.45.0.1"

# Nettoyage complet du faconnage: qdisc root et ingress de oaitun_ue1 + interface ifb_ue1.
TC_CLEAR = (
    "tc qdisc del dev oaitun_ue1 root 2>/dev/null; "
    "tc qdisc del dev oaitun_ue1 ingress 2>/dev/null; "
    "ip link del ifb_ue1 2>/dev/null"
)


def _default_results():
    return {
        "ok": True,
        "active_profile": "n78-3500",
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
    data.setdefault("active_profile", "n78-3500")
    data.setdefault("profiles", PROFILES)
    data.setdefault("rows", [])
    return data


def _save_results(data):
    data["profiles"] = PROFILES
    RESULTS_FILE.write_text(json.dumps(data, indent=2, sort_keys=True))


# After a scenario, put the carrier back on the reference profile so the platform
# is never left on a test band (a stale DU carrier leaves the UEs looping on
# "Got NACK ... SIB1" at the next start). Disable: ORAN_FREQ_AUTO_RESTORE=0, or
# send {"auto_restore": false} in the POST body to keep the tested band.
BASELINE_PROFILE = "n78-3500"
AUTO_RESTORE = os.environ.get("ORAN_FREQ_AUTO_RESTORE", "1") == "1"


def _auto_restore(profile, enabled):
    """Return (restored_ok, log). restored_ok is None when no restore was needed."""
    if not enabled or profile == BASELINE_PROFILE:
        return None, ""
    res = _run(BASELINE_PROFILE, timeout=900)
    log = "\n\n--- AUTO RESTORE " + BASELINE_PROFILE + " ---\n" + res.get("output", "")
    if res["ok"]:
        data = _load_results()
        data["active_profile"] = BASELINE_PROFILE
        _save_results(data)
    return res["ok"], log


def _run(profile, timeout=900):
    if profile not in PROFILES and profile != "status":
        return {"ok": False, "returncode": 2, "output": f"Unknown real-frequency profile: {profile}"}

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
    tunnel_flags = re.findall(r"TUNNEL_READY=(yes|no)", output or "")
    tunnel = tunnel_flags[-1] if tunnel_flags else "no"
    return {
        "carrier_keys": keys,
        "du_deploy": du_deploy.group(1) if du_deploy else "",
        "du_cm": du_cm.group(1) if du_cm else "",
        "ue_deploy": ue_deploy.group(1) if ue_deploy else "",
        "verdict": verdict.group(1) if verdict else "",
        "tunnel_ready": tunnel,
    }


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


@real_freq_bp.route("/results", methods=["GET"])
def results():
    data = _load_results()
    return jsonify(data)


@real_freq_bp.route("/run-band", methods=["POST"])
def run_band():
    payload = request.get_json(silent=True) or {}
    profile = payload.get("profile", "")
    if profile not in PROFILES:
        return jsonify({"ok": False, "error": f"Unknown profile: {profile}"}), 400

    auto_restore = bool(payload.get("auto_restore", AUTO_RESTORE))

    # Step 1 - REAL carrier retune
    res = _run(profile, timeout=900)
    parsed = _parse_carrier_keys(res.get("output", ""))
    retune_log = res.get("output", "")

    if not res["ok"]:
        return jsonify({
            "ok": False,
            "profile": profile,
            "row": None,
            "retune_verdict": "FAIL",
            "log": retune_log,
        })

    # Baseline carrier: retune only, there is no emulated KPI profile for it.
    if profile not in BAND_NETEM:
        data = _load_results()
        data["active_profile"] = profile
        _save_results(data)
        restored, restore_log = _auto_restore(profile, auto_restore)
        return jsonify({
            "ok": restored is not False,
            "profile": profile,
            "row": None,
            "retune_verdict": parsed["verdict"] or "PASS",
            "restored": restored,
            "log": retune_log + restore_log,
        })

    # Step 2 - EMULATED netem KPI (only runs if retune succeeded)
    kpi = _run_kpi_test(profile)
    kpi_log = kpi.get("log", "")

    row = {
        "profile":        profile,
        "band":           PROFILES[profile]["band"],
        "freq_mhz":       PROFILES[profile]["freq_mhz"],
        "ssb":            PROFILES[profile]["ssb"],
        "pointa":         PROFILES[profile]["pointa"],
        "du_deploy":      parsed["du_deploy"],
        "retune_verdict": parsed["verdict"] or "PASS",
        "tunnel_ready":   parsed["tunnel_ready"],
        "netem":          kpi.get("netem", ""),
        "snr_ref_db":     SNR_REF_DB,
        "ping_avg":       kpi.get("ping_avg", "?"),
        "ping_loss":      kpi.get("ping_loss", "?"),
        "tcp_mbps":       kpi.get("tcp_mbps", "?"),
        "retransmits":    kpi.get("retransmits", "?"),
        "timestamp":      time.strftime("%Y-%m-%d %H:%M:%S"),
        "verdict":        "PASS" if res["ok"] and kpi.get("ok") else "FAIL",
    }
    _save_kpi_result(row)

    # Keep active_profile in sync so the status header reflects the band just run.
    data = _load_results()
    data["active_profile"] = profile
    _save_results(data)

    # The KPI row is already saved above: restoring afterwards loses no result.
    restored, restore_log = _auto_restore(profile, auto_restore)

    return jsonify({
        "ok":      row["verdict"] == "PASS" and restored is not False,
        "profile": profile,
        "row":     row,
        "restored": restored,
        "log":     retune_log + "\n\n--- EMULATED KPI ---\n" + kpi_log + restore_log,
    })


# ── KPI comparison helpers ──────────────────────────────────────────────────

def _get_ue_pod():
    proc = subprocess.run(
        ["kubectl", "-n", "oran-ran", "get", "pod", "-l", "app=oai-nr-ue",
         "--field-selector=status.phase=Running",
         "-o", "jsonpath={.items[0].metadata.name}"],
        text=True, capture_output=True, timeout=20,
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
        text=True, capture_output=True, timeout=20,
    )
    if chk.returncode != 0:
        return {"ok": False, "error": "oaitun_ue1 not up", "log": "oaitun_ue1 not found in UE pod"}
    log.append("oaitun_ue1 up")

    # Seul le RATE est faconne (proxy d'attenuation: bande haute -> debit plus bas).
    # Cap pose SOUS le debit reel de la bande -> netem MORD, debit mesure ~= cap.
    # Pas de delay/jitter/loss artificiels: la latence ne depend pas de la bande
    # -> ping = base RFsim reelle, identique entre bandes.
    # Le TCP est mesure en DOWNLOAD (iperf3 -R): le cap doit donc aussi s'appliquer au
    # sens descendant. Meme mecanisme que scripts/frequency/apply-fspl-band-profile.sh:
    # le trafic entrant sur oaitun_ue1 est redirige vers ifb_ue1, qui porte le meme cap.
    tc_apply = (
        TC_CLEAR + "; "
        f"tc qdisc add dev oaitun_ue1 root netem rate {netem['rate']}; "
        "ip link add ifb_ue1 type ifb && ip link set ifb_ue1 up && "
        "tc qdisc add dev oaitun_ue1 handle ffff: ingress && "
        "tc filter add dev oaitun_ue1 parent ffff: protocol ip u32 match u32 0 0 "
        "action mirred egress redirect dev ifb_ue1 && "
        f"tc qdisc add dev ifb_ue1 root netem rate {netem['rate']}"
    )

    ping_out = ""
    iperf_out = ""
    try:
        subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--", "sh", "-lc", tc_apply],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
        )
        log.append(f"netem applied: rate={netem['rate']} "
                   f"({netem['pct']}% du plafond {_CEIL}mbit - modele Shannon, K={netem['k']})")

        show = subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--",
             "tc", "qdisc", "show", "dev", "oaitun_ue1"],
            text=True, capture_output=True, timeout=10,
        )
        log.append(f"tc state: {show.stdout.strip()}")
        show_ifb = subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--",
             "tc", "qdisc", "show", "dev", "ifb_ue1"],
            text=True, capture_output=True, timeout=10,
        )
        log.append(f"tc state (download, ifb_ue1): {show_ifb.stdout.strip() or show_ifb.stderr.strip()}")

        p = subprocess.run(
            ["kubectl", "-n", "oran-ran", "exec", pod, "--",
             "ping", "-I", "oaitun_ue1", "-c", "20", "-i", "0.3", KPI_PING_TARGET],
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
             TC_CLEAR + "; true"],
            text=True, capture_output=True, timeout=15,
        )
        log.append("netem cleared")

    loss_m = re.search(r"(\d+(?:\.\d+)?)% packet loss", ping_out)
    rtt_m = re.search(r"rtt min/avg/max/mdev = ([\d.]+)/([\d.]+)/([\d.]+)/([\d.]+)", ping_out)
    tcp_m = re.search(r"Throughput Mbps:\s*([\d.]+)", iperf_out)
    retrans_m = re.search(r"TCP retransmits:\s*(\d+)", iperf_out)

    return {
        "ok": True,
        "profile": profile,
        "netem": f"rate {netem['rate']} ({netem['pct']}% du plafond - modele Shannon, K={netem['k']})",
        "ping_loss": (loss_m.group(1) + "%") if loss_m else "?",
        "ping_avg": (rtt_m.group(2) + " ms") if rtt_m else "?",
        "ping_rtt": (f"{rtt_m.group(1)}/{rtt_m.group(2)}/{rtt_m.group(3)}/{rtt_m.group(4)} ms") if rtt_m else "?",
        "tcp_mbps": tcp_m.group(1) if tcp_m else "?",
        "retransmits": retrans_m.group(1) if retrans_m else "?",
        "log": "\n".join(log),
    }


@real_freq_bp.route("/kpi-results", methods=["GET"])
def kpi_results():
    return jsonify({
        "ok": True,
        "rows": _load_kpi_results(),
        "netem_profiles": BAND_NETEM,
        "snr_ref_db": SNR_REF_DB,
        "note": "KPIs are EMULATED via tc netem on oaitun_ue1 (upload) and ifb_ue1 (download). Differences come from the netem profile, not RFsim physics.",
    })
