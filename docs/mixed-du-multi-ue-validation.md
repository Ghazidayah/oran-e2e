# Mixed DU Multi-UE Validation

Date: 2026-05-29

## Goal

Validate a safe handover / DU-continuity design where:

- `ue1` remains protected on DU0.
- `ue2`, `ue3`, `ue4`, and `ue5` can use DU1.
- Multi-UE eMBB realistic scenarios continue to work in mixed DU mode.
- Phase 3 / Phase 4 slicing and End-to-End UE validation remain safe because `ue1` is not modified.

## Final validated DU mapping

| UE | DU target | Purpose |
|---|---|---|
| ue1 | oai-du0-rfsim | protected reference UE |
| ue2 | oai-du1-rfsim | handover / DU-continuity UE |
| ue3 | oai-du1-rfsim | handover / DU-continuity UE |
| ue4 | oai-du1-rfsim | handover / DU-continuity UE |
| ue5 | oai-du1-rfsim | handover / DU-continuity UE |

## Final traffic matrix

| UE | Scenario | Tunnel | Result |
|---|---|---|---|
| ue1 | image | 10.45.0.37/24 | OK |
| ue2 | web | 10.45.0.36/24 | OK |
| ue3 | streaming | 10.45.0.41/24 | OK |
| ue4 | video_download | 10.45.0.43/24 | OK |
| ue5 | tcp_download | 10.45.0.45/24 | OK |

## Final verdict

```text
VERDICT=MIXED_DU_MULTI_UE_MATRIX_OK
RESULT=ue1 protected on DU0; ue2-ue5 validated on DU1 with Multi-UE traffic
```

## Design rule

`ue1` must remain protected on DU0 until Phase 3 / Phase 4 slicing scripts become fully DU-aware.

The DU-continuity / handover feature must operate only on:

```text
ue2
ue3
ue4
ue5
```

