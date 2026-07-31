#!/usr/bin/env bash
# ==========================================================================
# Auto-calibration du PLAFOND de débit (UL TCP non-capé, UE1 isolé).
# Écrit la MÉDIANE entière dans ~/oran-proof/ceiling-mbit.txt + preuve JSON.
# ==========================================================================
set -uo pipefail
REPO="${REPO:-$HOME/oran-e2e}"
SAMPLES="${SAMPLES:-3}"
DURATION="${DURATION:-15}"
OUT="$HOME/oran-proof/ceiling-mbit.txt"
PROOFDIR="$HOME/oran-proof/ceiling-calibration"
TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$PROOFDIR" "$(dirname "$OUT")"

echo "===== CALIBRATION PLAFOND (UL TCP non-capé, UE1 isolé) ====="
echo "SAMPLES=$SAMPLES  DURATION=${DURATION}s  TS=$TS"

echo "----- vidage de tout façonnage sur oaitun_ue1 -----"
bash "$REPO/scripts/slicing/apply-slice-resource-profile.sh" clear >/dev/null 2>&1 || true

vals=()
for i in $(seq 1 "$SAMPLES"); do
  out="$(DURATION="$DURATION" bash "$REPO/scripts/traffic/run-iperf-tcp.sh" 2>/dev/null || true)"
  m="$(awk '/Throughput Mbps:/{print $3; exit}' <<<"$out")"
  if [ -n "$m" ]; then
    echo "  échantillon $i : ${m} Mbps"
    vals+=("$m")
  else
    echo "  échantillon $i : (échec iperf, ignoré)"
  fi
done

[ "${#vals[@]}" -ge 1 ] || { echo "[FAIL] aucune mesure valide — plafond non mis à jour."; exit 1; }

CEIL="$(printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print int(a[int((NR+1)/2)])}')"
[ "$CEIL" -ge 1 ] 2>/dev/null || { echo "[FAIL] médiane invalide ($CEIL)."; exit 1; }
echo "$CEIL" > "$OUT"

python3 - "$PROOFDIR/ceiling-$TS.json" "$CEIL" "$TS" "$DURATION" "${vals[@]}" <<'PY'
import json, sys
out, ceil, ts, dur = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
samples = [float(x) for x in sys.argv[5:]]
json.dump({"timestamp": ts, "samples_mbps": samples, "median_floor_mbit": ceil,
           "duration_s": dur, "conditions": "UL TCP, UE1 isolé, netem/tbf vidés (uncapped)",
           "note": "ref pour les caps slices/fréquence (% de cette valeur). Sous charge 5-UE le débit/UE est plus bas."},
          open(out, "w"), indent=2)
print("preuve:", out)
PY

echo "=============================================================="
echo "PLAFOND CALIBRÉ = ${CEIL} Mbit  ->  $OUT   (${TS})"
echo "=============================================================="
