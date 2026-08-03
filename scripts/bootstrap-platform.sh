#!/usr/bin/env bash
# =============================================================================
# bootstrap-platform.sh — Fresh Ubuntu 22.04 host → running O-RAN E2E platform
# -----------------------------------------------------------------------------
# Consolidated from the March 2026 deployment report (Steps 1-9 + annexes) and
# the current repository (F1/E1-split era). Core procedure (Steps 1-7) was
# executed in March 2026; the RAN layer (Step 8) reflects the later F1/E1
# evolution and uses only current repo manifests.
#
# *** NOT re-executed end-to-end on a fresh host since consolidation. ***
# *** Review every TODO before first use. FRESH HOSTS ONLY (see guard). ***
#
# Companion doc: docs/reference/DEPLOYMENT-GUIDE.md (same steps, success
# criteria, failure/fix table per step).
# =============================================================================
set -euo pipefail

REPO="${REPO:-$HOME/oran-e2e}"

STEP() {
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "  STEP $*"
  echo "════════════════════════════════════════════════════════════"
}

MANUAL() {
  echo
  echo "─────────────── MANUAL CHECKPOINT ───────────────"
  printf '%s\n' "$@"
  echo "──────────────────────────────────────────────────"
  read -r -p "Press Enter when done (Ctrl-C to abort)... " _
}

TODO_ABORT() {
  echo
  echo "!!! TODO — cannot proceed automatically: $*"
  echo "!!! Resolve this (see docs/reference/DEPLOYMENT-GUIDE.md), then re-run."
  exit 2
}

# Strip live-capture metadata (OPERATING-RULES.md rule 4) so a saved manifest can be applied.
apply_stripped() {
  local f="$1" ns="$2"
  awk '/^status:/{exit} {print}' "$f" \
    | sed -E '/^\s*(resourceVersion|uid|generation|creationTimestamp):/d' \
    | kubectl -n "$ns" apply -f -
}

# ─── GUARD: fresh hosts only ─────────────────────────────────────────────────
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get ns oran-core >/dev/null 2>&1; then
    pod_count="$(kubectl -n oran-core get pods --no-headers 2>/dev/null | wc -l)"
    if [ "${pod_count:-0}" -gt 0 ]; then
      echo "ABORT: namespace oran-core already has ${pod_count} pod(s)."
      echo "This script is for FRESH hosts only — the platform is already deployed."
      exit 1
    fi
  fi
fi

[ -d "$REPO" ] || { echo "ABORT: repo not found at $REPO"; exit 1; }
cd "$REPO"

# ─── 1. Host preparation (March, unchanged) ──────────────────────────────────
STEP "1/10 — Host preparation"
sudo apt update && sudo apt -y full-upgrade
sudo apt install -y curl wget git vim nano jq net-tools iproute2 iputils-ping \
  traceroute dnsutils tcpdump iperf3 python3 python3-pip lksctp-tools

sudo tee /etc/modules-load.d/oran-k8s-5g.conf >/dev/null <<'EOF'
overlay
br_netfilter
nf_conntrack
sctp
gtp
EOF
sudo modprobe overlay br_netfilter nf_conntrack sctp
sudo modprobe gtp || true

# Values proven in March (report Capture 2)
sudo tee /etc/sysctl.d/99-oran-k8s-5g.conf >/dev/null <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.conf.all.rp_filter = 0
EOF
sudo sysctl --system >/dev/null

sudo swapoff -a
# TODO: permanent swap disable (fstab edit) was not recorded in the March report.
sudo hostnamectl set-hostname oran-lab

# ─── 2. k3s + Helm (March, unchanged) ────────────────────────────────────────
STEP "2/10 — k3s + Helm"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sudo sh -
fi
# TODO: March fixed a kubeconfig permission issue but the exact command was not
# recorded. Standard approach (verify before relying on it):
mkdir -p "$HOME/.kube"
if [ ! -f "$HOME/.kube/config" ]; then
  sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
fi
export KUBECONFIG="$HOME/.kube/config"
kubectl get nodes
command -v helm >/dev/null 2>&1 || sudo snap install helm --classic --channel=3.7/stable

# ─── 3. Namespaces ───────────────────────────────────────────────────────────
STEP "3/10 — Namespaces"
kubectl create namespace oran-core 2>/dev/null || true
kubectl create namespace oran-ran 2>/dev/null || true
kubectl create namespace oran-monitoring 2>/dev/null || true
# Evolution note: the live monitoring stack ended up in ns "monitoring" (Step 9).

# ─── 4. Open5GS 5G SA core ───────────────────────────────────────────────────
STEP "4/10 — Open5GS core (Gradiant chart + repo values)"
CHART_DIR="${CHART_DIR:-}"
if [ -z "$CHART_DIR" ] || [ ! -d "$CHART_DIR" ]; then
  TODO_ABORT "Gradiant open5gs chart tree not available. March used a local copy \
(~/oran-e2e/k8s/5g-charts/charts/open5gs); exact chart version unrecorded. \
Restore it, then re-run with CHART_DIR=<path-to-charts/open5gs>."
fi
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null
( cd "$(dirname "$CHART_DIR")" && helm dependency build "$(basename "$CHART_DIR")" )

# Version pins (SMF 2.7.2 / UPF 2.7.6) applied AT INSTALL TIME — in March they
# were a post-hoc fix for "Cannot find PFCP-Node"; here we skip the broken state.
# TODO: open5gs-populate-disable.yaml content was never captured in repo or
# report; recreate it (disables the populate job: EACCES/duplicate-key crashes)
# and add it as a third -f if populate CrashLoops.
helm -n oran-core install open5gs "$CHART_DIR" \
  -f "$REPO/manifests/core/open5gs-5gsa.yaml" \
  -f "$REPO/manifests/core/open5gs-overrides.yaml"
kubectl -n oran-core wait --for=condition=Available deploy --all --timeout=10m || true

MANUAL "Verify before continuing (March success criteria):" \
  "  - all oran-core pods Running (populate may need the disable override — see TODO above)" \
  "  - kubectl -n oran-core get endpoints open5gs-smf-pfcp open5gs-upf-pfcp -o wide" \
  "  - SMF log shows 'PFCP associated'; UPF log clean of PFCP errors for 2 min"

# ─── 5. N2/N3 bridges + netplan persistence ──────────────────────────────────
STEP "5/10 — Host bridges br-n2 / br-n3"
sudo ip link add br-n2 type bridge 2>/dev/null || true
sudo ip addr add 10.10.0.1/24 dev br-n2 2>/dev/null || true
sudo ip link set br-n2 up
sudo ip link add br-n3 type bridge 2>/dev/null || true
sudo ip addr add 10.20.0.1/24 dev br-n3 2>/dev/null || true
sudo ip link set br-n3 up

# Persistence (bridges lost after reboot = March failure mode). Content recovered
# from git history: git show b89f0c0^:manifests/network/99-oran-bridges.yaml
# TODO: renderer says NetworkManager — verify it matches the fresh host's netplan
# renderer BEFORE applying (a wrong renderer can take down host networking).
sudo tee /etc/netplan/99-oran-bridges.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: NetworkManager
  bridges:
    br-n2:
      addresses: [10.10.0.1/24]
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0
    br-n3:
      addresses: [10.20.0.1/24]
      dhcp4: no
      parameters:
        stp: false
        forward-delay: 0
EOF
MANUAL "Review /etc/netplan/99-oran-bridges.yaml (renderer!) then apply manually:" \
  "  sudo netplan generate && sudo netplan apply" \
  "  ip -br a | egrep 'br-n2|br-n3'   # both UP with .1/24 addresses"

# ─── 6. Multus + NADs ────────────────────────────────────────────────────────
STEP "6/10 — Multus + NetworkAttachmentDefinitions"
if ! kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1; then
  TODO_ABORT "Multus not installed and the March install method was not recorded \
in either source. Install the multus-cni DaemonSet for k3s, verify the NAD CRD \
exists, then re-run."
fi
kubectl apply -f "$REPO/manifests/network/n2-net-core.yaml"
kubectl apply -f "$REPO/manifests/network/n3-net-core.yaml"
kubectl apply -f "$REPO/manifests/network/n2-net-ran.yaml"
kubectl apply -f "$REPO/manifests/network/n3-net-ran.yaml"
kubectl -n oran-core get network-attachment-definitions
kubectl -n oran-ran get network-attachment-definitions

# ─── 7. AMF/UPF on N2/N3 + net1 rebinding ────────────────────────────────────
STEP "7/10 — AMF/UPF Multus attach + open5gs-oai-prep rebinding"
# Fixed IPs — values from manifests/core/open5gs-{amf,upf}-deploy-live.yaml
kubectl -n oran-core patch deploy open5gs-amf --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"n2-net\",\"ips\":[\"10.10.0.101/24\"]}]"}}}}}'
kubectl -n oran-core patch deploy open5gs-upf --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"n3-net\",\"ips\":[\"10.20.0.101/24\"]}]"}}}}}'

MANUAL "TODO — volumeMount rewiring must be done by hand on a fresh install:" \
  "  The AMF/UPF must mount ConfigMap open5gs-oai-prep over their config file" \
  "  (OPERATING-RULES.md rule 9: real AMF config = open5gs-oai-prep key amf.yaml)." \
  "  The live capture manifests/core/open5gs-amf-deploy-live.yaml holds the shape" \
  "  (mountPath /opt/open5gs/etc/open5gs/amf.yaml) but with placeholders" \
  "  (AMF_KEY_HERE / AMF_CM_HERE) — reconstruct and verify on a throwaway target." \
  "  Same for the UPF (upf.yaml)."

# open5gs-oai-prep from repo sources (net1 bindings), restart + socket verification
bash "$REPO/scripts/deploy-core.sh"

MANUAL "Verify (March Capture 15 success criteria):" \
  "  AMF: SCTP LISTEN 10.10.0.101:38412   UPF: UDP 10.20.0.101:2152 + :8805" \
  "  PFCP re-associated after the restarts (SMF/UPF logs)"

# ─── 8. RAN: F1 + E1 split (CURRENT REPO ONLY) ───────────────────────────────
# Evolution note: replaces the March monolithic oai-gnb (gnb.lab.conf, UE-as-
# RFsim-server, manual UE route fix). DU is now the RFsim server (oai-du*-rfsim).
STEP "8/10 — RAN F1/E1 split + 5 UEs"

kubectl -n oran-ran create configmap oai-du0-f1-config \
  --from-file=gnb.conf="$REPO/manifests/ran/f1/du0.conf" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n oran-ran create configmap oai-du1-f1-config \
  --from-file=gnb.conf="$REPO/manifests/ran/f1/du1.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$REPO/manifests/ran/e1/e1-split.yaml"
kubectl apply -f "$REPO/manifests/ran/f1/f1-ran.yaml"

# Manifests ship with replicas=0 (platform-start.sh normally scales them from the
# state file, which does not exist yet on first bootstrap). Scale up in E1 order:
# CU-CP first (must be ready before CU-UP connects), then CU-UP, then DUs.
kubectl -n oran-ran scale deploy/oai-cu-cp --replicas=1
kubectl -n oran-ran rollout status deploy/oai-cu-cp --timeout=180s
kubectl -n oran-ran scale deploy/oai-cu-up --replicas=1
kubectl -n oran-ran rollout status deploy/oai-cu-up --timeout=180s
kubectl -n oran-ran scale deploy/oai-du0 deploy/oai-du1 --replicas=1
kubectl -n oran-ran rollout status deploy/oai-du0 --timeout=180s
kubectl -n oran-ran rollout status deploy/oai-du1 --timeout=180s

MANUAL "Create the reference subscriber BEFORE the UEs attach:" \
  "  kubectl -n oran-core port-forward svc/open5gs-webui 9999:9999" \
  "  http://localhost:9999 → add IMSI 999700000000001" \
  "  (K / OPc values = manifests/ran/nrue.lab.conf)"
bash "$REPO/scripts/ue/provision-5ue-subscribers.sh"

# UE1 (reference UE, home DU0)
kubectl -n oran-ran create configmap oai-nrue-config \
  --from-file=nr-ue.conf="$REPO/manifests/ran/nrue.lab.conf" \
  --dry-run=client -o yaml | kubectl apply -f -
apply_stripped "$REPO/manifests/ran/mixed-du-live/deploy-oai-nr-ue.yaml" oran-ran

# UE2-UE5 (generated manifests embed ConfigMap + Deployment)
bash "$REPO/scripts/ue/generate-5ue-manifests.sh"
kubectl apply -f "$REPO/manifests/ran/multi-ue/"

# The generated UE manifests also ship with replicas=0 (same convention as the
# RAN manifests above). Without this, UE2-UE5 stay at zero after a bootstrap and
# only UE1 attaches.
kubectl -n oran-ran scale deploy/oai-nr-ue-2 deploy/oai-nr-ue-3 \
                          deploy/oai-nr-ue-4 deploy/oai-nr-ue-5 --replicas=1
for d in oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n oran-ran rollout status "deploy/$d" --timeout=180s || true
done

MANUAL "Verify RAN bring-up (CU-CP log):" \
  "  'Received NGSetupResponse from AMF', 'Accepting new CU-UP'," \
  "  'Accepting DU 3584 (du-rfsim0)' and '... 3585 (du-rfsim1)'" \
  "  Cold-start 'Registration reject [9]' => restart AMF+SMF after NRF is populated"

# ─── 9. Monitoring ───────────────────────────────────────────────────────────
STEP "9/10 — Monitoring"
echo "TODO: kube-prometheus-stack install (live in ns 'monitoring') is recorded in"
echo "neither source. Once installed, import monitoring/grafana/dashboards/"
echo "(oran-5g-lab-ops.improved.json; Grafana NodePort 30300, Prometheus 30090)."

# ─── 10. Dashboard + validation ──────────────────────────────────────────────
STEP "10/10 — Dashboard, traffic API, first-start validation"
nohup "$REPO/run-web-dashboard.sh" >/dev/null 2>&1 & sleep 3; pgrep -f "web-dashboard/app.py" >/dev/null || echo "[WARN] dashboard not running — start ./run-web-dashboard.sh manually"
bash "$REPO/scripts/traffic/start-traffic-api.sh" || echo "[WARN] traffic API start failed"

echo
echo "NOTE: scripts/platform-start.sh is the RESTART path — it needs"
echo "~/.oran-lab/platform-replicas.tsv (written by scripts/platform-stop.sh)."
echo "Run one stop/start cycle later to seed it; for now validate directly:"
bash "$REPO/scripts/validate-f1-ran.sh" || true
bash "$REPO/scripts/validate-e2e.sh"    || true

echo
echo "Bootstrap done. Full acceptance suite (long, exercises the whole platform):"
echo "  bash tests/run-full-platform-acceptance.sh"
echo "Checklist: docs/reference/DEPLOYMENT-GUIDE.md §'First-start verification'"
