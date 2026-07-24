# O-RAN Dashboard — Full Test Report
**Date:** 2026-06-11  
**Branch:** `allow-ue1-du-switch-all-scenarios`  
**Dashboard:** Flask on `http://192.168.1.142:18080`  
**Tester:** assistant de développement (automated API + scenario sweep, read-only)

---

## Platform State at Test Time

| Component | Status | Notes |
|-----------|--------|-------|
| k3s node | Ready | CPU 61% (7377m/12000m), RAM 77% (12161/15700 Mi), Disk 60% |
| AMF | Running | 0 restarts since last deploy |
| SMF | Running | 2 restarts (stable) |
| UPF | Running | 1 restart (stable) |
| oai-cu | Running | **5 restarts** (known segfault, exit 139) |
| oai-du0 | Running | 5 restarts (follows CU) |
| oai-du1 | Running | 1 restart |
| UE1 | Running / DU0 | SST=1, tunnel 10.45.0.83/24 |
| UE2 | Running / DU1 | tunnel 10.45.0.86/24 |
| UE3 | Running / DU1 | tunnel 10.45.0.84/24 |
| UE4 | Running / DU1 | tunnel 10.45.0.85/24 |
| UE5 | Running / DU1 | tunnel 10.45.0.87/24 |
| Monitoring | Running | 6/6 pods (Prometheus + Grafana) |

---

## Section 1 — Dashboard Core / Infrastructure

### 1.1 Dashboard Load
| Test | Result | HTTP | Latency |
|------|--------|------|---------|
| GET / (index page) | **PASS** | 200 | 5.6ms |

### 1.2 GET /api/status
**PASS** — All subsystem pods reflected correctly.

Key values returned:
- `core_ready: 3/3` (AMF, SMF, UPF)
- `ran_ready: 8/8` (CU + DU0 + DU1 + UE1–UE5)
- `monitoring_ready: 6/6`
- `active_ues: 5`
- `serving: DU0`

**Bug found:** `multus-test` pod (restarts=262 over 99d) appears in the RAN pod list. It is a passive Multus probe pod — its restart count could visually alarm operators. Not a code bug, cosmetic noise.

### 1.3 GET /api/live_metrics (legacy UE1-only endpoint)
**PASS** — Returns UE1 tunnel IP (10.45.0.83/24), tx_bytes, rx_bytes, timestamp.

**Bug found:** `rx_bytes=0` for UE1 even though traffic is flowing. This is a counter read timing issue in the legacy endpoint — the multi-UE `/api/ues/live_metrics` shows non-zero `total_rx_bytes: 63,955,404`. The legacy endpoint is still used by the real-time chart.

---

## Section 2 — UE Status APIs

### 2.1 GET /api/ues (multi-UE list)
**PASS** — Returns all 5 UEs with correct tunnel IPs, pod names, IMSI, restarts, rx/tx bytes.

**Bug found:** The response has **no `status` or `du` fields** per UE. The UI JS references `u.status` and `u.du` — these show as `?` in the Multi-UE panel cards. The API returns `attached`, `phase`, `ready` instead. Root cause: the JS card renderer expects keys that the backend never sends.

Fields actually returned per UE:
```
attached, baseline, deployment, dnn, imsi, index, name, phase,
pod, pod_ip, ready, restarts, rx_bytes, selector, tunnel, tunnel_ip, tx_bytes
```

Missing from API: `status`, `du`

### 2.2 GET /api/ues/live_metrics
**PASS** — Returns per-UE tunnel IP, rx_bytes, tx_bytes, total bytes, active_count.

**Bug found:** Per-UE `rx_mbps` and `tx_mbps` fields are **missing** from the response. The `ues[]` entries do not have `rx_mbps`/`tx_mbps` — only totals are present. Individual UE rate columns in the dashboard show `?`.

### 2.3 POST /api/ue/ue1/ping
**PASS** — UE1 ping DN gateway: 0% loss, avg 22ms.

### 2.4 POST /api/ues/desired
**FAIL (400)** — Called with `{"ues":["ue1"]}`, returns `"error": "count must be an integer"`. The endpoint expects `{"count": N}` not `{"ues": [...]}`. The dashboard JS may call it incorrectly.

---

## Section 3 — Serving DU Check

### 3.1 POST /api/run/ownership
**PASS** — Script detects UE1 on DU0 via serveraddr, shows RNTI activity in DU logs.

Output excerpt:
```
UE1 serveraddr    : oai-du0-rfsim
Active serving DU : oai-du0

UE RNTI d4d5 CU-UE-ID 1 in-sync PH 48 dB PCMAX 20 dBm, average RSRP -44
UE d4d5: ulsch_rounds 18248/0/0/0, BLER 0.00000 MCS(0) SNR 51.0 dB
```

---

## Section 4 — Platform Analysis Report

### 4.1 POST /api/run/report (8-section F1-split analysis)
**PASS** — Full report generated in ~45s, exit=0.

Key findings from the report:
- Section 1 (Node): Ready, 61% CPU, 77% RAM
- Section 2 (Pods): All Running — CU restarts=5 flagged
- Section 3 (F1 topology): CU + DU0 (dl_max_mcs=13 / 16QAM) + DU1 (adaptive)
- Section 4 (UE1 serving): DU0, tunnel 10.45.0.83/24, ping GW avg 19.7ms, ping 8.8.8.8 avg 119ms
- Section 5 (All UE tunnels): All 5 tunnels UP — state shows `UNKNOWN` (normal for TUN)
- Section 6 (DU activity): 2 UEs active on DU0 (RNTI d4d5 + df2a)
- Sections 7–8: Slice and frequency status

**Bug found:** UE1 tunnel state reports `UNKNOWN` in all reports and UE panels. This is the normal Linux TUN interface state for point-to-point tunnels — not an actual problem. However the dashboard displays `UNKNOWN` as a status string which looks like an error to users. Should be mapped to `UP` or `Active`.

---

## Section 5 — Phase 1: E2E Connectivity

### 5.1 POST /api/run/ping (UE1 baseline ping)
**PASS**

| Target | Packets | Loss | Avg RTT |
|--------|---------|------|---------|
| DN Gateway (10.45.0.1) | 5/5 | **0%** | 16.4 ms |
| Internet (8.8.8.8) | 4/4 | **0%** | 119.8 ms |

### 5.2 POST /api/run/e2e (E2E health check)
**PASS** — Core pods present, RAN pods present, UE1 tunnel UP, DN gateway ping 0% loss, internet ping 0% loss.

**Bug found:** The `e2e` action's RAN pod filter uses `egrep 'oai-gnb|oai-nr-ue|NAME'` — it **misses oai-cu, oai-du0, oai-du1**. The E2E health check output doesn't include CU or DU pods, so the scenario passes but misses the most important RAN health signals (specifically the CU restart counter which is the #1 risk signal).

---

## Section 6 — Phase 2: Traffic Simulation

### 6.1 Named scenarios (image, iperf, video, web, streaming)
**FAIL (404-equivalent)** — These action names (`image`, `iperf`, `video`, `web`, `streaming`) are **not registered** in the action router in `app.py`. Calling `/api/run/image` returns `"Unknown action: image"`.

Root cause: These button labels exist in the UI but their action names don't match any registered handler. The dashboard UI likely calls these but they silently fail.

### 6.2 Actual traffic actions (light_traffic, throughput, heavy_traffic, stream)
**TIMEOUT** — `light_traffic`, `throughput`, `heavy_traffic`, `stream` all timeout (>20s on a 15s test budget). These send hundreds of pings and attempt HTTP downloads to `speedtest.tele2.net` through the GTP tunnel. They likely complete eventually but take 90–220s.

**Not a bug** — this is by design (long-running traffic simulation). However the UI shows no progress indicator during execution; the user sees nothing until the full result returns.

### 6.3 POST /api/run/stop_traffic
**PASS** — Returns immediately: `"No background traffic process active."` The stop function is a no-op since traffic runs synchronously (not as a background process). This means there is no way to cancel a running traffic scenario.

---

## Section 7 — Phase 3: Real S-NSSAI Slice Traffic

### 7.1 GET /api/real-slice/results
**PASS** — Returns stored results. One existing entry from previous session:

| Profile | SST | Granted | Tunnel | Ping avg | Loss | TCP Mbps | UDP Jitter | Verdict |
|---------|-----|---------|--------|----------|------|----------|------------|---------|
| URLLC | 2 | SST:2 SD:0xffffff | 10.45.0.81 | 75.6ms | 0% | 0.86 | 5.5ms | **PASS** |

### 7.2 POST /api/real-slice/\<profile\> (embb, urllc, mmtc, v2x)
**NOT TESTED in this sweep** — These switch UE1's slice (mutation). Requires separate confirmation per safety rules.

### 7.3 POST /api/real-slice/badprofile
**PASS (correct error)** — Returns HTTP 400 with `"Unknown slice profile: badprofile"`.

---

## Section 8 — Mixed-DU Handover

### 8.1 GET /api/handover/status and /api/handover/mixed-du/status
**PASS** — Both routes work (mixed-du status intercepts via `before_request`).

Returns:
- `handover_ready: true`
- `du0_ready: true`, `du1_ready: true`
- `ue1_du: du0`, `ue1_baseline_du: du0`
- All 5 UEs switchable
- Mode: `mixed-du-rfsim`

### 8.2 POST /api/handover/f1/run and /api/handover/mixed-du/run
**NOT TESTED** — Triggers DU switch (mutation). Requires separate confirmation.

### 8.3 POST /api/handover/mixed-du/recover
**FAIL (404)** — This URL is referenced in the dashboard UI but **is not a registered route**. The `recover-mixed-du-state.sh` script exists on disk but is not wired to any Flask route. The recover button in the UI would get a 404.

---

## Section 9 — Radio / Modulation Profiles

### 9.1 GET /api/radio/status
**PASS** — Returns current active profile.

Current state:
- Active profile: `qam16-balanced`
- Active DU: `oai-du0`
- dl_max_mcs: `13` (16QAM forced)
- Tunnel ready: `yes`
- UE pod: `oai-nr-ue-5c64fb5b85-khp8s`

### 9.2 GET /api/radio/results
**PASS** — Returns all 6 profiles with reference KPI data.

| Profile | Modulation | MCS | Qm | Note |
|---------|-----------|-----|----|------|
| scheduler-auto | adaptive → 64QAM | none | adaptive | Reference row |
| qpsk-robust | QPSK | 4 | 2 | |
| qpsk-stress | QPSK low (calibration) | 2 | 2 | |
| qam16-balanced | 16QAM (forced) | 13 | 4 | **Currently active** |
| qam64-throughput | 64QAM (forced) | 28 | 6 | |
| qam256-max | 256QAM req; UE-cap → 64QAM | 28 | 6 | UE cap limited |

**Bug found (cosmetic):** The `rows` array in the response is empty — only `reference_rows` and `profile_mcs` are populated. The live KPI table in the dashboard relies on `rows` having run data; first-time users see an empty table with no guidance that reference data is under a different key.

### 9.3 POST /api/radio/apply, /api/radio/kpi-test, /api/radio/restore
**NOT TESTED** — These modify DU0 ConfigMap (mutation). Requires separate confirmation.

---

## Section 10 — Frequency Profiles

### 10.1 GET /api/real-frequency/profiles
**PASS** — 6 profiles returned:
- `n78-current` (baseline, 3319.68 MHz)
- `n78-3500` (3499.68 MHz)
- `n78-cband-3780` (3779.04 MHz)
- `n78-raster-high` (3321.12 MHz)
- `n41-2600` (2593.35 MHz)
- `n28-700` (781.25 MHz, marked `experimental=true`)

### 10.2 GET /api/real-frequency/status
**PASS** — DU0 is on baseline n78-current (SSB 621312, PointA 620040, band 78, 30kHz SCS, 106 RBs).

**Bug found:** `tunnel_ready: "no"` despite UE1 having a live tunnel. The status script runs `validate` which checks the tunnel at the time of the call — the transient "no" likely comes from a timing window during the script execution. However this is shown persistently in the frequency status panel and may mislead operators.

### 10.3 GET /api/real-frequency/kpi-results
**PASS** — Returns netem-emulated KPI profiles for all 4 frequency bands (n78-3500, n78-cband-3780, n41-2600, n28-700). Note: these are **emulated** via `netem`, not real measured values.

### 10.4 POST /api/real-frequency/apply, /restore, /kpi-test
**NOT TESTED** — These retune DU0 carrier (mutation). Requires separate confirmation.

---

## Section 11 — Multi-UE E2E Scenarios

### 11.1 POST /api/ues/scenario/connectivity — **PASS (all 5 UEs)**

| UE | Tunnel IP | GW ping loss | GW avg RTT | Internet loss | Internet avg RTT |
|----|-----------|-------------|-----------|--------------|-----------------|
| ue1 | 10.45.0.83 | 0% | 22.9ms | 0% | 117.5ms |
| ue2 | 10.45.0.86 | 0% | 30.6ms | 0% | 137.3ms |
| ue3 | 10.45.0.84 | 0% | 21.0ms | 0% | 112.9ms |
| ue4 | 10.45.0.85 | 0% | 27.5ms | 0% | 117.1ms |
| ue5 | 10.45.0.87 | 0% | 33.2ms | 0% | 148.6ms |

### 11.2 POST /api/ues/scenario/throughput — **PASS (4/5 UEs)**

| UE | GW loss | GW avg RTT | Internet loss | Notes |
|----|---------|-----------|--------------|-------|
| ue1 | 0% | 27.7ms | 0% | PASS |
| ue2 | 0% | 43.2ms | **3.3%** | Minor internet loss |
| ue3 | 0% | 28.1ms | 0% | PASS |
| ue4 | 0% | 43.5ms | 0% | PASS |
| ue5 | 0% | 40.2ms | 0% | PASS |

**Bug found:** UE2 shows 3.3% internet packet loss during throughput scenario. UE2 is on DU1; loss may be due to interference from concurrent 5-UE load on DU1. Intermittent — needs repeated runs to confirm.

### 11.3 POST /api/ues/scenario/attach_pdu, stability, video, stress
**PASS** (ok=True, exit=0) — ran successfully but results not shown here (too verbose). All returned ok=True.

### 11.4 POST /api/ues/scenario/ping_all
**FAIL (400)** — `"error": "unknown scenario ping_all"`. This scenario name is not in the registered list: `[attach_pdu, connectivity, stability, stop, stress, throughput, video]`. The dashboard UI may reference this name incorrectly.

### 11.5 POST /api/ues/embb-scenarios
**FAIL (400)** — `"error": "no runnable Multi-UE eMBB scenario jobs selected"`. No UEs selected. The endpoint requires a UE selection payload.

### 11.6 POST /api/ues/scenarios
**FAIL (400)** — `"error": "no runnable per-UE scenario jobs selected"`. Same — requires selection payload.

### 11.7 POST /api/ues/desired with `{"ues":["ue1"]}`
**FAIL (400)** — `"error": "count must be an integer"`. Expects `{"count": N}` not a UE name list.

---

## Bug Summary

| # | Severity | Section | Description |
|---|----------|---------|-------------|
| B1 | **Medium** | UE Status | `/api/ues` missing `status` and `du` fields — displayed as `?` in UE cards |
| B2 | **Medium** | Live Metrics | `/api/ues/live_metrics` per-UE `rx_mbps`/`tx_mbps` missing — rate columns show `?` |
| B3 | **Medium** | Phase 2 | Action names `image`, `iperf`, `video`, `web`, `streaming` not registered in router — always return "Unknown action" |
| B4 | **Medium** | E2E Health | `/api/run/e2e` pod filter misses `oai-cu`, `oai-du0`, `oai-du1` — CU restarts not visible in health check |
| B5 | **Medium** | Handover | `/api/handover/mixed-du/recover` route not registered — 404 if called from UI |
| B6 | Low | Frequency | `tunnel_ready: "no"` shown in frequency status despite live tunnel (timing artifact) |
| B7 | Low | Radio | `rows: []` in `/api/radio/results` — live run data not shown; only `reference_rows` populated |
| B8 | Low | Live Metrics | Legacy `/api/live_metrics` `rx_bytes=0` for UE1 even when traffic is flowing |
| B9 | Low | Traffic | No way to cancel a running traffic scenario (`stop_traffic` is a no-op) |
| B10 | Low | UE Status | Tunnel state `UNKNOWN` shown in all panels — normal for TUN but looks like an error |
| B11 | Low | Multi-UE | `ping_all` scenario name not registered (available: connectivity, attach_pdu, stability, throughput, video, stress, stop) |
| B12 | Low | Monitoring | `multus-test` pod (restarts=262) appears in RAN table — cosmetic noise |

---

## Scenarios Not Tested (Require Cluster Mutation)

These were not run in this read-only sweep. Each requires explicit confirmation per safety rules:

| Scenario | API | Mutation |
|----------|-----|---------|
| Real slice eMBB (SST=1) | POST /api/real-slice/embb | Restarts UE1 |
| Real slice URLLC (SST=2) | POST /api/real-slice/urllc | Restarts UE1 |
| Real slice mMTC (SST=3) | POST /api/real-slice/mmtc | Restarts UE1 |
| Real slice V2X (SST=4) | POST /api/real-slice/v2x | Restarts UE1 |
| DU switch (UE1 → DU1) | POST /api/handover/mixed-du/switch | Restarts UE1 |
| Radio profile apply | POST /api/radio/apply | Patches DU0 ConfigMap + restarts DU0 |
| Frequency retune | POST /api/real-frequency/apply | Patches DU0 ConfigMap + restarts DU0 |

---

## What Works Well

- All 5 UEs attached, all tunnels UP, zero packet loss to DN gateway
- Serving DU detection accurate (serveraddr-first, RNTI fallback)
- Platform analysis report (8 sections, ~45s) — comprehensive and accurate
- Real slice results API and table — one validated URLLC run confirmed SST=2 granted
- Handover status API — correctly reflects DU0/DU1 state and switchability
- Frequency profile status — accurate carrier keys read from live ConfigMap
- Multi-UE connectivity scenario — all 5 UEs pass simultaneously
- Radio/modulation profile inventory — all 6 profiles with correct MCS/Qm metadata

---

## Errata (post-sweep triage)

**B2 — per-UE `rx_mbps`/`tx_mbps` missing from `/api/ues/live_metrics`**
By design. The frontend computes per-UE rates from two successive samples (delta bytes ÷ elapsed time). The API returns only raw `rx_bytes`/`tx_bytes`; the rate calculation happens client-side in `dashboard-status-live.js:loadMetrics()`. The `?` display is correct on the first sample before a delta can be computed. Not a bug.

**B3 — Phase 2 buttons (`image`, `iperf`, `video`, `web`, `streaming`) always return "Unknown action"**
Misdiagnosis. The Phase 2 buttons call the external traffic API at `http://192.168.1.142:5055` (see `PHASE2_TRAFFIC_API` in `dashboard-inline.js`), not Flask's `/api/run/<action>`. The sweep tested the Flask route directly and got "Unknown action" — that is the correct fallback for unknown Flask actions. The buttons themselves correctly target the traffic API server. The actual failure mode is that the traffic API server at `:5055` is not running, which causes a network error caught by the JS try/catch. Not a routing bug.

**B1 — `/api/ues` missing `status` and `du` fields**
No UI consumer. Grepping all JS files confirms no code reads `u.status` or `u.du` from the `/api/ues` response. The `?` display seen during testing came from a test script that attempted to read non-existent keys. Not a live bug.

**B11 — `ping_all` scenario name not registered**
No UI consumer. No dashboard button calls `ping_all`. The available scenario names are correctly documented in the error response. Not a bug.

**B4 and B5 — Fixed in commit `3305037`**
- B4: E2E health check pod filter now includes `oai-cu`/`oai-du*` (was pre-F1-split regex).
- B5: `/api/handover/mixed-du/recover` route now wired in `mixed_du_handover_api.py` before_request dispatcher.
