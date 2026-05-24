# F1 DU Switch Validation Summary

## Objective

The objective was to redesign the old broken F1 handover section into a clean OAI F1 split architecture.

The validated architecture is:

- OAI CU
- DU0
- DU1
- one NR-UE
- Open5GS core
- DNN=oai
- UE tunnel through oaitun_ue1

## Validated results

### CU + DU0 + UE1

Result:

- CU running
- DU0 running
- UE1 attached
- oaitun_ue1 active
- ping 10.45.0.1 OK
- ping 8.8.8.8 OK

### CU + DU1 + UE1

Result:

- CU running
- DU1 running
- UE1 attached
- oaitun_ue1 active
- ping 10.45.0.1 OK
- ping 8.8.8.8 OK

### Controlled DU switch sequence

Validated sequence:

- DU0 active
- stability ping OK
- switch to DU1
- stability ping OK
- switch back to DU0
- final UE tunnel OK

Final result:

- SWITCH_du0_OK
- SWITCH_du1_OK
- SWITCH_du0_OK
- F1_DU_SWITCH_SEQUENCE_OK

## Important limitation

This is a controlled F1 DU switch / handover-like validation.

It is not yet a seamless live radio handover because the UE is restarted and patched toward the selected RFsim DU service during the switch.

## Evidence

Evidence is stored under:

~/oran-proof/f1-du-switch-sequence-*
