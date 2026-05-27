# Phase 4 — Per-slice QoS and Resource Profiles

## Objective

Move beyond only changing S-NSSAI/SST by adding different QoS and resource behavior per slice.

This phase adds:

1. Control-plane QoS profiles in the Open5GS subscriber database.
2. Data-plane resource profiles on the UE tunnel `oaitun_ue1` using Linux `tc`.
3. Validation with real traffic per slice.

## Slice profiles

| Slice | SST | Control-plane profile | Data-plane resource profile | Traffic |
|---|---:|---|---|---|
| eMBB | 1 | high AMBR, 5QI/index 9, ARP 8 | 100Mbit, burst 256Kb, latency 50ms | image, video, web, streaming, iperf TCP |
| URLLC | 2 | 100 Mbps AMBR, 5QI/index 80, ARP 1 | 10Mbit, burst 32Kb, latency 10ms | UDP jitter/loss |
| mMTC | 3 | 1 Mbps AMBR, 5QI/index 9, ARP 15 | 256Kbit, burst 16Kb, latency 100ms | small UDP IoT-style packets |
| V2X | 4 | 50 Mbps AMBR, 5QI/index 79, ARP 2 | 15Mbit, burst 64Kb, latency 30ms | streaming-like HLS + UDP |

## Components modified

- Open5GS subscriber database
- Open5GS AMF / SMF / PCF restarted after QoS update
- OAI NR-UE slice switching script
- Real slice traffic runner
- Per-slice resource profile script using `tc`
- Rollback script for returning to the Phase 3 shared-QoS profile

## Validation results

| Slice | SST | Validation result |
|---|---:|---|
| eMBB | 1 | OK |
| URLLC | 2 | OK |
| mMTC | 3 | OK |
| V2X | 4 | OK |

## Evidence directories

QoS profile application:

~/oran-proof/phase4-qos-resource-profiles/20260527-012346

URLLC validation:

~/oran-proof/phase4-qos-resource-validation/20260527-020520

Batch validation:

~/oran-proof/phase4-qos-resource-validation-batch/20260527-020944

## Key proof

### URLLC

- UE switched to SST=2
- `oaitun_ue1` created
- `tc` TBF applied: rate 10Mbit, burst 32Kb, latency 10ms
- UDP packets received: 1000/1000
- Packet loss: 0.0%
- Verdict: OK

### mMTC

- UE switched to SST=3
- `oaitun_ue1` created
- `tc` TBF applied: rate 256Kbit, burst 16Kb, latency 100ms
- UDP packets received: 300/300
- Packet loss: 0.0%
- Verdict: OK

### V2X

- UE switched to SST=4
- `oaitun_ue1` created
- `tc` TBF applied: rate 15Mbit, burst 64Kb, latency 30ms
- Streaming-like HLS segments OK
- UDP packets received: 1000/1000
- Packet loss: 0.0%
- Verdict: OK

### eMBB

- UE switched to SST=1
- `oaitun_ue1` created
- `tc` TBF applied: rate 100Mbit, burst 256Kb, latency 50ms
- Image download OK
- Video download OK
- Web browsing OK
- Streaming-like HLS OK
- iperf TCP OK
- Verdict: OK

## Final verdict

VERDICT=ALL_PHASE4_RESOURCE_PROFILES_OK

## Important note

All slices still use the same DNN `oai`, SD `0xffffff`, and the same UPF/data-network path.  
However, Phase 4 now adds real differentiated behavior using:

- per-slice subscriber QoS/AMBR/ARP profiles
- per-slice tunnel resource profiles
- validated realistic traffic per slice

A future improvement can add separate DNNs, separate IP pools, or dedicated UPF paths.
