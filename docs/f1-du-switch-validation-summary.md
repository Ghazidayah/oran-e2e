# F1 DU Switch Validation Summary

## Objective

Validate the new OAI F1 split architecture with:

- one CU
- DU0
- DU1
- one NR-UE
- Open5GS core
- DNN=oai
- UE tunnel connectivity through oaitun_ue1

## Validated steps

### 1. CU + DU0 + UE1

Result:

- CU running
- DU0 running
- UE1 attached
- oaitun_ue1 active
- ping 10.45.0.1 OK
- ping 8.8.8.8 OK

### 2. CU + DU1 + UE1

Result:

- CU running
- DU1 running
- UE1 attached
- oaitun_ue1 active
- ping 10.45.0.1 OK
- ping 8.8.8.8 OK

### 3. Controlled DU switch sequence

Sequence:

- switch to DU0
- stability ping
- switch to DU1
- stability ping
- switch back to DU0

Final result:

- SWITCH_du0_OK
- SWITCH_du1_OK
- SWITCH_du0_OK
- F1_DU_SWITCH_SEQUENCE_OK

## Important note

This scenario is a controlled F1 DU switch / handover-like validation. It is not yet a seamless live radio handover because the UE is restarted and patched toward the selected RFsim DU service during the switch.

## Evidence location

Evidence is stored under:

~/oran-proof/f1-du-switch-sequence-*
