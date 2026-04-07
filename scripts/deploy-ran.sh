#!/usr/bin/env bash
set -euo pipefail

kubectl -n oran-ran create configmap oai-gnb-config \
  --from-file=gnb.conf=$PWD/manifests/ran/gnb.lab.conf \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n oran-ran create configmap oai-nrue-config \
  --from-file=nr-ue.conf=$PWD/manifests/ran/nrue.lab.conf \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n oran-ran apply -f manifests/ran/oai-nr-ue-rfsim-svc.yaml

kubectl -n oran-ran patch deploy oai-gnb --type='merge' -p '{"spec":{"strategy":{"type":"Recreate"}}}'

NRUE_CONTAINER=$(kubectl -n oran-ran get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].name}')
kubectl -n oran-ran patch deploy oai-nr-ue --type='strategic' -p "$(cat <<PATCH
spec:
  template:
    spec:
      containers:
      - name: ${NRUE_CONTAINER}
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/sh
              - -lc
              - |
                for i in \$(seq 1 90); do
                  ip link show oaitun_ue1 >/dev/null 2>&1 && break
                  sleep 2
                done
                ip route add 10.43.0.0/16 via 10.42.0.1 dev eth0 2>/dev/null || true
                ip route replace default dev oaitun_ue1 || true
PATCH
)"

kubectl -n oran-ran rollout restart deploy/oai-gnb
kubectl -n oran-ran rollout restart deploy/oai-nr-ue
kubectl -n oran-ran rollout status deploy/oai-gnb --timeout=10m
kubectl -n oran-ran rollout status deploy/oai-nr-ue --timeout=10m
