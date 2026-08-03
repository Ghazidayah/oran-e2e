# Deployment Guide — Fresh Ubuntu 22.04 → Running O-RAN E2E Platform

> **Provenance**: consolidated from the **March 2026 deployment report**
> (Rapport d'avancement O-RAN, Steps 1–9 + annexes) and the **current repository**
> (`~/oran-e2e`, branch `cleanup-final-state`). The core procedure (host →
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

sudo swapoff -a
# Permanent: the swap entry in /etc/fstab is commented out on oran-lab
#   #/swapfile   none   swap   sw   0   0
# (recovered from the live host 2026-08-02)
sudo hostnamectl set-hostname oran-lab
```

**Success criteria**: `lsmod` shows `sctp`, `br_netfilter`, `overlay`; `swapon --show` empty;
`sysctl net.ipv4.ip_forward` = 1.
**Likely failure**: `gtp` module absent on stock kernel — non-blocking (`|| true`), GTP-U is
handled by the UPF in userspace.

## Step 2 — k3s + Helm (March, unchanged)

```bash
curl -sfL https://get.k3s.io | sudo sh -
# kubeconfig for the current user. The standard approach below matches what is
# in place on oran-lab (verified 2026-08-02):
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config && chmod 600 ~/.kube/config
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
# Chart version recovered from the live release 2026-08-02 (`helm list -A`):
#   release open5gs, namespace oran-core, chart open5gs-2.3.4, app version 2.7.5
# The local chart tree used in March is gone from disk; fetch open5gs 2.3.4
# specifically. Do NOT take latest upstream.
helm repo add bitnami https://charts.bitnami.com/bitnami && helm repo update
cd <chart-parent-dir> && helm dependency build charts/open5gs

helm -n oran-core install open5gs ./charts/open5gs \
  -f ~/oran-e2e/manifests/core/open5gs-5gsa.yaml \
  -f ~/oran-e2e/manifests/core/open5gs-overrides.yaml
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
| `open5gs-populate` init container CrashLoopBackOff (EACCES on MongoDB / duplicate IMSI key) | Disable populate via a third values file. Content recovered from the live release 2026-08-02: `populate:` / `  enabled: false`. See the recovered Helm values at the end of this document. |

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
  renderer: NetworkManager    # matches oran-lab (/etc/netplan/01-network-manager-all.yaml, verified 2026-08-02)
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
# Method recovered from the live cluster 2026-08-02: installed as a k3s HelmChart
# custom resource, release rke2-multus-v4.2.401 (app 4.2.4). Recreate with:
#
#   apiVersion: helm.cattle.io/v1
#   kind: HelmChart
#   metadata: { name: multus, namespace: kube-system }
#   spec:
#     repo: https://rke2-charts.rancher.io
#     chart: rke2-multus
#     targetNamespace: kube-system
#     valuesContent: |
#       config:
#         fullnameOverride: multus
#         cni_conf:
#           confDir: /var/lib/rancher/k3s/agent/etc/cni/net.d
#           binDir: /var/lib/rancher/k3s/data/cni/
#           kubeconfig: /var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d/multus.kubeconfig
#           multusAutoconfigDir: /var/lib/rancher/k3s/agent/etc/cni/net.d
#
# Then verify:
kubectl -n kube-system get ds | grep -i multus
kubectl get crd | grep -i network-attachment

# NADs — from this repo (bridge CNI, host-local IPAM, range .100-.200, gw .1):
kubectl apply -f ~/oran-e2e/manifests/network/n2-net-core.yaml
kubectl apply -f ~/oran-e2e/manifests/network/n3-net-core.yaml
kubectl apply -f ~/oran-e2e/manifests/network/n2-net-ran.yaml
kubectl apply -f ~/oran-e2e/manifests/network/n3-net-ran.yaml
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
**`open5gs-oai-prep`** (OPERATING-RULES.md rule 9 — NOT `open5gs-amf`), built from this repo and
rolled out by an existing script:

```bash
cd ~/oran-e2e && bash scripts/deploy-core.sh
# creates/updates open5gs-oai-prep from manifests/core/{amf,smf,upf}.yaml,
# restarts AMF/SMF/UPF, verifies sockets 38412 (NGAP) and 2152/8805 (GTP-U/PFCP)
```

**Prerequisite** — the AMF/UPF deployments must *mount* `open5gs-oai-prep` over their config
file. On a fresh Gradiant install they do not. The live capture in `manifests/core/open5gs-amf-deploy-live.yaml` carries sanitised
placeholders (`AMF_KEY_HERE` / `AMF_CM_HERE`). The real wiring, read from the running
AMF on 2026-08-02, is:

- volume `amf-config-fixed` → configMap `open5gs-oai-prep`
- volumeMount `amf-config-fixed` → mountPath `/opt/open5gs/etc/open5gs/amf.yaml`, subPath `amf.yaml`

Note that the AMF reads `open5gs-oai-prep`, **not** the chart's own `open5gs-amf`
ConfigMap (which also exists and is mounted at volumes `config` and `amf-config`
but reaches no container). This is OPERATING-RULES.md rule 9. Verify on a
throwaway target first.

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
cd ~/oran-e2e

# 8.1 DU ConfigMaps from the canonical confs (OPERATING-RULES.md rule 5: du0.conf is the n78 baseline)
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
# (OPERATING-RULES.md rule 4). bootstrap-platform.sh does this automatically.

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

Recovered from the live cluster 2026-08-02 (`helm list -A`): release
`oran-monitoring`, namespace `monitoring`, chart `kube-prometheus-stack-84.5.0`,
app version v0.90.1. Once installed, import the dashboards from
`monitoring/grafana/dashboards/` (`oran-5g-lab-ops.improved.json` is the live one;
Grafana NodePort 30300, Prometheus 30090).

## Step 10 — Dashboard, traffic API, first-start validation

```bash
cd ~/oran-e2e
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
| 6 | UE tunnels | loop from OPERATING-RULES.md "Quick health check" | 5 × `oaitun_ue1 10.45.0.x` |
| 7 | User plane | `validate-e2e.sh` | `VERDICT=E2E_UE1_VALIDATION_OK` (ping 8.8.8.8, 0 % loss) |
| 8 | Subscribers | Mongo `db.subscribers.count()` | 5 IMSIs `999700000000001-005` |
| 9 | Acceptance | `tests/run-full-platform-acceptance.sh` | all sections PASS |
| 10 | Reboot survival | reboot host, re-check 1–7 | bridges persist (netplan), pods return |


---

## Annex — Helm values recovered from the live cluster (2026-08-02)

These were read from the running platform with `helm -n oran-core get values open5gs`
and `helm list -A`. They replace the values that were never captured in the March
report. They are only readable while that cluster runs; treat this annex as the
record of record.

### Releases

| Release | Namespace | Chart | App version |
|---|---|---|---|
| `open5gs` | `oran-core` | `open5gs-2.3.4` | 2.7.5 |
| `multus` | `kube-system` | `rke2-multus-v4.2.401` | 4.2.4 |
| `oran-monitoring` | `monitoring` | `kube-prometheus-stack-84.5.0` | v0.90.1 |

### Open5GS user-supplied values

```yaml
amf:
  config:
    guamiList:
      - amf_id: {region: 2, set: 1}
        plmn_id: {mcc: "999", mnc: "70"}
    plmnList:
      - plmn_id: {mcc: "999", mnc: "70"}
        s_nssai: [{sd: "0x111111", sst: 1}]
    taiList:
      - plmn_id: {mcc: "999", mnc: "70"}
        tac: [1]
nssf:
  config:
    nsiList: [{sd: "0x111111", sst: 1, uri: ""}]
populate:
  enabled: false
  initCommands:
    - open5gs-dbctl add_ue_with_slice 999700000000001 <K> <OPc> internet 1 111111
    - open5gs-dbctl add_ue_with_slice 999700000000002 <K> <OPc> internet 1 111111
smf:
  config: {pcrf: {enabled: false}}
  image: {tag: 2.7.2}
upf:
  image: {tag: 2.7.6}
hss:   {enabled: false}
mme:   {enabled: false}
pcrf:  {enabled: false}
sgwc:  {enabled: false}
sgwu:  {enabled: false}
webui: {ingress: {enabled: false}}
```

`<K>` and `<OPc>` are the standard OAI public test credentials; see
`manifests/ran/nrue.lab.conf` for the values actually in use.

**Important**: these Helm values describe the *install-time* slice configuration
(a single S-NSSAI, `sst: 1 / sd: 0x111111`). The running platform was
subsequently reconfigured to four slices. See "Slice configuration — install
state versus running state" below before rebuilding.


---

## Core configuration — where each function reads from

Captured from the running cluster on 2026-08-03 and committed. The four files
under `manifests/core/` are **byte-identical to the live configuration**, so
`scripts/deploy-core.sh` is a no-op on content against the current platform.

The ConfigMap mapping is not uniform — this is OPERATING-RULES.md rule 9:

| Function | ConfigMap actually mounted | Key | Repo file |
|---|---|---|---|
| AMF | `open5gs-oai-prep` | `amf.yaml` | `manifests/core/amf.yaml` |
| UPF | `open5gs-oai-prep` | `upf.yaml` | `manifests/core/upf.yaml` |
| SMF | `open5gs-smf` | `smf.yaml` | `manifests/core/smf.yaml` |
| NSSF | `open5gs-nssf` | `nssf.yaml` | `manifests/core/nssf.yaml` |

The AMF mounts `open5gs-oai-prep` at
`/opt/open5gs/etc/open5gs/amf.yaml` through the volume `amf-config-fixed`. The
chart's own `open5gs-amf` ConfigMap also exists and is bound to the volumes
`config` and `amf-config`, but neither reaches a container — **editing
`open5gs-amf` has no effect.** The `smf.yaml` key inside `open5gs-oai-prep` is
likewise inert: the SMF reads `open5gs-smf`.

`deploy-core.sh` handles both shapes. It rebuilds `open5gs-oai-prep` wholesale,
and patches only the `data` key of `open5gs-smf` and `open5gs-nssf` so the Helm
labels and annotations on those two survive.

### History

Until 2026-08-03 the repository carried the *install-time* configuration from the
Helm values (a single S-NSSAI, `sst 1 / sd 0x111111`), while the running platform
had been reconfigured to `sst 1/2/3/4` with `sd 0xffffff`. The SMF and NSSF
configurations were absent from the repository entirely. Rebuilding from the repo
would therefore have left only eMBB working, with URLLC and mMTC no longer
grantable. That gap is now closed.

## RAN slice lists — SST 4 residue

The platform runs **three slices**: eMBB (SST 1), URLLC (SST 2), mMTC (SST 3).
These are the profiles the dashboard exposes (`REAL_SLICE_PROFILES` in
`web-dashboard/app.py`) and the only ones any validated scenario uses.

SST 4 is a retired value. It was written into the core and RAN configs by
`scripts/slicing/apply-real-snssai-slicing.sh` (now gated), then removed from the
subscriber baseline in commit `bc9158d`. See `docs/reference/SLICING-TRUTH.md`,
which documents this and notes that the `1|2|3|4` guard in `switch-ue-slice.sh`
is stale.

Residue measured on the running platform 2026-08-02:

| Component | `snssaiList` (running) | `snssaiList` (repo) |
|---|---|---|
| CU-CP | `sst 1, 2, 3` | `sst 1, 2, 3` |
| DU0 | `sst 1, 2, 3, 4` | `sst 1, 2, 3` |
| DU1 | `sst 1, 2, 3, 4` | `sst 1, 2, 3` |

**Nothing to decide here.** Since no subscriber carries SST 4, the Allowed NSSAI
can never contain it, so the extra entry on the DUs is unreachable. The repo's
`sst 1, 2, 3` is the correct description of what the platform actually does.

## Carrier baseline

The documented baseline carrier is profile `n78-current`
(`absoluteFrequencySSB = 621312`, `dl_absoluteFrequencyPointA = 620040`), which is
what `manifests/ran/f1/du0.conf` and `du1.conf` declare.

The frequency-retune scenarios leave the DU on the last profile applied. Before
any demonstration or measurement campaign, restore the baseline and confirm it:

```bash
bash scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh n78-current
curl -s http://127.0.0.1:18080/api/real-frequency/status | grep active_profile
```

## Throughput ceiling

`scripts/frequency/apply-fspl-band-profile.sh` and
`scripts/slicing/apply-slice-resource-profile.sh` read the measured TCP ceiling
from `~/oran-proof/ceiling-mbit.txt`, falling back to a hardcoded **33 Mbit/s**
when that file is absent. `~/oran-proof/` is local evidence and is not part of
the repository, so a fresh installation falls back to 33 while the published
results are calibrated on 35.

The ceiling is host-specific. Measure it once before running the frequency or
slicing scenarios:

```bash
bash scripts/traffic/measure-ceiling.sh    # writes ~/oran-proof/ceiling-mbit.txt
```
