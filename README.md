# O-RAN E2E Testbed — oran-e2e

Single-node 5G SA testbed: Open5GS core + OAI E1/F1-split RAN (CU-CP + CU-UP + DU0 + DU1) + 5 UEs, RFsim.
Dashboard at **http://oran-lab:18080** (Flask, port 18080).

> **Do not run `kubectl apply -f manifests/` directly.**
> The RAN manifests (`ran/f1/f1-ran.yaml`, `ran/e1/e1-split.yaml`,
> `ran/multi-ue/*.yaml`) declare `replicas: 0` on purpose — the bring-up order
> matters (CU-CP → CU-UP → DU → UEs). Applying them directly scales the running
> components to zero. Use `scripts/bootstrap-platform.sh` (fresh host) or
> `scripts/platform-start.sh` (restart), which apply and then scale up in order.
> Several files under `manifests/core/` are Open5GS config fragments or Helm
> values, not Kubernetes objects, and will be rejected by `kubectl apply` — this
> is expected.
>
> `scripts/deploy-core.sh` is safe to run: the files under `manifests/core/` are
> byte-identical to the live cluster configuration. See "Core configuration —
> where each function reads from" in `docs/reference/DEPLOYMENT-GUIDE.md` for
> which ConfigMap each network function actually mounts.

Run artefacts (logs, verdicts, KPI summaries) are written **outside this repo**, under
`$HOME/oran-proof/` — the evidence root used by the dashboard actions and every
validation script (`web-dashboard/actions/common.sh`). Note that the `RUN_ROOT`
export in `web-dashboard/run-dashboard.sh` is inert — no Python module reads it;
the evidence root is derived from `$HOME` in code. The repo holds only curated evidence, under `docs/`.

---

## Repository Layout

```
oran-e2e/
├── config/             # UE fleet definition (ues.yaml — read by scripts/ue/uectl.sh)
├── docs/               # Validation evidence (DO NOT MOVE; only add files here)
│   ├── archive/        # Superseded reports + past inventories (kept for traceability)
│   ├── baselines/      # Stable baseline snapshots (pre-handover-debug E2E capture)
│   ├── proofs/         # PCAP evidence (E1AP / F1AP+RRC / N2 NGAP / N3 GTP-U) + README manifest
│   ├── reference/      # Deployment guide, topology, troubleshooting, file map, limitations
│   └── validation/     # Per-feature validation docs + session reports
├── manifests/
│   ├── core/           # Open5GS 5G SA manifests + live AMF/UPF captures (amf/smf/upf.yaml)
│   ├── network/        # Multus net-attach definitions (N2, N3 bridges)
│   └── ran/
│       ├── e1/         # CU-CP/CU-UP configs + deployments (cucp.conf, cuup.conf, e1-split.yaml)
│       ├── f1/         # DU configs + DU/rfsim deployments (du0.conf, du1.conf, f1-ran.yaml)
│       ├── mixed-du-live/   # Live-synced cluster manifests (source of truth for UE1-5 + DU deploys)
│       ├── multi-ue/   # Generated UE2-5 manifests (output of scripts/ue/generate-5ue-manifests.sh)
│       └── nrue.lab.conf    # UE1 config + key/opc source for generate-5ue-manifests.sh
├── monitoring/
│   └── grafana/dashboards/  # Grafana dashboard JSON
├── scripts/
│   ├── bootstrap-platform.sh    # Fresh-host full build (Steps 1-10, interactive)
│   ├── platform-start.sh / platform-stop.sh   # Restart path (state file in ~/.oran-lab)
│   ├── validate-f1-ran.sh / validate-e2e.sh   # Topology + end-to-end checks
│   ├── recover-ue-sessions.sh   # Diagnose-first UE session recovery (rule 2)
│   ├── dashboard/      # Dashboard + platform API audit (audit-dashboard-and-platform.sh)
│   ├── frequency/      # Carrier retune, FSPL band profiles, retune readiness audit
│   ├── handover/       # Mixed-DU handover (switch-ue-du-target.sh, recover-mixed-du-state.sh)
│   ├── radio/          # Modulation profile switching (switch-ue-modulation-profile-du-aware.sh)
│   ├── slicing/        # S-NSSAI slice switching + QoS profiles (switch-ue-slice.sh, …)
│   ├── traffic/        # Traffic API server (port 5055) + realistic scenario scripts
│   └── ue/             # UE management (ue-common.sh, generate-5ue-manifests.sh, uectl.sh)
├── tests/              # Section tests 01-07 + run-full-platform-acceptance.sh
├── web-dashboard/      # Flask dashboard (port 18080) + per-feature API modules
│   ├── actions/        # Shell scripts called by Flask APIs (f1_status.sh, validate_e2e.sh,
│   │                   #   collect_snapshot.sh, ci_ownership.sh, common.sh)
│   ├── static/         # CSS (style.css — single file) + JavaScript modules
│   └── templates/      # index.html
├── OPERATING-RULES.md           # Safety rules (11 rules + known risks — READ BEFORE TOUCHING CLUSTER)
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
curl -s http://127.0.0.1:5055/api/traffic/health # → {"ok":true,…}
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

### Section tests / acceptance suite

```bash
./tests/run-full-platform-acceptance.sh          # whole platform, never stops on first failure
./tests/test-section-01-baseline-e2e.sh          # 02-realistic-traffic, 03-real-slices,
                                                 # 04-radio-profiles, 05-multi-ue-embb,
                                                 # 06-mixed-du-handover, 07-final-regression
```

### Deploy / restore RAN (E1/F1 split)

There is **no single deploy script**. Three distinct paths:

```bash
# 1. Fresh host, whole platform (Steps 1-10, interactive checkpoints).
#    Guarded: aborts if oran-core already has pods. Never re-executed end-to-end
#    since consolidation — review its TODOs before first use.
./scripts/bootstrap-platform.sh

# 2. Restart an already-deployed platform (normal path).
#    platform-start.sh restores replica counts from ~/.oran-lab/platform-replicas.tsv,
#    which platform-stop.sh writes — so run a stop/start cycle once to seed it.
./scripts/platform-start.sh
./scripts/platform-stop.sh
```

```bash
# 3. RAN layer only, from repo manifests (bootstrap Step 8). All four Deployments
#    ship with replicas: 0 — scale in E1 order: CU-CP → CU-UP → DUs.
kubectl -n oran-ran create configmap oai-du0-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du0.conf --dry-run=client -o yaml | kubectl apply -f -
kubectl -n oran-ran create configmap oai-du1-f1-config \
  --from-file=gnb.conf=manifests/ran/f1/du1.conf --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f manifests/ran/e1/e1-split.yaml   # oai-cu-cp + oai-cu-up (+ their ConfigMaps)
kubectl apply -f manifests/ran/f1/f1-ran.yaml     # oai-du0 + oai-du1 + rfsim Services

kubectl -n oran-ran scale deploy/oai-cu-cp --replicas=1
kubectl -n oran-ran rollout status deploy/oai-cu-cp --timeout=180s
kubectl -n oran-ran scale deploy/oai-cu-up --replicas=1
kubectl -n oran-ran rollout status deploy/oai-cu-up --timeout=180s
kubectl -n oran-ran scale deploy/oai-du0 deploy/oai-du1 --replicas=1
```

```bash
# Validation (any path)
./scripts/validate-f1-ran.sh      # F1/E1 topology healthy
./scripts/validate-e2e.sh         # End-to-end tunnel + ping check
```

Step-by-step procedure with success criteria and a failure/fix table per step:
`docs/reference/DEPLOYMENT-GUIDE.md`.

---

## Key Docs

Grouped to match the client deliverables list: **Architecture Plateforme**,
**Guide Troubleshooting**, **Présentation & Démo**, **Rapport Tests E2E (captures
Wireshark)**. Read `OPERATING-RULES.md` before touching the cluster, whichever group
you came for.

### Safety — read first

| Document | What it covers |
|----------|---------------|
| `OPERATING-RULES.md` | 11 safety rules + known risks; platform identity, topology, band profiles, quick health check |

### Architecture Plateforme

| Document | What it covers |
|----------|---------------|
| `docs/reference/NETWORK-TOPOLOGY.md` | Logical UE→DU→CU→core diagram, `br-n2`/`br-n3` Multus subnets, fixed-IP and port table, UE↔DU mapping, PLMN/gNB identifiers, why DU deployments use `strategy: Recreate` |
| `docs/reference/what-is-real-vs-emulated.md` | The REAL/EMULATED boundary, feature by feature: real traffic, user plane, NAS/NGAP, F1 split, DU switching, slice admission, MCS forcing and carrier retune — versus the simulated RFsim channel and the `tc netem`/`tbf`-emulated per-band and per-slice performance deltas, with the evidence source for each claim |
| `docs/reference/SLICING-TRUTH.md` | What slicing actually does: SST=1-only cold-start baseline (by design), how multi-slice is activated, why `apply-real-snssai-slicing.sh` is blocked by default, the `tc`-emulated QoS profiles, and why success is an AMF-granted S-NSSAI rather than a tunnel |
| `docs/reference/FSPL-FREQUENCY-DEGRADATION.md` | The FSPL model behind per-band degradation: ΔPL/K math, n41 reference carrier, band coefficient table (n41 1.00 / n78 0.55 / n77 0.39), ceiling measurement, the `n78-current` vs `n78-3500` carrier ambiguity, and the opt-in `FSPL_CAP=1` path |
| `docs/reference/LIMITATIONS-AND-FUTURE-WORK.md` | Seven deliberate scoping decisions with their future-work path: single-node k3s, RFsim scope, config centralization, the pinned `2025.w45` image, absent CPU/memory limits on core/RAN pods, one gNB-ID shared across DUs, FSPL-derived shaping |
| `docs/reference/PROJECT-FILE-MAP.md` | Per-file inventory of the repository |

### Deployment

| Document | What it covers |
|----------|---------------|
| `docs/reference/DEPLOYMENT-GUIDE.md` | Full deployment procedure — companion to `scripts/bootstrap-platform.sh`, same steps with success criteria and a failure/fix table per step |

### Guide Troubleshooting

| Document | What it covers |
|----------|---------------|
| `docs/reference/TROUBLESHOOTING.md` | Symptom→cause→recovery for the recurring failures: CU segfault (exit 139), UE tunnels not re-forming after a restart, CU not NGAP-associated on cold start, registration rejected / no Allowed NSSAI, frequency and DU-switch restore, ConfigMap edits that never reach a pod, `kubectl apply` "object has been modified" |
| `docs/reference/cold-start-recovery.md` | The cold-start `Registration reject [9]` failure: stale-endpoint root cause across three hops, the proven manual ordered bring-up, and the ordering fix carried by `scripts/platform-start.sh` (`ensure_core_amf_ready`, gated by `ORAN_CORE_GATE`, settle time `ORAN_CORE_REGISTER_SETTLE`) with its verification procedure |

### Présentation & Démo

| Document | What it covers |
|----------|---------------|
| `docs/reference/demo-dry-run-checklist.md` | Click-by-click demo runbook: 15-minute pre-demo setup, a 7-step narrative with what each step proves, a PANIC BOX of mid-demo recoveries, post-demo baseline restore, and one-line answers to the likely questions |

### Rapport Tests E2E — evidence

| Document | What it covers |
|----------|---------------|
| `docs/proofs/README.md` | **PCAP evidence manifest** — E1AP CU-UP setup, F1AP setup + full RRC attach, N2 NGAP registration, N3 GTP-U user plane: per-frame walkthrough, address map, what to point a jury at, and why two pre-E1 captures were excluded |
| `docs/validation/modulation-scenarios-validation.md` | Real forced-MCS profiles (QPSK/16/64QAM verified) |
| `docs/validation/frequency-scenarios-validation.md` | Carrier retune + frequency KPI validation |
| `docs/validation/phase3-real-slice-traffic-validation.md` | S-NSSAI slice admission + traffic results |
| `docs/validation/ue1-du-aware-handover-validation.md` | UE1 DU0↔DU1 switchover validation |
| `docs/archive/repo-inventory-20260612.md` | June 2026 file inventory with ACTIVE / LEGACY verdicts |
| `docs/archive/dashboard-full-test-report-2026-06-11.md` | Full dashboard API sweep + bug triage |

---

## Platform Identity

- PLMN **999/70**, DNN **oai**, 5 UEs (IMSI `999700000000001`–`005`)
- AMF NGAP: `10.10.0.101:38412` — UPF GTP-U: `10.20.0.101:2152`
- UE1 baseline: DU0, SST=1 — UE2–UE5: DU1, SST=1
- Known risk: CU segfaults intermittently (exit 139, ~4–5/day); run `recover-ue-sessions.sh --fix` (~30 s)
