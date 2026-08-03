#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# WARNING — known drift between this repo and the running platform (2026-08-02)
#
# This script rebuilds the ConfigMap open5gs-oai-prep from manifests/core/*.yaml
# and restarts AMF/SMF/UPF. The AMF reads amf.yaml from THIS ConfigMap.
#
# manifests/core/amf.yaml currently reflects the ORIGINAL Helm install state:
# a single S-NSSAI (sst 1, sd 0x111111). The running platform was later
# reconfigured to four slices (sst 1/2/3/4, all sd 0xffffff) and that change was
# never written back to this file.
#
# Running this script against the current platform therefore REVERTS slicing to
# one slice: URLLC (SST 2) and mMTC (SST 3) stop working, and
# scripts/slicing/switch-ue-slice.sh fails its AMF-granted assertion.
#
# Before running on a live platform, capture the current state first:
#   kubectl -n oran-core get cm open5gs-oai-prep -o jsonpath='{.data.amf\.yaml}' \
#     > /tmp/amf-live.yaml
#   diff /tmp/amf-live.yaml manifests/core/amf.yaml
#
# Note also that the SMF mounts open5gs-smf, NOT open5gs-oai-prep, so the
# smf.yaml written here is never read by the SMF. The NSSF config is not in
# this repository at all. See docs/reference/DEPLOYMENT-GUIDE.md.
# ---------------------------------------------------------------------------
echo "[deploy-core] NOTE: rebuilds open5gs-oai-prep from manifests/core/." >&2
echo "[deploy-core] manifests/core/amf.yaml declares ONE slice; the running" >&2
echo "[deploy-core] platform may be on four. Diff before running on a live lab." >&2

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
