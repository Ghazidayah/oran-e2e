#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Deriving the attenuation coefficient between two frequencies.
#
# Role     : compute, at runtime, the free-space path-loss difference between
#            a reference frequency and a target frequency.
# Formulas : dPL = 20 x log10(f_target / f_ref)      in dB
#            K   = 10^(-dPL/10)                      power ratio
# Key point: distance and the constant CANCEL OUT by difference. The
#            coefficient therefore contains no arbitrary parameter, not even
#            a distance assumption -- which is what lets you claim it is
#            derived rather than chosen.
# Inputs   : two frequencies, in MHz
# Output   : dPL and K, consumed by apply-fspl-band-profile.sh
# Usage    : bash scripts/frequency/compute-fspl-k.sh <f_ref_MHz> <f_target_MHz>
# ---------------------------------------------------------------------------
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <f_ref_MHz> <f_target_MHz>" >&2
  echo "Example: $0 2593.35 3499.68" >&2
  exit 1
fi

F_REF="$1"
F_TGT="$2"

read -r DPL K <<<"$(awk -v fr="$F_REF" -v ft="$F_TGT" 'BEGIN{
  dpl = 20*log(ft/fr)/log(10);
  k   = exp(-dpl/10*log(10));
  printf "%.2f %.2f", dpl, k;
}')"

echo "f_ref    = ${F_REF} MHz"
echo "f_target = ${F_TGT} MHz"
echo "delta_PL = ${DPL} dB"
echo "K        = ${K}"
