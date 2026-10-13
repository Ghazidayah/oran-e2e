# oran-e2e - O-RAN end-to-end 5G testbed

Single-node 5G standalone testbed: an **Open5GS** core, an **OpenAirInterface** RAN with the
**E1/F1 split** (CU-CP + CU-UP + DU0 + DU1) and **5 UEs**, running on k3s with the radio replaced
by OAI **RFsim** (no RF hardware). A Flask dashboard on port **18080** drives scenarios
(traffic, slicing, modulation, frequency, DU handover) and displays the results.

This repository is not an ordinary codebase: it is a set of scripts, configs and manifests wired
to a **live cluster** on the host `oran-lab`. Commands here can take real UEs offline. Read
[Safety rules](#safety-rules) before touching the cluster.

## Contents

1. [Platform](#platform)
2. [Repository layout](#repository-layout)
3. [Getting started](#getting-started)
4. [Dashboard and APIs](#dashboard-and-apis)
5. [Scripts, tests and tools](#scripts-tests-and-tools)
6. [Safety rules](#safety-rules)
7. [Troubleshooting](#troubleshooting)
8. [What is real and what is emulated](#what-is-real-and-what-is-emulated)
9. [Slicing, modulation and frequency](#slicing-modulation-and-frequency)
10. [Limitations](#limitations)
11. [Evidence](#evidence)

---

## Platform

| Item | Value |
|---|---|
| Host | `oran-lab`, Ubuntu 22.04, single-node **k3s**, Helm |
| Core | Open5GS 5G SA (chart `open5gs-2.3.4`, app 2.7.5), namespace `oran-core` |
| RAN | OpenAirInterface `2025.w45`, E1/F1 split, RFsim, namespace `oran-ran` |
| Secondary networks | Multus with bridges `br-n2` (10.10.0.0/24) and `br-n3` (10.20.0.0/24) |
| Monitoring | kube-prometheus-stack, namespace `monitoring` |
| PLMN / DNN | MCC 999, MNC 70, DNN `oai`, TAC 1 |
| UEs | 5 UEs, IMSI `999700000000001` … `999700000000005` |
| Repo root on the host | `~/oran-e2e` (scripts honour the `REPO` environment variable) |

### Topology

```
UE1 (oai-nr-ue)          UE2-5 (oai-nr-ue-2..5)
  │ RFsim TCP 4043          │ RFsim TCP 4043
  ▼                         ▼
DU0 (oai-du0)           DU1 (oai-du1)
  │ F1-C (SCTP)           │ F1-C (SCTP)
  └──────────┬────────────┘
             ▼  br-n2 / 10.10.0.0/24
         CU-CP (oai-cu-cp)  ◄──── E1 ────►  CU-UP (oai-cu-up)
             │ NGAP (SCTP 38412)               │ GTP-U
             ▼                                 ▼
         AMF (open5gs-amf)               UPF (open5gs-upf)
         10.10.0.101                     10.20.0.101:2152
                                              │ br-n3 / 10.20.0.0/24
                                              ▼
                                    Data network 10.45.0.0/16, gateway 10.45.0.1
```

### Fixed addresses

| Component | Address | Port | Protocol |
|---|---|---|---|
| AMF NGAP | 10.10.0.101 | 38412 | SCTP (N2) |
| AMF SBI | 10.10.0.101 | 7777 | HTTP/2 |
| UPF GTP-U | 10.20.0.101 | 2152 | UDP (N3) |
| CU-CP F1-C / E1 | 10.10.0.120 | 38472 / 38462 | SCTP |
| DU0 F1 | 10.10.0.121 | 2152 (F1-U) | UDP |
| DU1 F1 | 10.10.0.132 | 2152 (F1-U) | UDP |
| RFsim (per DU) | service `oai-du0-rfsim` / `oai-du1-rfsim` | 4043 | TCP |

CU-UP has no fixed Multus address; it connects to CU-CP E1 at `10.10.0.120:38462`. Identifiers:
gNB_ID `0xe00`, DU0 `gNB_DU_ID` `0xe00`, DU1 `0xe01`. UE tunnels are `oaitun_ue1` inside each UE
pod, with dynamic `10.45.0.x` addresses that change on every PDU session re-establishment.

DU deployments use `strategy: Recreate` because they hold fixed Multus addresses; UE deployments
have no fixed address and can be restarted with `rollout restart`.

### UE ↔ DU mapping

UE1 has DU0 as its baseline and can be switched between DU0 and DU1. UE2-UE5 live on DU1. The
mapping is resolved at runtime from each UE's `--rfsimulator.serveraddr` deployment argument
(`ue_serveraddr_from_cm` in `scripts/ue/ue-common.sh`). Never hardcode a UE's DU.

---

## Repository layout

```
oran-e2e/
├── config/ues.yaml           UE fleet definition (read by tools/uectl.sh)
├── evidence/pcap/            Wireshark captures (E1AP, F1AP+RRC, N2 NGAP, N3 GTP-U)
├── manifests/
│   ├── core/                 Open5GS configs and live captures (amf/smf/upf/nssf, Helm values)
│   ├── network/              Multus network-attachment definitions (N2, N3)
│   └── ran/
│       ├── e1/               CU-CP / CU-UP configs and deployments
│       ├── f1/               DU configs, DU deployments and rfsim services
│       ├── mixed-du-live/    Manifests synced from the live cluster (UE1-5, DU0/DU1)
│       ├── multi-ue/         Generated UE2-5 manifests (scripts/ue/generate-5ue-manifests.sh)
│       └── nrue.lab.conf     UE1 config, source of the key/opc used for the generated UEs
├── monitoring/grafana/       Grafana dashboard JSON
├── scripts/                  Platform operation (called by the dashboard, tests and each other)
│   ├── bootstrap-platform.sh      Fresh-host build (interactive)
│   ├── run-web-dashboard.sh / stop-web-dashboard.sh   Start / stop the dashboard
│   ├── deploy-core.sh             Rebuild core configuration and restart the core
│   ├── validate-f1-ran.sh / validate-e2e.sh   Topology and end-to-end checks
│   ├── recover-ue-sessions.sh     Diagnose-first UE session recovery
│   ├── frequency/  handover/  radio/  slicing/  traffic/  ue/
├── tests/                    Section tests 01-07 and the full acceptance suite
├── tools/                    Manual helpers, never called by other code
├── web-dashboard/            Flask dashboard and per-feature API modules
├── platform-start.sh         Restart the platform (restores replica counts)
└── platform-stop.sh          Stop the platform (snapshot + scale to zero)
```

Run artefacts (logs, verdicts, KPI summaries) are written **outside the repository**, under
`$HOME/oran-proof/`.

---

## Getting started

> **Never run `kubectl apply -f manifests/` directly.** The RAN manifests (`ran/f1/f1-ran.yaml`,
> `ran/e1/e1-split.yaml`, `ran/multi-ue/*.yaml`) declare `replicas: 0` on purpose, because the
> bring-up order matters (CU-CP → CU-UP → DUs → UEs); applying them scales running components to
> zero. Several files under `manifests/core/` are Open5GS config fragments or Helm values, not
> Kubernetes objects, and are rejected by `kubectl apply`. Use the scripts below.

### Three ways to deploy

```bash
# 1. Fresh host, whole platform (interactive checkpoints).
#    Aborts if oran-core already has pods. Covers host preparation, k3s, Helm,
#    namespaces, Open5GS, bridges, Multus, RAN, UEs, subscribers, dashboard.
./scripts/bootstrap-platform.sh

# 2. Restart an already-deployed platform (normal path).
#    platform-start.sh restores replica counts from ~/.oran-lab/platform-replicas.tsv,
#    which platform-stop.sh writes: run one stop/start cycle to create it.
./platform-start.sh
./platform-stop.sh

# 3. RAN layer only, from the repo manifests. All four Deployments ship with
#    replicas: 0; scale in E1 order: CU-CP -> CU-UP -> DUs.
kubectl -n oran-ran create configmap oai-du0-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du0.conf --dry-run=client -o yaml | kubectl apply -f -
kubectl -n oran-ran create configmap oai-du1-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du1.conf --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/ran/e1/e1-split.yaml
kubectl apply -f manifests/ran/f1/f1-ran.yaml
kubectl -n oran-ran scale deploy/oai-cu-cp --replicas=1
kubectl -n oran-ran rollout status deploy/oai-cu-cp --timeout=180s
kubectl -n oran-ran scale deploy/oai-cu-up --replicas=1
kubectl -n oran-ran rollout status deploy/oai-cu-up --timeout=180s
kubectl -n oran-ran scale deploy/oai-du0 deploy/oai-du1 --replicas=1
```

`scripts/deploy-core.sh` rebuilds the core configuration from `manifests/core/`; the files there
are byte-identical to the live configuration, so it is a no-op on content but still restarts the
affected network functions. Which ConfigMap each function really reads:

| Function | ConfigMap (key) |
|---|---|
| AMF | `open5gs-oai-prep` (`amf.yaml`), not `open5gs-amf` which is mounted but unused |
| UPF | `open5gs-oai-prep` (`upf.yaml`) |
| SMF | `open5gs-smf` (`smf.yaml`) |
| NSSF | `open5gs-nssf` (`nssf.yaml`) |

### Cold-start ordering

On a cold start the CU-CP can become `Ready` before its NGAP association with the AMF exists, and
UEs then fail with `Registration reject [9]` or have no tunnel. `platform-start.sh`
handles this: it waits for the AMF endpoint, then checks **both** CU interfaces (NGAP to the AMF
and E1 to the CU-UP) and, when either is down, restarts CU-CP, then CU-UP, then the DUs, up to
three times. Environment switches: `ORAN_CORE_GATE`, `ORAN_CORE_REGISTER_SETTLE`, `ORAN_CU_GATE=0`
(disable), `ORAN_CU_MAX_TRIES` (default 3), `ORAN_CU_SETTLE_SECONDS` (default 25),
`ORAN_START_DASHBOARD`, `ORAN_RECOVER_MIXED_DU`.

### Health check (read-only)

```bash
kubectl get nodes -o wide
kubectl -n oran-core get pods -o wide
kubectl -n oran-ran  get pods -o wide
kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn | egrep '38412|7777'
kubectl -n oran-core exec deploy/open5gs-upf -- ss -lunp | egrep '2152|8805'
for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  p=$(kubectl -n oran-ran get pod -l app=$d -o jsonpath='{.items[0].metadata.name}')
  echo -n "$d: "; kubectl -n oran-ran exec "$p" -- sh -c 'ip -br a | grep oaitun || echo NO_TUNNEL'
done
./scripts/validate-f1-ran.sh     # F1/E1 topology healthy
./scripts/validate-e2e.sh        # end-to-end tunnel + ping
```

---

## Dashboard and APIs

```bash
./scripts/stop-web-dashboard.sh                              # stop any running instance
nohup ./scripts/run-web-dashboard.sh > /tmp/dash.log 2>&1 &  # start (does not self-detach)
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18080/   # 200
```

One Flask process on port **18080** serves the UI and every API. Modules in `web-dashboard/`:

| File | Role |
|---|---|
| `app.py` | Application, main routes, command runner, blueprint registration |
| `settings.py` | Shared paths (repo root, proof directory) |
| `traffic_scenarios_api.py` | `/api/traffic/*`: realistic traffic scenarios and real-slice traffic jobs |
| `traffic_kpi_api.py` | Parses job logs into consolidated KPI results (`/api/e2e-kpi/results`) |
| `multi_ue_api.py` | Multi-UE control and multi-UE eMBB scenarios |
| `mixed_du_handover_api.py` | `/api/handover/mixed-du/*`: UE DU switching and recovery |
| `handover_api.py` | `/api/handover/status` (uses `actions/f1_status.sh`) |
| `radio_profile_api.py` | Modulation profiles (QPSK / 16QAM / 64QAM / auto) |
| `real_frequency_api.py` | Carrier retune and band KPI comparison |
| `templates/index.html`, `static/` | Single-page UI, one CSS file, JavaScript modules (`common.js` holds the shared helpers) |

Install dependencies with `pip install -r web-dashboard/requirements.txt`. The port defaults to 18080
(`ORAN_DASHBOARD_PORT`) and the repo root to the parent of `web-dashboard/` (`ORAN_REPO`).

### UI sections

| Section | Controls | Backend |
|---|---|---|
| Top bar | Section links, **Evidence Report** (text report of platform state), Grafana link | `POST /api/action/report` |
| Status cards | Core / RAN + UE / Monitoring / UE tunnel (refreshed every 10 s) | `GET /api/status` |
| Radio / Modulation | Profile select, **Apply + KPI Test**, KPI table | `/api/radio/*` |
| Frequency | Band select (the `n78 3320 MHz (baseline)` entry restores the original carrier), **Run**, KPI table | `/api/real-frequency/*` |
| End-to-End scenarios | **UE Check** (serving DU, attach + PDU, connectivity in sequence), six traffic scenarios, **Run All** | `/api/action/ownership`, `/api/ues/scenario/*`, `/api/traffic/run/*` |
| Slices | eMBB / URLLC / mMTC traffic, results table | `/api/real-slice/*` |
| Pods | RAN and core pod tables | `/api/status` |
| Live transfer | Aggregate RX/TX chart and per-UE rates | `/api/ues/live_metrics` |
| DU handover | One card per UE with a **DU0 | DU1** toggle (the lit half is the serving DU; click the other half to hand over) | `/api/handover/mixed-du/*` |
| Multi-UE | Desired UE count (**Apply**), **Run selected scenarios**, per-UE Stop / Ping | `/api/ues*`, `/api/ue/<name>/*` |

Status, results and DU placement refresh automatically (10-30 s, paused while a job runs or the tab is hidden), so there are no manual refresh buttons. Actions and handovers run without a confirmation dialog: this is a lab platform, and most
long-running buttons disable themselves until their job finishes.

---

## Scripts, tests and tools

| Directory | Contents |
|---|---|
| `scripts/ue/` | `ue-common.sh` (shared helpers), `generate-5ue-manifests.sh`, `provision-5ue-subscribers.sh` |
| `scripts/slicing/` | `switch-ue-slice.sh`, `validate-current-slice.sh`, `apply-slice-resource-profile.sh`, `run-real-slice-traffic.sh` |
| `scripts/traffic/` | One script per scenario (image, video, web, streaming, iperf TCP, UDP), `run-all-realistic-traffic.sh`, `measure-ceiling.sh` |
| `scripts/frequency/` | `switch-ue-actual-frequency-retune-du-aware.sh`, `apply-fspl-band-profile.sh` |
| `scripts/radio/` | `switch-ue-modulation-profile-du-aware.sh` |
| `scripts/handover/` | `switch-ue-du-target.sh`, `recover-mixed-du-state.sh` (needs the dashboard running) |
| `tests/` | `test-section-01` … `07` and `run-full-platform-acceptance.sh` |
| `tools/` | `uectl.sh`, `compute-fspl-k.sh`, `audit-dashboard-and-platform.sh`, `audit-frequency-retune-readiness.sh`, `test-traffic-scenarios.sh`, `gather-report-data.sh`, `diagnose-du-layout.sh` (read-only UE/DU snapshot) |

```bash
./tests/run-full-platform-acceptance.sh          # whole platform, never stops at the first failure
QUICK=1 ./tests/run-full-platform-acceptance.sh  # shorter run
./tests/test-section-03-real-slices.sh           # one section
./tools/test-traffic-scenarios.sh                # every traffic scenario through the API
./tools/uectl.sh status                          # UE fleet helper (run from the repo root)
```

Section tests: 01 baseline end-to-end, 02 realistic traffic, 03 real slices, 04 radio profiles,
05 multi-UE eMBB, 06 mixed-DU handover, 07 final regression.

---

## Safety rules

1. **Read-only is free; mutation needs confirmation.** `kubectl get/describe/logs` and file reads
   are always fine. Confirm before `kubectl delete/scale/patch/apply/rollout restart`, `helm
   upgrade`, or anything that restarts core or RAN pods.
2. **A core (AMF/SMF/UPF/MongoDB) or CU restart wipes all PDU sessions.** UEs usually re-register
   and re-form tunnels with new addresses, but some keep a stale `oaitun_ue1`. Do not blind-restart
   all UEs: run `scripts/recover-ue-sessions.sh` (read-only diagnosis) and add `--fix` to restart
   only the UEs that fail.
3. **`sed` edits to `.conf` files must be whitespace-agnostic.** The configs align values with long
   runs of spaces: `sed -E 's/(key[[:space:]]*=[[:space:]]*)OLD;/\1NEW;/'`, then `grep` to confirm
   the change landed.
4. **Never `kubectl apply` a previously saved manifest verbatim.** It carries a stale
   `resourceVersion` and is rejected (`Conflict: object has been modified`). Strip
   `resourceVersion/uid/creationTimestamp/managedFields/generation` and `status`, or rebuild with
   `kubectl create cm ... --dry-run=client -o yaml | kubectl apply -f -`.
5. **The DU0 n78 baseline lives in `manifests/ran/f1/du0.conf`** (band 78, SSB 621312, F1
   10.10.0.121). Restore DU0 from this file, not from a backup copy.
6. After any RF experiment on DU0/UE1, **restore n78** and confirm UE1 pings with 0 % loss.
7. Report what the logs show. Call a result validated only with end-to-end proof (tunnel + ping or
   session), not partial success.
8. **ConfigMap edits do not reach running pods** (subPath mounts). Restart the consuming deployment
   and verify the file inside the new pod (`kubectl exec ... grep`).
9. **The AMF reads `open5gs-oai-prep` (key `amf.yaml`)**, not `open5gs-amf`. The slice list lives
   there.
10. **UE deployment args override ConfigMap values** (for example `--rfsimulator.serveraddr`). When a
    UE misbehaves, check the deployment args first.
11. **Slice switching = UE config (legacy nssai keys) + MongoDB `default_indicator` together.** The
    `2025.w45` nr-ue ignores `pdu_sessions = ({...})` and sends no Requested NSSAI, so the Allowed
    NSSAI is the subscriber default only. Use `scripts/slicing/switch-ue-slice.sh`; success is the
    AMF-granted `S_NSSAI[SST:x]`, never just a tunnel.

Conventions: prove a change live (or on a throwaway target) before wiring it into the dashboard or
the main scripts; DU/UE changes must be reversible to the n78 / DU baseline.

---

## Troubleshooting

**CU segfault (exit 139).** `oai-cu-cp` restarts, no OOMKill event, all PDU sessions drop. This is
an intermittent upstream fault of image `oai-gnb:2025.w45` under RFsim load (a few restarts per
day), not a memory problem. Wait for the pod to restart, then run `scripts/recover-ue-sessions.sh`
and, if any UE is `NO_POD`, `UNHEALTHY(no-pod)` or `UNHEALTHY(ping-fail)`,
`scripts/recover-ue-sessions.sh --fix` (add `--yes` to skip the prompt). It compares each UE's
tunnel address with the SMF's latest assignment, pings the gateway 10.45.0.1 through the tunnel and
restarts only the failing UEs. Do not change the CU image without re-validating everything.

**UE tunnels not forming after a core/CU restart.** Same recovery as above.

**CU not NGAP-associated on cold start.** CU log shows `[NGAP] No AMF is associated`. Handled
automatically by `platform-start.sh` (see Cold-start ordering). Manually:

```bash
kubectl -n oran-ran logs deploy/oai-cu-cp --tail=20 | grep -i "AMF\|ngap"
kubectl -n oran-ran rollout restart deploy/oai-cu-cp
kubectl -n oran-ran rollout status  deploy/oai-cu-cp --timeout=3m
kubectl -n oran-ran rollout restart deploy/oai-du0 deploy/oai-du1
scripts/recover-ue-sessions.sh --fix
```

**Registration rejected / no Allowed NSSAI.** Check, in order: the AMF ConfigMap
(`kubectl -n oran-core get cm open5gs-oai-prep -o jsonpath='{.data.amf\.yaml}' | grep -A5 s_nssai`,
then restart the AMF and verify inside the pod); the UE deployment args
(`kubectl -n oran-ran get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}'`);
the MongoDB subscriber slices
(`kubectl -n oran-core exec <mongodb-pod> -- mongosh open5gs --eval 'db.subscribers.find({},{imsi:1,slice:1}).toArray()'`).

**Frequency or DU switch left UE1 stranded.**

```bash
bash scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh restore   # back to n78-current
bash scripts/handover/recover-mixed-du-state.sh                                # or POST /api/handover/mixed-du/recover
```

**ConfigMap edit has no effect.** Restart the deployment and verify inside the new pod (rule 8).

**`kubectl apply` says "object has been modified".** See rule 4.

---

## What is real and what is emulated

Real application traffic runs over the real 5G protocol stack end to end, on top of a simulated
radio channel. Only the over-the-air radio is simulated; a few performance comparisons that an
idealised radio cannot produce are emulated with traffic shaping and labelled as such.

| Layer / feature | Status | Notes |
|---|---|---|
| Application traffic (HTTP, UDP, iperf3, HLS-like) | Real | Byte-exact checksums, real connections |
| User plane | Real | UE app → `oaitun_ue1` → PHY/MAC → DU → F1-U → CU → GTP-U → UPF |
| Registration, PDU session, S-NSSAI grant | Real | Grants are read from AMF logs, never assumed |
| F1 split, DU switching / handover | Real | UE is re-pointed to the other DU and re-attaches |
| Slice admission | Real | AMF grants the requested S-NSSAI |
| Modulation profiles | Real | Forced via gNB MAC `dl/ul_max_mcs`; Qm confirmed in DU MAC logs |
| Carrier retune (n78 / n41 / C-band) | Real | OAI carrier keys reconfigured, DU+UE restarted |
| Scenario KPIs (throughput, jitter, integrity) | Real | Measured on the user plane, no shaping |
| Radio channel (propagation, fading, mobility) | Simulated | RFsim provides an idealised channel |
| Per-band performance differences | Emulated | `tc netem` / `tbf`, because RFsim does not vary with frequency |
| Per-slice QoS differences | Emulated | `tc tbf`, because the RFsim scheduler does not enforce 5QI/GBR |

How each real claim is proven: the UDP receiver logs the UPF pod address as packet source; the SMF
assigns an IPv4 lease per IMSI visible on the UE tunnel; the AMF logs `S_NSSAI[SST:N]` per UE; DU
MAC logs show the modulation order; DU carrier keys change on retune; ICMP to 10.45.0.1 shows 0 %
loss.

---

## Slicing, modulation and frequency

### Slicing

The manifests and the subscriber database carry **SST=1 only** at rest (`sst=1, sd=FFFFFF`,
`default_indicator=true`); the running core advertises SST 1-4 in ConfigMaps. Admission is gated by
the subscriber record, so the platform sits at SST=1 unless a slice is switched on purpose:

```bash
scripts/slicing/switch-ue-slice.sh <sst> [sd]     # UE1: patch UE config + MongoDB default, restart UE1
scripts/slicing/validate-current-slice.sh         # assert the AMF-granted slice, tunnel and ping
scripts/slicing/switch-ue-slice.sh 1 0xffffff     # back to the eMBB baseline
scripts/slicing/apply-slice-resource-profile.sh <embb|urllc|mmtc|clear>
```

Only SST 1, 2 and 3 are actually granted (SST 4 was removed from the subscriber baseline although
the script guard still accepts it). Per-slice QoS profiles are emulated: rate is a percentage of the
measured ceiling (`scripts/traffic/measure-ceiling.sh` writes `~/oran-proof/ceiling-mbit.txt`;
fallback 33 Mbit/s): eMBB 100 %, URLLC 3 %, mMTC 0.1 %, with one-way `netem` delays of 0 / 0 / 1000 ms
beyond the baseline, applied in both directions (the downstream path is mirrored through `ifb_ue1`).

### Modulation

| Profile | Max MCS | Modulation | Measured uplink |
|---|---|---|---|
| qpsk-robust | 4 | QPSK | ~ 6.7 Mbit/s |
| qam16-balanced | 13 | 16QAM | ~ 17.7-19 Mbit/s |
| qam64-throughput | 28 | 64QAM | ~ 30-36 Mbit/s |
| scheduler-auto | none | adaptive | climbs to 64QAM under load |

`qam256-max` tops out at 64QAM: the OAI UE does not advertise `pdsch-256QAM-FR1`.

### Frequency

Validated carriers (TDD, 30 kHz, carrier-retune only): **n78 3500 / 3780 MHz**, **n41 2600 MHz**,
n77 4174 MHz. `n28 700 MHz` (FDD) is sync-only in RFsim because of a Msg3 PUSCH limitation of OAI
RFsim FDD. The two experiments are distinct: **Real Carrier Retune** reconfigures the DU carrier
(real), **Band KPI Comparison** keeps the DU on n78 and shapes traffic with `netem` (emulated).

The emulated degradation follows free-space path loss relative to the n41 reference carrier:
`dPL = 20·log10(f_target / f_ref)` dB and `K = 10^(-dPL/10)`; distance cancels in the difference.

| Band | Carrier (MHz) | dPL (dB) | K | Cap (% of ceiling) |
|---|---|---|---|---|
| n41 | 2593.35 | 0.00 | 1.00 | 100 % |
| n78 | 3499.68 | ≈ 2.61 | ≈ 0.55 | ≈ 55 % |
| n77 | 4173.60 | ≈ 4.14 | ≈ 0.39 | ≈ 39 % |

`tools/compute-fspl-k.sh <f_ref_MHz> <f_target_MHz>` computes the coefficient. `n78-current` is SSB
621312 (3319.68 MHz) and `n78-3500` is SSB 633312 (3499.68 MHz); `restore` returns to `n78-current`.
`FSPL_CAP=1` opts in to applying the FSPL cap during retune scenarios.

---

## Limitations

- **Single-node k3s**: no node failure domain, no scheduling across hosts.
- **RFsim scope**: physical layer only; no real propagation, fading or mobility.
- **Configuration is spread over several ConfigMaps** (see the table in Getting started).
- **Pinned image** `oai-gnb:2025.w45`: carries the intermittent CU segfault and the UE NSSAI and
  256QAM limitations above.
- **No CPU/memory limits** on core and RAN pods.
- **One gNB-ID (`0xe00`) shared across both DUs** (F1-split architecture).
- **Band and slice performance deltas are shaped, not radio-derived.**
- **E2**: the agent is configured, but no Near-RT RIC is deployed.

---

## Evidence

`evidence/pcap/` holds captures of the E1/F1-split platform:

| File | Shows |
|---|---|
| `01-e1ap-cuup-setup.pcap` | E1AP CU-UP setup |
| `02-f1ap-setup-rrc-attach.pcap` | F1AP setup and the full RRC attach |
| `03-n2-ngap-registration.pcap` | N2 NGAP registration |
| `04-n3-gtpu-userplane.pcap` | N3 GTP-U user plane |
