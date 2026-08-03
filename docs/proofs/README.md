# PCAP Evidence — O-RAN 5G Platform

Packet captures proving end-to-end operation of the frozen platform: Open5GS 5G SA
core + OAI RAN with E1/F1 split (CU-CP + CU-UP + DU0 + DU1), 5 UEs over RFsim.

**These are four independent capture sessions, not one synchronised trace.** Timestamps
are not correlated across files; each documents one interface in isolation.

Total size: ~24 KB. Open with Wireshark or `tshark -r <file>`.

## Address map

| Node | Interface | Address |
|---|---|---|
| AMF | N2 (NGAP) | `10.10.0.101:38412` |
| CU-CP | N2 / F1-C / E1 | `10.10.0.120` |
| CU-UP | E1 | `10.10.0.140` |
| CU-UP | N3 (GTP-U) | `10.20.0.120` |
| DU0 | F1-C | `10.10.0.121` |
| DU1 | F1-C | `10.10.0.132` |
| UPF | N3 (GTP-U) | `10.20.0.101:2152` |
| UE subnet | — | `10.45.0.0/16` |

PLMN **999/70** (`99f907` on the wire), DNN `oai`.

---

## 01 — E1 interface establishment

**File:** `01-e1ap-cuup-setup.pcap` — 15 frames, 5.9 s, captured 2026-06-25 03:10:49 UTC

CU-UP registering with CU-CP over E1AP. This is the E1 interface coming up — the
CU-CP/CU-UP split that distinguishes an O-RAN CU from a monolithic one.

| Frame | Direction | Message |
|---|---|---|
| 12 | CU-UP `.140` → CU-CP `.120` | `GNB-CU-UP-E1SetupRequest` |
| 14 | CU-CP `.120` → CU-UP `.140` | `GNB-CU-UP-E1SetupResponse` |

**What to point at:** frame 14. A successful outcome means the CU-CP accepted the
CU-UP's supported PLMN list and the E1 association is up.

---

## 02 — F1 setup and full RRC attach

**File:** `02-f1ap-setup-rrc-attach.pcap` — 60 frames, 38.4 s, captured 2026-07-15 23:31:48 UTC

The richest capture in the set. It contains the F1 interface establishment, the
complete RRC attach procedure, **and** the E1 bearer context setup — three
interfaces interleaved in one trace.

| Frame | Direction | Message |
|---|---|---|
| 15 | DU0 `.121` → CU-CP `.120` | `F1SetupRequest` — carries **MIB + SIB1** |
| 17 | CU-CP → DU0 | `F1SetupResponse` |
| 19 / 20 | DU0 ↔ CU-CP | `GNBDUConfigurationUpdate` / `Acknowledge` |
| 22 | DU0 → CU-CP | `InitialULRRCMessageTransfer` — RRC Setup Request |
| 23 | CU-CP → DU0 | `DLRRCMessageTransfer` — RRC Setup |
| 24 | DU0 → CU-CP | `ULRRCMessageTransfer` — RRC Setup Complete + Registration request |
| 25 / 26 | ↔ | Authentication request / response over RRC |
| 29 / 30 | ↔ | Security Mode Command / Complete |
| 31 / 32 | ↔ | UE Capability Enquiry / Information |
| 38 | CU-CP `.120` → CU-UP `.140` | `BearerContextSetupRequest` (E1) |
| 39 | CU-UP → CU-CP | `BearerContextSetupResponse` (E1) |
| 40 | CU-CP → DU0 | `UEContextSetupRequest` (F1) |
| 42 | DU0 → CU-CP | `UEContextSetupResponse` (F1) |

**Two things worth showing a jury.**

*Frame 15 independently confirms the DU0 configuration file.* The `F1SetupRequest`
carries the served-cell information, and it matches `manifests/ran/f1/du0.conf`
field for field:

| On the wire (frame 15) | In `du0.conf` |
|---|---|
| `freqBandIndicatorNR: 78` | `bands = [78]` |
| `nRARFCN: 620040` | `dl_absoluteFrequencyPointA = 620040` |
| `physCellId / nRPCI: 0` | `physCellId = 0` |
| MCC 999 / MNC 70 | PLMN 999/70 |
| `nRCellIdentity: 0x000bc614e0` (decimal 12345678) | — |
| `GNB-DU-ID: 3584` | — |

The capture is not a screenshot of a config file; it is the DU announcing that
config to the CU over a standard 3GPP interface.

*Frames 27/28 versus 29/30 prove security activation.* In the earlier RRC frames the
integrity MAC field reads `MAC=0x00000000` — no integrity protection yet. From frame
29 onward the MAC carries real values (`0x3e774660`, `0x886cd809`, …). That transition
is visible evidence that NAS/RRC security was activated, not merely configured.

Frames 8–9 (`BearerContextReleaseCommand` / `Complete`) are the teardown of a previous
session, captured before the new attach began.

---

## 03 — N2 registration and PDU session establishment

**File:** `03-n2-ngap-registration.pcap` — 51 frames, 76.8 s, captured 2026-07-15 23:27:23 UTC

NGAP between CU-CP and AMF: the full 5G registration and PDU session establishment.

| Frame | Direction | Message |
|---|---|---|
| 11 / 13 | AMF ↔ CU-CP | `UEContextReleaseCommand` / `Complete` (prior session teardown) |
| 17 | CU-CP `.120` → AMF `.101` | `InitialUEMessage` — NAS Registration request |
| 18 | AMF → CU-CP | `DownlinkNASTransport` — Authentication request |
| 19 | CU-CP → AMF | `UplinkNASTransport` — Authentication response |
| 20 | AMF → CU-CP | `DownlinkNASTransport` — Security mode command |
| 22 | AMF → CU-CP | `InitialContextSetupRequest` |
| 23 | CU-CP → AMF | `UERadioCapabilityInfoIndication` |
| 24 | CU-CP → AMF | `InitialContextSetupResponse` |
| 30 | AMF → CU-CP | `PDUSessionResourceSetupRequest` |
| 32 | CU-CP → AMF | `PDUSessionResourceSetupResponse` |

**What to point at:** frames 17 → 32. That span is a complete 5G SA registration —
identity, authentication, security, context setup, PDU session — with every message a
real 3GPP NGAP PDU. Nothing here is emulated; RFsim replaces only the physical radio.

---

## 04 — N3 user plane

**File:** `04-n3-gtpu-userplane.pcap` — 41 frames, 19.1 s, captured 2026-07-15 23:30:01 UTC

GTP-U between CU-UP and UPF, carrying real UE traffic to the public internet.

| TEID | Direction | Payload |
|---|---|---|
| `0x0000eba4` | CU-UP `10.20.0.120` → UPF `10.20.0.101` | 20 × G-PDU: inner `10.45.0.7 → 8.8.8.8`, ICMP echo request |
| `0x9c98d5a3` | UPF → CU-UP | 20 × G-PDU: inner `8.8.8.8 → 10.45.0.7`, ICMP echo reply |

All 41 frames are GTP-U message type `0xff` (G-PDU) — user data, not signalling.

**What to point at:** any uplink frame, expanded to show the encapsulation. Wireshark
displays the outer GTP-U header and the inner IP packet together: a UE-sourced
`10.45.0.7` datagram tunnelled inside GTP-U, addressed to `8.8.8.8`. Matching reply
TEIDs in both directions prove a bidirectional tunnel, and the ICMP echo pairs are the
same reachability that `scripts/validate-e2e.sh` reports as
`VERDICT=E2E_UE1_VALIDATION_OK`.

---

## Reproducing these captures

The bridges are Multus Linux bridges on the host, so captures are taken from the host,
not inside pods:

```bash
sudo tcpdump -i br-n2 -w n2-ngap.pcap        # N2 (NGAP/SCTP)
sudo tcpdump -i br-n3 -w n3-gtpu.pcap        # N3 (GTP-U/UDP 2152)
```

F1-C and E1 run on the pod network (`10.10.0.0/24` via the N2 bridge), so the same
`br-n2` capture picks up F1AP (SCTP 38472) and E1AP (SCTP 38462) alongside NGAP.
Filter after the fact:

```bash
tshark -r capture.pcap -Y "ngap"    # or f1ap, e1ap
```

## Excluded captures

Two earlier captures were deliberately left out of this evidence set: they were taken
on **1 May 2026**, before the E1/F1 split, when the RAN was a monolithic gNB at
`10.10.0.111` / `10.20.0.111`. Those addresses appear in **no manifest of the current
platform**. They are valid captures of an earlier architecture, and presenting them as
evidence of the frozen platform would be inaccurate.
