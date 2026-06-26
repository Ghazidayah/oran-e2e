# Repository Inventory — 2026-06-12

Generated before cleanup pass. Every tracked directory and file is listed with
its purpose, verdict, and (for LEGACY-candidates) what references it.

---

## Step 4 Health Sweep Results (2026-06-12)

All checks pass. No broken files.

| Check | Count | Result |
|-------|-------|--------|
| `bash -n` (shell scripts, excl. attic) | 64 scripts | ALL PASS |
| `python3 -m py_compile` | 8 Python files | ALL PASS |
| Executable bits (`+x`) | 64 scripts | ALL ALREADY SET |

BROKEN files: **none**.
KEEP-flagged items needing human decision: see Summary section at bottom.

**Verdicts:**
- **ACTIVE** — in use by live scripts or APIs; do not move
- **LEGACY-candidate** — superseded; scheduled for `attic/` in Step 2
- **KEEP-flagged** — has live references but looks potentially legacy; flagged for human decision
- **JUNK** — untracked disk artefact (pycache, log, gitignored patch); removed in Step 3

---

## Top-Level Directories

| Path | Purpose | Verdict |
|------|---------|---------|
| `config/` | UE deployment config (`ues.yaml`) | ACTIVE |
| `docs/` | Validation evidence, session reports | ACTIVE — protected, nothing moves |
| `k8s/` | Initial F1-split manifests (pre-mixed-du era) | LEGACY-candidate |
| `manifests/` | Core, network, and RAN manifests (mixed-du-live is source of truth) | ACTIVE |
| `monitoring/` | Grafana dashboard JSON | ACTIVE |
| `scripts/` | Platform scripts (see sub-inventory below) | Mixed |
| `web-dashboard/` | Flask dashboard app, action scripts, static assets | ACTIVE |
| `run-web-dashboard.sh` | Dashboard launcher | ACTIVE |
| `stop-web-dashboard.sh` | Dashboard stopper | ACTIVE |
| `CLAUDE.md` | Project safety rules (protected) | ACTIVE |
| `README.md` | Quick-reference (stale — updated in Step 6) | ACTIVE |
| `.gitignore` | Gitignore (incomplete — updated in Step 3) | ACTIVE |
| `.last-stable-baseline` | Baseline tag pointer | ACTIVE |
| `.last-stable-baseline-clean` | Baseline tag pointer | ACTIVE |

**Untracked / gitignored disk artefacts (removed in Step 3):**
| Path | Why junk |
|------|---------|
| `web-dashboard.log` | Empty runtime log; gitignored by `*.log` |
| `allow-ue1-du-switch-all-scenarios.patch` | Gitignored; content already applied to current branch |
| `web-dashboard/__pycache__/` | Python bytecode; gitignored |
| `scripts/traffic/__pycache__/` | Python bytecode; gitignored |

---

## k8s/ Directory

| Path | Purpose | Verdict |
|------|---------|---------|
| `k8s/f1-rfsim/` | Initial F1-split Kubernetes manifest set (CU, DU0, DU1, UE). Created during the F1 migration sprint; has since been superseded by `manifests/ran/f1/` (CU/DU configs) and `manifests/ran/mixed-du-live/` (live-synced). | LEGACY-candidate |

References to `k8s/f1-rfsim/`: only `scripts/switch-to-f1-rfsim.sh` (itself legacy).
**Archival plan:** `attic/pre-f1-ran/k8s-f1-rfsim/` together with `switch-to-f1-rfsim.sh`.

---

## manifests/ Directory

### manifests/core/ — ACTIVE (Open5GS 5G SA core)
### manifests/network/ — ACTIVE (Multus bridge/net-attach definitions)

### manifests/ran/ — Mixed

| File / Dir | Purpose | Verdict |
|-----------|---------|---------|
| `f1/` | Current CU/DU configs (cu.conf, du0.conf, du1.conf, f1-ran.yaml, n28 FDD conf) | **ACTIVE** |
| `mixed-du-live/` | Live-synced cluster manifests (UE1-5 deploys + CMs, DU0/DU1 deploys, RFsim svcs) | **ACTIVE** — live sync target |
| `multi-ue/` | Generated UE2-5 ConfigMap+Deploy stubs output by `scripts/ue/generate-5ue-manifests.sh` | **ACTIVE** |
| `nrue.lab.conf` | UE1 base config (key/opc source); referenced by `scripts/ue/generate-5ue-manifests.sh` | **KEEP-flagged** — live reference from generate-5ue-manifests.sh; also referenced by `scripts/deploy-ran.sh` (legacy). Not removing until generate-5ue-manifests.sh is updated. |
| `gnb.lab.conf` | Monolithic gNB config. Predates F1 split. Referenced only by `scripts/deploy-ran.sh` (legacy). | LEGACY-candidate |
| `oai-gnb-configmap-live.yaml` | Live snapshot of monolithic gNB ConfigMap. No live script references (docs only). | LEGACY-candidate |
| `oai-gnb-deploy-live.yaml` | Live snapshot of monolithic gNB Deployment. No live script references (docs only). | LEGACY-candidate |
| `oai-nr-ue-deploy-live.yaml` | Live snapshot of monolithic UE1 Deployment (single-gNB era). No live script references. | LEGACY-candidate |
| `oai-nrue-configmap-live.yaml` | Live snapshot of monolithic UE1 ConfigMap. No live script references. | LEGACY-candidate |
| `oai-nr-ue-rfsim-svc.yaml` | RFsim service for monolithic gNB. Referenced only by `scripts/deploy-ran.sh` (legacy). | LEGACY-candidate |
| `multi-ue-rfsim-du0-live/` | Initial multi-UE manifests (UE2-5, DU0-targeted). Superseded by `mixed-du-live/`. No live script references. | LEGACY-candidate |

---

## scripts/ Top-Level

| File | Purpose | Verdict |
|------|---------|---------|
| `deploy-core.sh` | Deploy Open5GS core (Helm) | **ACTIVE** |
| `deploy-f1-ran.sh` | Deploy F1-split RAN (CU + DU0 + DU1) — **current** RAN deploy | **ACTIVE** |
| `deploy-ran.sh` | Deploy monolithic gNB + UE1 — pre-F1-split era. Referenced by: `README.md` (step 3), `web-dashboard/actions/recover_ran.sh`, `web-dashboard/actions/recover_full.sh`. All three referencing files are themselves legacy or will be fixed. | **LEGACY-candidate** |
| `platform-start.sh` | Scale up all namespaces + start dashboard + recover mixed-DU state | **ACTIVE** |
| `platform-stop.sh` | Scale down all namespaces + stop dashboard | **ACTIVE** |
| `prepare-network.sh` | Apply Multus network attachments | **ACTIVE** |
| `recover-ue-sessions.sh` | Diagnose-first UE session recovery (rule 2 of CLAUDE.md) | **ACTIVE** |
| `rollback-to-monolithic-ran.sh` | Emergency rollback to monolithic gNB. No live references. Deliberately designed escape hatch. | **LEGACY-candidate** — archived per task instructions with full restore doc in attic/README.md |
| `run-f1-du-switch-sequence.sh` | Automated DU0↔DU1 switch test sequence | **ACTIVE** |
| `switch-f1-du.sh` | Switch UE1 between DU0 and DU1 (RFsim serveraddr patch) | **ACTIVE** (referenced by run-f1-du-switch-sequence.sh and mixed-du handover scripts) |
| `switch-to-f1-rfsim.sh` | One-shot migration script: applied k8s/f1-rfsim/ to transition FROM monolithic TO F1. No live references; platform is already F1. | **LEGACY-candidate** |
| `validate-e2e.sh` | E2E tunnel + ping validation | **ACTIVE** |
| `validate-f1-ran.sh` | F1-split specific RAN validation | **ACTIVE** |

---

## scripts/ Subdirectories

### scripts/dashboard/ — ACTIVE
Full set of section-level dashboard test scripts (test-section-01 through 07) + audit.

### scripts/frequency/ — ACTIVE (with flagged items)

| File | Purpose | Verdict |
|------|---------|---------|
| `switch-ue-actual-frequency-retune-du-aware.sh` | **Carrier retune** — patches DU ConfigMap + UE args and restarts pods. Called by `real_frequency_api.py`. | **ACTIVE** |
| `switch-ue-frequency-profile-du-aware.sh` | **Profile-based freq switch** (emulated via netem). Called by `frequency_profile_api.py`. | **ACTIVE** |
| `validate-n28-700-on-du0.sh` | n28 700 MHz FDD experiment validator. Referenced from `real_frequency_api.py`. | **ACTIVE** |
| `audit-actual-frequency-retune-readiness.sh` | Pre-flight audit tool. Not API-referenced; standalone diagnostic. | **KEEP-flagged** (useful debug tool; no references to remove) |
| `audit-frequency-control-readiness.sh` | Earlier readiness audit. Not API-referenced. | **KEEP-flagged** |
| `test-frequency-profile-cli.sh` | CLI test harness for profile switching. References `switch-ue-frequency-profile-du-aware.sh`. Not API-referenced. | **KEEP-flagged** |

### scripts/handover/ — ACTIVE
`recover-mixed-du-state.sh`, `switch-ue-du-target.sh`.

### scripts/multi-ue/ — ACTIVE (empty directory)
Placeholder for future multi-UE scripts. No files yet.

### scripts/radio/ — ACTIVE
`switch-ue-modulation-profile-du-aware.sh` (called by `radio_profile_api.py`),
`switch-ue-radio-profile-du-aware.sh` (legacy radio profile with netem; see validation doc).

### scripts/slicing/ — ACTIVE
`switch-ue-slice.sh`, `validate-current-slice.sh`, `run-real-slice-traffic.sh` (called from app.py),
`apply-real-snssai-slicing.sh`, `apply-slice-resource-profile.sh`,
`apply-phase4-qos-resource-profiles.sh`, `rollback-*` variants,
`install-real-slice-dashboard-buttons.sh` (install/migration script, not API-wired).

### scripts/traffic/ — ACTIVE
`traffic_api_server.py` (Port 5055 traffic API), `start-traffic-api.sh`,
`stop-traffic-api.sh`, `test-all-scenarios.sh`, `run-*.sh` scenario scripts.
`install-*.sh` scripts are installation/migration artefacts (not API-wired) — KEEP-flagged.

### scripts/ue/ — ACTIVE
`ue-common.sh` (shared UE library), `generate-5ue-manifests.sh` (uses `nrue.lab.conf`),
`provision-5ue-subscribers.sh`, `uectl.sh` (uses `config/ues.yaml`).

---

## web-dashboard/ Directory

### Python / templates / static — ACTIVE
`app.py`, `*_api.py` modules, `templates/index.html`, `static/*.css`, `static/*.js`,
`requirements.txt`, `run-dashboard.sh`.

### web-dashboard/actions/ — Mixed

| File | Purpose | Verdict |
|------|---------|---------|
| `common.sh` | Shared logging/path setup; sourced by all action scripts | **ACTIVE** |
| `f1_status.sh` | F1 topology status check; called by `handover_api.py` | **ACTIVE** |
| `f1_handover.sh` | F1 handover trigger; called by `handover_api.py` | **ACTIVE** |
| `recover_ran.sh` | Calls `deploy-ran.sh` (legacy) to restore monolithic RAN. Not wired to any live API endpoint. | **LEGACY-candidate** (archived with deploy-ran.sh in Step 2) |
| `recover_full.sh` | Calls `deploy-ran.sh` (legacy). Not wired to any live API endpoint. | **LEGACY-candidate** (archived with deploy-ran.sh in Step 2) |
| `ci_ownership.sh` | CI-era ownership check script. Not called from any live API endpoint or app.py. | **KEEP-flagged** — no live references but unclear if still needed |
| `collect_snapshot.sh` | Snapshot collection. Not called from live API. | **KEEP-flagged** |
| `ho_a_to_b.sh` | Handover A→B (early version). Not called from live API (handover_api.py calls f1_handover.sh directly). | **KEEP-flagged** |
| `ho_b_to_a.sh` | Handover B→A (early version). Not called from live API. | **KEEP-flagged** |
| `validate_e2e.sh` | E2E validation action. Not called from live API (app.py uses inline shell). | **KEEP-flagged** |

---

## config/ Directory

| File | Purpose | Verdict |
|------|---------|---------|
| `ues.yaml` | UE fleet definition (IMSIs, deployments, CMs). Referenced by `scripts/ue/uectl.sh`. | **ACTIVE** |

---

## Summary — Step 2 Archive Plan

Files to move to `attic/pre-f1-ran/`:
1. `manifests/ran/gnb.lab.conf` — only reference is deploy-ran.sh (co-archived)
2. `manifests/ran/oai-gnb-configmap-live.yaml` — docs-only references
3. `manifests/ran/oai-gnb-deploy-live.yaml` — docs-only references
4. `manifests/ran/oai-nr-ue-deploy-live.yaml` — no live references
5. `manifests/ran/oai-nrue-configmap-live.yaml` — no live references
6. `manifests/ran/oai-nr-ue-rfsim-svc.yaml` — only reference is deploy-ran.sh (co-archived)
7. `manifests/ran/multi-ue-rfsim-du0-live/` (full dir) — superseded by mixed-du-live/
8. `scripts/deploy-ran.sh` — monolithic gNB deploy; co-archiving all references
9. `scripts/rollback-to-monolithic-ran.sh` — deliberate escape hatch; documented in attic/README.md
10. `scripts/switch-to-f1-rfsim.sh` — one-shot migration script; already applied
11. `k8s/f1-rfsim/` (full dir) — only reference is switch-to-f1-rfsim.sh (co-archived)
12. `web-dashboard/actions/recover_ran.sh` — calls deploy-ran.sh (co-archived)
13. `web-dashboard/actions/recover_full.sh` — calls deploy-ran.sh (co-archived)

README.md `deploy-ran.sh` reference patched to `deploy-f1-ran.sh` in same Step 2 commit.

Files kept with flags for human review:
- `manifests/ran/nrue.lab.conf` — live reference from generate-5ue-manifests.sh
- `config/ues.yaml` — live reference from uectl.sh
- `web-dashboard/actions/ci_ownership.sh`, `collect_snapshot.sh`, `ho_a_to_b.sh`, `ho_b_to_a.sh`, `validate_e2e.sh` — not API-wired; unclear if still needed
- `scripts/frequency/audit-*.sh`, `test-frequency-profile-cli.sh` — standalone tools; not API-wired
- `scripts/traffic/install-*.sh` — install-era migration scripts; not API-wired
- `scripts/slicing/install-real-slice-dashboard-buttons.sh` — install-era; not API-wired
