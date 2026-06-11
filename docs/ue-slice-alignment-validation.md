# UE2-UE5 Slice Alignment Validation (2026-06-11)

Closes handoff item 3: align UE2-UE5 slice assignments consistently across
UE configs, MongoDB defaults, and DU slice lists.

## Decision: Option A — all UEs SST1 at rest
All five UEs default to SST1 (eMBB). Slice diversity is demonstrated via
on-demand switching (scripts/slicing/switch-ue-slice.sh, UE1) rather than
permanent per-UE assignments, preserving the Multi-UE eMBB Parallel section's
all-SST1 assumption.

## Audit findings (pre-fix)
- MongoDB: already consistent — all subscribers hold SST1-4, default SST1. No change.
- DU1 live ConfigMap: already SST1-4 (fixed on-cluster during ee66444 work);
  repo manifests/ran/f1/du1.conf was stale single-slice -> synced (commit bdc2f17).
- UE2-UE5 ConfigMaps: still used the pdu_sessions = ({...}) syntax, which the
  2025.w45 nr-ue silently IGNORES (slicing root-cause layer 1). Harmless by
  accident (Mongo default SST1 matched), but any future slice edit on these UEs
  would have silently done nothing.

## Fix applied (2026-06-11 09:46)
Converted UE2-UE5 CMs from the ignored pdu_sessions block to the legacy
dnn/nssai_sst/nssai_sd keys (same SST1 values), verified inside each CM,
rollout-restarted UE2-UE5, then asserted fresh AMF grants.

## Evidence
- recover-ue-sessions.sh: all 5 UEs HEALTHY post-restart, new IPs .62-.65
  matching SMF assignments, DN-gateway ping 0% loss.
- AMF log (post-restart): S_NSSAI[SST:1 SD:0xffffff] granted to
  imsi-...002/003/004/005 at 08:46:40-08:46:45.
- Behavior-neutral by design: the win is that configs now say what actually
  happens (no silently-ignored block), making future slice work on UE2-UE5
  trustworthy.

## Repo/live consistency restored
- manifests/ran/f1/du1.conf: snssaiList synced to live SST1-4.
- manifests/ran/mixed-du-live/cm-oai-nrue-config-{2..5}.yaml: regenerated from
  live CMs (legacy keys), server fields stripped per CLAUDE.md rule 4.
