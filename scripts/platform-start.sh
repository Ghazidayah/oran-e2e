#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${HOME}/.oran-lab"
STATE_FILE="${STATE_DIR}/platform-replicas.tsv"

echo "===== O-RAN platform start ====="
echo

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl not found"
  exit 1
}

if [ ! -s "$STATE_FILE" ]; then
  echo "ERROR: no saved replica state found."
  echo "Expected: $STATE_FILE"
  echo "Run scripts/platform-stop.sh once while the platform is running."
  exit 1
fi

echo "Using replica state:"
echo "$STATE_FILE"
echo
cat "$STATE_FILE"
echo

restore_one() {
  ns="$1"
  kind="$2"
  name="$3"
  replicas="$4"

  echo "Restoring $ns $kind/$name to replicas=$replicas"
  kubectl -n "$ns" scale "$kind/$name" --replicas="$replicas" || true
}

restore_namespace() {
  ns_filter="$1"
  awk -v ns="$ns_filter" '$1 == ns {print $0}' "$STATE_FILE" \
    | while read -r ns kind name replicas; do
        restore_one "$ns" "$kind" "$name" "$replicas"
      done
}

restore_ran_gnbs() {
  awk '$1 == "oran-ran" && $3 ~ /^oai-gnb/ {print $0}' "$STATE_FILE" \
    | while read -r ns kind name replicas; do
        restore_one "$ns" "$kind" "$name" "$replicas"
      done
}

restore_ran_ues() {
  awk '$1 == "oran-ran" && $3 ~ /^oai-nr-ue/ {print $0}' "$STATE_FILE" \
    | while read -r ns kind name replicas; do
        restore_one "$ns" "$kind" "$name" "$replicas"
      done
}

wait_deploy_if_needed() {
  ns="$1"
  name="$2"
  timeout="${3:-240s}"

  replicas="$(awk -v ns="$ns" -v name="$name" '$1 == ns && $2 == "deploy" && $3 == name {print $4}' "$STATE_FILE" | tail -1)"
  replicas="${replicas:-0}"

  if [ "$replicas" -gt 0 ]; then
    echo "Waiting for $ns deploy/$name..."
    kubectl -n "$ns" rollout status "deploy/$name" --timeout="$timeout"
  fi
}

echo "===== Restoring Open5GS core first ====="
restore_namespace "oran-core"

wait_deploy_if_needed oran-core open5gs-amf 240s
wait_deploy_if_needed oran-core open5gs-smf 240s
wait_deploy_if_needed oran-core open5gs-upf 240s

echo
echo "===== Restoring gNBs ====="
restore_ran_gnbs

wait_deploy_if_needed oran-ran oai-gnb 300s
wait_deploy_if_needed oran-ran oai-gnb-b 300s

echo
echo "===== Restoring UEs ====="
restore_ran_ues

wait_deploy_if_needed oran-ran oai-nr-ue 300s
wait_deploy_if_needed oran-ran oai-nr-ue-2 300s
wait_deploy_if_needed oran-ran oai-nr-ue-3 300s
wait_deploy_if_needed oran-ran oai-nr-ue-4 300s
wait_deploy_if_needed oran-ran oai-nr-ue-5 300s

echo
echo "===== Restoring monitoring ====="
restore_namespace "monitoring"

echo
echo "===== Final status ====="

echo
echo "----- oran-core -----"
kubectl -n oran-core get pods -o wide || true

echo
echo "----- oran-ran -----"
kubectl -n oran-ran get pods -o wide || true

echo
echo "----- monitoring -----"
kubectl -n monitoring get pods -o wide | grep -E 'grafana|prometheus|alertmanager|kube-state|operator' || true

echo
echo "Platform workloads have been restored from saved replica state."
