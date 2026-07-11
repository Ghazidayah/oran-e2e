# Mixed-DU Dashboard Handover Validation

Date: 2026-05-29

## Goal

Integrate the validated mixed-DU continuity design into the dashboard handover section.

The dashboard now:

- protects `ue1`
- allows DU switching only for `ue2`, `ue3`, `ue4`, and `ue5`
- exposes Mixed-DU handover/continuity status
- validates traffic using the existing Multi-UE eMBB realistic scenario API
- keeps compatibility with the previous handover endpoint

## Final validated status

```text
mode: mixed-du-rfsim
DU0 ready: true
DU1 ready: true
attached: 5 / 5
ue1 protected: true
handover ready: true
```

## Final UE mapping

| UE  | DU  | Role                     |
| --- | --- | ------------------------ |
| ue1 | DU0 | protected reference UE   |
| ue2 | DU1 | switchable continuity UE |
| ue3 | DU1 | switchable continuity UE |
| ue4 | DU1 | switchable continuity UE |
| ue5 | DU1 | switchable continuity UE |

## Safety validation

Attempting to switch `ue1` is blocked:

```text
VERDICT=UE1_PROTECTED_NO_DU_SWITCH
```

## Dashboard validation result

```text
VERDICT=MIXED_DU_DASHBOARD_HANDOVER_OK
RESULT=Dashboard supports DU switch for ue2-ue5, blocks ue1, and validates traffic with fallback
```

## Dashboard endpoints

```text
GET  /api/handover/mixed-du/status
POST /api/handover/mixed-du/switch
POST /api/handover/mixed-du/run
POST /api/handover/f1/run
```

The old `/api/handover/f1/run` endpoint is kept for compatibility but now validates mixed-DU Multi-UE continuity.
