# Repo Restructure Plan — DEFERRED (post-defense work)

> **STATUS: NOT APPLIED. Do not execute any part of this plan before the PFE
> defense.** The platform is frozen and validated; these moves touch runtime
> paths (manifests, the traffic API service, dashboard blueprints) and each one
> requires the full validation gate below before merge.

Written 2026-07-11 on branch `cleanup-final-state`. The zero-risk subset
(empty-dir removal, `.gitignore` fix, `gather-report-data.sh` move,
`docs/reference/` + `docs/validation/` split) was applied the same day and is
**not** part of this plan. Every "references to update" list below was produced
by grepping the repo on 2026-07-11; re-run the greps before executing, in case
files changed after the freeze.

---

## Part A — `manifests/ran/` renames

### Target layout

```
manifests/ran/
├── cu/          ← rename of e1/        (CU-CP + CU-UP, E1 split)
├── du/          ← rename of f1/        (DU configs + F1 RAN deployment)
├── ue/          ← rename of multi-ue/  (UE2–UE5 deployment manifests)
├── handover/    ← rename of mixed-du-live/ (live mixed-DU overlays + rfsim services)
└── nrue.lab.conf                        (unchanged, stays at ran/ root)
```

### Files affected (contents as of 2026-07-11)

| Current dir | Contents | Destination |
|---|---|---|
| `manifests/ran/e1/` | `cucp.conf`, `cuup.conf`, `e1-split.yaml` | `manifests/ran/cu/` |
| `manifests/ran/f1/` | `du0.conf`, `du1.conf`, `f1-ran.yaml` | `manifests/ran/du/` |
| `manifests/ran/multi-ue/` | `oai-nr-ue-2.yaml` … `oai-nr-ue-5.yaml` | `manifests/ran/ue/` |
| `manifests/ran/multi-ue-rfsim-du0-live/` | **empty** | delete (no move needed) |
| `manifests/ran/mixed-du-live/` | `cm-oai-nrue-config{,-2..-5}.yaml`, `deploy-oai-du{0,1}.yaml`, `deploy-oai-nr-ue{,-2..-5}.yaml`, `svc-oai-du{0,1}-rfsim.yaml` | `manifests/ran/handover/` |

### References to update (grep-verified 2026-07-11)

| File:line | Current reference | New reference |
|---|---|---|
| `scripts/platform-start.sh:242` | `manifests/ran/e1/e1-split.yaml` | `manifests/ran/cu/e1-split.yaml` |
| `scripts/ue/uectl.sh:59` | `kubectl apply -f manifests/ran/multi-ue/` | `manifests/ran/ue/` |
| `scripts/ue/uectl.sh:69` | `manifests/ran/multi-ue/${dep}.yaml` | `manifests/ran/ue/${dep}.yaml` |
| `scripts/ue/generate-5ue-manifests.sh:5` | `OUT_DIR="manifests/ran/multi-ue"` | `OUT_DIR="manifests/ran/ue"` |
| `scripts/gather-report-data.sh:32` | `manifests/ran/f1/du0.conf manifests/ran/f1/du1.conf` | `manifests/ran/du/...` |
| `scripts/gather-report-data.sh:34` | `manifests/ran/mixed-du-live/*.yaml` | `manifests/ran/handover/*.yaml` |
| `web-dashboard/multi_ue_api.py:28,37,46,55` | `manifests/ran/multi-ue/oai-nr-ue-{2..5}.yaml` | `manifests/ran/ue/...` |
| `OPERATING-RULES.md:51` | Safety Rule 5: baseline lives in `manifests/ran/f1/du0.conf` | `manifests/ran/du/du0.conf` — **must be edited in the same commit; this is the DU0 restore-source rule** |
| `README.md:93` | "Deploy CU + DU0 + DU1 from `manifests/ran/f1/`" | `manifests/ran/du/` |
| `docs/reference/PROJECT-FILE-MAP.md:98,101,104,107` | `manifests/ran/multi-ue/oai-nr-ue-{2..5}.yaml` | `manifests/ran/ue/...` |
| `docs/reference/LIMITATIONS-AND-FUTURE-WORK.md:140` | `manifests/ran/f1/du0.conf` | `manifests/ran/du/du0.conf` |

Comment-only (cosmetic, fix opportunistically):
`manifests/ran/e1/cucp.conf:2` and `manifests/ran/e1/e1-split.yaml:12` say
"Derived from `manifests/ran/f1/cu.conf`" — that file does not exist today
(pre-existing stale comment).

### Risk notes

- These manifests are the **restore source for live DU/UE configmaps**
  (OPERATING-RULES.md rules 5 and 8). Nothing on the cluster references the repo paths,
  so the rename cannot break running pods — but every recovery procedure and
  doc that names the old path must land in the same commit, or an operator
  following TROUBLESHOOTING/OPERATING-RULES.md during an outage will hit a dead path.
- Use `git mv` for every file so history follows.

---

## Part B — `traffic-api/` extraction

`scripts/traffic/traffic_api_server.py` is a long-running Flask service
(port 5055), not a script. It moves to a top-level service directory; the
`run-*.sh` scenario scripts it invokes **stay** in `scripts/traffic/`.

### Target layout

```
traffic-api/
├── server.py    ← from scripts/traffic/traffic_api_server.py
├── start.sh     ← from scripts/traffic/start-traffic-api.sh
└── stop.sh      ← from scripts/traffic/stop-traffic-api.sh
```

### Internal changes required in the moved files

- `start.sh`: launch line is currently
  `nohup web-dashboard/.venv/bin/python scripts/traffic/traffic_api_server.py`
  → becomes `... traffic-api/server.py`. Decide whether to keep borrowing the
  dashboard venv or give `traffic-api/` its own `requirements.txt` (flask only).
- `start.sh:9` and `stop.sh:6,11`: `pkill -f "traffic_api_server.py"` — the
  match pattern **must change** to the new filename (`traffic-api/server.py`),
  otherwise stop.sh silently stops matching and start.sh stacks duplicate
  servers on port 5055.
- `server.py` needs **no** path changes: `REPO = Path.home()/"oran-e2e"`
  is home-anchored, and the `SCENARIOS` dict paths
  (`scripts/traffic/run-*.sh`) remain valid because those scripts do not move.

### References to update (grep-verified 2026-07-11)

| File:line | Current reference |
|---|---|
| `scripts/platform-start.sh:166` | `starter="$ROOT_DIR/scripts/traffic/start-traffic-api.sh"` |
| `scripts/platform-start.sh:167` | warn message naming `start-traffic-api.sh` |
| `scripts/traffic/test-all-scenarios.sh:33,39` | `$REPO/scripts/traffic/start-traffic-api.sh` |
| `scripts/dashboard/audit-dashboard-and-platform.sh:83` | required-file list: `scripts/traffic/traffic_api_server.py` |
| `scripts/dashboard/audit-dashboard-and-platform.sh:118,119` | `bash -n` list: start/stop-traffic-api.sh |
| `scripts/dashboard/audit-dashboard-and-platform.sh:323` | warn text naming `scripts/traffic/start-traffic-api.sh` |
| `README.md:68,71` | start/stop commands |
| `docs/reference/demo-dry-run-checklist.md:21,111` | `./scripts/traffic/start-traffic-api.sh` |

### Contract to preserve

- Port **5055** and all `/api/traffic/*` routes are consumed by
  `web-dashboard/static/dashboard-inline.js:603`
  (`PHASE2_TRAFFIC_API = "http://192.168.1.142:5055"`) and by
  `web-dashboard/traffic_kpi_api.py` (reads the same
  `~/oran-proof/phase2-traffic-api/` job dirs from disk). Neither changes.

---

## Part C — `web-dashboard/api/` package

### Target layout

```
web-dashboard/
├── app.py
├── api/
│   ├── __init__.py            (new, empty)
│   ├── handover_api.py
│   ├── mixed_du_handover_api.py
│   ├── multi_ue_api.py
│   ├── radio_profile_api.py
│   ├── real_frequency_api.py
│   └── traffic_kpi_api.py
├── actions/                    (stays at web-dashboard/ root)
├── static/  templates/
└── *.json result files         (stay at web-dashboard/ root)
```

### References to update — imports

| File:line | Current | New |
|---|---|---|
| `web-dashboard/app.py:9` | `from multi_ue_api import register_multi_ue_routes` | `from api.multi_ue_api import ...` |
| `web-dashboard/app.py:10` | `from handover_api import handover_bp` | `from api.handover_api import ...` |
| `web-dashboard/app.py:11` | `from radio_profile_api import radio_bp` | `from api.radio_profile_api import ...` |
| `web-dashboard/app.py:12` | `from real_frequency_api import real_freq_bp` | `from api.real_frequency_api import ...` |
| `web-dashboard/app.py:13` | `from traffic_kpi_api import traffic_kpi_bp` | `from api.traffic_kpi_api import ...` |
| `web-dashboard/app.py:1052` | `from mixed_du_handover_api import install_mixed_du_handover_api` | `from api.mixed_du_handover_api import ...` |

### References to update — `__file__`-derived paths (THE trap in this move)

Four blueprints compute paths from their own file location; moving them one
directory deeper silently shifts every derived path:

| File:line | Current expression | Breakage after move | Fix |
|---|---|---|---|
| `handover_api.py:8-10` | `BASE_DIR = dirname(__file__)`; `REPO_DIR = BASE_DIR/".."`; `ACTIONS_DIR = BASE_DIR/"actions"` | `REPO_DIR` → `web-dashboard/` (not repo root); `ACTIONS_DIR` → nonexistent `api/actions/` | re-anchor: `REPO_DIR = parents[2]`, `ACTIONS_DIR = parents[1]/"actions"` |
| `real_frequency_api.py:12` | `REPO = Path(__file__).parents[1]` (fallback when `ORAN_REPO` unset) | resolves to `web-dashboard/` | `parents[2]` |
| `real_frequency_api.py:14-15` | `RESULTS_FILE` / `KPI_RESULTS_FILE` = `with_name(...)` | JSON files expected inside `api/` | anchor to `parents[1]` (web-dashboard root) |
| `mixed_du_handover_api.py:16` | `REPO = Path(__file__).parents[1]` | resolves to `web-dashboard/` | `parents[2]` |
| `multi_ue_api.py:8` | `MULTI_UE_RESULTS_FILE = with_name("multi-ue-results.json")` | file expected inside `api/` | anchor to `parents[1]` |

Safe as-is (home- or env-anchored, no `__file__` dependence):
`radio_profile_api.py:12-13`, `traffic_kpi_api.py:8`, `app.py:15-16`.

### References to update — external path mentions

| File:line | Current reference |
|---|---|
| `scripts/dashboard/audit-dashboard-and-platform.sh:76,77,78` | required-file list: `web-dashboard/{radio_profile,mixed_du_handover,multi_ue}_api.py` |
| `scripts/dashboard/audit-dashboard-and-platform.sh:98,99,100` | `python -m py_compile` list, same three files |
| `tests/test-section-05-multi-ue-embb.sh:116` | `web-dashboard/multi_ue_api.py` |
| `docs/reference/PROJECT-FILE-MAP.md:147` | `web-dashboard/multi_ue_api.py` |
| `scripts/traffic/install-multi-ue-embb-realistic-scenarios.sh:7,20,538,552` | one-shot installer that patches `multi_ue_api.py` in place — already applied; consider retiring it to `attic/` instead of updating |

Launcher (`run-web-dashboard.sh` → `cd web-dashboard && python3 app.py`) needs
no change: `app.py` stays put and `api/` is imported as a package from cwd.

---

## Validation gate (mandatory, per part — each part is its own commit)

1. `bash -n` on **every** `*.sh` in `scripts/`, `tests/`, `web-dashboard/actions/`,
   repo root (and `traffic-api/` once it exists) — zero syntax errors.
2. `tests/run-full-platform-acceptance.sh` passes end-to-end on the live
   platform.

Both must pass **before merge** of each part. Recommended extras (not gating):
dashboard smoke (`curl -s localhost:18080/` + one call per blueprint route
family), traffic API health (`curl -s localhost:5055/api/traffic/health`), and
one mixed-DU status call (`/api/handover/mixed-du/status`).

Suggested order: **A → B → C** (A is pure renames with textual reference
updates; B changes a process launch path; C has the most hidden coupling via
`__file__`-derived paths).

---

## Appendix — pre-existing stale references found during the 2026-07-11 scans
(not caused by, and not fixed in, the zero-risk pass)

- `README.md:93` → `./scripts/deploy-f1-ran.sh` does not exist in the repo.
- `README.md:113` → `docs/repo-inventory-20260612.md` actually lives in `docs/archive/`.
- `README.md:118` → `docs/dashboard-full-test-report-2026-06-11.md` actually lives in `docs/archive/`.
- `docs/validation/frequency-scenarios-validation.md:21` → `docs/radio-profile-netem-final-validation-20260602.md` actually lives in `docs/archive/`.
- `manifests/ran/e1/{cucp.conf:2, e1-split.yaml:12}` → comment references nonexistent `manifests/ran/f1/cu.conf`.
