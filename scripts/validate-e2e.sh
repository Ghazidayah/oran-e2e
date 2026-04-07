#!/usr/bin/env bash
set -euo pipefail

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
UPF_POD=$(kubectl -n oran-core get pod -l app.kubernetes.io/name=upf -o jsonpath='{.items[0].metadata.name}')

kubectl get nodes -o wide
kubectl -n oran-core get pods -o wide
kubectl -n oran-ran get pods -o wide

kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip addr | grep -A2 oaitun_ue1'
kubectl -n oran-ran exec "$UE_POD" -- sh -c 'ip route'
kubectl -n oran-ran exec "$UE_POD" -- ping -c 2 10.45.0.1
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 4 8.8.8.8

kubectl -n oran-core logs deploy/open5gs-amf --since=10m | egrep -i 'Registration complete|gNB|999700000000001'
kubectl -n oran-core logs deploy/open5gs-smf --since=10m | egrep -i 'UE SUPI|session|10.45|oai|associated'
kubectl -n oran-core logs "$UPF_POD" --since=10m | egrep -i 'gtp|2152|PFCP|associated'
