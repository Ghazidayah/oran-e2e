# Limitations and Future Work

This document describes the deliberate scoping decisions made in the design of this O-RAN 5G SA
testbed, together with the natural extensions that would be required to move from a validation
platform towards a production or research infrastructure. Each item is a known trade-off, not an
oversight.

---

## 1. Single-node Kubernetes (k3s)

**Scoping decision.**
The platform runs as a single k3s node on `oran-lab` (Ubuntu 22.04). This is the correct choice
for a functional validation testbed: it eliminates cluster networking complexity, makes the system
reproducible on a single server, and allows all pods to share memory and CPU without inter-node
latency or distributed state.

All components — AMF, SMF, UPF, NRF, SCP, AUSF, NSSF, CU-CP, CU-UP, DU0, DU1, and five UEs —
co-exist on one node with predictable L3 connectivity via Linux bridges (`br-n2`, `br-n3`) managed
by Multus CNI.

**Future work.**
A multi-node k3s or kubeadm cluster would allow workload isolation per network function, geographic
distribution of DUs, and high-availability failover for core NFs (e.g., AMF with multiple instances
behind a load-balancer). This would also expose real inter-node latency on N2 and N3 interfaces,
enabling more realistic performance benchmarking.

---

## 2. RFsim scope: physical/RF layer only

**Scoping decision.**
OpenAirInterface RFsim replaces only the physical RF channel — the analogue radio link between the
UE antenna and the DU antenna. Every layer above it is the full production OAI stack:

| Interface / Layer | Implementation |
|---|---|
| MAC, RLC, PDCP, RRC | Full OAI L2/L3 |
| F1-AP (DU ↔ CU-CP) | Real SCTP/F1 over `br-n2` |
| E1-AP (CU-CP ↔ CU-UP) | Real SCTP/E1 over `br-n2` |
| NGAP / N2 (CU-CP ↔ AMF) | Real SCTP, AMF at `10.10.0.101:38412` |
| GTP-U / N3 (CU-UP ↔ UPF) | Real GTP-U, UPF at `10.20.0.101:2152` |
| 5G Core (NAS, SMF, UPF, NRF…) | Full Open5GS stack |

N2 handover has been validated at the control-plane level: NGAP Handover Required, AMF cell
transition, and NGAP Handover Command have been exercised, and UE1 successfully re-homes between
DU0 and DU1 at the RRC/NGAP level.

The user-plane switch requires re-pointing the UE's RFsim `serveraddr` from `oai-du0-rfsim` to
`oai-du1-rfsim` and restarting the UE pod. This is a known constraint of the RFsim transport: it
does not model a physical beam handoff, so the UE must re-attach to the target DU's RFsim server.
The control-plane handover procedure (NGAP) is real and correct; the user-plane switch is an
RFsim-layer artifact.

**Future work.**
Replacing RFsim with an SDR front-end (USRP, LimeSDR) or a channel emulator would enable physical
handover without pod restarting, wideband channel measurements, and multi-path / mobility testing.
OAI's channel model plugin (`chanmod`) within RFsim also provides a partial upgrade path for
adding controlled fading without hardware.

---

## 3. Configuration centralization

**Scoping decision.**
Several platform constants repeat across scripts rather than being sourced from a single
configuration file. The DN gateway (`10.45.0.1`) appears in five scripts:
`scripts/slicing/validate-current-slice.sh`, `scripts/ue/uectl.sh`, `scripts/validate-f1-ran.sh`,
`scripts/recover-ue-sessions.sh` (with an `${DN_GW:-10.45.0.1}` override), and
`scripts/slicing/validate-current-slice.sh`. The AMF NGAP address (`10.10.0.101:38412`) is
defined in DU and CU ConfigMaps.

This was an acceptable approach during iterative development: each script was self-contained and
could be run independently without sourcing a global file.

**Future work.**
A single `platform.yaml` or `platform.env` sourced by all scripts and templated into manifests
would make the platform relocatable (change of subnet, PLMN, or node IP requires one edit). Tools
such as Helm values files or Kustomize overlays are the standard Kubernetes mechanism for this and
integrate naturally with the existing Helm-based core deployment.

---

## 4. OAI image pinned to a fixed weekly tag

**Scoping decision.**
All RAN components are pinned to `oaisoftwarealliance/oai-gnb:2025.w45` and
`oaisoftwarealliance/oai-nr-ue:2025.w45`. Pinning to a specific weekly build guarantees that the
validated E2E behaviour is reproducible: every test run, every reboot, every `kubectl rollout
restart` brings up exactly the same binary. This is essential for a PFE validation campaign where
results must be attributable to a fixed software baseline.

The CU-CP intermittent segfault (exit code 139, ~4 restarts per 23 h, observed 2026-06-10/11) is
a known upstream issue in `2025.w45` and is documented in OPERATING-RULES.md. It does not affect
reproducibility of the validated scenarios.

**Future work.**
A validated upgrade path would consist of: (1) updating the image tag in manifests, (2) running
the full acceptance suite (`tests/run-full-platform-acceptance.sh`), (3) tagging the repo with the
new validated baseline. Automation of this cycle (CI pipeline triggered on a new weekly OAI
release) is a natural evolution for a longer-running testbed.

---

## 5. No CPU/memory limits on core and RAN pod deployments

**Scoping decision.**
AMF (`open5gs-amf-deploy-live.yaml`), UPF (`open5gs-upf-deploy-live.yaml`), DU0, and DU1
deployments specify `resources: {}`, meaning no CPU or memory requests or limits are set. UE pods
have explicit limits (4 CPU / 4 GiB per UE) to prevent runaway RFsim processes from starving the
node.

Omitting limits on core NFs is deliberate for a single-node testbed: it allows the OS scheduler
to allocate burst capacity freely, avoids CPU throttling artifacts in latency measurements, and
sidesteps the risk of OOMKill on pods whose memory footprint varies with the number of registered
UEs or active PDU sessions.

**Future work.**
In a multi-tenant or production-adjacent deployment, resource quotas would be required to provide
QoS guarantees between NFs and to prevent a misbehaving pod from destabilising the node. Vertical
Pod Autoscaler (VPA) can provide empirical request/limit recommendations based on observed usage,
and should be consulted before setting static values.

---

## 6. Single gNB-ID shared across DUs (F1-split architecture)

**Scoping decision.**
Both DU0 and DU1 share `gNB_ID = 0xe00`, which is correct for a 3GPP F1-split deployment.
In this architecture there is a single logical gNB (the CU-CP, at `gNB_ID = 0xe00`), and the DUs
are its radio heads identified by their own unique `gNB_DU_ID`: DU0 uses `0xe00` and DU1 uses
`0xe01`. The AMF, UE, and NGAP messages all reference the single gNB, while F1-AP internally
routes to the correct DU via `gNB_DU_ID`. This is the intended 3GPP TS 38.473 behaviour for
a distributed RAN with a centralised CU.

**Future work.**
Adding a second independent gNB (separate `gNB_ID`, separate CU-CP + CU-UP pair) would enable
inter-gNB Xn handover, multi-operator or multi-tenant scenarios, and evaluation of O-RAN E2
interface coordination across multiple gNBs. The E2 agent stub already present in
`manifests/ran/f1/du0.conf` (`near_ric_ip_addr = "127.0.0.1"`) provides the configuration
insertion point for near-RT RIC integration when a FlexRIC or O-RAN SC RIC instance is available.

---

## 7. Frequency-band degradation emulated via FSPL-derived traffic shaping

**Scoping decision.**
OAI RFsim does not model path loss as a function of carrier frequency: a 4.2 GHz link and a
2.6 GHz link produce identical throughput in simulation. To provide physically-grounded
differentiation between frequency bands, this testbed derives a throughput coefficient K from
the free-space path loss model:

```
ΔPL = 20 · log₁₀(f_target / f_ref)    [dB]
K   = 10^(−ΔPL / 10)
```

with f_ref = 2593.35 MHz (n41 SSB carrier) as the reference. K is then used to cap both uplink
and downlink throughput on `oaitun_ue1` via `tc tbf` on egress and an `ifb_ue1` redirect on
ingress. Approximate coefficients: n41 K ≈ 1.00 (uncapped), n78 K ≈ 0.55, n77 K ≈ 0.39.

The approach is analytically justified — FSPL is the correct first-order model for the
frequency-dependent propagation loss at fixed distance in free space — and the coefficients are
computed from real carrier frequencies (n41: 2593.35 MHz, n78: 3499.68 MHz, n77: 4173.60 MHz)
derived from 3GPP NR-ARFCN values. The cap applies at the IP/traffic layer and is opt-in via
`FSPL_CAP=1`, so it does not interfere with the baseline retune validation.

**Future work.**
RFsim's channel model plugin (`chanmod`) can introduce Gaussian noise, delay spread, and Doppler
profiles. A future extension would map each frequency band to a parameterised channel model
(e.g., 3GPP TR 38.901 UMa at the corresponding frequency), providing physically modelled
throughput variation rather than a traffic-layer cap. This would also capture effects that FSPL
alone does not represent, such as diffraction loss, coherence bandwidth differences between
sub-3 GHz and mid-band carriers, and beam management overhead.
