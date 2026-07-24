# Frequency Scenarios Validation — O-RAN E2E Testbed

Date: 2026-06-09
Branch: `allow-ue1-du-switch-all-scenarios`

---

## 1. Introduction and RFsim Caveat

This document covers two distinct things and it is important not to conflate them.

**What this validates:**
- Correct carrier bring-up per NR band and raster point (cell boots, SIB1 broadcasts, UE attaches, data tunnel forms).
- TDD vs FDD structural behavior on OAI RFsim.
- Emulated per-band impairment KPIs via `tc netem` on `oaitun_ue1`.

**What this does NOT validate:**
RFsim uses a perfect AWGN channel model (`modelname = "AWGN"` in all DU configs). MCS stays
pinned at 0 / Qm 2 regardless of carrier frequency or any RFsim path-loss metadata, as proven
by empirical observation across all radio-profile experiments (see
`docs/radio-profile-netem-final-validation-20260602.md`). **Carrier frequency does NOT change
radio performance in RFsim.** The bring-up KPIs prove correct cell configuration per band/raster
and TDD-vs-FDD waveform behaviour, not frequency-dependent radio performance.

The emulated impairment KPIs in §5 use `tc netem` parameters chosen to *represent* typical
band trade-offs. They are labelled **EMULATED** throughout; the differences come from the
emulation profile, not from RFsim physics.

---

## 2. Frequency Profile Matrix

Values quoted directly from source files. Two mechanisms are used:

- **key-patch** — `switch-ue-actual-frequency-retune-du-aware.sh` patches individual keys
  (`absoluteFrequencySSB`, `dl_absoluteFrequencyPointA`, `dl_frequencyBand`,
  `dl_carrierBandwidth`, `ul_frequencyBand`, `ul_carrierBandwidth`) inside the live DU ConfigMap
  via inline Python, then patches UE deployment args (`-C`, `--band`, `--ssb`).
- **full-conf-swap** — `validate-n28-700-on-du0.sh` replaces the entire `gnb.conf` in the DU0
  ConfigMap with `manifests/ran/f1/gnb-du0.n28-700.fdd.conf`. Required for n28 because FDD
  eliminates the `tdd-UL-DL-ConfigurationCommon` block and changes subcarrierSpacing from 1→0
  (30 kHz → 15 kHz); key-patching cannot add or remove config blocks.

### 2.1 Profile values from `switch-ue-actual-frequency-retune-du-aware.sh` `profile_values()`

| Profile | TARGET_BAND | TARGET_SSB | TARGET_POINTA | TARGET_BW | TARGET_C_HZ | TARGET_UE_BAND | TARGET_SSB_ARG |
|---|---|---|---|---|---|---|---|
| `n78-current` / `restore` | 78 | 621312 | 620040 | 106 | 3319680000 | 78 | 516 |
| `n78-raster-high` | 78 | 621408 | 620136 | 106 | 3321120000 | 78 | 516 |
| `n78-3500` | 78 | 633312 | 632040 | 106 | 3499680000 | 78 | 516 |
| `n78-cband-3780` | 78 | 651936 | 650664 | 106 | 3779040000 | 78 | 516 |
| `n41-2600` | 41 | 518670 | 514854 | 106 | 2593350000 | 41 | 516 |

Note: `TARGET_SSB_ARG` (the UE `--ssb` command-line argument) is 516 for every TDD profile.
This is the half-BW offset into the 106-PRB carrier, not the SSB ARFCN.

### 2.2 n28 700 MHz values from `manifests/ran/f1/gnb-du0.n28-700.fdd.conf`

```
absoluteFrequencySSB          = 156250      # 156250 × 5 kHz = 781.25 MHz
dl_frequencyBand              = 28
dl_absoluteFrequencyPointA    = 154342
dl_subcarrierSpacing          = 0           # 15 kHz
dl_carrierBandwidth           = 106         # 20 MHz
ul_frequencyBand              = 28
ul_absoluteFrequencyPointA    = 143342      # DL − 55 MHz (n28 FDD duplex gap)
ul_subcarrierSpacing          = 0           # 15 kHz
ul_carrierBandwidth           = 106
# No tdd-UL-DL-ConfigurationCommon block (FDD)
prach_ConfigurationIndex      = 16          # long preamble, FDD/paired-spectrum table
dmrs_TypeA_Position           = 0           # pos2
prach_RootSequenceIndex_PR    = 1           # 839-symbol root sequence
prach_RootSequenceIndex       = 1
```

UE args (`validate-n28-700-on-du0.sh`):
```
-C 781250000  --band 28  --numerology 0  --ssb 516  -r 106
```

### 2.3 Full scenario matrix

| Profile | Script | Band | Duplex / SCS | DL center MHz | SSB ARFCN | DL PointA ARFCN | UL PointA ARFCN | BW PRB | Expected result |
|---|---|---|---|---|---|---|---|---|---|
| `n78-current` | key-patch | n78 | TDD / 30 kHz | 3319.68 | 621312 | 620040 | same | 106 | Full attach + ping |
| `n78-raster-high` | key-patch | n78 | TDD / 30 kHz | 3321.12 | 621408 | 620136 | same | 106 | Full attach + ping |
| `n78-3500` | key-patch | n78 | TDD / 30 kHz | 3499.68 | 633312 | 632040 | same | 106 | Full attach + ping |
| `n78-cband-3780` | key-patch | n78 | TDD / 30 kHz | 3779.04 | 651936 | 650664 | same | 106 | Full attach + ping |
| `n41-2600` | key-patch | n41 | TDD / 30 kHz | 2593.35 | 518670 | 514854 | same | 106 | Full attach + ping |
| `n28-700` | full-conf-swap | n28 | **FDD / 15 kHz** | 781.25 | **156250** | 154342 | **143342** | 106 | **SYNC-ONLY** (Msg3 blocked) |

---

## 3. Bring-up KPI Definitions

The exact command sequence that proves each KPI step.

### 3.1 Cell bring-up (DU boots, no assert, SIB1 ready)

```bash
kubectl -n oran-ran logs deploy/oai-du0 --tail=300 \
  | egrep -i 'Assert|Exiting|gNB_DU_Served|SIB1|CORESET|served cell|F1 Setup|band|FDD|TDD'
```

Look for: `gNB_DU_Served_Cells` or `F1 Setup Response` = cell registered. Absence of `Assert`
or `Exiting` = clean boot.

### 3.2 UE SSB/MIB/SIB1 decode

```bash
UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n oran-ran logs "$UE_POD" --tail=500 \
  | egrep -i 'synch|SIB1|MIB|ssb_subcarrier'
```

Look for: `PBCH` / `MIB decoded` / `SIB1 decoded` (exact wording varies by OAI version).

### 3.3 RACH Msg1 / Msg2 / Msg3

```bash
kubectl -n oran-ran logs deploy/oai-du0 --tail=500 \
  | egrep -i 'preamble|RA-RNTI|Msg3|RAR|contention'
```

- Msg1: `preamble detected` or `PRACH preamble` in DU log
- Msg2: `RAR` or `RA-RNTI` in DU log (Random Access Response sent)
- Msg3: `Msg3 CRC` / `tb_crc_status` — `0` = pass, `1` = fail

### 3.4 RRC Setup → Registration Complete

```bash
kubectl -n oran-ran logs "$UE_POD" --tail=1000 \
  | egrep -i 'RRC Setup|RRCSetupComplete|Registration Accept|RegistrationComplete|PDU Session'
```

Sequence: `RRC Setup Request` → `RRC Setup` → `RRCSetupComplete` → `Registration Accept` →
`RegistrationComplete` → `PduSessionEstablishRequest` → `PDU Session Establishment Accept`.

### 3.5 PDU session and tunnel

```bash
kubectl -n oran-ran exec "$UE_POD" -- ip -4 addr show oaitun_ue1
```

### 3.6 User-plane ping

```bash
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 4 8.8.8.8
```

### 3.7 DU PHY readout (RFsim-fixed)

```bash
kubectl -n oran-ran logs deploy/oai-du0 --tail=20 \
  | egrep -i 'ulsch_rounds|dlsch_rounds|MCS|SNR|RSRP|BLER'
```

These values are **fixed by RFsim AWGN** regardless of carrier. They confirm the cell is
actively scheduling the UE, not that the channel is frequency-dependent.

---

## 4. Bring-up KPI Table

`✓` = confirmed. `✗` = failed or absent. `—` = not yet run (needs live measurement, see §6).
n28-700 results are from session-report-20260609.md (proven by elimination; do not re-run
without a different OAI build).

| Profile | DU boot (no assert) | SIB1 conf | UE SSB sync | Msg1 | Msg2 (RAR) | Msg3 CRC | RRC Setup→Reg OK | PDU session | oaitun_ue1 | Ping 0% | DU PHY (RFsim) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `n78-current` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | 10.45.0.21/24 | ✓ | MCS 0, Qm 2, SNR 51 dB, RSRP −44 dBm, BLER 0 |
| `n78-raster-high` | — | — | — | — | — | — | — | — | — | — | — |
| `n78-3500` | — | — | — | — | — | — | — | — | — | — | — |
| `n78-cband-3780` | — | — | — | — | — | — | — | — | — | — | — |
| `n41-2600` | — | — | — | — | — | — | — | — | — | — | — |
| `n28-700` | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ CRC fail | ✗ (T300) | ✗ | None | N/A | N/A |

**n78-current baseline** observed live on 2026-06-09: UE pod `oai-nr-ue-6cbbdc556-v5zlb`,
oaitun_ue1 = 10.45.0.21/24, no tc netem active, PDU Session Establishment Accept IPv4
10.45.0.21 seen in UE logs, DU reporting UE RNTI 3272 in-sync RSRP −44 dBm SNR 51 dB.

**n41-2600** noted as `# VALIDATED 2026-06-04` in the retune script's `profile_values()`.
The table entry above marks it as not yet run in this document; populate on next live run.

**n28-700 diagnosis (2026-06-09, by elimination):**
- DU0 booted on n28 FDD with no assert → FDD config structurally valid.
- UE decoded SSB/MIB/SIB1 → SSB ARFCN 156250, PointA 154342, CORESET0, `--ssb 516` all correct.
- RACH Msg1 (preamble detected) and Msg2 (RAR decoded) succeeded.
- Msg3 PUSCH: `tb_crc_status 1` / "Msg3 CRC did not pass" on every attempt; no Initial UL RRC
  sent; UE T300 expired.
- Ruled out: dmrs_TypeA_Position 0↔1, PRACH short-format (idx 98) **and** long-format
  (idx 16, ZCZ 1, RootSeq_PR 1).
- Conclusion: Msg1+Msg2 always succeed, Msg3 never decodes in a perfect AWGN RFsim FDD channel
  regardless of tunable parameters → **OAI RFsim FDD uplink limitation**, not a configuration
  error. Do not retry without a different OAI build or real radio hardware.

---

## 5. Emulated Band Impairment KPIs

Because RFsim produces identical radio behaviour at every carrier frequency, frequency-dependent
performance differences are **emulated** via `tc netem` applied on `oaitun_ue1` inside the UE
pod. This uses the same mechanism as `scripts/radio/switch-ue-radio-profile-du-aware.sh`
(`apply_tc_profile`) — no new mechanism is introduced.

**The differences in the KPI table below come entirely from the netem configuration, not from
RFsim physics. The emulation profiles are chosen to illustrate typical band trade-offs and are
labelled EMULATED throughout.**

### 5.1 Emulation profile definitions

Three profiles represent the three bands present in this testbed. Parameters are representative
of typical macro-cell characteristics; they are not derived from measurement.

| Emulation profile | Represents | delay | jitter | loss | rate cap | tc netem command |
|---|---|---|---|---|---|---|
| `band-700-lowband` | n28 700 MHz FDD | 20 ms | ±3 ms | 0.1% | 15 mbit | `delay 20ms 3ms distribution normal loss 0.1% rate 15mbit` |
| `band-2600-midband` | n41 2600 MHz TDD | 6 ms | ±1 ms | 0.2% | 28 mbit | `delay 6ms 1ms distribution normal loss 0.2% rate 28mbit` |
| `band-3500-cband` | n78 3500 MHz TDD | 2 ms | ±1 ms | 0.5% | 44 mbit | `delay 2ms 1ms distribution normal loss 0.5% rate 44mbit` |

Rationale:
- **700 MHz**: wide-area coverage, deep indoor penetration, limited spectral bandwidth (106 PRB
  × 15 kHz = ~20 MHz). Urban macro round-trip delay 15–25 ms; low loss over coverage area.
- **2600 MHz**: mid-band balance of coverage and bandwidth. Higher path loss than 700 MHz;
  moderate delay; better throughput.
- **3500 MHz / C-band**: highest bandwidth in this testbed; highest susceptibility to blockage
  at cell edge (0.5% loss); lowest propagation latency.

### 5.2 Measured KPI table — EMULATED

All entries marked `[TBD]` require live netem application (no DU/UE restart needed — see §6.2).

| Profile | Ping 20×: min/avg/max/mdev ms | Loss % | iperf3 TCP Mbps | Retransmits |
|---|---|---|---|---|
| no netem (baseline) | [TBD] | 0% | [TBD] | [TBD] |
| `band-700-lowband` (EMULATED) | [TBD] | [TBD] | [TBD] | [TBD] |
| `band-2600-midband` (EMULATED) | [TBD] | [TBD] | [TBD] | [TBD] |
| `band-3500-cband` (EMULATED) | [TBD] | [TBD] | [TBD] | [TBD] |

---

## 6. How to Reproduce

### 6.1 Carrier retune profiles (requires DU + UE pod restart ~3–5 min each)

**SAFETY:** Confirm with operator before each step. The retune script auto-restores to
n78-current on failure; the `restore` profile call is still required after a successful run.

```bash
# Apply a TDD profile
bash scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh n78-3500

# Capture post-retune KPIs (read-only)
UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n oran-ran logs deploy/oai-du0 --tail=300 \
  | egrep -i 'Assert|SIB1|CORESET|gNB_DU_Served|ulsch_rounds|RSRP|MCS|BLER|SNR'
kubectl -n oran-ran logs "$UE_POD" --tail=500 \
  | egrep -i 'synch|SIB1|RRC Setup|Registration|PDU Session'
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 4 8.8.8.8

# Restore baseline BEFORE the next profile or stopping
bash scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh restore
```

**n28-700 (FDD, different script):**

```bash
# Apply
bash scripts/frequency/validate-n28-700-on-du0.sh apply

# Check (sync-only expected — no tunnel)
kubectl -n oran-ran logs deploy/oai-du0 --tail=200 \
  | egrep -i 'band|n28|FDD|SSB|SIB1|preamble|RA-RNTI|Msg3|CORESET'
UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl -n oran-ran logs "$UE_POD" --tail=500 \
  | egrep -i 'synch|SIB1|MIB|T300|Msg3|RACH'

# Restore — MUST use the validate script restore, not the retune script
bash scripts/frequency/validate-n28-700-on-du0.sh restore
```

If `validate-n28-700-on-du0.sh restore` fails (backup corrupted — see OPERATING-RULES.md §5):

```bash
# Safe fallback: restore DU0 from canonical source file
kubectl -n oran-ran create configmap oai-du0-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du0.conf \
  --dry-run=client -o yaml | kubectl -n oran-ran apply -f -
kubectl -n oran-ran rollout restart deploy/oai-du0
kubectl -n oran-ran rollout restart deploy/oai-nr-ue
```

### 6.2 Emulated impairment KPIs (no DU/UE restart — tc netem only)

These can be applied while staying on n78-current. Each run takes about 30 s.

```bash
UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')

# 0. Baseline — no netem
kubectl -n oran-ran exec "$UE_POD" -- sh -lc \
  'tc qdisc del dev oaitun_ue1 root 2>/dev/null; true'
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 20 8.8.8.8
DURATION=20 bash scripts/traffic/run-iperf-tcp.sh

# 1. band-700-lowband (EMULATED n28 700 MHz FDD)
kubectl -n oran-ran exec "$UE_POD" -- sh -lc \
  'tc qdisc del dev oaitun_ue1 root 2>/dev/null; \
   tc qdisc add dev oaitun_ue1 root netem delay 20ms 3ms distribution normal loss 0.1% rate 15mbit'
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 20 8.8.8.8
DURATION=20 bash scripts/traffic/run-iperf-tcp.sh

# 2. band-2600-midband (EMULATED n41 2600 MHz TDD)
kubectl -n oran-ran exec "$UE_POD" -- sh -lc \
  'tc qdisc del dev oaitun_ue1 root 2>/dev/null; \
   tc qdisc add dev oaitun_ue1 root netem delay 6ms 1ms distribution normal loss 0.2% rate 28mbit'
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 20 8.8.8.8
DURATION=20 bash scripts/traffic/run-iperf-tcp.sh

# 3. band-3500-cband (EMULATED n78 3500 MHz TDD)
kubectl -n oran-ran exec "$UE_POD" -- sh -lc \
  'tc qdisc del dev oaitun_ue1 root 2>/dev/null; \
   tc qdisc add dev oaitun_ue1 root netem delay 2ms 1ms distribution normal loss 0.5% rate 44mbit'
kubectl -n oran-ran exec "$UE_POD" -- ping -I oaitun_ue1 -c 20 8.8.8.8
DURATION=20 bash scripts/traffic/run-iperf-tcp.sh

# Clear netem when done
kubectl -n oran-ran exec "$UE_POD" -- sh -lc \
  'tc qdisc del dev oaitun_ue1 root 2>/dev/null; true'
kubectl -n oran-ran exec "$UE_POD" -- tc qdisc show dev oaitun_ue1
```

---

## 7. Limitations and Honest Scope

1. **RFsim is a perfect AWGN channel.** MCS, SNR, BLER, and RSRP do not change with carrier
   frequency. The DU PHY readout in §4 (`MCS 0, SNR 51 dB, RSRP −44 dBm`) is the same value
   that will appear after every successful retune.

2. **The emulated KPIs (§5) are illustrative.** The `tc netem` parameters in §5.1 are chosen
   to represent typical band characteristics in a pedagogically useful way. They are NOT derived
   from measured propagation data or operator network statistics.

3. **n28 700 MHz FDD is sync-only.** Msg3 PUSCH never decodes in OAI RFsim FDD regardless of
   DMRS or PRACH configuration. This is an OAI RFsim FDD uplink limitation proven by elimination
   (see §4). The network configuration itself is correct: DU boots cleanly, SIB1 is broadcast,
   UE synchronises and decodes MIB/SIB1, RACH Msg1 and Msg2 complete successfully.

4. **DU-aware scripts.** The retune script auto-detects UE1's current DU via `serveraddr` in the
   UE ConfigMap. All profiles are validated on DU0 (UE1 home). Override with `DU_DEPLOY=oai-du1`
   if UE1 has been switched to DU1 (unlikely for frequency testing).

5. **`validate-n28-700-on-du0.sh` backup fragility.** On repeated applies the script overwrites
   its own backup in `backups/n28-700-on-du0/`. The safe fallback restore (see §6.1) uses
   `manifests/ran/f1/du0.conf` as the canonical n78 source — do not rely on the backup copy.

---

## 8. Known Issue — Dashboard API n28-700 SSB ARFCN Discrepancy

**File:** `web-dashboard/real_frequency_api.py`, `PROFILES["n28-700"]["ssb"]`

| Source | Value |
|---|---|
| Dashboard API (`real_frequency_api.py` line 55) | `"139236"` |
| Conf file (`gnb-du0.n28-700.fdd.conf`) | `absoluteFrequencySSB = 156250` |
| Session report 2026-06-09 | `SSB ARFCN 156250` |

**156250** is correct: 156250 × 5 kHz = 781.25 MHz (n28 FDD DL centre). 139236 does not
correspond to any parameter in the conf file or the UE args. The dashboard display value is
wrong and should be corrected to `"156250"`.

The UE `--ssb 516` argument (`UE_SSB` in `validate-n28-700-on-du0.sh`) is a separate parameter
(half-BW offset index into the 106-PRB carrier) and is correctly distinct from the SSB ARFCN.
