# Real S-NSSAI Slicing — Root Cause & Validation (2026-06-10)

## Result

First genuinely granted non-default slice on this platform:

```
UE1: [SIM] DNN=oai, SST=0x02, SD=0xffffff
UE1: [NAS] Received PDU Session Establishment Accept, UE IPv4: 10.45.0.42
AMF:  S_NSSAI[SST:2 SD:0xffffff]          <- the evidence line
```

UE1 requested SST 2, the AMF admitted it on SST 2, SMF established the session,
tunnel up, ping 0% loss. Restored to SST 1 baseline afterwards; all 5 UEs healthy.

## What "real" means here (honest two-layer framing)

- **S-NSSAI slice selection/admission: REAL.** 4 slices (SST 1–4, SD 0xffffff) in
  AMF/NSSF/SMF/MongoDB; the UE's requested slice is genuinely granted by the core
  and visible in the AMF log.
- **Per-slice resource enforcement: EMULATED.** Throughput/latency differences per
  slice are applied with `tc` on `oaitun_ue1` (`apply-slice-resource-profile.sh`);
  the RFsim gNB scheduler does not enforce 5QI/GBR radio resources.

## Why slice switching never worked before — four stacked root causes

1. **UE config syntax silently ignored.** `switch-ue-slice.sh` wrote
   `pdu_sessions = ({ ... })`, which the 2025.w45 nr-ue does not parse — the UE
   always fell back to default SST 1 while configs *looked* switched. Fix: legacy
   uicc0 keys (`dnn` / `nssai_sst` / `nssai_sd`), proven via the UE's own log
   (`[SIM] ... SST=0x02`).
2. **DU0's snssaiList regressed to SST 1 only.** Rebuilding the DU0 ConfigMap from
   the repo's stale `du0.conf` (during the n28 cleanup) wiped the 4-slice list.
   Fix: `du0.conf` now carries SST 1–4 (committed), ConfigMap rebuilt.
3. **The AMF never loaded the slicing config.** The AMF mounts its `amf.yaml`
   from ConfigMap **`open5gs-oai-prep`** (volume `amf-config-fixed`) — NOT from
   `open5gs-amf`, which is mounted but unused. The May-30 slicing work edited the
   unused one; the running AMF still had a single stale slice
   (`sst: 1, sd: "0x111111"`). Fix: patched `open5gs-oai-prep`'s `s_nssai` to
   SST 1–4 / 0xffffff (backup in `backups/slicing-amf-fix/`), restarted AMF.
4. **The OAI UE sends no Requested NSSAI at registration**, so Open5GS computes
   Allowed NSSAI = the subscriber's **default** slice only. A UE configured for a
   non-default slice gets `[NAS] E NSSAI parameters not match with allowed NSSAI.
   Couldn't request PDU session.` Fix: a slice switch must flip the MongoDB
   `default_indicator` to the target slice **together with** the UE config.

Additional incidental fix: UE2's deployment args still pointed at the
pre-F1-split RFsim host `oai-gnb-rfsim` (stale pod spec, flushed out by the CU
restart); patched to `oai-du1-rfsim`.

## The platform's true slice-switch mechanism (implemented in v2 scripts)

`scripts/slicing/switch-ue-slice.sh <SST> [SD]` now does, atomically:
1. UE ConfigMap: legacy slice keys (replaces any `pdu_sessions` block).
2. MongoDB: `default_indicator` -> target SST for the UE's IMSI.
3. UE rollout restart + tunnel wait.
4. **Asserts the AMF-granted `S_NSSAI[SST:x]` matches the request**
   (`VERDICT=REAL_SLICE_SWITCH_OK` / `GRANTED_SLICE_MISMATCH`).

`scripts/slicing/validate-current-slice.sh` (v2) likewise validates
**requested vs granted** (AMF log), not just config + tunnel
(`VERDICT=REAL_SLICE_VALIDATED`).

## How to reproduce

```bash
bash scripts/slicing/switch-ue-slice.sh 2 0xffffff   # expect VERDICT=REAL_SLICE_SWITCH_OK
bash scripts/slicing/validate-current-slice.sh        # expect VERDICT=REAL_SLICE_VALIDATED
bash scripts/slicing/switch-ue-slice.sh 1 0xffffff   # restore baseline
```

## Operational lessons (added to OPERATING-RULES.md)

- ConfigMap edits do NOT reach running pods (subPath mounts): the CU ran a stale
  config for 14 days; the AMF likewise. Always restart the consumer pod and
  verify the file *inside* the pod.
- The AMF's real config source is `open5gs-oai-prep` (key `amf.yaml`), not
  `open5gs-amf`.
- UE deployment args override ConfigMap values (serveraddr); check both.
- "Validated" requires core-side grant evidence, not config + tunnel.
