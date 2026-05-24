# F1 DU Handover Redesign Plan

## Decision

The old broken handover section based on oai-cu, oai-du0, oai-du1 and oai-nr-ue-f1 was removed from the active cluster.

## Reason

The old CU/DU/F1 topology was unstable and generated CrashLoopBackOff pods. The validated baseline remains the single OAI gNB serving multiple NR-UE pods.

## New target

Replace the current monolithic gNB topology with a clean split architecture:

- one OAI CU
- DU0
- DU1
- five NR-UEs
- same Open5GS core
- same DNN=oai
- same N2/N3 design
- F1-C and F1-U between CU and DUs
- mobility / handover between DU0 and DU1

## Implementation phases

1. Clean old broken handover resources.
2. Revalidate current 5 UE baseline.
3. Create new CU config from current gNB config.
4. Create DU0 config from current gNB radio/cell config.
5. Create DU1 config with separate DU identity and cell/PCI parameters.
6. Connect CU to Open5GS AMF on N2.
7. Connect DU0/DU1 to CU over F1.
8. Attach UE first on DU0.
9. Add mobility/handover test toward DU1.
10. Collect logs from UE, CU, DU0, DU1, AMF, SMF and UPF.
