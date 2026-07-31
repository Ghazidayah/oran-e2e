#!/usr/bin/env bash
# apply-fspl-band-profile.sh — emulate frequency-band path loss as a throughput cap.
# Reuses the SAME netem+tbf+ifb mechanism as scripts/slicing/apply-slice-resource-profile.sh.
# Rate source: K = 10^(-dPL/10), dPL = 20*log10(f_target/f_ref)  -> PCT = round(K*100).
# Usage: apply-fspl-band-profile.sh <band n41|n78|n77 | f_target_MHz> [clear]
#        apply-fspl-band-profile.sh clear
set +e; set +u
NS="${NS:-oran-ran}"; DEP="${DEP:-oai-nr-ue}"
REPO="${REPO:-$HOME/oran-e2e}"
source "$REPO/scripts/ue/ue-common.sh"

F_REF="${F_REF:-2593.35}"     # n41 reference carrier (MHz)
CEILING_MBIT="${CEILING_MBIT:-$(cat $HOME/oran-proof/ceiling-mbit.txt 2>/dev/null || echo 33)}"
BURST="${BURST:-256kb}"; LATENCY="${LATENCY:-50ms}"; DELAY="${DELAY:-2ms}"

ARG="${1:-}"; UE="$(ue_pod_for_deployment "$NS" "$DEP")"
[ -z "$UE" ] && { echo "VERDICT=UE1_POD_NOT_FOUND"; exit 0; }

if [ "$ARG" = "clear" ]; then
  kubectl -n "$NS" exec "$UE" -- sh -lc '
    tc qdisc del dev oaitun_ue1 root 2>/dev/null || true
    tc qdisc del dev oaitun_ue1 ingress 2>/dev/null || true
    ip link del ifb_ue1 2>/dev/null || true
    tc qdisc show dev oaitun_ue1 || true'
  echo "VERDICT=FSPL_BAND_CLEARED"; exit 0
fi

case "$ARG" in
  n41|N41) F_TGT=2593.35 ;;
  n78|N78) F_TGT=3499.68 ;;
  n77|N77) F_TGT=4173.60 ;;
  ''|*[!0-9.]*) echo "Usage: $0 <n41|n78|n77 | f_target_MHz> | clear"; echo "VERDICT=BAD_ARG"; exit 0 ;;
  *) F_TGT="$ARG" ;;
esac

read -r DPL K PCT <<<"$(awk -v fr="$F_REF" -v ft="$F_TGT" 'BEGIN{
  dpl=20*log(ft/fr)/log(10); k=exp(-dpl/10*log(10));
  printf "%.2f %.2f %d", dpl, k, (k*100)+0.5;
}')"
RATE="$(awk "BEGIN{printf \"%dmbit\", $PCT*$CEILING_MBIT/100}")"

echo "===== FSPL band emulation on UE1 ====="
echo "f_ref=${F_REF}MHz  f_target=${F_TGT}MHz  dPL=${DPL}dB  K=${K}  PCT=${PCT}%"
echo "Pod: $UE   Ceiling: ${CEILING_MBIT}mbit   -> rate=$RATE  burst=$BURST  netem-delay=$DELAY"

kubectl -n "$NS" exec "$UE" -- sh -lc "
  tc qdisc del dev oaitun_ue1 root 2>/dev/null || true
  tc qdisc del dev oaitun_ue1 ingress 2>/dev/null || true
  ip link del ifb_ue1 2>/dev/null || true
  tc qdisc replace dev oaitun_ue1 root handle 1: netem delay $DELAY
  tc qdisc replace dev oaitun_ue1 parent 1: handle 2: tbf rate $RATE burst $BURST latency $LATENCY
  ip link add ifb_ue1 type ifb 2>/dev/null
  ip link set ifb_ue1 up
  tc qdisc add dev oaitun_ue1 handle ffff: ingress
  tc filter add dev oaitun_ue1 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb_ue1
  tc qdisc replace dev ifb_ue1 root handle 1: netem delay $DELAY
  tc qdisc replace dev ifb_ue1 parent 1: handle 2: tbf rate $RATE burst $BURST latency $LATENCY
  echo '--- oaitun_ue1 (egress) ---'; tc qdisc show dev oaitun_ue1
  echo '--- ifb_ue1 (ingress) ---'; tc qdisc show dev ifb_ue1
"
echo "VERDICT=FSPL_BAND_APPLIED band_pct=${PCT} rate=${RATE}"
