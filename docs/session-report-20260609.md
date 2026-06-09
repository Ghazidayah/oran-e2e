# Session Report — 2026-06-09

Working session on the O-RAN E2E testbed (`oran-lab`, branch `allow-ue1-du-switch-all-scenarios`).
Captures everything done so a fresh Claude Code session has full context.

## Summary of outcomes

- ✅ Recovered all 5 UE data tunnels after a core bounce.
- ✅ Re-enabled + validated UE1 DU switching (DU0↔DU1) across all scenarios; confirmed committed.
- ✅ Made the frequency-retune script genuinely DU-aware.
- ✅ Restored platform to clean n78 state (UE1 ping 0% loss).
- ⚠️ n28 700 MHz FDD: cell + SIB1 + sync + RACH Msg1/Msg2 proven; full attach blocked at Msg3 (OAI RFsim FDD limitation). Committed as sync-only.

---

## 1. Problem: all 5 UE tunnels down

Health check showed every UE registered but with **no `oaitun` interface** and SMF reporting **0 sessions**.

**Root cause:** MongoDB readiness probe timed out → AMF/SMF/UPF restarted → all PDU-session context lost. UEs re-registered at NAS but never re-requested PDU sessions, so no GTP-U tunnel. (The `FailedGetResourceMetric` HPA events were unrelated noise.)

**Fix:** clean UE re-attach.
```bash
kubectl -n oran-ran rollout restart deploy/oai-nr-ue           # confirm on UE1 first
for d in oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do kubectl -n oran-ran rollout restart deploy/$d; done
```
**Result:** all 5 back; `oaitun_ue1=10.45.0.2`, PDU Session Establishment Accept, ping 0% loss, SMF "Number of SMF-Sessions is now 5".

**Follow-up (open):** build `scripts/recover-ue-sessions.sh` to make this a one-command recovery.

## 2. Problem: UE1 could not DU-switch (regression)

- 2026-05-30 (`4087972`): UE1 switching enabled + validated.
- 2026-06-02 (`d479640` "Restore Mixed-DU handover dashboard section"): restoring the dashboard panel **re-blocked UE1** in `switch-ue-du-target.sh` and `mixed_du_handover_api.py`, and repurposed that panel into a Radio Profile UI. The May-30 validation doc went stale.

Scenario scripts (slicing/QoS/traffic/radio) were already DU-agnostic; only the frequency-retune script was DU0-hardcoded.

**Fix (5 files):**
- `scripts/handover/switch-ue-du-target.sh` — removed UE1 block, added `ue1)` to case map.
- `web-dashboard/mixed_du_handover_api.py` — UE1 switchable; readiness = both DUs up + all 5 attached (no longer "UE1 on DU0"); `allowed_ues` all 5, `blocked_ues` `[]`.
- `scripts/handover/recover-mixed-du-state.sh` — "UE1 stay blocked" → "restore UE1 to baseline DU0".
- `scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh` — auto-detect UE1's current DU.
- `scripts/dashboard/test-section-06-mixed-du-handover.sh` — test `ue1→DU1→DU0` instead of asserting the block.

**Validated live:** switch `UE_DU_SWITCH_OK`; E2E `E2E_UE1_VALIDATION_OK` (0% loss on DU1); slice `PROTECTED_UE1_CURRENT_SLICE_VALIDATED`; frequency script reported `DU_DEPLOY=oai-du1` while UE1 there; restored to DU0. Confirmed committed at HEAD (`blocked_ues": []`, `ue1) CM="oai-nrue-config"`).

## 3. n28 700 MHz FDD — sync-only

700 MHz = band **n28 = FDD, 15 kHz** — structural, not a TDD carrier retune (no TDD ~700 MHz NR band exists).

**Radio plan (FDD, 15 kHz, 106 PRB = 20 MHz):** DL 771.71–790.79 (center 781.25); SSB ARFCN 156250; DL PointA 154342; UL PointA 143342 (DL−55 MHz). UE args `--band 28 --numerology 0 -C 781250000 --ssb 516 -r 106`.

**Artifacts:** `manifests/ran/f1/gnb-du0.n28-700.fdd.conf`, `scripts/frequency/validate-n28-700-on-du0.sh` (apply/check/restore; backs up DU0 cm + UE1 deploy).

**Diagnostic result (by elimination):**
- DU0 boots on n28 FDD, no assert → FDD config structurally valid.
- UE decodes SSB/MIB/SIB1 → SSB raster, PointA, CORESET0, `--ssb 516` all correct.
- RACH Msg1 (preamble detected) + Msg2 (RAR decoded) succeed.
- **Msg3 PUSCH fails CRC every attempt** (`tb_crc_status 1` / "Msg3 CRC did not pass"); no Initial UL RRC sent; UE `T300 expired`.
- Ruled out: F1/CU (CU healthy, accepts the cell), DMRS `dmrs_TypeA_Position` 0↔1, PRACH short-format (idx 98) **and** long-format (idx 16, ZCZ 1, RootSeq_PR 1).

**Conclusion:** Msg1+Msg2 always succeed, Msg3 never decodes regardless of DMRS/PRACH in a perfect AWGN channel → **OAI RFsim FDD uplink limitation**, not a tunable config value. Legitimate finding, documented; not retried further.

**Cleanup gotchas hit (now in CLAUDE.md safety rules):** stale-`resourceVersion` apply conflict; the validate script's own backup was overwritten by repeated applies → DU0 restored from `manifests/ran/f1/du0.conf`; non-whitespace-agnostic `sed` silently no-op'd twice.

## Final state

- Platform healthy: 5 UEs on n78, UE1 `oaitun_ue1=10.45.0.17`, ping 0% loss.
- Commits on branch `allow-ue1-du-switch-all-scenarios`: UE1-switching code (verified at HEAD) + `47e966f` (n28 sync-only artifacts, debug logging reverted to info).

## Still open

1. n28 700 MHz writeup in `docs/` (sync-only, by-elimination).
2. Wire working 3500/2600 profiles into the dashboard.
3. `scripts/recover-ue-sessions.sh` for core-bounce tunnel loss.
4. Refresh stale `docs/ue1-du-aware-handover-validation.md`.
5. Fix `validate-n28-700-on-du0.sh` restore (version-strip; don't trust its backup).
