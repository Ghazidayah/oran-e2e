#!/usr/bin/env bash
# Real forced-MCS modulation profiles for UE1 (replaces the netem-faked radio profiles).
# Each profile caps the gNB scheduler's MCS on the ACTIVE DU via --MACRLCs.[0].dl/ul_max_mcs,
# so the modulation order actually used on air changes (verified in DU logs as Qm 2/4/6).
# DU is auto-detected from the UE's RFsim serveraddr. Args-only: no configmap surgery.
#
#   ./switch-ue-modulation-profile-du-aware.sh ue1 <profile> --apply
#   ./switch-ue-modulation-profile-du-aware.sh ue1 status
#
# Profiles -> forced max MCS (64QAM table; MCS 0-9=QPSK, 10-16=16QAM, 17-28=64QAM):
#   scheduler-auto    : no cap (adaptive AMC; reaches MCS 28 / 64QAM under load)
#   qpsk-robust       : 4   (Qm 2, QPSK)
#   qam16-balanced    : 13  (Qm 4, 16QAM)
#   qam64-throughput  : 28  (Qm 6, 64QAM)
set -Eeuo pipefail

RAN_NS="${RAN_NS:-oran-ran}"
UE="${1:-}"
PROFILE="${2:-}"
MODE="${3:---apply}"

die(){ echo "[FAIL] $*" >&2; echo "VERDICT=FAIL"; exit 1; }
info(){ echo "[INFO] $*"; }

case "$UE" in
  ue1) UE_DEPLOY="oai-nr-ue"; UE_CM="oai-nrue-config"; UE_APP_LABEL="app=oai-nr-ue" ;;
  ""|-h|--help) echo "Usage: $0 ue1 <profile> --apply | $0 ue1 status"; exit 0 ;;
  *) die "Only ue1 is supported. Got: $UE" ;;
esac

profile_mcs(){
  case "$PROFILE" in
    scheduler-auto)   MAXMCS="";  QM="adaptive";        DESC="adaptive AMC (no cap; reaches 64QAM under load)" ;;
    qpsk-robust)      MAXMCS="4";  QM="2 (QPSK)";        DESC="forced QPSK" ;;
    qam16-balanced)   MAXMCS="13"; QM="4 (16QAM)";       DESC="forced 16QAM" ;;
    qam64-throughput) MAXMCS="28"; QM="6 (64QAM)";       DESC="forced 64QAM" ;;
    status) return 1 ;;
    *) die "Unsupported profile: $PROFILE" ;;
  esac
}

# resolve active DU from the UE's serveraddr
SERVERADDR="$(kubectl -n "$RAN_NS" get cm "$UE_CM" -o jsonpath='{.data.nr-ue\.conf}' 2>/dev/null \
  | sed -n 's/.*serveraddr[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -z "$SERVERADDR" ] && SERVERADDR="$(kubectl -n "$RAN_NS" get deploy "$UE_DEPLOY" -o json \
  | python3 -c 'import json,sys; a=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["args"];
print(a[a.index("--rfsimulator.serveraddr")+1] if "--rfsimulator.serveraddr" in a else "")')"
case "$SERVERADDR" in
  oai-du0-rfsim|server) DU_DEPLOY="oai-du0" ;;
  oai-du1-rfsim)        DU_DEPLOY="oai-du1" ;;
  *) die "Unknown serveraddr=$SERVERADDR; refusing to guess active DU." ;;
esac
info "ACTIVE_DU_DEPLOY=$DU_DEPLOY  serveraddr=$SERVERADDR"

current_cap(){
  kubectl -n "$RAN_NS" get deploy "$DU_DEPLOY" -o json | python3 -c '
import json,sys
a=json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0]["args"]
v=a[a.index("--MACRLCs.[0].dl_max_mcs")+1] if "--MACRLCs.[0].dl_max_mcs" in a else "none(adaptive)"
print("dl_max_mcs="+v)'
}

if [ "$PROFILE" = "status" ]; then
  echo "ACTIVE_DU_DEPLOY=$DU_DEPLOY"
  current_cap
  echo "VERDICT=MODULATION_STATUS_DONE"
  exit 0
fi

[ "$MODE" = "--apply" ] || die "supports --apply only (got MODE=$MODE)"
profile_mcs
info "PROFILE=$PROFILE  DESC=$DESC  forced_max_mcs=${MAXMCS:-none}  expected_Qm=$QM"

# patch DU args: strip any existing dl/ul_max_mcs (flag+value), then add new caps if set
NEWARGS="$(kubectl -n "$RAN_NS" get deploy "$DU_DEPLOY" -o json | python3 -c '
import json,sys
maxmcs=sys.argv[1]
obj=json.load(sys.stdin)
a=obj["spec"]["template"]["spec"]["containers"][0]["args"]
out=[]; i=0
while i < len(a):
    if a[i] in ("--MACRLCs.[0].dl_max_mcs","--MACRLCs.[0].ul_max_mcs"):
        i+=2; continue
    out.append(a[i]); i+=1
if maxmcs:
    out += ["--MACRLCs.[0].dl_max_mcs",maxmcs,"--MACRLCs.[0].ul_max_mcs",maxmcs]
print(json.dumps(out))
' "${MAXMCS:-}")"

info "Patching $DU_DEPLOY args"
kubectl -n "$RAN_NS" patch deploy "$DU_DEPLOY" --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$NEWARGS}]" >/dev/null
kubectl -n "$RAN_NS" rollout status deploy "$DU_DEPLOY" --timeout=8m

info "Restarting UE for clean reattach"
kubectl -n "$RAN_NS" rollout restart deploy "$UE_DEPLOY" >/dev/null
kubectl -n "$RAN_NS" rollout status deploy "$UE_DEPLOY" --timeout=8m

# wait for tunnel
for i in $(seq 1 90); do
  POD="$(kubectl -n "$RAN_NS" get pod -l "$UE_APP_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$POD" ] && kubectl -n "$RAN_NS" exec "$POD" -- ip addr show oaitun_ue1 >/dev/null 2>&1 && break
  sleep 2
done
[ -n "$POD" ] || die "oaitun_ue1 did not return after profile switch"

echo "UE_POD=$POD"
current_cap
echo "VERDICT=MODULATION_PROFILE_APPLY_OK"
