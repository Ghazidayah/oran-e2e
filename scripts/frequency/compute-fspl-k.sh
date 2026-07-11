#!/usr/bin/env bash
# compute-fspl-k.sh — derive relative degradation coefficient K from FSPL model
# K = 10^(-ΔPL/10), where ΔPL = 20*log10(f_target/f_ref)  (distance cancels)
# Usage: compute-fspl-k.sh <f_ref_MHz> <f_target_MHz>
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
