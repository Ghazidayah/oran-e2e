# Network Topology

## Overview

Single-node k3s cluster on `oran-lab` (Ubuntu 22.04). All pods run on localhost.
Multus CNI provides secondary NICs for N2 and N3 traffic via Linux bridges.

## Logical diagram

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
                                    Data Network (10.45.0.0/16 configured;
                                    UE tunnels receive /24 addresses)
                                    DN gateway: 10.45.0.1
```

Namespaces:
- `oran-ran` — CU-CP, CU-UP, DU0, DU1, UE1–UE5
- `oran-core` — AMF, SMF, UPF, NRF, SCP, AUSF, NSSF, MongoDB

## Bridge subnets (Multus)

| Interface | Bridge | Subnet | Range | Gateway | Usage |
|---|---|---|---|---|---|
| N2 | `br-n2` | `10.10.0.0/24` | `.100–.200` | `10.10.0.1` | NGAP (AMF↔CU-CP) + F1 (DU↔CU) |
| N3 | `br-n3` | `10.20.0.0/24` | `.100–.200` | `10.20.0.1` | GTP-U (UPF↔CU-UP) |

## Fixed IPs

| Component | IP | Port | Protocol |
|---|---|---|---|
| AMF (NGAP) | `10.10.0.101` | 38412 | SCTP (N2) |
| AMF (SBI) | `10.10.0.101` | 7777 | HTTP/2 |
| UPF (GTP-U) | `10.20.0.101` | 2152 | UDP (N3) |
| CU-CP (F1-C + NGAP src) | `10.10.0.120` | 2152 / 38462 | SCTP |
| CU-CP E1 | `10.10.0.120` | 38462 | SCTP |
| DU0 (F1 local) | `10.10.0.121` | 2152 | SCTP |
| DU1 (F1 local) | `10.10.0.132` | 2152 | SCTP |

CU-UP has no fixed Multus IP; it connects outward to CU-CP E1 at `10.10.0.120:38462`.

## UE ↔ DU mapping

- **UE1** (`oai-nr-ue`) — baseline DU0; switchable to DU1 via handover API
- **UE2–UE5** (`oai-nr-ue-2..5`) — DU1 by default

UE→DU mapping is resolved at runtime from each UE's `--rfsimulator.serveraddr` deployment arg
(`oai-du0-rfsim` or `oai-du1-rfsim`). The ConfigMap value is overridden by deployment args
(OPERATING-RULES.md Rule 10). Never assume from the ConfigMap alone.

RFsim service TCP port: **4043** (`oai-du0-rfsim` / `oai-du1-rfsim`).

## UE data tunnels

Each UE gets a GRE/GTP tunnel interface inside its pod:

| UE | Interface | Subnet |
|---|---|---|
| UE1 | `oaitun_ue1` | `10.45.0.x/24` |
| UE2 | `oaitun_ue1` | `10.45.0.x/24` |
| UE3–5 | `oaitun_ue1` | `10.45.0.x/24` |

IP addresses are assigned by SMF/UPF dynamically; they change on each PDU session re-establishment.

## PLMN and identifiers

| Parameter | Value |
|---|---|
| MCC | 999 |
| MNC | 70 |
| DNN | `oai` |
| TAC | 1 |
| gNB_ID | `0xe00` |
| DU0 gNB_DU_ID | `0xe00` |
| DU1 gNB_DU_ID | `0xe01` |
| UE IMSIs | `999700000000001` – `999700000000005` |

## strategy: Recreate on DU deployments

DU0 and DU1 deployments use `strategy: Recreate` because they hold fixed Multus IPs
(`10.10.0.121` and `10.10.0.132`). A rolling update would briefly run two pods competing
for the same IP, causing the new pod to fail with an address conflict.

UE deployments have no fixed Multus IP and can safely use `rollout restart`.

## Monitoring

Kube-prometheus-stack is deployed in namespace `monitoring` (not `oran-monitoring`, which is empty).
Grafana, Prometheus, and Alertmanager run there.
