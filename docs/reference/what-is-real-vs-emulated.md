# What Is Real and What Is Emulated

**Purpose.** This is the single-source reference for which parts of the oran-e2e
testbed are *real* (genuine 3GPP/5G procedures and live data) and which are *emulated*
(deliberately synthesized to illustrate behaviour that an idealized simulator cannot
physically reproduce). It exists so that every number shown on the dashboard can be
honestly attributed, and so the boundary can be explained precisely on demand.

**Platform in one line.** Open5GS 5G SA core + OpenAirInterface F1-split RAN
(CU + DU0 + DU1) + 5 UEs, all in containers on a single-node k3s cluster, with the
radio replaced by OAI **RFsim** (a software channel simulator — there is no RF hardware).

---

## 1. The one-sentence summary

> **Real application traffic runs over the real 5G protocol stack end-to-end, on top of a
> simulated radio channel.** Everything from the application down through NAS/NGAP signalling,
> the F1 split, and the GTP-U user plane is genuine; only the over-the-air radio is simulated,
> and a few *performance comparisons* that the simulated radio cannot physically produce are
> emulated with traffic shaping — always labelled as such.

---

## 2. Master table

| Layer / Feature | Status | What that means here |
|---|---|---|
| Application traffic (HTTP, UDP, iperf3, HLS) | **REAL** | Actual TCP connections, UDP datagrams and HTTP transfers with byte-exact checksums. |
| 5G user plane (data path) | **REAL** | Every byte traverses UE app -> `oaitun_ue1` -> OAI PHY/MAC -> DU -> F1-U -> CU -> GTP-U -> Open5GS UPF. Proven: the UDP receiver logs the UPF pod IP as the packet source. |
| Control plane: registration, PDU session, S-NSSAI | **REAL** | Genuine 3GPP NAS/NGAP procedures. Slice grants are read from AMF logs, never assumed. |
| F1 functional split (CU + DU0/DU1) | **REAL** | Real F1-C/F1-U between a CU and two DUs; UEs attach through a DU and can be moved between DUs. |
| DU switching / UE-DU handover | **REAL** | The UE is genuinely re-pointed at a different DU (serveraddr + args) and re-attaches; verified by tunnel re-formation + AMF re-grant. |
| Network slicing - admission | **REAL** | AMF genuinely grants the requested S-NSSAI (e.g. SST:2 for URLLC); evidence parsed from AMF logs. |
| Modulation profiles (QPSK / 16QAM / 64QAM) | **REAL** | Forced via real gNB MAC parameters (`--MACRLCs.[0].dl/ul_max_mcs`); the modulation order (Qm 2/4/6) is confirmed in DU MAC logs and throughput scales with it. |
| Carrier retune (n78 / n41 / C-band) | **REAL** | Real OAI carrier-key reconfiguration (absoluteFrequencySSB, PointA, frequencyBand) with DU+UE pod restart; UE re-attaches on the new carrier. |
| Phase-2 scenario KPIs (throughput, jitter, integrity) | **REAL measurements** | No `tc`/`netem` in the path; measured over the genuine user plane. |
| Radio channel (propagation, fading, distance, mobility) | **SIMULATED** | RFsim provides an idealized AWGN channel. There is no real RF, no path loss vs distance, no Doppler. |
| Per-**band** performance differences | **EMULATED** (`tc netem`) | RFsim's channel does not vary with carrier frequency, so latency/throughput deltas between n78/n41/n28 are synthesized with netem to illustrate the real-world tradeoff. The retune itself (above) is real; its *performance consequences* are emulated. |
| Per-**slice** performance differences (QoS/GBR effects) | **EMULATED** (`tc tbf`) | The RFsim scheduler does not enforce 5QI/GBR, so per-slice rate/latency differences are shaped with tbf. Slice *admission* (above) is real. |

---

## 3. Per-scenario-family detail

### 3.1 Realistic traffic scenarios (Phase 2)
**REAL.** Image download (checksum-verified), video download, web browsing, HLS-style
streaming, iperf3 TCP, and a custom UDP jitter/loss test. All run as real application
traffic over the real user plane with no shaping. Validated measurements include iperf3
~ 17.6 Mbps uplink with 0 retransmits, UDP 1000/1000 packets at 0% loss, and byte-exact
download checksums. The radio underneath is simulated (RFsim), but the traffic and the
protocol stack carrying it are real.

### 3.2 Modulation profiles
**REAL.** Each profile caps the gNB scheduler's MCS through real MAC parameters, and the
resulting modulation order is confirmed in DU MAC logs:

| Profile | Max MCS | Modulation (Qm) | Measured throughput |
|---|---|---|---|
| qpsk-robust | 4 | QPSK (Qm 2) | ~ 6.7 Mbps |
| qam16-balanced | 13 | 16QAM (Qm 4) | ~ 17.7-19 Mbps |
| qam64-throughput | 28 | 64QAM (Qm 6) | ~ 30-36 Mbps |
| scheduler-auto | none | adaptive AMC | climbs to 64QAM under load |

Throughput scaling with modulation order (the ~7 / ~17.7 / ~30 ladder) matches the
theoretical spectral-efficiency progression - the evidence that the forcing is real and
not cosmetic. Measurement note: the validated ladder is measured with the UE as iperf3
client (uplink); the forced MCS caps apply symmetrically and the same scaling shows on that
path. **Honest limit:** `qam256-max` requests 256QAM but the OAI UE (2025.w45) does not
advertise the `pdsch-256QAM-FR1` capability, so the gNB cannot legally schedule Qm 8; it
tops out at 64QAM. This is labelled UE-capability-limited rather than hidden.

### 3.3 Frequency scenarios (two distinct experiments)
- **Real Carrier Retune - REAL.** Genuinely reconfigures the DU's carrier (real RF keys,
  pod restart, UE re-attach on the new carrier). Validated full attach on n41-2600,
  n78-3500, n78-cband-3780.
- **Band KPI Comparison - EMULATED (`tc netem`).** The DU stays on its n78 baseline; per-band
  latency/throughput differences are synthesized with netem because RFsim's channel does not
  change with frequency. After the fix, this measures a clean in-network ping (UPF gateway
  10.45.0.1, ~12 ms) and an emulated, rate-capped uplink, producing a strictly monotonic
  ladder across bands (ping rises and throughput falls as frequency drops) - clearly badged
  EMULATED.

Why emulate at all: in a real network, n28 (700 MHz) reaches farther but carries less than
n78 (3.5 GHz); RFsim's idealized channel cannot reproduce those frequency-dependent tradeoffs,
so the comparison is emulated to *illustrate* them. The frequency change is real; the
performance consequences of that change are emulated.

### 3.4 Network slicing (Phase 3 / Phase 4)
**Admission REAL; per-slice performance EMULATED.** Four slices are defined and the AMF
genuinely admits each requested S-NSSAI:

| Slice | SST | Real admission | Performance differentiation |
|---|---|---|---|
| eMBB | 1 | AMF-granted (real) | n/a (broadband baseline) |
| URLLC | 2 | AMF-granted (real) | low-latency profile **emulated** via `tc tbf` |
| mMTC | 3 | AMF-granted (real) | small-packet IoT profile **emulated** |
| V2X | 4 | AMF-granted (real) | continuity profile **emulated** |

The S-NSSAI grant is read from the AMF log (e.g. `S_NSSAI[SST:2]` for URLLC), so admission is
provably real. The *quality* differences between slices are emulated with tbf because the
RFsim scheduler does not enforce 5QI/GBR resources.

---

## 4. How each "REAL" claim is proven (evidence sources)

| Claim | Evidence |
|---|---|
| User plane is real | UDP receiver logs the UPF pod IP (10.42.0.x) as packet source. |
| Attach / PDU session is real | SMF assigns an IPv4 lease per IMSI (`IPv4[10.45.0.x]`), visible in SMF logs and on the UE's `oaitun_ue1`. |
| Slice admission is real | AMF logs `S_NSSAI[SST:N]` granted per UE SUPI. |
| Modulation forcing is real | DU MAC logs show the modulation order (Qm); throughput scales with it. |
| Carrier retune is real | DU carrier keys (absoluteFrequencySSB / PointA / band) change; UE re-attaches on the new carrier. |
| Data-plane connectivity is real | ICMP through the tunnel to the DN gateway 10.45.0.1 with 0% loss. |

---

## 5. Documented limitations (real, diagnosed, bounded - not weaknesses to hide)

- **CU stability:** the CU softmodem (oai-gnb:2025.w45) segfaults intermittently (exit 139,
  not OOM). Diagnosed and mitigated with a diagnose-first recovery script; not chased upstream.
- **n28-700 FDD:** sync-only in RFsim due to a confirmed OAI RFsim FDD Msg3 PUSCH limitation;
  documented rather than worked around.
- **256QAM:** UE-capability-limited to 64QAM (see section 3.2).

These are honest, evidence-backed boundaries of the simulation environment. Documenting a
limitation you have diagnosed and bounded demonstrates more than a feature that merely worked.

---

*Single source of truth for the real/emulated boundary. Cross-references the per-feature
evidence in the `docs/*-validation.md` set.*
