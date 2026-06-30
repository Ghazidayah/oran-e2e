#!/usr/bin/env bash
set +e; set +u
PROFILE="${1:-embb}"
NS="${NS:-oran-ran}"; DEP="${DEP:-oai-nr-ue}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"
source "$REPO/scripts/ue/ue-common.sh"

# Plafond = débit UL TCP non-capped, AUTO-MESURE par scripts/traffic/measure-ceiling.sh
# (UE1 isolé, ~36 le 2026-06-30). rate = PCT % du plafond. eMBB 100% (~plafond, non
# façonné) ; URLLC 60% et mMTC 6% MORDENT. Fallback 33 = filet de sécurité seulement.
CEILING_MBIT="${CEILING_MBIT:-$(cat $HOME/oran-proof/ceiling-mbit.txt 2>/dev/null || echo 33)}"

# Profils par slice:  PCT = % du plafond (débit, ÉMULÉ via tbf)
#                     DELAY = latence one-way (ÉMULÉ via netem ; RTT ~2x)
#  -> RFsim n'a pas de priorité 5QI: la différenciation est émulée (à documenter).
case "$PROFILE" in
  # DELAY proche des cibles 3GPP (URLLC ~1ms limite par le plancher RFsim ~11ms ;
  # eMBB ~4ms ; mMTC = plusieurs secondes). One-way ; RTT ~ base(~11ms) + 2xDELAY.
  embb|eMBB)   PCT=100; BURST="256kb"; LATENCY="50ms";  DELAY="${DELAY:-2ms}"    ;;
  urllc|URLLC) PCT=60;  BURST="64kb";  LATENCY="5ms";   DELAY="${DELAY:-0ms}"    ;;
  mmtc|mMTC)   PCT=6;   BURST="32kb";  LATENCY="100ms"; DELAY="${DELAY:-1000ms}" ;;
  clear)       PCT="" ;;
  *) echo "Unknown profile: $PROFILE"; echo "VERDICT=UNKNOWN_RESOURCE_PROFILE"; exit 0 ;;
esac

UE="$(ue_pod_for_deployment "$NS" "$DEP")"
echo "===== Apply resource profile to UE1 ====="
echo "Profile: $PROFILE   Pod: $UE   Plafond: ${CEILING_MBIT}mbit"
[ -z "$UE" ] && { echo "VERDICT=UE1_POD_NOT_FOUND"; exit 0; }

if [ "$PROFILE" = "clear" ]; then
  kubectl -n "$NS" exec "$UE" -- sh -lc '
    tc qdisc del dev oaitun_ue1 root 2>/dev/null || true
    tc qdisc del dev oaitun_ue1 ingress 2>/dev/null || true
    ip link del ifb_ue1 2>/dev/null || true
    tc qdisc show dev oaitun_ue1 || true'
  echo "VERDICT=UE1_RESOURCE_PROFILE_CLEARED"; exit 0
fi

RATE="$(awk "BEGIN{printf \"%dmbit\", $PCT*$CEILING_MBIT/100}")"
echo "Computed: rate=$RATE (=$PCT% de ${CEILING_MBIT}mbit)  burst=$BURST  tbf-lat=$LATENCY  netem-delay=$DELAY"

kubectl -n "$NS" exec "$UE" -- sh -lc "
  tc qdisc del dev oaitun_ue1 root 2>/dev/null || true
  tc qdisc del dev oaitun_ue1 ingress 2>/dev/null || true
  ip link del ifb_ue1 2>/dev/null || true
  # egress/uplink: netem(delay) root + tbf(rate) child
  tc qdisc replace dev oaitun_ue1 root handle 1: netem delay $DELAY
  tc qdisc replace dev oaitun_ue1 parent 1: handle 2: tbf rate $RATE burst $BURST latency $LATENCY
  # ingress/downlink via ifb: netem(delay) root + tbf(rate) child
  ip link add ifb_ue1 type ifb 2>/dev/null
  ip link set ifb_ue1 up
  tc qdisc add dev oaitun_ue1 handle ffff: ingress
  tc filter add dev oaitun_ue1 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb_ue1
  tc qdisc replace dev ifb_ue1 root handle 1: netem delay $DELAY
  tc qdisc replace dev ifb_ue1 parent 1: handle 2: tbf rate $RATE burst $BURST latency $LATENCY
  echo '--- oaitun_ue1 (egress) ---'; tc qdisc show dev oaitun_ue1
  echo '--- ifb_ue1 (ingress) ---'; tc qdisc show dev ifb_ue1
"
echo "VERDICT=UE1_RESOURCE_PROFILE_APPLIED"
