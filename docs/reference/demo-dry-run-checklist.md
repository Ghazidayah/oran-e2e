# Demo Dry-Run Checklist

A click-by-click runbook for demonstrating the oran-e2e-freeze testbed, with what each
step proves and inline recovery for the one thing that may break mid-demo (the CU).
Keep this open in a second window during the demo.

---

## 0. Pre-demo setup (run 15 minutes before, from a terminal)

```bash
cd ~/oran-e2e-freeze

# 1. Dashboard up (does not self-detach)
./stop-web-dashboard.sh; sleep 2
nohup ./run-web-dashboard.sh > /tmp/dash.log 2>&1 &
sleep 6
curl -s -o /dev/null -w "dashboard: %{http_code}\n" http://127.0.0.1:18080/    # expect 200

# 2. Traffic API up (REQUIRED for Phase-2 scenario buttons + KPI table)
./scripts/traffic/start-traffic-api.sh
sleep 3
curl -s http://127.0.0.1:5055/api/traffic/health     # expect ok:true

# 3. Platform at baseline + healthy
curl -s http://127.0.0.1:18080/api/radio/status | grep -o 'scheduler-auto' && echo "baseline OK"
./scripts/recover-ue-sessions.sh                     # expect VERDICT=ALL_HEALTHY
```

Then open the dashboard in the browser and hard-refresh (Ctrl+Shift+R).
Confirm: nav bar present, RAN Pods shows 8 pods (CU + 2 DU + 5 UE), 5/5 UEs attached.

Golden rule: before the audience arrives, the last line you want to have seen is
VERDICT=ALL_HEALTHY. If not, run step 3's recovery (see panic box below) until you do.

---

## 1. Suggested demo narrative (in order)

### Step 1 - Platform overview (Status section)
- Click: Reload Status.
- Say: "5G SA core, F1-split RAN with one CU and two DUs, five UEs, all on a single
  node with a simulated radio."
- Proves: 3/3 core, 8/8 RAN+UE, monitoring up. Point at the CU restart counter - "the
  CU has a known upstream stability quirk I'll come back to; the platform self-recovers."

### Step 2 - Real end-to-end traffic (E2E Scenarios section)
- Click: Run Image, then Run iperf3 TCP (or Run All).
- Say: "Real application traffic over the real 5G user plane - checksum-verified
  download, ~17 Mbps measured throughput."
- Proves: REAL data path. The Scenario KPI Results table fills with verdicts.
- Reference: docs/reference/what-is-real-vs-emulated.md section 3.1.

### Step 3 - Modulation control (Radio / Modulation Profile section)
- Click: select qam16-balanced -> Run KPI Test; then qam64-throughput -> Run KPI Test.
- Say: "I force the modulation order through real gNB MAC parameters; throughput
  scales with it - about 17 Mbps at 16QAM, about 30+ at 64QAM."
- Proves: REAL modulation forcing; the live rows reproduce the validated ladder.
- After: click Restore Scheduler Auto to return to baseline.
- Reference: section 3.2. Mention the honest 256QAM UE-capability limit if asked.

### Step 4 - Frequency scenarios (Frequency section)
- Say: "Two experiments here. The top is a *real* carrier retune; the bottom *emulates*
  per-band performance differences, because the simulated radio can't physically produce
  them - and it's labelled EMULATED."
- Click: Band KPI -> Run All Bands (fast, emulated).
- Optional: a real retune (slow, ~minutes - only if time allows; restart-heavy).
- Proves: the REAL vs EMULATED distinction - your strongest honesty point.
- Reference: section 3.3.

### Step 5 - Network slicing (Real S-NSSAI Slice Traffic section)
- Click: Run URLLC Slice.
- Say: "The AMF really grants the requested slice - here SST:2 - and I read that grant
  straight from the AMF log. The per-slice performance differences are emulated."
- Proves: REAL slice admission (Granted S-NSSAI column), emulated QoS.
- Reference: section 3.4.

### Step 6 - Multi-UE + DU handover (Multi-UE / DU Continuity sections)
- Click: Multi-UE -> Run selected scenarios (a couple of UEs); then DU Continuity ->
  Run Mixed-DU Validation.
- Say: "Several UEs running different realistic workloads in parallel, and UEs that can
  be moved between DUs while staying attached."
- Proves: parallel multi-UE traffic + real F1 DU switching.

### Step 7 - Evidence (top bar)
- Click: Generate Evidence Report.
- Say: "A live platform analysis - node, pods, health - generated on demand."
- Proves: reproducibility; everything shown is inspectable.

---

## 2. PANIC BOX - if something breaks mid-demo

The CU segfaults intermittently (known upstream OAI issue, ~a few times a day). If during
the demo a scenario suddenly fails, UEs show as detached, or pings stop working - stay calm,
it is almost always the CU, and it is a 30-second fix. This recovery story is itself a good
thing to show.

Symptom: UEs detached / scenarios failing / pings fail
```bash
cd ~/oran-e2e-freeze
./scripts/recover-ue-sessions.sh --fix --yes      # restarts only failing UEs (~30s)
./scripts/recover-ue-sessions.sh                  # re-verify -> VERDICT=ALL_HEALTHY
```
Say while it runs: "The CU restarted - a known upstream quirk. My recovery script diagnoses
which UEs lost their session and repairs only those."

Symptom: Phase-2 scenario buttons do nothing / error
The traffic API (port 5055) is probably down. Restart it:
```bash
./scripts/traffic/start-traffic-api.sh
```

Symptom: DU/handover state looks wrong after switching demos
```bash
bash scripts/handover/recover-mixed-du-state.sh   # ue1 back to baseline DU0, re-validate
# or from the dashboard: POST /api/handover/mixed-du/recover
```

Symptom: a forced profile got left active (throughput looks capped)
Click Restore Scheduler Auto in the Radio section, then:
```bash
./scripts/recover-ue-sessions.sh --fix --yes
```

Symptom: dashboard page errors / stale
Hard-refresh first (Ctrl+Shift+R). If still broken, restart it (step 0.1).

---

## 3. Post-demo: restore baseline

```bash
cd ~/oran-e2e-freeze
# If any modulation/frequency profile was applied during the demo:
curl -s -X POST http://127.0.0.1:18080/api/radio/restore >/dev/null
sleep 30
./scripts/recover-ue-sessions.sh --fix --yes
./scripts/recover-ue-sessions.sh                  # confirm VERDICT=ALL_HEALTHY
```

---

## 4. One-line answers to likely questions

- "Is this real or simulated?" -> "Real traffic and real 5G protocol stack end-to-end;
  the radio channel is simulated. See the real-vs-emulated reference." (section 1 of that doc)
- "Why does the CU restart?" -> "An upstream OAI softmodem segfault, not a resource
  problem - diagnosed (exit 139, not OOM) and mitigated with a recovery script."
- "Why emulate the band/slice differences?" -> "The idealized simulated channel can't
  physically reproduce frequency- or QoS-dependent performance, so those comparisons are
  emulated to illustrate the real-world behaviour - and labelled EMULATED."
- "Can it reach 256QAM?" -> "The UE doesn't advertise that capability, so it tops out at
  64QAM - documented honestly rather than faked."
