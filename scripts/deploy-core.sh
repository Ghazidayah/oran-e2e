#!/usr/bin/env bash
set -euo pipefail

kubectl -n oran-core create configmap open5gs-oai-prep \
  --from-file=amf.yaml=$PWD/manifests/core/amf.yaml \
  --from-file=smf.yaml=$PWD/manifests/core/smf.yaml \
  --from-file=upf.yaml=$PWD/manifests/core/upf.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n oran-core rollout restart deploy/open5gs-amf
kubectl -n oran-core rollout restart deploy/open5gs-smf
kubectl -n oran-core rollout restart deploy/open5gs-upf

kubectl -n oran-core rollout status deploy/open5gs-amf --timeout=10m
kubectl -n oran-core rollout status deploy/open5gs-smf --timeout=10m
kubectl -n oran-core rollout status deploy/open5gs-upf --timeout=10m

kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn | egrep '38412|7777'
kubectl -n oran-core exec deploy/open5gs-upf -- ss -lunp | egrep '2152|8805'
