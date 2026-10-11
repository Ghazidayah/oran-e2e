#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
TUN="${TUN:-oaitun_ue1}"

usage() {
  echo "Usage:"
  echo "  $0 list"
  echo "  $0 apply-manifests"
  echo "  $0 start ue2|ue3|ue4|ue5"
  echo "  $0 stop ue2|ue3|ue4|ue5"
  echo "  $0 status"
  echo "  $0 ping ue1|ue2|ue3|ue4|ue5"
  exit 1
}

ue_num() {
  case "$1" in
    ue1) echo 1 ;;
    ue2) echo 2 ;;
    ue3) echo 3 ;;
    ue4) echo 4 ;;
    ue5) echo 5 ;;
    *) echo "[ERROR] Unknown UE: $1" >&2; exit 1 ;;
  esac
}

dep_for() {
  n=$(ue_num "$1")
  if [ "$n" = "1" ]; then
    echo "oai-nr-ue"
  else
    echo "oai-nr-ue-$n"
  fi
}

selector_for() {
  n=$(ue_num "$1")
  if [ "$n" = "1" ]; then
    echo "app=oai-nr-ue"
  else
    echo "app=oai-nr-ue-$n"
  fi
}

pod_for() {
  sel=$(selector_for "$1")
  kubectl -n "$NS" get pod -l "$sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

cmd="${1:-}"
case "$cmd" in
  list)
    cat config/ues.yaml
    ;;

  apply-manifests)
    kubectl apply -f manifests/ran/multi-ue/
    ;;

  start)
    ue="${2:-}"
    [ -n "$ue" ] || usage
    dep=$(dep_for "$ue")
    if [ "$ue" = "ue1" ]; then
      kubectl -n "$NS" scale deploy "$dep" --replicas=1
    else
      kubectl -n "$NS" apply -f "manifests/ran/multi-ue/${dep}.yaml"
      kubectl -n "$NS" scale deploy "$dep" --replicas=1
    fi
    kubectl -n "$NS" rollout status deploy "$dep" --timeout=180s
    ;;

  stop)
    ue="${2:-}"
    [ -n "$ue" ] || usage
    dep=$(dep_for "$ue")
    kubectl -n "$NS" scale deploy "$dep" --replicas=0
    ;;

  status)
    kubectl -n "$NS" get deploy,pods -o wide | grep -E 'oai-nr-ue|NAME' || true
    echo
    for ue in ue1 ue2 ue3 ue4 ue5; do
      pod=$(pod_for "$ue")
      echo "===== $ue ====="
      echo "pod=${pod:-none}"
      if [ -n "$pod" ]; then
        kubectl -n "$NS" exec "$pod" -- sh -lc "ip -4 addr show $TUN 2>/dev/null | awk '/inet /{print \$2; exit}' || true" 2>/dev/null || true
      fi
    done
    ;;

  ping)
    ue="${2:-}"
    [ -n "$ue" ] || usage
    pod=$(pod_for "$ue")
    if [ -z "$pod" ]; then
      echo "[ERROR] pod not found for $ue"
      exit 1
    fi
    echo "UE=$ue"
    echo "POD=$pod"
    kubectl -n "$NS" exec "$pod" -- sh -lc "
      ip addr show $TUN || true
      echo '----- PING DN GW -----'
      ping -I $TUN -c 3 10.45.0.1
      echo '----- PING INTERNET -----'
      ping -I $TUN -c 3 8.8.8.8
    "
    ;;

  *)
    usage
    ;;
esac
