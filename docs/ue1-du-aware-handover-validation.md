# UE1 DU-Aware Handover Validation

Date: 2026-05-30

## Goal

Allow `ue1` to switch between DU0 and DU1 without breaking Phase 3, Phase 4, or End-to-End validation.

## Final design

DU switching and slice switching are separated:

```text
DU switch:
  changes only RFsim serveraddr

Slice switch:
  changes only nssai_sst / nssai_sd
  preserves serveraddr
```

## Final dashboard behavior

```text
allowed_ues:
  ue1
  ue2
  ue3
  ue4
  ue5

blocked_ues:
  none
```

`ue1` remains the Phase 3 / Phase 4 reference UE, but it is no longer blocked from DU switching.

## Final validation

```text
Switch ue1 -> DU1:
  VERDICT=UE_DU_SWITCH_OK

After DU1 switch:
  serveraddr=oai-du1-rfsim
  slice=nssai_sst=1 nssai_sd=0xffffff

Phase 3 validation on DU1:
  VERDICT=PROTECTED_UE1_CURRENT_SLICE_VALIDATED

E2E validation on DU1:
  VERDICT=E2E_UE1_VALIDATION_OK

Phase 4 profile on DU1:
  VERDICT=UE1_RESOURCE_PROFILE_APPLIED
  VERDICT=UE1_RESOURCE_PROFILE_CLEARED

Real traffic on DU1:
  image_download verdict=OK

Restore ue1 -> DU0:
  VERDICT=UE_DU_SWITCH_OK

Final result:
  VERDICT=UE1_DU1_PHASE3_PHASE4_SAFE_OK
```

## Final architecture

```text
ue1:
  Phase 3 / Phase 4 / E2E reference UE
  DU switchable: DU0 <-> DU1
  slice-safe: yes

ue2-ue5:
  Multi-UE continuity UEs
  DU switchable: DU0 <-> DU1
```
