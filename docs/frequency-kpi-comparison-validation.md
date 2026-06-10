# Frequency Band KPI Comparison — Measurement Fix Validation (2026-06-10)

Branch: `allow-ue1-du-switch-all-scenarios`

This fixes the **measurement** behind the dashboard's "Frequency Band KPI Comparison"
table. It does **not** touch the real carrier retune (PROFILES + switch-ue-frequency-profile-du-aware.sh),
which remains validated separately (see docs/frequency-scenarios-validation.md).

## What was wrong
1. Ping targeted 8.8.8.8 — internet base RTT (~60-90 ms) swamped emulated deltas (2-25 ms);
   all bands reported ~70-96 ms.
2. Rate caps (28-44 Mbit) sat above real RFsim UL capacity so netem rate never bound;
   throughput was raw uncapped UL + variance, giving non-monotonic ordering.

## Baseline evidence (uncapped, 2026-06-10, UE1 oaitun_ue1)
- Local ping to UPF gw 10.45.0.1: rtt min/avg/max/mdev = 8.67/11.60/15.75/1.65 ms (20 pkts, 0% loss)
- Uncapped UL TCP (iperf3 UE->host, 3 runs): 17.54 / 17.08 / 17.18 Mbps

## The fix
Ping target -> 10.45.0.1; BAND_NETEM caps retuned below ~17 Mbps UL floor so caps bind,
delay deltas >= 3x base mdev so ordering is jitter-stable.

| Profile | Old netem | New netem |
|---|---|---|
| n78-3500 | 2ms / 0.5% / 44mbit | 2ms / 0% / 12mbit |
| n78-cband-3780 | 2ms / 0.8% / 40mbit | 3ms / 0.1% / 10mbit |
| n41-2600 | 6ms / 0.2% / 28mbit | 8ms / 0.1% / 7mbit |
| n28-700 | 20ms / 0.1% / 15mbit | 25ms / 0.3% / 3mbit |

## Validated results (2026-06-10, Run All Bands)
| Profile | Actual ping | Actual UL TCP | Retrans |
|---|---|---|---|
| n78-3500 | 12.37 ms | 11.50 Mbps | 0 |
| n78-cband-3780 | 14.68 ms | 9.61 Mbps | 12 |
| n41-2600 | 20.46 ms | 6.73 Mbps | 3 |
| n28-700 | 35.24 ms | 2.88 Mbps | 8 |

Both columns strictly monotonic.

## Honesty caveats (unchanged)
- KPIs are EMULATED via tc netem, not RFsim PHY (AWGN channel does not vary with carrier).
- Throughput is UPLINK (UE = iperf3 client; netem root qdisc shapes UE egress only).
  Column labelled "UL TCP Mbps" so ~11.5 Mbps is not mistaken for DL capability
  (DL reaches ~30 Mbps under forced 64QAM — see docs/modulation-scenarios-validation.md).
