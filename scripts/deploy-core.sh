#!/usr/bin/env bash
set -euo pipefail

# Rebuilds the Open5GS core configuration from manifests/core/ and restarts the
# affected network functions. Run from the repository root.
#
# Which ConfigMap each function actually reads (verified on the live cluster,
# 2026-08-03) — this mapping is not uniform, see OPERATING-RULES.md rule 9:
#
#   AMF  → open5gs-oai-prep, key amf.yaml   (volume amf-config-fixed)
#   UPF  → open5gs-oai-prep, key upf.yaml
#   SMF  → open5gs-smf,      key smf.yaml   (NOT open5gs-oai-prep)
#   NSSF → open5gs-nssf,     key nssf.yaml  (NOT open5gs-oai-prep)
#
# The smf.yaml key inside open5gs-oai-prep is written for historical continuity
# but is read by nothing.
#
# The four files under manifests/core/ are byte-identical to the live cluster
# configuration as captured on 2026-08-03, so running this script against the
# current platform is a no-op on content. It still restarts the pods.

REPO="${REPO:-$PWD}"

for f in amf smf upf nssf; do
  [ -f "$REPO/manifests/core/$f.yaml" ] || {
    echo "missing: $REPO/manifests/core/$f.yaml (run from the repository root)" >&2
    exit 1
  }
done

# --- open5gs-oai-prep: read by AMF (amf.yaml) and UPF (upf.yaml) -------------
kubectl -n oran-core create configmap open5gs-oai-prep \
  --from-file=amf.yaml="$REPO/manifests/core/amf.yaml" \
  --from-file=smf.yaml="$REPO/manifests/core/smf.yaml" \
  --from-file=upf.yaml="$REPO/manifests/core/upf.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- open5gs-smf and open5gs-nssf: patched in place --------------------------
# These two ConfigMaps are owned by the Helm release. Patch only their data key
# so the Helm labels and annotations survive; recreating them from scratch would
# strip that metadata.
patch_cm_key() {
  local cm="$1" key="$2" file="$3"
  kubectl -n oran-core patch configmap "$cm" --type merge -p "$(
    python3 - "$key" "$file" <<'PY'
import json, sys
key, path = sys.argv[1], sys.argv[2]
print(json.dumps({"data": {key: open(path, encoding="utf-8").read()}}))
PY
  )"
}

patch_cm_key open5gs-smf  smf.yaml  "$REPO/manifests/core/smf.yaml"
patch_cm_key open5gs-nssf nssf.yaml "$REPO/manifests/core/nssf.yaml"

# --- restart the functions whose configuration may have changed --------------
kubectl -n oran-core rollout restart deploy/open5gs-amf
kubectl -n oran-core rollout restart deploy/open5gs-smf
kubectl -n oran-core rollout restart deploy/open5gs-upf
kubectl -n oran-core rollout restart deploy/open5gs-nssf

kubectl -n oran-core rollout status deploy/open5gs-amf  --timeout=10m
kubectl -n oran-core rollout status deploy/open5gs-smf  --timeout=10m
kubectl -n oran-core rollout status deploy/open5gs-upf  --timeout=10m
kubectl -n oran-core rollout status deploy/open5gs-nssf --timeout=10m

kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn | grep -E '38412|7777'
kubectl -n oran-core exec deploy/open5gs-upf -- ss -lunp | grep -E '2152|8805'
