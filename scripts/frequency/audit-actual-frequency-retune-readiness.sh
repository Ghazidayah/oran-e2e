#!/usr/bin/env bash
set -u
set -o pipefail

REPO="${REPO:-$HOME/oran-e2e}"
NS="${RAN_NS:-${NS:-oran-ran}}"
PORT="${ORAN_DASHBOARD_PORT:-18080}"
BASE="${ORAN_DASHBOARD_BASE:-http://127.0.0.1:${PORT}}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$HOME/oran-proof/actual-frequency-retune-readiness/$TS}"
LOG="$OUT/audit.log"

mkdir -p "$OUT"/{api,configmaps,deployments,extracted,proposals}
exec > >(tee -a "$LOG") 2>&1

PASS=0
WARN=0
FAIL=0

pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
warn(){ echo "[WARN] $1"; WARN=$((WARN+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
have(){ command -v "$1" >/dev/null 2>&1; }

section(){
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

capture(){
  local label="$1"; local file="$2"; shift 2
  echo "===== $label =====" > "$file"
  echo "COMMAND: $*" >> "$file"
  echo >> "$file"
  if "$@" >> "$file" 2>&1; then
    pass "$label"
    return 0
  else
    warn "$label failed; see $file"
    return 1
  fi
}

kcap(){
  local label="$1"; local file="$2"; shift 2
  if have kubectl; then
    capture "$label" "$file" kubectl "$@"
  else
    fail "kubectl not found"
    return 1
  fi
}

json_pretty(){
  local f="$1"
  if [ -s "$f" ] && have python3; then
    python3 -m json.tool "$f" 2>/dev/null || cat "$f"
  else
    cat "$f" 2>/dev/null || true
  fi
}

extract_cm_data(){
  local cm="$1"
  local key="$2"
  local dst="$3"
  kubectl -n "$NS" get cm "$cm" -o "jsonpath={.data.${key}}" > "$dst" 2>"$dst.err" || return 1
  [ -s "$dst" ]
}

section "0. READ-ONLY AUDIT CONTEXT"
echo "Repo=$REPO"
echo "Namespace=$NS"
echo "Dashboard=$BASE"
echo "Output=$OUT"
date -Iseconds | tee "$OUT/date.txt"

cd "$REPO" || { fail "cannot cd to $REPO"; exit 1; }
pass "repo reachable"

cat > "$OUT/safety-note.txt" <<'TXT'
READ-ONLY AUDIT.
This script does not patch ConfigMaps, update Deployments, restart pods, change tc/netem, change routes, or modify ue2-ue5.
TXT
cat "$OUT/safety-note.txt"

if [ -d .git ]; then
  git branch --show-current > "$OUT/git-branch.txt" 2>&1 || true
  git rev-parse HEAD > "$OUT/git-head.txt" 2>&1 || true
  git log --oneline -n 8 > "$OUT/git-log.txt" 2>&1 || true
  git status --short > "$OUT/git-status.txt" 2>&1 || true
  echo "--- git head ---"
  cat "$OUT/git-head.txt" || true
  echo "--- git status --short ---"
  cat "$OUT/git-status.txt" || true
fi

section "1. CURRENT ATTACH / DASHBOARD STATE"

if have curl; then
  if curl -fsS --max-time 20 "$BASE/api/handover/mixed-du/status" > "$OUT/api/handover-mixed-du-status.json" 2>"$OUT/api/handover-mixed-du-status.err"; then
    pass "mixed-DU status API reachable"
    json_pretty "$OUT/api/handover-mixed-du-status.json" | tee "$OUT/api/handover-mixed-du-status.pretty.txt" | head -120
  else
    warn "mixed-DU status API not reachable"
    cat "$OUT/api/handover-mixed-du-status.err" || true
  fi

  if curl -fsS --max-time 20 "$BASE/api/frequency/status" > "$OUT/api/frequency-status.json" 2>"$OUT/api/frequency-status.err"; then
    pass "frequency status API reachable"
    json_pretty "$OUT/api/frequency-status.json" | tee "$OUT/api/frequency-status.pretty.txt" | head -120
  else
    warn "frequency status API not reachable"
    cat "$OUT/api/frequency-status.err" || true
  fi
else
  warn "curl not found; dashboard API checks skipped"
fi

kcap "RAN pods" "$OUT/ran-pods.txt" -n "$NS" get pods -o wide
kcap "RAN services" "$OUT/ran-services.txt" -n "$NS" get svc -o wide
kcap "RAN ConfigMaps" "$OUT/configmaps/configmaps.txt" -n "$NS" get cm
kcap "RAN Deployments" "$OUT/deployments/deployments.txt" -n "$NS" get deploy -o wide

if [ -f scripts/validate-e2e.sh ]; then
  echo "Running read-only validate-e2e.sh..."
  if bash scripts/validate-e2e.sh > "$OUT/validate-e2e.log" 2>&1; then
    pass "validate-e2e.sh completed"
  else
    warn "validate-e2e.sh returned non-zero"
  fi
  tail -100 "$OUT/validate-e2e.log" || true
else
  warn "scripts/validate-e2e.sh not found"
fi

section "2. DU / UE CONFIGMAP AND DEPLOYMENT DUMPS"

DU_CMS=("oai-du0-f1-config" "oai-du1-f1-config")
UE_CMS=("oai-nrue-config" "oai-nrue-config-2" "oai-nrue-config-3" "oai-nrue-config-4" "oai-nrue-config-5")
DU_DEPS=("oai-du0" "oai-du1")
UE_DEPS=("oai-nr-ue" "oai-nr-ue-2" "oai-nr-ue-3" "oai-nr-ue-4" "oai-nr-ue-5")

for cm in "${DU_CMS[@]}"; do
  kcap "ConfigMap $cm yaml" "$OUT/configmaps/$cm.yaml" -n "$NS" get cm "$cm" -o yaml || true
  extract_cm_data "$cm" 'gnb\.conf' "$OUT/extracted/$cm.gnb.conf" && pass "extracted $cm gnb.conf" || warn "could not extract $cm gnb.conf"
done

for cm in "${UE_CMS[@]}"; do
  kcap "ConfigMap $cm yaml" "$OUT/configmaps/$cm.yaml" -n "$NS" get cm "$cm" -o yaml || true
  extract_cm_data "$cm" 'nr-ue\.conf' "$OUT/extracted/$cm.nr-ue.conf" && pass "extracted $cm nr-ue.conf" || warn "could not extract $cm nr-ue.conf"
done

for dep in "${DU_DEPS[@]}" "${UE_DEPS[@]}"; do
  kcap "Deployment $dep yaml" "$OUT/deployments/$dep.yaml" -n "$NS" get deploy "$dep" -o yaml || true
  kcap "Deployment $dep json" "$OUT/deployments/$dep.json" -n "$NS" get deploy "$dep" -o json || true
done

section "3. DU CARRIER KEY SUMMARY"

python3 - "$OUT" <<'PY' | tee "$OUT/du-carrier-summary.txt"
import json, pathlib, re, sys
out = pathlib.Path(sys.argv[1])
cms = ["oai-du0-f1-config", "oai-du1-f1-config"]
keys = [
 "absoluteFrequencySSB",
 "dl_frequencyBand",
 "dl_absoluteFrequencyPointA",
 "dl_carrierBandwidth",
 "ul_frequencyBand",
 "ul_carrierBandwidth",
 "dl_subcarrierSpacing",
 "ul_subcarrierSpacing",
 "initialDLBWPsubcarrierSpacing",
 "initialULBWPsubcarrierSpacing",
 "ssb_PositionsInBurst_Bitmap",
 "ssb_periodicityServingCell",
]
def arfcn_to_mhz(n):
    try: n=int(n)
    except Exception: return None
    if n < 600000: return None
    return 3000.0 + 0.015 * (n - 600000)

summary = {}
for cm in cms:
    p = out / "extracted" / f"{cm}.gnb.conf"
    text = p.read_text(errors="ignore") if p.exists() else ""
    d = {}
    for k in keys:
        m = re.search(rf"\b{k}\b\s*=\s*([^;\n]+)", text)
        if m: d[k] = m.group(1).strip().strip('"')
    if "absoluteFrequencySSB" in d:
        d["absoluteFrequencySSB_MHz"] = round(arfcn_to_mhz(d["absoluteFrequencySSB"]), 3)
    if "dl_absoluteFrequencyPointA" in d:
        d["dl_absoluteFrequencyPointA_MHz"] = round(arfcn_to_mhz(d["dl_absoluteFrequencyPointA"]), 3)
    if "absoluteFrequencySSB" in d and "dl_absoluteFrequencyPointA" in d:
        d["ssb_minus_pointA_arfcn"] = int(d["absoluteFrequencySSB"]) - int(d["dl_absoluteFrequencyPointA"])
    summary[cm] = d

print(json.dumps(summary, indent=2, sort_keys=True))
(out / "du-carrier-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
PY

grep -q absoluteFrequencySSB "$OUT/du-carrier-summary.txt" && pass "DU carrier keys found" || fail "DU carrier keys not found"

section "4. UE CONFIG AND DEPLOYMENT FREQUENCY DISCOVERY"

python3 - "$OUT" <<'PY' | tee "$OUT/ue-frequency-summary.txt"
import json, pathlib, re, sys
out = pathlib.Path(sys.argv[1])
ue_cms = ["oai-nrue-config", "oai-nrue-config-2", "oai-nrue-config-3", "oai-nrue-config-4", "oai-nrue-config-5"]
ue_deps = ["oai-nr-ue", "oai-nr-ue-2", "oai-nr-ue-3", "oai-nr-ue-4", "oai-nr-ue-5"]

summary = {"configmaps": {}, "deployments": {}}

for cm in ue_cms:
    p = out / "extracted" / f"{cm}.nr-ue.conf"
    text = p.read_text(errors="ignore") if p.exists() else ""
    lines = [l for l in text.splitlines() if re.search(r"(?i)frequency|arfcn|band|-C|ssb|rfsimulator|serveraddr|nssai", l)]
    server = None
    m = re.search(r"serveraddr\s*=\s*\"?([^\";\s]+)", text)
    if m: server = m.group(1)
    sst = None
    sd = None
    m = re.search(r"nssai_sst\s*=\s*([^;\n}]+)", text)
    if m: sst = m.group(1).strip()
    m = re.search(r"nssai_sd\s*=\s*([^;\n}]+)", text)
    if m: sd = m.group(1).strip()
    summary["configmaps"][cm] = {
        "serveraddr": server,
        "nssai_sst": sst,
        "nssai_sd": sd,
        "frequency_like_lines": lines,
    }

def tokens_from_container(c):
    vals = []
    vals += c.get("command") or []
    vals += c.get("args") or []
    for e in c.get("env") or []:
        vals.append(str(e.get("name","")) + "=" + str(e.get("value","")))
    joined = "\n".join(map(str, vals))
    toks = []
    for v in vals: toks += str(v).split()
    def after(flag):
        if flag in toks:
            i = toks.index(flag)
            if i + 1 < len(toks): return toks[i+1]
        m = re.search(re.escape(flag) + r"[= ]([^\s]+)", joined)
        return m.group(1) if m else None
    return {
        "-C": after("-C"),
        "--ssb": after("--ssb"),
        "--numerology": after("--numerology"),
        "-r": after("-r"),
        "--rfsimulator.serveraddr": after("--rfsimulator.serveraddr"),
        "raw_frequency_lines": [x for x in joined.splitlines() if re.search(r"(?i)-C|--ssb|numerology|rfsimulator|frequency|arfcn|band", x)],
    }

for dep in ue_deps:
    p = out / "deployments" / f"{dep}.json"
    if not p.exists() or p.stat().st_size == 0:
        summary["deployments"][dep] = {"error": "missing json"}
        continue
    try:
        obj = json.loads(p.read_text())
    except Exception as e:
        summary["deployments"][dep] = {"error": str(e)}
        continue
    spec = obj.get("spec",{}).get("template",{}).get("spec",{})
    containers = spec.get("containers",[])
    volumes = spec.get("volumes",[])
    summary["deployments"][dep] = {
        "containers": [
            {
                "name": c.get("name"),
                "command": c.get("command"),
                "args": c.get("args"),
                "env": c.get("env"),
                "parsed_frequency_args": tokens_from_container(c),
            } for c in containers
        ],
        "configmap_volumes": [
            {"volume": v.get("name"), "configMap": v.get("configMap",{}).get("name")}
            for v in volumes if "configMap" in v
        ],
    }

print(json.dumps(summary, indent=2, sort_keys=True))
(out / "ue-frequency-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
PY

grep -q '"-C"' "$OUT/ue-frequency-summary.txt" && pass "UE deployment args scanned for -C" || warn "UE -C not found in scan"

section "5. COMPUTE SAFE n78 PHASE-A PROPOSALS"

python3 - "$OUT" <<'PY' | tee "$OUT/proposals/n78-phase-a-profiles.txt"
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
du = json.loads((out/"du-carrier-summary.json").read_text())
ue = json.loads((out/"ue-frequency-summary.json").read_text())

active_cm = "oai-du0-f1-config"
carrier = du.get(active_cm, {})
ue1_cfg = ue.get("configmaps", {}).get("oai-nrue-config", {})
ue1_dep = ue.get("deployments", {}).get("oai-nr-ue", {})

def to_i(x):
    try: return int(str(x).strip())
    except Exception: return None

def arfcn_to_mhz(n):
    if n is None or n < 600000: return None
    return 3000.0 + 0.015 * (n - 600000)

def arfcn_to_hz(n):
    mhz = arfcn_to_mhz(n)
    return None if mhz is None else int(round(mhz * 1000000))

ssb = to_i(carrier.get("absoluteFrequencySSB"))
pointa = to_i(carrier.get("dl_absoluteFrequencyPointA"))
band = to_i(carrier.get("dl_frequencyBand"))
bw = to_i(carrier.get("dl_carrierBandwidth"))
uband = to_i(carrier.get("ul_frequencyBand"))
ubw = to_i(carrier.get("ul_carrierBandwidth"))

freq_args = {}
try:
    freq_args = ue1_dep["containers"][0]["parsed_frequency_args"]
except Exception:
    pass

notes = []
profiles = {}
checks = []

if ssb is None or pointa is None:
    verdict = "CANNOT_COMPUTE_MISSING_DU_ARFCN"
else:
    offset = ssb - pointa
    min_pointa = 620000
    max_ssb = 653000
    default_shift = 1000
    low_shift = min(default_shift, max(0, pointa - min_pointa))
    high_shift = min(default_shift, max(0, max_ssb - ssb))

    if low_shift < default_shift:
        notes.append(f"n78-low limited to {low_shift} ARFCN steps because current PointA is close to lower guard.")
    if high_shift < default_shift:
        notes.append(f"n78-high limited to {high_shift} ARFCN steps by upper guard.")

    def make(name, shift):
        nssb = ssb + shift
        npa = pointa + shift
        return {
            "profile": name,
            "dl_frequencyBand": band,
            "ul_frequencyBand": uband,
            "dl_carrierBandwidth": bw,
            "ul_carrierBandwidth": ubw,
            "absoluteFrequencySSB": nssb,
            "dl_absoluteFrequencyPointA": npa,
            "ssb_minus_pointA_arfcn": offset,
            "absoluteFrequencySSB_MHz": round(arfcn_to_mhz(nssb), 3),
            "dl_absoluteFrequencyPointA_MHz": round(arfcn_to_mhz(npa), 3),
            "ue_C_Hz_if_using_ssb": arfcn_to_hz(nssb),
            "keep_bandwidth_scs_numerology": True,
            "keep_serveraddr": ue1_cfg.get("serveraddr"),
            "keep_s_nssai": {
                "sst": ue1_cfg.get("nssai_sst"),
                "sd": ue1_cfg.get("nssai_sd"),
            },
        }

    profiles["n78-current"] = make("n78-current", 0)
    profiles["restore"] = profiles["n78-current"]
    profiles["n78-low"] = make("n78-low", -low_shift)
    profiles["n78-high"] = make("n78-high", high_shift)

    for name in ["n78-current", "n78-low", "n78-high"]:
        p = profiles[name]
        safe = True
        reasons = []
        if p["dl_frequencyBand"] != 78 or p["ul_frequencyBand"] != 78:
            safe = False; reasons.append("band not 78")
        if p["dl_absoluteFrequencyPointA"] < min_pointa:
            safe = False; reasons.append("PointA below conservative guard")
        if p["absoluteFrequencySSB"] > max_ssb:
            safe = False; reasons.append("SSB above conservative guard")
        checks.append({"profile": name, "safe_for_phase_a": safe, "reasons": reasons})

    verdict = "PHASE_A_PROFILE_VALUES_COMPUTED" if all(c["safe_for_phase_a"] for c in checks) else "PHASE_A_PROFILE_VALUES_HAVE_RISK"

result = {
    "verdict": verdict,
    "active_du_for_phase_a": "du0",
    "active_du_configmap": active_cm,
    "ue1_configmap": "oai-nrue-config",
    "ue1_deployment": "oai-nr-ue",
    "ue1_detected_deployment_frequency_args": freq_args,
    "profiles": profiles,
    "checks": checks,
    "notes": notes,
    "future_apply_guidance": [
        "Patch only UE1 active DU ConfigMap during Phase A.",
        "Patch UE1 deployment -C if and only if -C is detected in args/env.",
        "Preserve serveraddr and S-NSSAI.",
        "Do not touch ue2-ue5.",
        "After each apply, wait for oaitun_ue1 and run scripts/validate-e2e.sh.",
        "If attach fails, restore n78-current automatically."
    ],
}
print(json.dumps(result, indent=2, sort_keys=True))
(out/"proposals/n78-phase-a-profiles.json").write_text(json.dumps(result, indent=2, sort_keys=True))

csv = ["profile,ssb_arfcn,ssb_mhz,pointa_arfcn,pointa_mhz,ue_C_Hz_if_using_ssb,band,bw"]
for name in ["n78-current", "n78-low", "n78-high"]:
    p = profiles.get(name, {})
    csv.append(f"{name},{p.get('absoluteFrequencySSB')},{p.get('absoluteFrequencySSB_MHz')},{p.get('dl_absoluteFrequencyPointA')},{p.get('dl_absoluteFrequencyPointA_MHz')},{p.get('ue_C_Hz_if_using_ssb')},{p.get('dl_frequencyBand')},{p.get('dl_carrierBandwidth')}")
(out/"proposals/n78-phase-a-profiles.csv").write_text("\n".join(csv) + "\n")
PY

grep -q "PHASE_A_PROFILE_VALUES_COMPUTED" "$OUT/proposals/n78-phase-a-profiles.txt" && pass "n78 Phase-A values computed" || warn "n78 Phase-A values not fully computed"

section "6. RISK ASSESSMENT"

cat > "$OUT/risk-assessment.md" <<'TXT'
# Risk assessment

- LOW/MEDIUM: n78-low/n78-high stay inside band 78 and keep bandwidth/SCS stable, but attach can still fail if UE-side -C handling differs from DU-side ARFCN.
- MEDIUM: If UE deployment args do not expose -C, actual UE-side retune method must be found before applying.
- LOW: Actual carrier retune alone may not create large KPI differences in RFsim.
- REQUIRED: Future apply script must restore n78-current automatically if attach or validate-e2e fails.
- REQUIRED: Phase A must use ue1 only and must not touch ue2-ue5.
TXT
cat "$OUT/risk-assessment.md"

section "7. FINAL VERDICT"

cat > "$OUT/README.md" <<EOF2
# Actual Frequency Retune Readiness Audit

Timestamp: $TS
Repo: $REPO
Namespace: $NS
Dashboard: $BASE

Important files:
- audit.log
- api/handover-mixed-du-status.json
- api/frequency-status.json
- validate-e2e.log
- du-carrier-summary.json
- ue-frequency-summary.json
- proposals/n78-phase-a-profiles.json
- proposals/n78-phase-a-profiles.csv
- risk-assessment.md
EOF2

echo "PASS=$PASS"
echo "WARN=$WARN"
echo "FAIL=$FAIL"
echo "OUTPUT_DIR=$OUT"
echo "LOG=$LOG"

if [ "$FAIL" -eq 0 ] && grep -q "PHASE_A_PROFILE_VALUES_COMPUTED" "$OUT/proposals/n78-phase-a-profiles.txt"; then
  VERDICT="ACTUAL_FREQUENCY_RETUNE_READINESS_PASS"
elif [ "$FAIL" -eq 0 ]; then
  VERDICT="ACTUAL_FREQUENCY_RETUNE_READINESS_PASS_WITH_WARNINGS"
else
  VERDICT="ACTUAL_FREQUENCY_RETUNE_READINESS_HAS_FAILURES"
fi

echo "VERDICT=$VERDICT" | tee "$OUT/final-verdict.txt"

[ "$FAIL" -eq 0 ]
