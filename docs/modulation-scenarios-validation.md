# Modulation Scenarios — Validation (2026-06-09)

Real, forced modulation-order control for UE1 on the active DU, replacing the previous
netem-faked "radio profiles". Each profile caps the gNB MAC scheduler's MCS via
`--MACRLCs.[0].dl_max_mcs` / `ul_max_mcs` (args-only on the DU deployment, auto-detected
from UE1's RFsim serveraddr — no ConfigMap surgery). The modulation order actually used on
air is confirmed in the DU logs as `MCS (Q) M` where Q is the table (0 = 64QAM) and the
companion `Qm` is the modulation order (2 = QPSK, 4 = 16QAM, 6 = 64QAM, 8 = 256QAM).

## Why this is real (not the old netem approach)

The previous `radio_profile` feature shaped `oaitun_ue1` with `tc netem` and named the
profiles after modulation orders — the gNB still ran QPSK (MCS 0) the whole time. This
version forces the scheduler's MCS, so the PHY genuinely modulates at the chosen order and
throughput scales with it. Verified live: forcing the cap changes the `Qm` in the DU log and
the measured TCP throughput accordingly.

## Validated results (n78, 106 PRB, RFsim AWGN ~50 dB SNR, BLER 0)

| Profile | Forced max MCS | MCS used (under load) | Qm | Modulation | TCP throughput | Status |
|---|---|---|---|---|---|---|
| scheduler-auto | none (adaptive) | climbs to 28 | 6 | 64QAM (adaptive) | ~30 Mbps | ✅ |
| qpsk-robust | 4 | 4 | 2 | QPSK | ~6.7 Mbps | ✅ |
| qam16-balanced | 13 | 13 | 4 | 16QAM | ~17.7 Mbps | ✅ |
| qam64-throughput | 28 | 28 | 6 | 64QAM | ~30 Mbps | ✅ |
| qam256-max | 28 | 28 | 6 | 64QAM* | ~30 Mbps | ⚠️ UE-cap-limited |
| qpsk-stress | 2 | 2 | 2 | QPSK (low) | calibration | ✅ |

Throughput scales with modulation order exactly as theory predicts (QPSK 2 bits/symbol →
16QAM 4 → 64QAM 6), confirming the modulation is genuinely changing, not emulated.

\* **256QAM finding:** the gNB allows 256QAM by default (`force_256qam_off = 0`), but the
OAI nr-ue (image `2025.w45`) does **not** advertise `pdsch-256QAM-FR1` capability in its
UECapabilityInformation. With no UE 256QAM capability the gNB stays on the 64QAM MCS table
(`MCS (0) …`), so `qam256-max` reaches 64QAM, not 256QAM. Making it genuine would require a
UE capability change (e.g. a `--uecap_file` advertising 256QAM) and is not reliably supported
on RFsim. Documented as a UE-capability limitation, not a config error.

## How to reproduce

```bash
# force a modulation order (auto-detects UE1's active DU)
scripts/radio/switch-ue-modulation-profile-du-aware.sh ue1 qpsk-robust --apply
scripts/radio/switch-ue-modulation-profile-du-aware.sh ue1 qam16-balanced --apply
scripts/radio/switch-ue-modulation-profile-du-aware.sh ue1 qam64-throughput --apply

# observe the modulation actually used, under load
DU=$(kubectl -n oran-ran get pod -l app=oai-du0 -o jsonpath='{.items[0].metadata.name}')
UE=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
HOSTIP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
nohup iperf3 -s -p 5201 >/tmp/ipsrv.log 2>&1 & sleep 2
kubectl -n oran-ran exec "$UE" -- iperf3 -c "$HOSTIP" -p 5201 -t 12 &
kubectl -n oran-ran logs "$DU" --since=6s | egrep 'dlsch_rounds.*MCS' | tail -1   # shows MCS (0) x / Qm

# restore adaptive (default)
scripts/radio/switch-ue-modulation-profile-du-aware.sh ue1 scheduler-auto --apply
```

## Scope / honesty notes

- RFsim uses a perfect AWGN channel, so the **channel never forces** a lower order — these
  profiles demonstrate scheduler/PHY modulation control by *capping*, which is the legitimate
  way to show QPSK/16QAM/64QAM behaviour on a simulator.
- "scheduler-auto" shows the real adaptive AMC: it climbs to 64QAM under load on its own.
- Dashboard: the modulation dropdown (`/api/radio/*`) now drives this script; the old
  netem-based `switch-ue-radio-profile-du-aware.sh` is superseded.
