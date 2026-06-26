# Claude Code Session Report — 2026-06-10

Branch: `allow-ue1-du-switch-all-scenarios`
Working directory: `~/oran-e2e-freeze`
Continues from: `docs/claude-code-session-2026-06-09.md`

---

## 1. Summary

Five dashboard fixes and improvements committed today, all on top of the 2026-06-09
frequency + modulation profile work:

| Commit | Change |
|---|---|
| `231d5b1` | Real modulation profiles: fix broken results display + pre-populate reference KPIs |
| `e44aabb` | Remove standalone "Latest Action Output / Recent Evidence Runs" panel |
| `ea58237` | Serving DU Check: replace legacy gNB-A/B with F1-split DU0/DU1 topology |
| `8903803` | Evidence Report: full 8-section F1-split platform analysis + remove IDLE pill |
| `c329cfa` | Real S-NSSAI Slice Traffic (Phase 3): fix "Failed to fetch" by routing through Flask |

---

## 2. What Was Done

### 2.1 Real Modulation Profiles Dashboard — fix results never showing (`231d5b1`)

**Problem:** The modulation profile results table was permanently empty. Root cause: two bugs
in `web-dashboard/static/mixed-du-handover.js`:

1. `refreshResults()` read `r.dynamic_rows` and `r.reference_rows` from the API response, but
   the `/api/radio/results` endpoint returns `r.rows`. Since `r.dynamic_rows` is always
   `undefined`, the spread produced an empty array and nothing was ever displayed.
2. `renderRows()` referenced `r.mcs_snr` (a stale field from the old netem-faked API). The new
   API returns `r.max_mcs` and `r.modulation` — the `mcs_snr` column always showed `—`.
3. Table had 8 columns including `RFsim values` and `MCS/SNR proof` — both stale from the old
   architecture.
4. The note box (yellow) said *"Direct forced QPSK/16QAM/64QAM/256QAM was not proven"* — this
   was written before the MCS-forcing work (commit `4b1d926`) proved it definitively.

**Fixes applied:**

- `refreshResults()`: `r.dynamic_rows` → `r.rows`, `r.reference_rows` now comes from the API
- `renderRows(rows)`: removed `r.mcs_snr`; added `r.max_mcs`; reduced to 7 columns:
  Profile | Max MCS | Modulation | Ping avg ms | TCP Mbps | Retransmits | Verdict
- Status cards: replaced `rp-slice` / `rp-verdict` → `rp-max-mcs` / `rp-modulation`
- Subtitle and note box updated to reflect proven real MCS forcing (green note, not yellow)
- Stale "honest limitation" yellow note replaced with green validated note:
  *"✅ Real MCS forcing verified (2026-06-09): QPSK ~6.7 Mbps · 16QAM ~17.7 Mbps ·
  64QAM ~30 Mbps. 256QAM is UE-capability-limited."*

**Reference rows added to API (`radio_profile_api.py`):**

`REFERENCE_ROWS` list added from `docs/modulation-scenarios-validation.md`. The `/results`
endpoint now returns `reference_rows` for any profile not yet in the live results file, so the
table pre-populates with validated data from the doc instead of being empty on first load.
Live run rows (from Apply / KPI Test) take precedence and hide the corresponding reference row.

**`radio-profile-results.json` cleaned:** Four stale netem-format entries
(old fake profiles with `netem_params` / `rf_values` fields) were removed.
Kept only the one real validated entry (`qpsk-robust`, ping_avg_ms=72.883).

---

### 2.2 Remove standalone "Latest Action Output / Recent Evidence Runs" panel (`e44aabb`)

**Problem:** The dashboard had a separate two-column panel below the live metrics section
showing "Latest Action Output" (`<pre id="actionOutput">`) and "Recent Evidence Runs"
(`<table id="runsTable">`). The user correctly noted this was redundant — the scenario
output should appear inline in the "End-to-End UE Validation Scenarios" section like the
other scenarios.

Additionally the `actionOutput` element showing *"Status reload failed: TypeError: Failed to
fetch"* on every page refresh was caused by `dashboard-status-live.js` calling
`document.getElementById("runsTable").innerHTML = ...` when the element existed — and by
the status `/api/status` network error writing to the same `actionOutput` element.

**Changes:**

- `templates/index.html`:
  - Removed the `<section class="grid two section">` panel entirely (16 lines)
  - Renamed `<pre id="phase2TrafficOutput">` → `<pre id="actionOutput">` so all scenario
    output (baseline checks + Phase 2 traffic) lands in the same element at the bottom of the
    "End-to-End UE Validation Scenarios" section
- `dashboard-inline.js`: updated `setPhase2TrafficOutput()` to use `"actionOutput"` instead of
  `"phase2TrafficOutput"`
- `dashboard-status-live.js`: guarded `runsTable.innerHTML` with a null-check
  (`const runsTable = document.getElementById("runsTable"); if (data.recent_runs && runsTable)`)
  to prevent the null-reference TypeError now that the element is gone

**Result:** All scenario outputs — Serving DU Check, UE Attach+PDU, Connectivity, Image
Download, iperf3 TCP, UDP, Video, Web, Streaming, Run All — now appear in one `<pre>` at the
bottom of the validation section.

---

### 2.3 Serving DU Check — F1-split topology (`ea58237`)

**Problem:** The "Serving gNB Check" button ran a script that looked for `oai-gnb-a-*` and
`oai-gnb-b-*` pods via `kubectl port-forward` + OAI CI socket commands (`ci get_single_rnti`,
`ci fetch_du_by_ue_id`). These pods do not exist in the current F1-split architecture (CU +
DU0 + DU1). The script always returned empty results.

**New script in `action_ownership()` (app.py):**

1. Reads UE1's `serveraddr` from `oai-nrue-config` ConfigMap:
   - `oai-du0-rfsim` or `server` → active DU = `oai-du0`
   - `oai-du1-rfsim` → active DU = `oai-du1`
   - Falls back to parsing UE Deployment args if ConfigMap read fails
2. Shows UE1 pod name + `oaitun_ue1` tunnel IP
3. Shows DU0 pod/phase — marks `>>> SERVING UE1 <<<` with last 60s of
   RNTI/Qm/RRC/dlsch_rounds log lines if it is the active DU
4. Shows DU1 pod/phase — same, marks if active
5. Shows CU pod/phase

**Parser updated (`latest_ownership_details()`):** Parses new output format
`"Active serving DU : oai-du0"` → `serving="DU0"`. Legacy `gNB-A/B` fallback kept for old
log files already on disk.

**`guess_serving_from_logs()`:** Primary path now reads `serveraddr` directly (fast, no log
scrape). Falls back to RNTI grep on DU0/DU1 logs if serveraddr unavailable. Old gNB-A/B log
scrape removed.

**HTML card:** `"Serving gNB Check"` → `"Serving DU Check"`, button text updated to
`"Check Serving DU"`, description updated.

---

### 2.4 Evidence Report — full 8-section platform analysis (`8903803`)

**Problem:** The "Generate Evidence Report" used a 70-line script that still referenced
`GNB_A_POD` and `GNB_B_POD` (old architecture), ran only 2-ping checks, and omitted F1
topology, modulation profile state, all-UE tunnel status, and serving DU activity.

**New 8-section report script (180s timeout):**

| § | Title | Content |
|---|---|---|
| 1 | Kubernetes Node | `kubectl get nodes -o wide` + `kubectl top nodes` + `df -h` |
| 2 | Pod Health Summary | All pods in oran-core / oran-ran / monitoring |
| 3 | F1 RAN Topology | CU + DU0 + DU1 pod/phase + current `dl_max_mcs` read from Deployment args |
| 4 | UE1 User Plane | Serving DU (from serveraddr) + `oaitun_ue1` IP + ping DN-GW (10.45.0.1) + ping 8.8.8.8 |
| 5 | All UE Tunnels | oaitun status for UE1–UE5 |
| 6 | Serving DU Activity | Last 90s of RNTI/Qm/RRC/dlsch_rounds log lines from the active DU pod |
| 7 | Core Network | AMF last registrations + NGAP socket check; SMF PDU sessions; UPF GTP-U socket |
| 8 | Recent Run History | Last 10 `summary.json` entries from `~/oran-proof` |

**`dl_max_mcs` introspection:** The report reads the active MCS cap from each DU's Deployment
args at report time via inline Python (same logic as `current_cap()` in the modulation script),
so the report always reflects the live scheduler state.

**IDLE pill removed:** The `<span id="action-feedback-pill" class="feedback-pill">IDLE</span>`
span was removed from the `ensurePanel()` HTML in `dashboard-inline.js`. The element lookup
in `setPanel()` returns `null` harmlessly (the existing `if (pill)` guard absorbs it).

---

### 2.5 Real S-NSSAI Slice Traffic (Phase 3) — fix "Failed to fetch" (`c329cfa`)

**Problem:** All four Phase 3 buttons (eMBB, URLLC, mMTC, V2X) immediately showed
*"Real slice traffic failed: TypeError: Failed to fetch"*. The JS called
`http://192.168.1.142:5055` — an external traffic API server that is not running on the lab
host. The 90-line polling loop never got past the first `fetch`.

**Root cause:** `PHASE3_REAL_SLICE_API = "http://192.168.1.142:5055"` in `dashboard-inline.js`
was a leftover from a previous architecture that ran a standalone `traffic_api_server.py`
Flask process on a different port. That server is no longer started.

**Fix:**

- `app.py`: added `/api/real-slice/<profile>` route (profiles: `embb`, `urllc`, `mmtc`, `v2x`)
  that runs `scripts/slicing/run-real-slice-traffic.sh <profile>` via `save_run()` with a 600s
  timeout. Input is validated — unknown profiles return HTTP 400 with the allowed list.
- `dashboard-inline.js`: replaced the 90-line external-API polling loop with a 30-line direct
  `fetch("/api/real-slice/<profile>")` call. The browser waits synchronously for the response
  (consistent with all other scenario buttons in the dashboard). On completion, output is
  displayed with a `✅ PASS` / `❌ FAIL` prefix.
- `index.html`: updated `<pre id="phase3RealSliceOutput">` initial text from
  `"Real Slice API ready: http://192.168.1.142:5055"` to `"Ready. Select a slice profile..."`.

**What `run-real-slice-traffic.sh` does per profile:**

| Step | Action |
|---|---|
| 1 | `switch-ue-slice.sh <sst> 0xffffff` — patches `nssai_sst`/`nssai_sd` in UE1 ConfigMap (DU-aware: never changes `serveraddr`), restarts UE1, waits for `oaitun_ue1` |
| 2 | `validate-current-slice.sh` — verifies tunnel and slice fields |
| 3 | `apply-slice-resource-profile.sh <profile>` — applies `tc tbf` rate shaping on `oaitun_ue1` for the slice (eMBB: 50mbit; URLLC: 20mbit; mMTC: 2mbit; V2X: 10mbit) |
| 4 | Traffic scenarios (eMBB: image+video+web+streaming+iperf; URLLC/V2X: UDP; mMTC: small-UDP) |
| 5 | `switch-ue-slice.sh 1 0xffffff` on EXIT trap — always restores SST=1 |

---

## 3. Problems Hit and How They Were Solved

### 3.1 Modulation results table never showed data

The `r.dynamic_rows` field name was carried over from an old multi-UE API design that split
results into `dynamic_rows` + `reference_rows`. When the API was rewritten to use a single
`rows` list, the JS was not updated. Because `undefined || []` evaluates to `[]`, no error was
thrown — just a permanently empty table. Identified by reading the API response directly via
`curl /api/radio/results` and comparing with the JS field references.

### 3.2 Stale netem entries in radio-profile-results.json blocking reference rows

The `/results` endpoint filters reference rows by removing any profile already present in the
live results file. The four old netem-format entries had `profile` fields matching real profile
names (`scheduler-auto`, `qam64-throughput`, etc.), so they blocked all four reference rows.
Fix: cleared the stale entries from the JSON file, keeping only `qpsk-robust` (a real run).

### 3.3 runsTable null-reference after panel removal

After removing the "Recent Evidence Runs" panel, `dashboard-status-live.js` threw a TypeError
on every status poll: `Cannot set properties of null (setting 'innerHTML')`. The `runsTable`
element no longer existed in the DOM. Fixed with a two-line null guard before the `.innerHTML`
assignment.

### 3.4 Phase 3 "Failed to fetch" root cause identification

The error message `TypeError: Failed to fetch` in JavaScript typically indicates either CORS
failure or network unreachability. Since the URL was an external host (`192.168.1.142:5055`)
rather than the same origin, the browser's fetch failed at the TCP connect step before any
HTTP response. Confirmed by checking whether that port was listening:
`ss -tnlp | grep 5055` → no output. The external server was never started in this session.

---

## 4. Current Platform State

```
Branch   : allow-ue1-du-switch-all-scenarios
Last commit : c329cfa  Fix Real S-NSSAI Slice Traffic
Dashboard   : running on port 18080 (Flask, pid managed by run-web-dashboard.sh)

RAN:
  CU    : oai-cu         — Running
  DU0   : oai-du0        — Running  dl_max_mcs=none (scheduler-auto / adaptive)
  DU1   : oai-du1        — Running
  UE1   : oai-nr-ue      — Running  serveraddr=oai-du0-rfsim  oaitun_ue1=UP
  UE2-5 : oai-nr-ue-2..5 — Running on DU1

Core    : AMF / SMF / UPF / MongoDB — Running (oran-core)
PLMN    : 999/70  DNN: oai  SST=1 (restored)

Frequency baseline: n78-3500 MHz TDD (DU0 baseline, no retune active)
Modulation profile: scheduler-auto (no MCS cap, adaptive AMC)
Netem              : none active
```

---

## 5. Open Items (unchanged from 2026-06-09 except where noted)

1. **Bring-up KPI table TBDs** (`docs/frequency-scenarios-validation.md` §4) — individual
   carrier retune runs for n78-3500, n78-cband-3780, n41-2600 not yet validated. Requires ~5 min
   per profile + operator confirmation before each switch.
2. **`scripts/recover-ue-sessions.sh`** — one-command recovery for core-bounce PDU session loss
   (CLAUDE.md open item §3). Not built.
3. **`validate-n28-700-on-du0.sh` restore fragility** — script overwrites its own backup on
   repeated applies. Fallback is `manifests/ran/f1/du0.conf`. Not fixed.
4. **`docs/ue1-du-aware-handover-validation.md`** — stale doc (describes a state rolled back
   2026-06-02, re-enabled 2026-06-09). Not refreshed.
5. **Phase 3 slice traffic not live-tested** — the fix routes through Flask and calls the
   existing scripts, but no actual SST=2/3/4 slice run was performed in this session. Whether
   Open5GS accepts non-SST=1 registrations on this subscriber profile is unknown. The scripts
   have a restore trap (`switch-ue-slice.sh 1 0xffffff`) so failure is safe.
6. **Phase 2 traffic (image/iperf/video/web/streaming) also calls 192.168.1.142:5055** — only
   Phase 3 was fixed this session. Phase 2 traffic buttons still call the dead external API.
   Fix would be the same pattern: add Flask routes and call the existing scripts directly.

---

## 6. Honesty Notes

### Dashboard is now internally consistent with the F1-split architecture

All three places that previously referenced `oai-gnb-a`/`oai-gnb-b` pods (ownership check,
evidence report, `guess_serving_from_logs`) have been updated to use `oai-cu`/`oai-du0`/`oai-du1`.

### Phase 2 traffic remains broken (not fixed this session)

The Phase 2 traffic buttons (Image Download, iperf3 TCP, UDP, Video, Web, Streaming, Run All)
also call `http://192.168.1.142:5055` and will fail with the same "Failed to fetch" error.
This was not addressed in this session. The underlying scripts exist and work (`run-iperf-tcp.sh`
is used by the radio profile KPI test and works correctly). The fix is the same as Phase 3.

### MCS forcing is confirmed real (carried forward from 2026-06-09)

The modulation profile dashboard section now accurately describes the validated results:
QPSK →~6.7 Mbps, 16QAM →~17.7 Mbps, 64QAM →~30 Mbps. 256QAM is UE-capability-limited.
All reference rows in the table are sourced from `docs/modulation-scenarios-validation.md`.

---

## Appendix: Commits This Session

```
c329cfa Fix Real S-NSSAI Slice Traffic: route through Flask, drop dead external API
8903803 Evidence report: full F1-split platform analysis + remove IDLE pill
ea58237 Serving DU Check: replace legacy gNB-A/B ownership with F1-split DU0/DU1 check
e44aabb Dashboard: remove separate Latest Action Output / Recent Evidence Runs panel
231d5b1 Real modulation profiles dashboard: fix result display + reference KPIs
```

Files modified across the session:
```
web-dashboard/app.py                          (ownership, report, real-slice route)
web-dashboard/templates/index.html            (panel removal, Serving DU card, Phase 3 output)
web-dashboard/static/mixed-du-handover.js     (full modulation profile section rewrite)
web-dashboard/static/dashboard-inline.js      (Phase 2/3 output target, IDLE pill, Phase 3 JS)
web-dashboard/static/dashboard-status-live.js (runsTable null guard)
web-dashboard/radio_profile_api.py            (REFERENCE_ROWS, /results update)
web-dashboard/radio-profile-results.json      (stale netem entries cleared; live qam16 run added)
```
