# attic/ — Archived Legacy Artefacts

Files here have been archived with `git mv` so full history is preserved.
A file in `attic/` is never permanently deleted — restore is a single command.

**Restore any file:**
```bash
git mv attic/pre-f1-ran/<filename> <original-path>
git commit -m "Restore <filename> from attic"
```

---

## attic/pre-f1-ran/

These files belong to the **monolithic gNB era** — before the F1-split (CU+DU0+DU1) was
deployed in May 2026. The platform now runs an F1-split topology and these files are no
longer needed for day-to-day operations.

### Archived files

| File in attic/ | Original path | Why archived | Notes |
|---------------|--------------|--------------|-------|
| `gnb.lab.conf` | `manifests/ran/gnb.lab.conf` | Monolithic gNB OAI config. Only reference was `deploy-ran.sh` (co-archived). | Superseded by `manifests/ran/f1/cu.conf` + `du0.conf` + `du1.conf` |
| `oai-gnb-configmap-live.yaml` | `manifests/ran/oai-gnb-configmap-live.yaml` | Live-snapshot of monolithic gNB ConfigMap. No live references. | For historical reference only |
| `oai-gnb-deploy-live.yaml` | `manifests/ran/oai-gnb-deploy-live.yaml` | Live-snapshot of monolithic gNB Deployment. No live references. | For historical reference only |
| `oai-nr-ue-deploy-live.yaml` | `manifests/ran/oai-nr-ue-deploy-live.yaml` | Live-snapshot of monolithic UE1 Deployment (single-gNB era). No live references. | Superseded by `manifests/ran/mixed-du-live/deploy-oai-nr-ue.yaml` |
| `oai-nrue-configmap-live.yaml` | `manifests/ran/oai-nrue-configmap-live.yaml` | Live-snapshot of monolithic UE1 ConfigMap. No live references. | Superseded by `manifests/ran/mixed-du-live/cm-oai-nrue-config.yaml` |
| `oai-nr-ue-rfsim-svc.yaml` | `manifests/ran/oai-nr-ue-rfsim-svc.yaml` | RFsim service for monolithic gNB. Only reference was `deploy-ran.sh` (co-archived). | Superseded by `manifests/ran/mixed-du-live/svc-oai-du0-rfsim.yaml` + `svc-oai-du1-rfsim.yaml` |
| `deploy-ran.sh` | `scripts/deploy-ran.sh` | Monolithic gNB+UE deploy script (pre-F1-split). References cleared: `recover_ran.sh` and `recover_full.sh` co-archived; `README.md` updated to reference `deploy-f1-ran.sh`. | Current equivalent: `scripts/deploy-f1-ran.sh` |
| `rollback-to-monolithic-ran.sh` | `scripts/rollback-to-monolithic-ran.sh` | **Deliberate escape hatch.** Archives the procedure to rollback from F1-split to monolithic gNB in an emergency. No live references from API or active scripts. | **HOW TO USE IF NEEDED:** Restore with `git mv attic/pre-f1-ran/rollback-to-monolithic-ran.sh scripts/rollback-to-monolithic-ran.sh && git commit ...`. Then run `./scripts/rollback-to-monolithic-ran.sh`. It: (1) scales down CU/DU0/DU1, (2) patches UE1 back to `oai-gnb-rfsim` serveraddr, (3) cleans stale Multus/CNI leases, (4) starts the monolithic `oai-gnb` deployment. Also restore `deploy-ran.sh` and `gnb.lab.conf` to regenerate the gNB ConfigMap. |
| `switch-to-f1-rfsim.sh` | `scripts/switch-to-f1-rfsim.sh` | One-shot migration script used to transition the platform FROM monolithic gNB TO F1-split. Applied `k8s/f1-rfsim/f1-ran.yaml`. Platform is already F1; this script is no longer needed. No live references. | Applied on 2026-05-17 |
| `k8s-f1-rfsim/` | `k8s/f1-rfsim/` | Initial F1-split Kubernetes manifest set (CU, DU0, DU1 Deployments + Services, initial conf files). Only reference was `switch-to-f1-rfsim.sh` (co-archived). Superseded by `manifests/ran/f1/` (configs) and `manifests/ran/mixed-du-live/` (live-synced deploys). | Files: `f1-ran.yaml`, `gnb-cu.sa.f1.conf`, `gnb-du0/du1.sa.band78.106prb.rfsim.conf` |
| `actions-recover_ran.sh` | `web-dashboard/actions/recover_ran.sh` | Dashboard action script that called `deploy-ran.sh` to recover RAN. Not wired to any live Flask API endpoint. Stale because `deploy-ran.sh` deploys the monolithic gNB (wrong for the current F1 platform). | If a RAN recovery action is needed, wire `deploy-f1-ran.sh` via a new action or `platform-start.sh` |
| `actions-recover_full.sh` | `web-dashboard/actions/recover_full.sh` | Dashboard action script for full platform recovery (prepare-network + deploy-core + deploy-ran). Not wired to any live Flask API endpoint. Stale for same reason as `actions-recover_ran.sh`. | Full recovery workflow: run `./scripts/prepare-network.sh && ./scripts/deploy-core.sh && ./scripts/deploy-f1-ran.sh` manually |
