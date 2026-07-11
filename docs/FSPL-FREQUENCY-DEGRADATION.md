# FSPL-Based Frequency Degradation Model

## Why this exists

OAI RFsim is a pure software radio that ignores carrier frequency for path-loss calculations.
A UE retuned from n41 (2.6 GHz) to n77 (4.2 GHz) would show identical throughput in simulation,
which is physically wrong. This model emulates the expected throughput reduction using FSPL theory.

## The math

Free Space Path Loss at distance d:

```
PL = 20·log10(d) + 20·log10(f) + 20·log10(4π/c)
```

At fixed distance (same UE, same cell geometry) the distance terms cancel:

```
ΔPL = 20·log10(f_target / f_ref)   [dB]
```

The relative throughput coefficient K (linear ratio):

```
K = 10^(−ΔPL / 10)
```

Scripts: `scripts/frequency/compute-fspl-k.sh` (standalone calculator),
`scripts/frequency/apply-fspl-band-profile.sh` (applies as tc tbf cap).

## Reference carrier

The reference frequency is the **n41 SSB carrier: f_ref = 2593.35 MHz**.
All degradation values are relative to n41.

## Band coefficients

| Band | Carrier (MHz) | ΔPL (dB) | K | Cap (% of ceiling) |
|---|---|---|---|---|
| n41 | 2593.35 | 0.00 | 1.00 | 100% |
| n78 | 3499.68 | ≈ 2.61 | ≈ 0.55 | ≈ 55% |
| n77 | 4173.60 | ≈ 4.14 | ≈ 0.39 | ≈ 39% |

PCT is rounded to the nearest integer by the script (`awk` `+0.5` truncation).
Exact values are recomputed at runtime from the actual target frequency.

## Ceiling measurement

The raw throughput ceiling is measured by `scripts/traffic/measure-ceiling.sh` (UE1 isolated,
uncapped TCP upload) and stored in `~/oran-proof/ceiling-mbit.txt`.

Fallback if the file is absent: **33 Mbit**.

The `apply-fspl-band-profile.sh` script reads this file at runtime:

```bash
CEILING_MBIT="${CEILING_MBIT:-$(cat $HOME/oran-proof/ceiling-mbit.txt 2>/dev/null || echo 33)}"
RATE="$(awk "BEGIN{printf \"%dmbit\", $PCT*$CEILING_MBIT/100}")"
```

## n78 carrier ambiguity

There are two n78 configurations in this repo:

| Name | SSB NR-ARFCN | Carrier frequency |
|---|---|---|
| `n78-current` (running) | 621312 | 3319.68 MHz |
| `n78-3500` (retune target) | 633312 | 3499.68 MHz |

`apply-fspl-band-profile.sh` maps `n78` → **3499.68 MHz**.
The DUs and UE1 are currently running at 3319.68 MHz (`n78-current`).
If you need the FSPL cap to match the running carrier, pass the exact MHz value:

```bash
bash scripts/frequency/apply-fspl-band-profile.sh 3319.68
```

## How the cap is applied

`apply-fspl-band-profile.sh` uses the same `netem + tbf + ifb` mechanism as
`scripts/slicing/apply-slice-resource-profile.sh`:

```
oaitun_ue1 egress:  netem delay → tbf rate=$RATE
oaitun_ue1 ingress: mirred redirect → ifb_ue1 → netem delay → tbf rate=$RATE
```

Both uplink and downlink are capped symmetrically at the FSPL-derived rate.
The ifb kernel module must be loaded: `sudo modprobe ifb`.

`platform-start.sh` warns if the module is absent (via `check_ifb_module()`).

## Opt-in: FSPL_CAP=1

The cap is **not applied automatically** during a frequency retune.
It is an opt-in feature gated by the environment variable `FSPL_CAP=1`.

When set, `switch-ue-actual-frequency-retune-du-aware.sh` applies the cap after a successful
retune using the target carrier frequency (`TARGET_C_HZ`, converted to MHz):

```bash
if [ "${FSPL_CAP:-0}" = "1" ] && [ -n "${TARGET_C_HZ:-}" ]; then
  F_MHZ="$(awk "BEGIN{printf \"%.2f\", ${TARGET_C_HZ}/1000000}")"
  bash scripts/frequency/apply-fspl-band-profile.sh "$F_MHZ"
fi
```

Example:

```bash
FSPL_CAP=1 bash scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh n77-4174
```

## Clearing the cap

```bash
bash scripts/frequency/apply-fspl-band-profile.sh clear
# or
bash scripts/slicing/apply-slice-resource-profile.sh clear
```

Both clear `oaitun_ue1 root`, `oaitun_ue1 ingress`, and delete `ifb_ue1`.

## Relationship to slice QoS

FSPL cap and slice resource profiles use the same tc infrastructure on `oaitun_ue1`.
Applying one overwrites the other. Only one can be active at a time.
If you need both, you would need to compose the rates manually (not currently supported).
