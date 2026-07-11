# O-RAN E2E Testbed — oran-e2e-freeze

Single-node 5G SA testbed: Open5GS core + OAI F1-split RAN (CU + DU0 + DU1) + 5 UEs, RFsim.
Dashboard at **http://oran-lab:18080** (Flask, port 18080).

---

## Repository Layout

```
oran-e2e-freeze/
├── attic/              # Archived legacy files (git-mv; restore with git mv attic/... <path>)
│   └── pre-f1-ran/     # Monolithic-gNB era artefacts (superseded May 2026)
├── config/             # UE fleet definition (ues.yaml — used by scripts/ue/uectl.sh)
├── docs/               # Validation evidence (DO NOT MOVE; only add files here)
│   ├── baselines/      # Stable baseline snapshots
│   ├── old-handover-backup/
│   ├── proofs/
│   └── *.md            # Per-feature validation docs + session reports
├── manifests/
│   ├── core/           # Open5GS 5G SA manifests (AMF, SMF, UPF, MongoDB)
│   ├── network/        # Multus net-attach definitions (N2, N3 bridges)
│   └── ran/
│       ├── f1/         # Current CU/DU configs (cu.conf, du0.conf, du1.conf, f1-ran.yaml)
│       ├── mixed-du-live/   # Live-synced cluster manifests (source of truth for UE1-5 + DU deploys)
│       ├── multi-ue/   # Generated UE2-5 ConfigMap stubs (output of generate-5ue-manifests.sh)
│       └── nrue.lab.conf    # UE key/opc source for generate-5ue-manifests.sh
├── monitoring/
│   └── grafana/        # Grafana dashboard JSON definitions
├── scripts/
│   ├── dashboard/      # Section-level test scripts (test-section-01 to 07, audit)
│   ├── frequency/      # Carrier retune + frequency profile switching
│   ├── handover/       # Mixed-DU handover (switch-ue-du-target.sh, recover-mixed-du-state.sh)
│   ├── multi-ue/       # (placeholder)
│   ├── radio/          # Modulation profile switching (switch-ue-modulation-profile-du-aware.sh)
│   ├── slicing/        # S-NSSAI slice switching + traffic (switch-ue-slice.sh, run-real-slice-traffic.sh)
│   ├── traffic/        # Traffic API server (port 5055) + realistic scenario scripts
│   └── ue/             # UE management (ue-common.sh, generate-5ue-manifests.sh, uectl.sh)
├── web-dashboard/      # Flask dashboard (port 18080)
│   ├── actions/        # Shell scripts called by Flask APIs (f1_status.sh, f1_handover.sh, …)
│   ├── static/         # CSS (style.css — single file) + JavaScript modules
│   └── templates/      # index.html
├── CLAUDE.md           # Safety rules (11 rules + known risks — READ BEFORE TOUCHING CLUSTER)
├── run-web-dashboard.sh
└── stop-web-dashboard.sh
```

---

## Operational Quick Reference

### Start / stop dashboard

```bash
# Stop any running instance
./stop-web-dashboard.sh

# Start (does not self-detach — use nohup for background)
nohup ./run-web-dashboard.sh > /tmp/dash.log 2>&1 &

# Verify
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18080/   # → 200
```

### Start traffic API (required for Phase-2 scenarios + KPI table)

```bash
./scripts/traffic/start-traffic-api.sh          # starts on port 5055
curl -s http://127.0.0.1:5055/api/traffic/health # → {"ok":true}
# Stop:
./scripts/traffic/stop-traffic-api.sh
```

### Health gate after any core/CU restart

```bash
# Diagnose only (read-only, safe):
./scripts/recover-ue-sessions.sh

# Fix stranded UEs:
./scripts/recover-ue-sessions.sh --fix
```

### Full scenario sweep

```bash
./scripts/traffic/test-all-scenarios.sh
```

### Deploy / restore RAN (F1-split)

```bash
./scripts/deploy-f1-ran.sh        # Deploy CU + DU0 + DU1 from manifests/ran/f1/
./scripts/validate-f1-ran.sh      # Validate F1 topology is healthy
./scripts/validate-e2e.sh         # End-to-end tunnel + ping check
```

### Full platform start / stop

```bash
./scripts/platform-start.sh       # Scale up all namespaces + start dashboard
./scripts/platform-stop.sh        # Scale down all namespaces + stop dashboard
```

---

## Key Docs

| Document | What it covers |
|----------|---------------|
| `CLAUDE.md` | **Safety rules** — read before any cluster mutation |
| `attic/README.md` | Legacy file index + restore instructions |
| `docs/repo-inventory-20260612.md` | Full file inventory with ACTIVE / LEGACY verdicts |
| `docs/validation/modulation-scenarios-validation.md` | Real forced-MCS profiles (QPSK/16/64QAM verified) |
| `docs/validation/frequency-scenarios-validation.md` | Carrier retune + frequency KPI validation |
| `docs/validation/phase3-real-slice-traffic-validation.md` | S-NSSAI slice admission + traffic results |
| `docs/validation/ue1-du-aware-handover-validation.md` | UE1 DU0↔DU1 switchover validation |
| `docs/dashboard-full-test-report-2026-06-11.md` | Full dashboard API sweep + bug triage |

---

## Platform Identity

- PLMN **999/70**, DNN **oai**, 5 UEs (IMSI `999700000000001`–`005`)
- AMF NGAP: `10.10.0.101:38412` — UPF GTP-U: `10.20.0.101:2152`
- UE1 baseline: DU0, SST=1 — UE2–UE5: DU1, SST=1
- Known risk: CU segfaults intermittently (exit 139, ~4–5/day); run `recover-ue-sessions.sh --fix` (~30 s)
