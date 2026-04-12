#!/usr/bin/env bash
set -euo pipefail

sudo netplan generate
sudo netplan apply

kubectl -n oran-core delete network-attachment-definition n2-net n3-net --ignore-not-found=true
kubectl -n oran-ran  delete network-attachment-definition n2-net n3-net --ignore-not-found=true

kubectl create -f manifests/network/n2-net-core.yaml
kubectl create -f manifests/network/n3-net-core.yaml
kubectl create -f manifests/network/n2-net-ran.yaml
kubectl create -f manifests/network/n3-net-ran.yaml

kubectl -n oran-core rollout restart deploy/open5gs-amf
kubectl -n oran-core rollout restart deploy/open5gs-upf
kubectl -n oran-core rollout status deploy/open5gs-amf --timeout=10m
kubectl -n oran-core rollout status deploy/open5gs-upf --timeout=10m

kubectl -n oran-ran exec multus-test -- ping -c 2 10.10.0.101
kubectl -n oran-ran exec multus-test -- ping -c 2 10.20.0.101
