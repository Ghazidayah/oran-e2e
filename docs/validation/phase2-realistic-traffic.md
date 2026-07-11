# Phase 2 — Realistic Traffic Scenarios

## Objective

Phase 2 extends the O-RAN / Open5GS / OAI RFsim platform beyond ping-only validation by adding realistic traffic scenarios.

## Validated scenarios

| Scenario | Script | Main KPI |
|---|---|---|
| Image download | scripts/traffic/run-image-download.sh | HTTP status, bytes, checksum, throughput |
| TCP throughput | scripts/traffic/run-iperf-tcp.sh | Mbps, retransmissions |
| UDP jitter/loss | scripts/traffic/run-udp-traffic.sh | packet loss, jitter, throughput |
| Video download | scripts/traffic/run-video-download.sh | HTTP status, bytes, checksum, throughput |
| Web browsing | scripts/traffic/run-web-browsing.sh | resources OK, page load time, total bytes |
| Streaming-like HLS | scripts/traffic/run-streaming-like.sh | segment success rate, segment delay, throughput |

## Global runner

All scenarios can be executed with:

scripts/traffic/run-all-realistic-traffic.sh

## Evidence locations

Individual scenario proofs:

~/oran-proof/phase2-realistic-traffic/

Full suite proofs:

~/oran-proof/phase2-realistic-traffic-suite/

## Known limitation

iperf3 UDP was tested but not retained as a stable scenario. Host-local iperf3 UDP works and custom UDP through oaitun_ue1 works, but iperf3 UDP through the current Open5GS/UPF/NAT path fails. The retained URLLC-style scenario is run-udp-traffic.sh.
