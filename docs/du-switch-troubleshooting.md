# DU switch troubleshooting (ue <-> DU0/DU1)

Start with `tools/diagnose-du-layout.sh <label>`: the **AUTOMATIC CHECKS** block at the top of
the report names the usual causes. Symptom -> cause -> fix:

| Symptom | Cause | Fix |
|---|---|---|
| UE log repeats `Got NACK on NR-BCCH-DL-SCH-Message (SIB1)`, never attaches | UE carrier `-C` differs from the DU carrier (e.g. ue1 left on `n78-3500` = 3499680000 while DU1 runs 3319680000) | `scripts/handover/switch-ue-du-target.sh` now re-aligns `-C` to the target DU. After any frequency experiment: `scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh restore` |
| UE pod crashes with `Assertion ... to_nrarfcn() ... Band 78, dl_CarrierFreq 4173600000` | UE has no `--band` (OAI defaults to 78) but was sent to DU0, which runs band 77 | `scripts/handover/switch-ue-du-target.sh` now adds `--band` when missing; re-run it for the UE |
| CU-CP log: `No AMF is associated to the gNB` | NG link to the AMF lost, CU-CP does not reconnect | `kubectl -n oran-ran rollout restart deploy/oai-cu-cp`, then cu-up, du0, du1, then `scripts/recover-ue-sessions.sh --fix` |
| AMF `Registration reject [9]`, AUSF `HTTP response error [500]`, SCP `No route to host` | stale UDR/UDM endpoint after the core was recreated | `scripts/recover-core-auth.sh --fix` |
| UE pods in CrashLoopBackOff | consequence of the two cases above (UE exits on Registration reject) | fix the cause, then restart the UEs |

Always check `attached_count: 5` and `handover_ready: true` on
`/api/handover/mixed-du/status` before testing a switch.
