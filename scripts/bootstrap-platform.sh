#!/usr/bin/env bash
# =============================================================================
# bootstrap-platform.sh — Fresh Ubuntu 22.04 host → running O-RAN E2E platform
# -----------------------------------------------------------------------------
# FIXED VERSION — replaces the two TODO_ABORT stops and the unresolved MANUAL
# volumeMount step in the original script with concrete, verified commands.
# Sources for every value below: docs/reference/DEPLOYMENT-GUIDE.md (Annex —
# "Helm values recovered from the live cluster"), manifests/core/open5gs-
# {amf,upf}-deploy-live.yaml, and scripts/deploy-core.sh. Nothing here is
# guessed; where a value could not be confirmed from your repo (the monitoring
# chart), it is clearly marked best-effort and skippable.
#
# *** Still only as tested as the repo it reads from. Review before running
#     against a platform you can't afford to lose (there is none here — this
#     targets a genuinely fresh host). ***
# =============================================================================
set -euo pipefail

REPO="${REPO:-$HOME/oran-e2e}"
CHART_VERSION="${CHART_VERSION:-2.3.4}"       # confirmed live release: open5gs-2.3.4 / app 2.7.5
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

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

# ─── 1. Host preparation ──────────────────────────────────────────────────────
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

sudo tee /etc/sysctl.d/99-oran-k8s-5g.conf >/dev/null <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.conf.all.rp_filter = 0
EOF
sudo sysctl --system >/dev/null

sudo swapoff -a
# FIX: persist across reboot — comment out any active swap line in fstab
# (confirmed state on oran-lab: "#/swapfile   none   swap   sw   0   0").
if [ -f /etc/fstab ] && grep -qE '^\s*[^#].*\sswap\s' /etc/fstab; then
  sudo sed -i -E '/^\s*[^#].*\sswap\s/ s/^/#/' /etc/fstab
  echo "  fstab: commented out active swap entry"
fi
sudo hostnamectl set-hostname oran-lab

# ─── 2. k3s + Helm ────────────────────────────────────────────────────────────
STEP "2/10 — k3s + Helm"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sudo sh -
fi
mkdir -p "$HOME/.kube"
if [ ! -f "$HOME/.kube/config" ]; then
  sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
  chmod 600 "$HOME/.kube/config"
fi
export KUBECONFIG="$HOME/.kube/config"
kubectl get nodes
command -v helm >/dev/null 2>&1 || sudo snap install helm --classic --channel=3.7/stable

# ─── 3. Namespaces ────────────────────────────────────────────────────────────
STEP "3/10 — Namespaces"
kubectl create namespace oran-core 2>/dev/null || true
kubectl create namespace oran-ran 2>/dev/null || true
kubectl create namespace oran-monitoring 2>/dev/null || true
# Note: the live monitoring stack actually lands in ns "monitoring" (Step 9),
# not "oran-monitoring" — that namespace exists but stays empty. Not a bug.

# ─── 4. Open5GS 5G SA core ────────────────────────────────────────────────────
STEP "4/10 — Open5GS core (Gradiant chart via OCI + repo values)"
# FIX: the March local chart copy is gone, but the chart is published on
# Docker Hub's OCI registry — no local tree or CHART_DIR needed.
helm pull "oci://registry-1.docker.io/gradiant/open5gs" \
  --version "$CHART_VERSION" --untar --untardir "$WORKDIR"
CHART_DIR="$WORKDIR/open5gs"

# FIX: manifests/core/open5gs-5gsa.yaml ships with populate.enabled: true,
# which CrashLoops (EACCES / duplicate IMSI key) on a second run of the init
# container. Recovered fix from the live release: populate.enabled: false.
# Subscribers are created later at Step 8 (WebUI + provision script) instead.
POPULATE_DISABLE="$REPO/manifests/core/open5gs-populate-disable.yaml"
if [ ! -f "$POPULATE_DISABLE" ]; then
  cat > "$POPULATE_DISABLE" <<'EOF'
populate:
  enabled: false
EOF
  echo "  wrote $POPULATE_DISABLE (recovered from live release, 2026-08-02)"
fi

helm -n oran-core install open5gs "$CHART_DIR" \
  -f "$REPO/manifests/core/open5gs-5gsa.yaml" \
  -f "$REPO/manifests/core/open5gs-overrides.yaml" \
  -f "$POPULATE_DISABLE"
kubectl -n oran-core wait --for=condition=Available deploy --all --timeout=10m || true

MANUAL "Verify before continuing:" \
  "  - all oran-core pods Running (populate is disabled — no init CrashLoop expected)" \
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
MANUAL "Confirm your host's netplan renderer is NetworkManager before applying" \
  "(confirmed correct on oran-lab; verify it still matches your host), then:" \
  "  sudo netplan generate && sudo netplan apply" \
  "  ip -br a | egrep 'br-n2|br-n3'   # both UP with .1/24 addresses"

# ─── 6. Multus + NADs ─────────────────────────────────────────────────────────
STEP "6/10 — Multus + NetworkAttachmentDefinitions"
# FIX: installed as a k3s HelmChart custom resource on the live cluster
# (release rke2-multus-v4.2.401, app 4.2.4). No manual install needed.
if ! kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1; then
  kubectl apply -f - <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: multus
  namespace: kube-system
spec:
  repo: https://rke2-charts.rancher.io
  chart: rke2-multus
  targetNamespace: kube-system
  valuesContent: |-
    config:
      fullnameOverride: multus
      cni_conf:
        confDir: /var/lib/rancher/k3s/agent/etc/cni/net.d
        binDir: /var/lib/rancher/k3s/data/cni/
        kubeconfig: /var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d/multus.kubeconfig
        multusAutoconfigDir: /var/lib/rancher/k3s/agent/etc/cni/net.d
EOF
  echo "  waiting for Multus DaemonSet and the NAD CRD..."
  for i in $(seq 1 30); do
    kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1 && break
    sleep 10
  done
  kubectl get crd network-attachment-definitions.k8s.cni.cncf.io >/dev/null 2>&1 || {
    echo "!!! Multus CRD still not present after 5 min — check:"
    echo "!!!   kubectl -n kube-system get helmchart multus -o yaml"
    echo "!!!   kubectl -n kube-system logs -l app=helm-install-multus"
    exit 2
  }
fi
kubectl -n kube-system get ds | grep -i multus

kubectl apply -f "$REPO/manifests/network/n2-net-core.yaml"
kubectl apply -f "$REPO/manifests/network/n3-net-core.yaml"
kubectl apply -f "$REPO/manifests/network/n2-net-ran.yaml"
kubectl apply -f "$REPO/manifests/network/n3-net-ran.yaml"
kubectl -n oran-core get network-attachment-definitions
kubectl -n oran-ran get network-attachment-definitions

# ─── 7. AMF/UPF on N2/N3 + net1 rebinding ────────────────────────────────────
STEP "7/10 — AMF/UPF Multus attach + config rewiring"
kubectl -n oran-core patch deploy open5gs-amf --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"n2-net\",\"ips\":[\"10.10.0.101/24\"]}]"}}}}}'
kubectl -n oran-core patch deploy open5gs-upf --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"n3-net\",\"ips\":[\"10.20.0.101/24\"]}]"}}}}}'

# FIX (this was the unresolved MANUAL step): a fresh Gradiant install does NOT
# mount open5gs-oai-prep into the AMF/UPF containers. Values below are read
# directly from the live AMF/UPF deployments (manifests/core/open5gs-{amf,upf}
# -deploy-live.yaml), not placeholders.
#
# 7.1 — create open5gs-oai-prep FIRST so the volume patch below doesn't leave
# pods stuck in ContainerCreateConfigError waiting on a ConfigMap that isn't
# there yet.
kubectl -n oran-core create configmap open5gs-oai-prep \
  --from-file=amf.yaml="$REPO/manifests/core/amf.yaml" \
  --from-file=smf.yaml="$REPO/manifests/core/smf.yaml" \
  --from-file=upf.yaml="$REPO/manifests/core/upf.yaml" \
  --dry-run=client -o yaml | kubectl apply -f -

# 7.2 — add the missing volume + volumeMount (strategic merge = additive,
# preserves the chart's own volumes/mounts instead of wiping the array).
cat > "$WORKDIR/patch-amf.yaml" <<'EOF'
spec:
  template:
    spec:
      volumes:
      - name: amf-config-fixed
        configMap:
          name: open5gs-oai-prep
      containers:
      - name: open5gs-amf
        volumeMounts:
        - name: amf-config-fixed
          mountPath: /opt/open5gs/etc/open5gs/amf.yaml
          subPath: amf.yaml
          readOnly: true
EOF
cat > "$WORKDIR/patch-upf.yaml" <<'EOF'
spec:
  template:
    spec:
      volumes:
      - name: open5gs-oai-prep
        configMap:
          name: open5gs-oai-prep
      containers:
      - name: open5gs-upf
        volumeMounts:
        - name: open5gs-oai-prep
          mountPath: /opt/open5gs/etc/open5gs/upf.yaml
          subPath: upf.yaml
EOF
kubectl -n oran-core patch deploy open5gs-amf --patch-file "$WORKDIR/patch-amf.yaml"
kubectl -n oran-core patch deploy open5gs-upf --patch-file "$WORKDIR/patch-upf.yaml"
kubectl -n oran-core rollout status deploy/open5gs-amf --timeout=5m
kubectl -n oran-core rollout status deploy/open5gs-upf --timeout=5m

# 7.3 — now the idempotent repo script: rebuilds open5gs-oai-prep (no-op on
# content, since we just created it identically), patches open5gs-smf and
# open5gs-nssf in place, restarts all four, verifies sockets.
bash "$REPO/scripts/deploy-core.sh"

MANUAL "Verify (sockets confirmed by deploy-core.sh above, re-check if unsure):" \
  "  AMF: SCTP LISTEN 10.10.0.101:38412   UPF: UDP 10.20.0.101:2152 + :8805" \
  "  PFCP re-associated after the restarts (SMF/UPF logs)"

# ─── 8. RAN: F1 + E1 split ────────────────────────────────────────────────────
STEP "8/10 — RAN F1/E1 split + 5 UEs"

kubectl -n oran-ran create configmap oai-du0-f1-config \
  --from-file=gnb.conf="$REPO/manifests/ran/f1/du0.conf" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n oran-ran create configmap oai-du1-f1-config \
  --from-file=gnb.conf="$REPO/manifests/ran/f1/du1.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$REPO/manifests/ran/e1/e1-split.yaml"
kubectl apply -f "$REPO/manifests/ran/f1/f1-ran.yaml"

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

kubectl -n oran-ran create configmap oai-nrue-config \
  --from-file=nr-ue.conf="$REPO/manifests/ran/nrue.lab.conf" \
  --dry-run=client -o yaml | kubectl apply -f -
apply_stripped "$REPO/manifests/ran/mixed-du-live/deploy-oai-nr-ue.yaml" oran-ran

bash "$REPO/scripts/ue/generate-5ue-manifests.sh"
kubectl apply -f "$REPO/manifests/ran/multi-ue/"

kubectl -n oran-ran scale deploy/oai-nr-ue-2 deploy/oai-nr-ue-3 \
                          deploy/oai-nr-ue-4 deploy/oai-nr-ue-5 --replicas=1
for d in oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n oran-ran rollout status "deploy/$d" --timeout=180s || true
done

MANUAL "Verify RAN bring-up (CU-CP log):" \
  "  'Received NGSetupResponse from AMF', 'Accepting new CU-UP'," \
  "  'Accepting DU 3584 (du-rfsim0)' and '... 3585 (du-rfsim1)'" \
  "  Cold-start 'Registration reject [9]' => restart AMF+SMF after NRF is populated"

# ─── 9. Monitoring (best-effort) ─────────────────────────────────────────────
STEP "9/10 — Monitoring"
# Recovered from the live cluster: release oran-monitoring, ns monitoring,
# chart kube-prometheus-stack-84.5.0, app v0.90.1. Chart repo/version were not
# independently reverified for this run — check before relying on it.
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace monitoring 2>/dev/null || true
if helm -n monitoring install oran-monitoring prometheus-community/kube-prometheus-stack \
     --version 84.5.0 --timeout 10m; then
  echo "  monitoring installed — import monitoring/grafana/dashboards/oran-lab-dashboard-4-panels.json"
  echo "  Grafana NodePort 30300, Prometheus 30090 (patch the Service type if not already NodePort)"
else
  echo "[WARN] monitoring install failed or version 84.5.0 unavailable — platform is unaffected," \
       "install manually later: helm search repo prometheus-community/kube-prometheus-stack --versions"
fi

# ─── 10. Dashboard + validation ──────────────────────────────────────────────
STEP "10/10 — Dashboard, traffic API, first-start validation"
nohup "$REPO/run-web-dashboard.sh" >/dev/null 2>&1 & sleep 3
pgrep -f "web-dashboard/app.py" >/dev/null || echo "[WARN] dashboard not running — start ./run-web-dashboard.sh manually"
bash "$REPO/scripts/traffic/start-traffic-api.sh" || echo "[WARN] traffic API start failed"

echo
echo "NOTE: scripts/platform-start.sh is the RESTART path — it needs"
echo "~/.oran-lab/platform-replicas.tsv (written by scripts/platform-stop.sh)."
echo "Run one stop/start cycle later to seed it."

# FIX: don't swallow validation failures behind a blind "Bootstrap done."
f1_ok=1; e2e_ok=1
bash "$REPO/scripts/validate-f1-ran.sh" || f1_ok=0
bash "$REPO/scripts/validate-e2e.sh"    || e2e_ok=0

echo
if [ "$f1_ok" -eq 1 ] && [ "$e2e_ok" -eq 1 ]; then
  echo "Bootstrap done — F1/RAN and E2E validation both passed."
else
  echo "Bootstrap finished but validation reported problems:"
  [ "$f1_ok"  -eq 0 ] && echo "  - validate-f1-ran.sh FAILED — check CU-CP/DU logs before continuing"
  [ "$e2e_ok" -eq 0 ] && echo "  - validate-e2e.sh FAILED — check AMF/UE registration and PFCP state"
fi
echo "Full acceptance suite (long, exercises the whole platform):"
echo "  bash tests/run-full-platform-acceptance.sh"
echo "Checklist: docs/reference/DEPLOYMENT-GUIDE.md §'First-start verification'"
