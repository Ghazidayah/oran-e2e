#!/usr/bin/env bash
# EXPERIMENTAL: bring up the CU-CP/CU-UP (E1) split, replacing the monolithic CU.
# Reversible: scripts/e1/restore-monolithic-cu.sh puts oai-cu back.
set +e
NS="${NS:-oran-ran}"
REPO="${REPO:-$HOME/oran-e2e-freeze}"
section(){ echo; echo "================ $* ================"; }
ready(){ kubectl -n "$NS" get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]'; }

section "1. Apply E1 split manifests"
kubectl apply -f "$REPO/manifests/ran/e1/e1-split.yaml"

section "2. Scale DOWN monolithic oai-cu (frees 10.10.0.120 / 10.20.0.120)"
kubectl -n "$NS" scale deploy/oai-cu --replicas=0
kubectl -n "$NS" rollout status deploy/oai-cu --timeout=60s

section "3. Start CU-CP first, wait Ready"
kubectl -n "$NS" scale deploy/oai-cu-cp --replicas=1
kubectl -n "$NS" rollout status deploy/oai-cu-cp --timeout=120s
if ! ready oai-cu-cp; then
  echo "[FAIL] CU-CP did not become Ready. Logs:"
  kubectl -n "$NS" logs deploy/oai-cu-cp --tail=30
  echo "Aborting. Fix CU-CP, or restore: bash $REPO/scripts/e1/restore-monolithic-cu.sh"
  exit 1
fi

section "4. Start CU-UP, wait Ready"
kubectl -n "$NS" scale deploy/oai-cu-up --replicas=1
kubectl -n "$NS" rollout status deploy/oai-cu-up --timeout=120s
if ! ready oai-cu-up; then
  echo "[FAIL] CU-UP did not become Ready — NOT proceeding to DU/UE (would be futile)."
  echo "--- why (events) ---"; kubectl -n "$NS" describe pod -l app=oai-cu-up | grep -iE "Warning|Failed|Error|not available" | tail -10
  echo "--- cu-up log (if any) ---"; kubectl -n "$NS" logs deploy/oai-cu-up --tail=30 2>/dev/null
  echo "Aborting. Fix CU-UP, or restore: bash $REPO/scripts/e1/restore-monolithic-cu.sh"
  exit 1
fi

section "5. E1 association check (CU-CP <- CU-UP over SCTP:38462)"
sleep 8
echo "--- CU-CP log (E1) ---"; kubectl -n "$NS" logs deploy/oai-cu-cp --tail=200 | grep -iE "e1|cuup|cu-up|bearer|associat" | tail -15
echo "--- CU-UP log (E1) ---"; kubectl -n "$NS" logs deploy/oai-cu-up --tail=200 | grep -iE "e1|setup|cucp|cu-cp|associat" | tail -15
if kubectl -n "$NS" logs deploy/oai-cu-cp --tail=300 2>/dev/null | grep -qiE "e1.*setup (request|response)|E1AP.*setup|CU-UP.*(connect|associat|accept)"; then
  echo "==> E1 association looks ESTABLISHED."
else
  echo "==> [WARN] No clear E1 setup string yet — read the two logs above (it may still be up)."
fi

section "6. Restart DUs so F1-C re-associates to the CU-CP"
kubectl -n "$NS" rollout restart deploy/oai-du0 deploy/oai-du1
kubectl -n "$NS" rollout status deploy/oai-du0 --timeout=120s
kubectl -n "$NS" rollout status deploy/oai-du1 --timeout=120s

section "7. Restart UEs to reattach through the split CU"
for d in $(kubectl -n "$NS" get deploy -o name | grep oai-nr-ue); do kubectl -n "$NS" rollout restart "$d"; done

section "8. Settle + reconcile UE sessions"
sleep 20
[ -x "$REPO/scripts/recover-ue-sessions.sh" ] && bash "$REPO/scripts/recover-ue-sessions.sh" --fix --yes

section "DONE — verify: kubectl -n $NS get pods | grep oai-cu ; check a UE tunnel + data path"
echo "Rollback anytime: bash $REPO/scripts/e1/restore-monolithic-cu.sh"
