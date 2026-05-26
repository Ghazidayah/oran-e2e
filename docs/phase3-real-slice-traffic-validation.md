# Phase 3 — Real Slice Traffic Validation

## Objective

Validate realistic application traffic on top of real S-NSSAI slice selection.

This phase connects the real slice switching mechanism with the realistic traffic scenarios created in Phase 2.

## Slice-to-service mapping

| Slice | SST | Service profile | Traffic scenario |
|---|---:|---|---|
| eMBB | 1 | High throughput broadband | Image, video, web, streaming, iperf TCP |
| URLLC | 2 | Low-latency / jitter-sensitive traffic | Custom UDP jitter/loss |
| mMTC | 3 | IoT-style periodic small messages | Small UDP packets |
| V2X | 4 | Mobility / continuity-oriented traffic | Streaming-like HLS + UDP |

## Validation result

| Slice | SST | Validation result |
|---|---:|---|
| eMBB | 1 | OK |
| URLLC | 2 | OK |
| mMTC | 3 | OK |
| V2X | 4 | OK |

## Evidence directories

URLLC:

~/oran-proof/phase3-real-slice-traffic/20260526-023527

mMTC:

~/oran-proof/phase3-real-slice-traffic/20260526-023743

V2X:

~/oran-proof/phase3-real-slice-traffic/20260526-023825

eMBB:

~/oran-proof/phase3-real-slice-traffic/20260526-023932

Batch run:

~/oran-proof/phase3-real-slice-traffic-batch/20260526-023743

## Key results

### URLLC SST=2

- UE switched to SST=2
- oaitun_ue1 created
- Internet ping through tunnel worked
- UDP packets received: 1000/1000
- Packet loss: 0.0%
- Estimated jitter: about 3.55 ms
- Verdict: OK

### mMTC SST=3

- UE switched to SST=3
- oaitun_ue1 created
- Internet ping through tunnel worked
- UDP packets received: 300/300
- Packet loss: 0.0%
- Estimated jitter: about 1.22 ms
- Verdict: OK

### V2X SST=4

- UE switched to SST=4
- oaitun_ue1 created
- Internet ping through tunnel worked
- Streaming-like HLS segments: 8/8 OK
- Streaming throughput: about 32.82 Mbps
- UDP packets received: 1000/1000
- Packet loss: 0.0%
- Estimated jitter: about 3.42 ms
- Verdict: OK

### eMBB SST=1

- UE switched to SST=1
- oaitun_ue1 created
- Internet ping through tunnel worked
- Image download: OK
- Video download: OK
- Web browsing: OK
- Streaming-like HLS: OK
- iperf TCP: OK
- Verdict: OK

## Important note

All slices currently share:

- DNN=oai
- SD=0xffffff
- same UPF/data-network path

The validated improvement is real S-NSSAI slice selection and real traffic execution per selected SST. Future work can extend this to separate DNNs, separate IP pools, per-slice QoS, or dedicated UPF paths.

## Final state

After validation, the UE was restored to default:

- DNN=oai
- SST=1
- SD=0xffffff
- oaitun_ue1 active
