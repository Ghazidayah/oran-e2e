#!/usr/bin/env bash
# Revert the E1 split: scale down CU-CP/CU-UP, bring back the monolithic oai-cu.
set +e
NS="${NS:-oran-ran}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"
section(){ echo; echo "================ $* ================"; }

section "1. Scale DOWN the E1 split"
kubectl -n "$NS" scale deploy/oai-cu-cp --replicas=0 2>/dev/null
kubectl -n "$NS" scale deploy/oai-cu-up --replicas=0 2>/dev/null

section "2. Bring back monolithic oai-cu"
kubectl -n "$NS" scale deploy/oai-cu --replicas=1
kubectl -n "$NS" rollout status deploy/oai-cu --timeout=180s

section "3. Restart DUs + UEs to reattach to monolithic CU"
kubectl -n "$NS" rollout restart deploy/oai-du0 deploy/oai-du1
kubectl -n "$NS" rollout status deploy/oai-du0 --timeout=120s
kubectl -n "$NS" rollout status deploy/oai-du1 --timeout=120s
for d in $(kubectl -n "$NS" get deploy -o name | grep oai-nr-ue); do kubectl -n "$NS" rollout restart "$d"; done

section "4. Settle + reconcile"
sleep 20
[ -x "$REPO/scripts/recover-ue-sessions.sh" ] && bash "$REPO/scripts/recover-ue-sessions.sh" --fix --yes
section "RESTORED to monolithic CU."
