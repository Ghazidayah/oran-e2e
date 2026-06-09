#!/usr/bin/env bash
# Standalone n28 700 MHz FDD validation on DU0 + UE1.
# Non-destructive: backs up the live DU0 ConfigMap and UE1 Deployment before any
# change, applies the n28 FDD config + UE1 args, restarts, and checks sync/PDU/ping.
# `restore` puts DU0 + UE1 back exactly as they were. UE2-UE5 (on DU1) are untouched.
#
#   ./validate-n28-700-on-du0.sh apply     # switch DU0+UE1 to n28 700 MHz FDD
#   ./validate-n28-700-on-du0.sh check     # re-run the sync/ping checks only
#   ./validate-n28-700-on-du0.sh restore   # roll DU0+UE1 back to the saved baseline
set +e
set +u

REPO="${REPO:-$HOME/oran-e2e-freeze}"
NS="${RAN_NS:-${NS:-oran-ran}}"
DU_CM="${DU_CM:-oai-du0-f1-config}"
DU_DEPLOY="${DU_DEPLOY:-oai-du0}"
UE_DEPLOY="${UE_DEPLOY:-oai-nr-ue}"
N28_CONF="${N28_CONF:-$REPO/manifests/ran/f1/gnb-du0.n28-700.fdd.conf}"

# UE radio args for n28 700 MHz
UE_C_HZ="781250000"
UE_BAND="28"
UE_NUM="0"      # 15 kHz
UE_SSB="516"
UE_PRB="106"

STAMP="$(date +%Y%m%d-%H%M%S)"
PROOF="${PROOF:-$HOME/oran-proof/n28-700-validate-$STAMP}"
BK_DIR="$REPO/backups/n28-700-on-du0"     # fixed dir so restore can always find it
mkdir -p "$PROOF" "$BK_DIR"

ACTION="${1:-apply}"

. "$REPO/scripts/ue/ue-common.sh" 2>/dev/null || true

say(){ echo; echo "===== $* ====="; }
pass(){ echo "[PASS] $*"; }
warn(){ echo "[WARN] $*"; }
fail(){ echo "[FAIL] $*"; }

# ---- UE arg patcher: set -C/--band/--numerology/--ssb/-r, preserve serveraddr ----
patch_ue_args(){
  local c_hz="$1" band="$2" num="$3" ssb="$4" prb="$5"
  kubectl -n "$NS" get deploy "$UE_DEPLOY" -o json > "$PROOF/ue.before.json" || return 1
  python3 - "$PROOF/ue.before.json" "$PROOF/ue.after.json" "$c_hz" "$band" "$num" "$ssb" "$prb" <<'PY'
import json, sys
src,dst,c_hz,band,num,ssb,prb = sys.argv[1:]
obj=json.load(open(src))
def set_kv(arr,key,val):
    for i,x in enumerate(arr):
        if x==key and i+1<len(arr):
            arr[i+1]=val; return
    # insert before serveraddr if present, else append
    at=len(arr)
    if "--rfsimulator.serveraddr" in arr: at=arr.index("--rfsimulator.serveraddr")
    arr[at:at]=[key,val]
for c in obj["spec"]["template"]["spec"]["containers"]:
    arr=c.get("args")
    if not isinstance(arr,list): continue
    set_kv(arr,"-C",c_hz)
    set_kv(arr,"--band",band)
    set_kv(arr,"--numerology",num)
    set_kv(arr,"--ssb",ssb)
    set_kv(arr,"-r",prb)
for k in ["resourceVersion","uid","managedFields","creationTimestamp","generation","selfLink"]:
    obj.get("metadata",{}).pop(k,None)
obj.pop("status",None)
json.dump(obj,open(dst,"w"),indent=2)
PY
  kubectl apply -f "$PROOF/ue.after.json"
}

# ---- inject a full gnb.conf file into the DU ConfigMap's data['gnb.conf'] ----
swap_du_conf(){
  local conf_file="$1"
  kubectl -n "$NS" get cm "$DU_CM" -o json > "$PROOF/ducm.before.json" || return 1
  python3 - "$PROOF/ducm.before.json" "$conf_file" "$PROOF/ducm.after.json" <<'PY'
import json, sys
src,conf,dst=sys.argv[1:]
obj=json.load(open(src))
obj.setdefault("data",{})["gnb.conf"]=open(conf,encoding="utf-8").read()
for k in ["resourceVersion","uid","managedFields","creationTimestamp","generation","selfLink"]:
    obj.get("metadata",{}).pop(k,None)
obj.pop("status",None)
json.dump(obj,open(dst,"w"),indent=2)
PY
  kubectl apply -f "$PROOF/ducm.after.json"
}

restart_and_wait(){
  kubectl -n "$NS" rollout restart deploy "$DU_DEPLOY"
  kubectl -n "$NS" rollout status  deploy "$DU_DEPLOY" --timeout=8m
  kubectl -n "$NS" rollout restart deploy "$UE_DEPLOY"
  kubectl -n "$NS" rollout status  deploy "$UE_DEPLOY" --timeout=8m
}

checks(){
  say "DU0 boot (look for asserts / band 28 / SSB)"
  kubectl -n "$NS" logs deploy/"$DU_DEPLOY" --tail=120 \
    | egrep -i 'Assert|Exiting|band|n28|SSB|PointA|frequency|TDD|FDD|served cell|CORESET' | tail -25

  say "UE1 sync + PDU"
  local pod tun
  pod="$(ue_pod_for_deployment "$NS" "$UE_DEPLOY")"
  kubectl -n "$NS" logs "$pod" --tail=200 \
    | egrep -i 'synch|SIB1|MIB|RRC|Registration|PDU Session|oaitun|Assert|fail' | tail -25
  tun="$(kubectl -n "$NS" exec "$pod" -- sh -c 'ip -4 addr show oaitun_ue1 2>/dev/null | awk "/inet /{print \$2; exit}"' 2>/dev/null)"

  say "Verdict"
  if [ -n "$tun" ]; then
    pass "UE1 attached on n28 700 MHz: tunnel=$tun"
    kubectl -n "$NS" exec "$pod" -- ping -I oaitun_ue1 -c 4 8.8.8.8 \
      && echo "VERDICT=N28_700_VALIDATION_OK" \
      || { warn "tunnel up but ping failed"; echo "VERDICT=N28_700_TUNNEL_NO_PING"; }
  else
    fail "UE1 did NOT attach on n28. Inspect logs above."
    echo "Likely tunables: initialDLBWPcontrolResourceSetZero (gNB assert at boot),"
    echo "or prach_ConfigurationIndex (UE syncs MIB/SIB1 but RACH never completes)."
    echo "VERDICT=N28_700_NO_ATTACH"
  fi
}

case "$ACTION" in
  apply)
    [ -f "$N28_CONF" ] || { fail "n28 conf not found: $N28_CONF"; exit 1; }
    say "Backup live DU0 ConfigMap + UE1 Deployment"
    kubectl -n "$NS" get cm "$DU_CM" -o yaml         > "$BK_DIR/$DU_CM.baseline.yaml"      && pass "saved $DU_CM"
    kubectl -n "$NS" get deploy "$UE_DEPLOY" -o yaml  > "$BK_DIR/$UE_DEPLOY.baseline.yaml"  && pass "saved $UE_DEPLOY"

    say "Apply n28 700 MHz FDD to DU0 + UE1"
    swap_du_conf "$N28_CONF"               && pass "DU0 gnb.conf swapped to n28 FDD"
    patch_ue_args "$UE_C_HZ" "$UE_BAND" "$UE_NUM" "$UE_SSB" "$UE_PRB" \
                                            && pass "UE1 args set: -C $UE_C_HZ --band 28 --numerology 0 --ssb 516 -r 106"

    say "Restart DU0 + UE1"
    restart_and_wait
    checks
    echo; echo "Backup kept in: $BK_DIR  (run: $0 restore  to roll back)"
    ;;

  check)
    checks
    ;;

  restore)
    say "Restore DU0 + UE1 from baseline backup"
    [ -f "$BK_DIR/$DU_CM.baseline.yaml" ]     || { fail "no DU0 backup in $BK_DIR"; exit 1; }
    [ -f "$BK_DIR/$UE_DEPLOY.baseline.yaml" ] || { fail "no UE1 backup in $BK_DIR"; exit 1; }
    kubectl apply -f "$BK_DIR/$DU_CM.baseline.yaml"     && pass "DU0 ConfigMap restored"
    kubectl apply -f "$BK_DIR/$UE_DEPLOY.baseline.yaml" && pass "UE1 Deployment restored"
    restart_and_wait
    checks
    ;;

  *)
    echo "Usage: $0 {apply|check|restore}"
    exit 1
    ;;
esac
