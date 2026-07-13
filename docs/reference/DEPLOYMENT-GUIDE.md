# Deployment Guide — Fresh Ubuntu 22.04 → Running O-RAN E2E Platform

> **Provenance**: consolidated from the **March 2026 deployment report**
> (Rapport d'avancement O-RAN, Steps 1–9 + annexes) and the **current repository**
> (`~/oran-e2e-freeze`, branch `cleanup-final-state`). The core procedure (host →
> k3s → Open5GS → Multus/N2/N3) was executed in March 2026 on this host; the RAN
> layer reflects the **later F1/E1 split evolution** and uses only current repo
> manifests. This guide has **not been re-executed end-to-end on a fresh host**
> since consolidation — treat unverified spots (marked `TODO`) accordingly.
>
> Scripted version: `scripts/bootstrap-platform.sh` (same steps, same TODOs).

**Two eras, one rule**: where the March report and the repo disagree, **the repo
wins**. Evolution notes mark each divergence.

Target state: k3s single-node `oran-lab`, Open5GS 5G SA (ns `oran-core`),
OAI F1+E1 split CU-CP/CU-UP/DU0/DU1 + 5 RFsim UEs (ns `oran-ran`), PLMN 999/70,
DNN `oai`, AMF NGAP `10.10.0.101:38412`, UPF GTP-U `10.20.0.101:2152`.

---

## Step 1 — Host preparation (March, unchanged)

```bash
sudo apt update && sudo apt -y full-upgrade
sudo apt install -y curl wget git vim nano jq net-tools iproute2 iputils-ping \
  traceroute dnsutils tcpdump iperf3 python3 python3-pip lksctp-tools

# Kernel modules (persisted in /etc/modules-load.d/oran-k8s-5g.conf)
sudo modprobe overlay br_netfilter nf_conntrack sctp
sudo modprobe gtp || true

# Sysctl (persisted in /etc/sysctl.d/99-oran-k8s-5g.conf) — values proven in March:
#   net.ipv4.ip_forward=1  net.bridge.bridge-nf-call-iptables=1  net.ipv4.conf.all.rp_filter=0
sudo sysctl --system

sudo swapoff -a          # TODO: permanent disable (fstab edit) not recorded in March report
sudo hostnamectl set-hostname oran-lab
```

**Success criteria**: `lsmod` shows `sctp`, `br_netfilter`, `overlay`; `swapon --show` empty;
`sysctl net.ipv4.ip_forward` = 1.
**Likely failure**: `gtp` module absent on stock kernel — non-blocking (`|| true`), GTP-U is
handled by the UPF in userspace.

## Step 2 — k3s + Helm (March, unchanged)

```bash
curl -sfL https://get.k3s.io | sudo sh -
# kubeconfig for the current user — a permissions issue was hit and fixed in March,
# exact command not recorded. TODO: standard approach is copying
# /etc/rancher/k3s/k3s.yaml to ~/.kube/config and chown-ing it; verify before relying on it.
sudo snap install helm --classic --channel=3.7/stable
```

**Success criteria**: `kubectl get nodes` → `oran-lab Ready control-plane`; DNS test
(`kubectl run -it --rm bb --image=busybox:1.36.1 --restart=Never -- nslookup
kubernetes.default.svc.cluster.local`) resolves; PVC write/read test passes; `helm version` OK.

## Step 3 — Namespaces (March, unchanged)

```bash
kubectl create namespace oran-core || true
kubectl create namespace oran-ran || true
kubectl create namespace oran-monitoring || true
```

> **Evolution note**: the live monitoring stack (kube-prometheus-stack) ultimately landed in
> namespace **`monitoring`**, not `oran-monitoring` (which exists but is empty). See Step 9.

## Step 4 — Open5GS 5G SA core (March, values files now in this repo)

March deployed via a **local copy of the Gradiant open5gs Helm chart**
(`~/oran-e2e/k8s/5g-charts/charts/open5gs`). That chart tree is **not** in this repo.

```bash
# TODO: restore the Gradiant open5gs chart tree (local copy used in March;
#       exact chart version not recorded — do NOT blindly take latest upstream).
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
cd <chart-parent-dir> && helm dependency build charts/open5gs

helm -n oran-core install open5gs ./charts/open5gs \
  -f ~/oran-e2e-freeze/manifests/core/open5gs-5gsa.yaml \
  -f ~/oran-e2e-freeze/manifests/core/open5gs-overrides.yaml
kubectl -n oran-core wait --for=condition=Available deploy --all --timeout=10m
```

> **Evolution note**: in March the version pins (**SMF 2.7.2, UPF 2.7.6** in
> `open5gs-overrides.yaml`) were applied as a *fix* after PFCP breakage; here they are applied
> at install time, skipping the broken state entirely.

**Success criteria**: all `oran-core` pods Running; MongoDB PVC Bound; PFCP endpoints present
(`kubectl -n oran-core get endpoints open5gs-smf-pfcp open5gs-upf-pfcp -o wide`); UPF logs free
of PFCP errors for ≥2 min.

**Likely failures (all hit and solved in March)**:
| Symptom | Fix |
|---|---|
| UPF logs `Cannot find PFCP-Node`, heartbeat failures | The version pins above (SMF 2.7.2 / UPF 2.7.6). If already installed unpinned: `helm upgrade` with both values files, then `rollout status` SMF+UPF |
| `open5gs-populate` init container CrashLoopBackOff (EACCES on MongoDB / duplicate IMSI key) | Disable populate via a third values file. TODO: `open5gs-populate-disable.yaml` content was never captured in repo or report — recreate (disable the populate component) and verify |

**MANUAL CHECKPOINT**: do not proceed until NRF/SCP/UDR/UDM/AUSF are Ready and PFCP is
associated (SMF log shows `PFCP associated`).

## Step 5 — N2/N3 bridges on the host (March, netplan file recovered from git history)

```bash
sudo ip link add br-n2 type bridge 2>/dev/null || true
sudo ip addr add 10.10.0.1/24 dev br-n2 2>/dev/null || true
sudo ip link set br-n2 up
sudo ip link add br-n3 type bridge 2>/dev/null || true
sudo ip addr add 10.20.0.1/24 dev br-n3 2>/dev/null || true
sudo ip link set br-n3 up
```

**Likely failure (hit in March)**: bridges lost after reboot → AMF/UPF/gNB lose their Multus
interfaces. Fix: persist via `/etc/netplan/99-oran-bridges.yaml`. The repo copy was deleted in
the July 2026 hygiene pass (commit `b89f0c0`, "k3s 1.20-era, zero references") — content
recovered from git history (`git show b89f0c0^:manifests/network/99-oran-bridges.yaml`):

```yaml
network:
  version: 2
  renderer: NetworkManager    # TODO: verify renderer matches the fresh host before applying
  bridges:
    br-n2:
      addresses: [10.10.0.1/24]
      dhcp4: no
      parameters: { stp: false, forward-delay: 0 }
    br-n3:
      addresses: [10.20.0.1/24]
      dhcp4: no
      parameters: { stp: false, forward-delay: 0 }
```

Then `sudo netplan generate && sudo netplan apply`.
**Success criteria**: `ip -br a | egrep 'br-n2|br-n3'` shows both UP with their /24 addresses,
and they survive a reboot.

## Step 6 — Multus + NetworkAttachmentDefinitions

```bash
# TODO: Multus installation method not recorded in either source (March annex only shows
#       verification commands). Install the multus-cni DaemonSet for k3s, then verify:
kubectl -n kube-system get ds | grep -i multus
kubectl get crd | grep -i network-attachment

# NADs — from this repo (bridge CNI, host-local IPAM, range .100-.200, gw .1):
kubectl apply -f ~/oran-e2e-freeze/manifests/network/n2-net-core.yaml
kubectl apply -f ~/oran-e2e-freeze/manifests/network/n3-net-core.yaml
kubectl apply -f ~/oran-e2e-freeze/manifests/network/n2-net-ran.yaml
kubectl apply -f ~/oran-e2e-freeze/manifests/network/n3-net-ran.yaml
```

**Success criteria**: a test pod with both NADs gets `net1`/`net2` and can ping `10.10.0.1`
and `10.20.0.1` (March Captures 13–14).

## Step 7 — AMF/UPF on N2/N3 + net1 rebinding (March mechanism, repo sources)

Fixed IPs via Multus annotations (values from the live captures in
`manifests/core/open5gs-{amf,upf}-deploy-live.yaml`):

```bash
kubectl -n oran-core patch deploy open5gs-amf --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"n2-net\",\"ips\":[\"10.10.0.101/24\"]}]"}}}}}'
kubectl -n oran-core patch deploy open5gs-upf --type merge -p \
  '{"spec":{"template":{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"n3-net\",\"ips\":[\"10.20.0.101/24\"]}]"}}}}}'
```

NGAP/GTP-U must bind to `net1`, not `eth0`. The current source of truth is ConfigMap
**`open5gs-oai-prep`** (CLAUDE.md rule 9 — NOT `open5gs-amf`), built from this repo and
rolled out by an existing script:

```bash
cd ~/oran-e2e-freeze && bash scripts/deploy-core.sh
# creates/updates open5gs-oai-prep from manifests/core/{amf,smf,upf}.yaml,
# restarts AMF/SMF/UPF, verifies sockets 38412 (NGAP) and 2152/8805 (GTP-U/PFCP)
```

**Prerequisite** — the AMF/UPF deployments must *mount* `open5gs-oai-prep` over their config
file. On a fresh Gradiant install they do not. TODO: the live capture's volumeMount carries
placeholders (`AMF_KEY_HERE` / `AMF_CM_HERE`); reconstruct the volume patch from
`manifests/core/open5gs-amf-deploy-live.yaml` (mountPath
`/opt/open5gs/etc/open5gs/amf.yaml`, configMap `open5gs-oai-prep`, key `amf.yaml` per
CLAUDE.md rule 9) and verify on a throwaway target first.

**Likely failure (hit in March)**: AMF/UPF CrashLoopBackOff after N2/N3 preparation — bind
params pointing at `eth0`/missing in mounted files. Fix = exactly this step: rebuild
`open5gs-oai-prep` with `net1` bindings, restart, verify inside the pod (rule 8: ConfigMap
edits do NOT reach running pods through subPath mounts).

**Success criteria** (March Capture 15):
`kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn | egrep '38412|7777'` shows SCTP
LISTEN on `10.10.0.101:38412`; UPF shows UDP `10.20.0.101:2152` and `:8805`.

**MANUAL CHECKPOINT**: verify PFCP re-association after the restarts before starting the RAN.

## Step 8 — RAN: F1 + E1 split (CURRENT REPO ONLY)

> **Evolution note**: the March single monolithic `oai-gnb` (config `gnb.lab.conf`, N2
> `10.10.0.110`, UE-as-RFsim-server on TCP/4043 via `svc oai-nr-ue-rfsim`, manual UE
> default-route fix) **was later replaced** by the F1/E1 split: CU-CP `10.10.0.120`,
> CU-UP, DU0 `10.10.0.121` (F1), DU1, **DU as RFsim server** via `oai-du0-rfsim` /
> `oai-du1-rfsim` (TCP 4043), and 5 UEs. None of the March RAN commands apply anymore.

```bash
cd ~/oran-e2e-freeze

# 8.1 DU ConfigMaps from the canonical confs (CLAUDE.md rule 5: du0.conf is the n78 baseline)
kubectl -n oran-ran create configmap oai-du0-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du0.conf --dry-run=client -o yaml | kubectl apply -f -
kubectl -n oran-ran create configmap oai-du1-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du1.conf --dry-run=client -o yaml | kubectl apply -f -

# 8.2 CU split (embeds oai-cucp-config / oai-cuup-config) then DUs + RFsim services
kubectl apply -f manifests/ran/e1/e1-split.yaml
kubectl apply -f manifests/ran/f1/f1-ran.yaml

# Manifests ship with replicas=0 (normally scaled by platform-start.sh from the
# state file, absent on first bootstrap). Scale up in E1 order:
kubectl -n oran-ran scale deploy/oai-cu-cp --replicas=1 && kubectl -n oran-ran rollout status deploy/oai-cu-cp --timeout=180s
kubectl -n oran-ran scale deploy/oai-cu-up --replicas=1 && kubectl -n oran-ran rollout status deploy/oai-cu-up --timeout=180s
kubectl -n oran-ran scale deploy/oai-du0 deploy/oai-du1 --replicas=1

# 8.3 Subscribers BEFORE the UEs attach.
#     MANUAL: create IMSI 999700000000001 in the Open5GS WebUI
#     (kubectl -n oran-core port-forward svc/open5gs-webui 9999:9999 → http://localhost:9999;
#      K/OPc = the values in manifests/ran/nrue.lab.conf) — as done in March (Capture 9).
bash scripts/ue/provision-5ue-subscribers.sh   # clones ...001 → ...002-005 (backs up first)

# 8.4 UE1 (reference UE, home DU0)
kubectl -n oran-ran create configmap oai-nrue-config \
  --from-file=nr-ue.conf=manifests/ran/nrue.lab.conf --dry-run=client -o yaml | kubectl apply -f -
# Deployment: manifests/ran/mixed-du-live/deploy-oai-nr-ue.yaml is a LIVE capture —
# strip resourceVersion/uid/creationTimestamp/generation + status before applying
# (CLAUDE.md rule 4). bootstrap-platform.sh does this automatically.

# 8.5 UE2–UE5 (generated manifests embed ConfigMap + Deployment, image oai-nr-ue:2025.w45)
bash scripts/ue/generate-5ue-manifests.sh
kubectl apply -f manifests/ran/multi-ue/
```

**Success criteria**: CU-CP log shows `Received NGSetupResponse from AMF`, `Accepting new
CU-UP`, `Accepting DU 3584 (du-rfsim0)` and `... 3585 (du-rfsim1)`; every UE pod grows
`oaitun_ue1` with a `10.45.0.x/24` address; AMF logs `Registration complete` per IMSI.

**Likely failures**:
| Symptom | Fix |
|---|---|
| Cold-start `Registration reject` (5GMM cause #9) | AMF booted before NRF was populated — restart AMF+SMF *after* NRF/UDR/UDM/AUSF are Ready (`platform-start.sh` automates this gate) |
| UE attaches to wrong DU / no tunnel | UE deployment **args** override the ConfigMap (rule 10) — check `--rfsimulator.serveraddr` in the deployment, not just the CM |
| Stale tunnels after CU restart | `scripts/recover-ue-sessions.sh` (diagnose-first), `--fix` to act |

## Step 9 — Monitoring

TODO: the kube-prometheus-stack install (live in namespace `monitoring`) is recorded in
neither source. Once installed, import the dashboards from
`monitoring/grafana/dashboards/` (`oran-5g-lab-ops.improved.json` is the live one;
Grafana NodePort 30300, Prometheus 30090).

## Step 10 — Dashboard, traffic API, first-start validation

```bash
cd ~/oran-e2e-freeze
./run-web-dashboard.sh                      # Flask :18080
bash scripts/traffic/start-traffic-api.sh   # :5055

# Note: scripts/platform-start.sh is the RESTART path — it requires
# ~/.oran-lab/platform-replicas.tsv, written by scripts/platform-stop.sh.
# After first bootstrap the platform is already up; run one stop/start cycle
# later to seed that state file. From then on:
bash scripts/platform-start.sh

bash scripts/validate-f1-ran.sh
bash scripts/validate-e2e.sh                          # expects VERDICT=E2E_UE1_VALIDATION_OK
bash tests/run-full-platform-acceptance.sh            # full 7-section suite
```

### First-start verification checklist

| # | Check | Command | Pass condition |
|---|---|---|---|
| 1 | Node | `kubectl get nodes` | `oran-lab Ready` |
| 2 | Core pods | `kubectl -n oran-core get pods` | all Running, MongoDB Bound |
| 3 | NGAP socket | `kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn \| grep 38412` | SCTP LISTEN on `10.10.0.101` |
| 4 | GTP-U/PFCP | `kubectl -n oran-core exec deploy/open5gs-upf -- ss -lunp \| egrep '2152\|8805'` | both UDP sockets on `10.20.0.101`/pod |
| 5 | NG/E1/F1 | CU-CP log grep `NGSetupResponse\|Accepting new CU-UP\|Accepting DU` | all three present |
| 6 | UE tunnels | loop from CLAUDE.md "Quick health check" | 5 × `oaitun_ue1 10.45.0.x` |
| 7 | User plane | `validate-e2e.sh` | `VERDICT=E2E_UE1_VALIDATION_OK` (ping 8.8.8.8, 0 % loss) |
| 8 | Subscribers | Mongo `db.subscribers.count()` | 5 IMSIs `999700000000001-005` |
| 9 | Acceptance | `tests/run-full-platform-acceptance.sh` | all sections PASS |
| 10 | Reboot survival | reboot host, re-check 1–7 | bridges persist (netplan), pods return |
