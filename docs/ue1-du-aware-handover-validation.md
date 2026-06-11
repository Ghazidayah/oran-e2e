# UE DU-Aware Handover Validation

Refreshed: 2026-06-11 (supersedes 2026-05-30 version; design unchanged, evidence re-validated)

## Design (unchanged, re-proven today)

DU switching and slice switching are independent by construction:

```text
DU switch    (scripts/handover/switch-ue-du-target.sh <ue1..5> <du0|du1>):
  changes ONLY rfsimulator serveraddr (ConfigMap + deployment args, rule 10)
  takes a backup, restarts the UE deployment, asserts reattach

Slice switch (scripts/slicing/switch-ue-slice.sh, v2, UE1 only):
  changes ONLY dnn/nssai_sst/nssai_sd (legacy keys — pdu_sessions is ignored
  by the 2025.w45 nr-ue) PLUS the MongoDB default_indicator (v2 addition);
  preserves serveraddr; success = AMF-granted S_NSSAI
```

All five UEs (ue1-ue5) are DU-switchable; ue1 is the reference UE with
baseline home DU0. `scripts/handover/recover-mixed-du-state.sh` restores
ue1 to DU0.

## What changed since 2026-05-30

- Slice switching is now v2: flips the Mongo default together with the UE
  config and asserts the AMF grant (docs/slicing-real-snssai-validation.md).
- UE2-UE5 configs converted to legacy nssai keys, all-SST1-at-rest policy
  (docs/ue-slice-alignment-validation.md, tag ue-slice-alignment-validated-20260611).
- Known risk: the CU segfaults intermittently (CLAUDE.md "Known risks");
  recovery = scripts/recover-ue-sessions.sh --fix (diagnose-first).

## Re-validation evidence (2026-06-11, UE1 round trip DU0 -> DU1 -> DU0)

| Stage | Result |
|---|---|
| Baseline | ue1 on DU0, serveraddr=oai-du0-rfsim |
| Switch to DU1 | VERDICT=UE_DU_SWITCH_OK, tunnel 10.45.0.73/24 |
| On DU1 | recover-ue-sessions: HEALTHY; serveraddr=oai-du1-rfsim; nssai_sst=1 / nssai_sd=0xffffff UNTOUCHED |
| Switch back to DU0 | VERDICT=UE_DU_SWITCH_OK, tunnel 10.45.0.74/24 |
| Final | ALL 5 UEs HEALTHY (IPs match SMF, DN-gw ping 0% loss); serveraddr=oai-du0-rfsim |
| AMF grants | S_NSSAI[SST:1 SD:0xffffff] to imsi-...001 at 08:59:45 (DU1 attach) and 09:00:28 (DU0 return) |

The round trip ran after the slice-v2 work and the UE2-5 legacy-key
conversion, proving DU switching is unaffected by both. UE2-UE5 remained
attached and undisturbed throughout.
