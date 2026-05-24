#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
CORE_NS="${CORE_NS:-oran-core}"

echo "===== RAN pods ====="
kubectl -n "$NS" get pods -o wide

echo "===== Core pods ====="
kubectl -n "$CORE_NS" get pods -o wide

echo "===== F1 deployments ====="
kubectl -n "$NS" get deploy oai-cu oai-du0 oai-du1 -o wide

echo "===== CU logs: F1/NGAP ====="
kubectl -n "$NS" logs deploy/oai-cu --tail=200 | egrep -i 'F1|F1AP|DU|gNB|NGAP|SCTP|Setup|accepted|connected' || true

echo "===== DU0 logs: F1/RFsim ====="
kubectl -n "$NS" logs deploy/oai-du0 --tail=200 | egrep -i 'F1|F1AP|CU|DU|rfsim|connect|sync|SIB|RRC' || true

echo "===== DU1 logs: F1/RFsim ====="
kubectl -n "$NS" logs deploy/oai-du1 --tail=200 | egrep -i 'F1|F1AP|CU|DU|rfsim|connect|sync|SIB|RRC' || true

echo "===== AMF logs ====="
kubectl -n "$CORE_NS" logs deploy/open5gs-amf --since=30m | egrep -i 'gNB-N2 accepted|Registration complete|999700000000001|999700000000002|999700000000003|999700000000004|999700000000005' || true

echo "===== SMF logs ====="
kubectl -n "$CORE_NS" logs deploy/open5gs-smf --since=30m | egrep -i 'UE SUPI|DNN|10.45|session|associated' || true

echo "===== UE1 tunnel ====="
UE_POD=$(kubectl -n "$NS" get pods -l app=oai-nr-ue \
  --field-selector=status.phase=Running \
  --sort-by=.metadata.creationTimestamp \
  -o name | tail -n 1 | cut -d/ -f2)

echo "UE_POD=$UE_POD"

for i in $(seq 1 90); do
  if kubectl -n "$NS" exec "$UE_POD" -- ip addr show oaitun_ue1 >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl -n "$NS" exec "$UE_POD" -- ip addr show oaitun_ue1
kubectl -n "$NS" exec "$UE_POD" -- ip route
kubectl -n "$NS" exec "$UE_POD" -- ping -c 2 10.45.0.1
kubectl -n "$NS" exec "$UE_POD" -- ping -I oaitun_ue1 -c 4 8.8.8.8
