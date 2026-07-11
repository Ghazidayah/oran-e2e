# Phase 3 — Real S-NSSAI Slicing Validation

## Objective

Enable and validate real 5G S-NSSAI slicing on the O-RAN / Open5GS / OAI RFsim platform.

## Slice profiles

| Slice | SST | SD | DNN |
|---|---:|---|---|
| eMBB | 1 | 0xffffff | oai |
| URLLC | 2 | 0xffffff | oai |
| mMTC | 3 | 0xffffff | oai |
| V2X | 4 | 0xffffff | oai |

## Applied changes

The platform was updated to support SST 1/2/3/4 across:

- Open5GS AMF allowed NSSAI
- Open5GS SMF S-NSSAI/DNN info
- Open5GS NSSF NSI entries
- OAI CU/DU supported `snssaiList`
- Open5GS subscriber database
- OAI NR-UE requested NSSAI through `nr-ue.conf`

## Validation result

| Slice | Requested SST | Tunnel | Internet ping | Result |
|---|---:|---|---|---|
| eMBB | 1 | oaitun_ue1 OK | 0% loss | OK |
| URLLC | 2 | oaitun_ue1 OK | 0% loss | OK |
| mMTC | 3 | oaitun_ue1 OK | 0% loss | OK |
| V2X | 4 | oaitun_ue1 OK | 0% loss | OK |

## Evidence

Main evidence directory:

~/oran-proof/phase3-real-snssai-slice-switch/20260526-023017

Validation summary:

VERDICT=ALL_REAL_SLICES_OK

## Important note

All slices currently use the same DNN `oai` and the same UPF/data-network path. This validates real S-NSSAI selection and PDU session establishment per SST. A future improvement can add separate DNNs, IP pools, QoS rules, or UPF paths per slice.

## Final state

After validation, the UE was restored to default eMBB:

- DNN=oai
- SST=1
- SD=0xffffff
- oaitun_ue1 active
- Internet ping working
