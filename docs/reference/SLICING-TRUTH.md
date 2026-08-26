# Slicing Truth: What the Platform Actually Does

## Baseline state (out of the box)

AMF, SMF, NSSF, CU-CP, DU0, and DU1 ship with **SST=1 only** in this repository's
manifests. That is no longer what the running platform holds: measured 2026-08-02, the
live AMF advertises SST 1/2/3/4, the SMF declares DNN `oai` for SST 1/2/3/4, the NSSF
carries four NSI entries, and DU0/DU1 list SST 1/2/3/4 (CU-CP still lists 1/2/3). Those
changes live in ConfigMaps and persist across restarts, so a cold start does **not**
revert them.

What still holds is the part that matters: **admission is gated by the subscriber
record, not by these lists.** Allowed NSSAI equals the MongoDB default, which is
SST=1. The platform is therefore at SST=1 at rest regardless of what the core
advertises, and slice diversity is still demonstrated by switching the subscriber
default. See "Slice configuration — install state versus running state" in
`DEPLOYMENT-GUIDE.md`.
The subscriber DB (MongoDB) also has a single slice entry: `sst=1, sd=FFFFFF, default_indicator=true`.

Static audit tools that read the ConfigMaps without running any script will always see SST=1.
**This is correct and by design, not a bug.**

## How multi-slice is activated

The runtime scripts are already committed. No generation step is needed.

| Script | What it does |
|---|---|
| `scripts/slicing/switch-ue-slice.sh <sst> [sd]` | Patches UE1's ConfigMap (`oai-nrue-config`) with the requested `pdu_sessions` SST, then rollout-restarts UE1. Usable SST values: 1, 2, 3 (see note). |
| `scripts/slicing/validate-current-slice.sh` | Checks the live UE config, shows the tunnel IP, and pings 8.8.8.8 through `oaitun_ue1`. |
| `scripts/slicing/apply-slice-resource-profile.sh <profile>` | Applies per-UE QoS shaping on UE1 (see below). |

**Note on the accepted SST range.** `switch-ue-slice.sh` guards its argument with
`case "$SST" in 1|2|3|4)` and rejects anything else as "SST must be 1..4 (subscribed slices)".
That guard is stale: SST=4 was removed from the subscriber baseline (recorded in commit
`bc9158d`, "SST=4 retirée des abonnés" — the subscriber DB is live MongoDB state, not a repo
file). Requesting SST=4 therefore passes the guard but cannot be granted, because Allowed NSSAI
comes from the subscriber's slices. **Only 1, 2 and 3 are actually granted.** The guard and its
message are left as-is: the platform is frozen and no runtime script is being changed.

To activate full multi-slice support on AMF/SMF/NSSF/CU/DU you must run
`scripts/slicing/apply-real-snssai-slicing.sh`, but **that script is blocked by default**:

```
BLOCKED: legacy real S-NSSAI generator is disabled by default.
Reason: it may overwrite DU-aware Phase 3 / Phase 4 / E2E runtime scripts.
```

To run it anyway: `ALLOW_LEGACY_SNSSAI_GENERATOR=1 bash scripts/slicing/apply-real-snssai-slicing.sh`

It will:
1. Backup live ConfigMaps to `~/oran-proof/phase3-real-snssai-apply/<run-id>/backup/`
2. Patch AMF (PLMN 999/70 → SST 1/2/3/4), SMF (info: SST 1/2/3/4 + DNN oai), NSSF (NSI: SST 1/2/3/4)
3. Patch CU-CP, DU0, DU1 `snssaiList` to include SST 1/2/3/4. (SST=4 was later removed from the live subscriber DB baseline in commit bc9158d, but this legacy script still writes it.)
4. Update the subscriber DB so all IMSIs `99970*` have slices 1/2/3/4 with `sd=FFFFFF`
5. Restart AMF, SMF, NSSF, CU-CP, CU-UP, DU0, UE1

Rollback: `scripts/slicing/rollback-real-snssai-slicing.sh`
(Hardcoded to backup run `20260526-021239`; restores to SST=1 only.)

## Per-UE QoS shaping (apply-slice-resource-profile.sh)

Applies `tc tbf` + `netem delay` on `oaitun_ue1` (egress/uplink) and via an `ifb_ue1` redirect
on ingress (downlink). Requires the `ifb` kernel module to be loaded on the host node.

Rate is computed as a **percentage of the auto-measured ceiling** stored in
`~/oran-proof/ceiling-mbit.txt` (fallback: 33 Mbit if file is absent).

| Profile | Rate (% of ceiling) | Burst | netem delay | 3GPP target |
|---|---|---|---|---|
| `embb` | 100% (uncapped) | 256kb | 2ms | eMBB |
| `urllc` | 3% | 64kb | 0ms | URLLC (RFsim floor ~11ms RTT) |
| `mmtc` | 0.1% | 32kb | 1000ms | mMTC |
| `clear` | — | — | — | Remove all shaping |

QoS differentiation is **emulated via software tc**, not 5QI scheduling — RFsim has no radio
priority mechanism. Label results accordingly in demos and reports.

## Important: success is AMF-granted S-NSSAI, not a tunnel

The 2025.w45 nr-ue firmware ignores `pdu_sessions` in the ConfigMap and sends no Requested NSSAI.
Allowed NSSAI equals the subscriber MongoDB default only. A tunnel forming on SST=1 **does not
prove** that a slice switch worked. Success criterion is the AMF log line:

```
[AMF] Allowed NSSAI[SST:X]
```

Use `scripts/slicing/validate-current-slice.sh` to confirm end-to-end connectivity after any
slice switch.
