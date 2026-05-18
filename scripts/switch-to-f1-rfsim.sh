#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"

section() {
  echo
  echo "===== $1 ====="
}

section "Scale down monolithic gNB mode and extra UEs"
kubectl -n "$NS" scale deploy/oai-gnb --replicas=0 || true
kubectl -n "$NS" scale deploy/oai-gnb-b --replicas=0 || true
kubectl -n "$NS" scale deploy/oai-nr-ue-2 --replicas=0 || true
kubectl -n "$NS" scale deploy/oai-nr-ue-3 --replicas=0 || true
kubectl -n "$NS" scale deploy/oai-nr-ue-4 --replicas=0 || true
kubectl -n "$NS" scale deploy/oai-nr-ue-5 --replicas=0 || true

section "Apply F1 RFsim manifest"
kubectl apply -f k8s/f1-rfsim/f1-ran.yaml

section "Force required F1 replicas"
kubectl -n "$NS" scale deploy/oai-cu --replicas=1
kubectl -n "$NS" scale deploy/oai-du0 --replicas=1
kubectl -n "$NS" scale deploy/oai-du1 --replicas=1
kubectl -n "$NS" scale deploy/oai-nr-ue --replicas=1

section "Patch UE for F1 RFsim mode"
python3 - <<'PY'
import json
import os
import subprocess
import sys

ns = os.environ.get("NS", "oran-ran")
raw = subprocess.check_output([
    "kubectl", "-n", ns, "get", "deploy", "oai-nr-ue", "-o", "json"
])
deploy = json.loads(raw)
args = deploy["spec"]["template"]["spec"]["containers"][0]["args"]

patch = []

def replace_arg(flag, value):
    if flag not in args:
        raise SystemExit(f"Missing UE arg: {flag}")
    idx = args.index(flag) + 1
    old = args[idx]
    if old != value:
        patch.append({
            "op": "replace",
            "path": f"/spec/template/spec/containers/0/args/{idx}",
            "value": value,
        })
    print(f"{flag}: {old} -> {value}", file=sys.stderr)

replace_arg("-C", "3450720000")
replace_arg("--rfsimulator.serveraddr", "server")

if patch:
    subprocess.check_call([
        "kubectl", "-n", ns, "patch", "deploy/oai-nr-ue",
        "--type=json",
        "-p", json.dumps(patch),
    ])
else:
    print("UE args already match F1 RFsim mode", file=sys.stderr)
PY

section "Wait for F1 deployments"
kubectl -n "$NS" rollout status deploy/oai-cu --timeout=180s
kubectl -n "$NS" rollout status deploy/oai-du0 --timeout=180s
kubectl -n "$NS" rollout status deploy/oai-du1 --timeout=180s
kubectl -n "$NS" rollout status deploy/oai-nr-ue --timeout=180s

section "Wait for UE attach"
sleep 45

section "F1 readiness"
web-dashboard/actions/f1_status.sh

section "Current deployments"
kubectl -n "$NS" get deploy -o wide
