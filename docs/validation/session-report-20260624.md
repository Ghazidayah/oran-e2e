# Session Report — 2026-06-24

> **Historical record — do not use as current reference (note added 2026-07-30).**
> This report describes the platform as it was on 2026-06-24 and is accurate for that
> date. The identifiers it names were introduced the same day in `aa29e5d`, then renamed
> the next day in `87244a3` when the E1 split (CU-CP + CU-UP) landed and the gate was
> widened to check E1 as well as NGAP:
>
> | Named here (2026-06-24) | Current name since `87244a3` (2026-06-25) |
> |---|---|
> | `ensure_cu_ngap_associated()` | `ensure_cu_plane_healthy()` |
> | `cu_ngap_down()` | `cucp_ngap_down()` (plus a new `e1_associated()` check) |
> | `ORAN_NGAP_GATE` | `ORAN_CU_GATE` |
> | `ORAN_NGAP_MAX_TRIES` | `ORAN_CU_MAX_TRIES` |
> | `ORAN_NGAP_SETTLE_SECONDS` | `ORAN_CU_SETTLE_SECONDS` |
>
> The old names exist in no current script. For current usage see
> `docs/reference/TROUBLESHOOTING.md` ("CU not NGAP-associated with AMF on cold start").
> The body below is left exactly as written.

Two changes committed and pushed on branch `allow-ue1-du-switch-all-scenarios`.

---

## 1. CU↔AMF NGAP association gate in `platform-start.sh`

**Commit:** `aa29e5d`

### Root cause addressed

On a cold start the CU pod reaches `Ready` but can remain stuck printing:

```
[NGAP] No AMF is associated to the gNB
```

The CU never self-heals from this state. Every UE proceeds through RRC connection
but the CU immediately issues an auto-release:

```
no AMF for CU UE ID ... auto-generate release command
```

Result: 0 of 5 `oaitun_ueN` tunnels form. `reconcile_ue_sessions` (which only
restarts UEs) cannot fix an upstream CU↔AMF break — it needs to run *after* the
CU is NGAP-associated.

Restarting the CU (plus DU0/DU1 to re-form the F1 link) re-triggers the NGAP
`NGSetupRequest → NGSetupResponse` exchange and clears the condition.

### What was added

New helpers in `scripts/platform-start.sh`:

| Symbol | Purpose |
|---|---|
| `cu_ngap_down()` | Two-sample check (5 s apart) — returns true only if the "No AMF is associated" message is still being written, avoiding false positives from old log lines |
| `amf_has_gnb()` | Confirms from the AMF side that `gNB-N2 accepted` appears in the last 5 minutes |
| `ensure_cu_ngap_associated()` | Loops up to `ORAN_NGAP_MAX_TRIES` (default 3) times; each attempt settles `ORAN_NGAP_SETTLE_SECONDS` (default 25 s), checks `cu_ngap_down()`, and if failing restarts `oai-cu` then `oai-du0`+`oai-du1` with `rollout status` waits |

### Startup sequence after the change

```
restore_all
wait for key workloads
start_dashboard
ensure_cu_ngap_associated   ← NEW: NGAP gate + self-heal before UE work
recover_mixed_du_if_available
reconcile_ue_sessions
```

### Environment overrides

```bash
ORAN_NGAP_GATE=0              # skip the gate entirely (e.g. hot restart)
ORAN_NGAP_MAX_TRIES=5         # more retries on slow hardware
ORAN_NGAP_SETTLE_SECONDS=40   # longer settle before sampling logs
```

### Validation

`bash -n scripts/platform-start.sh` → exit 0 (no syntax errors).
Live execution not run in this session (cold-start scenario not reproducible
without a full cluster power-cycle).

---

## 2. Dead single-F1-handover flow removal

**Commit:** `b76714b`

### Background

An earlier single-UE F1 handover experiment (`handover.js` + backend routes +
three action scripts) was superseded by the Mixed-DU multi-UE architecture. The
`handover.js` script tag had already been removed from `index.html` in commit
`5fe2b63`. This commit removes the now-unreachable backend and files.

### Files deleted

| File | Reason |
|---|---|
| `web-dashboard/static/handover.js` | No longer loaded; all its target DOM IDs absent from current HTML |
| `web-dashboard/actions/f1_handover.sh` | Only called by the dead `/api/handover/f1/run` route |
| `web-dashboard/actions/ho_a_to_b.sh` | Called by `f1_handover.sh` |
| `web-dashboard/actions/ho_b_to_a.sh` | Called by `f1_handover.sh` |

### Code removed

- `handover_api.py`: deleted the `@handover_bp.route("/api/handover/f1/run")` decorator
  and `run_f1_handover()` function (17 lines).
- `mixed_du_handover_api.py`: removed `/api/handover/f1/run` from the `before_request`
  compat bridge path list; cleaned the stale note string.

### What was kept (deliberately)

| Kept | Why |
|---|---|
| `web-dashboard/handover_api.py` | Contains the live `/api/handover/status` route |
| `/api/handover/status` route + `handover_status()` | Called by `dashboard-multi-ue.js` on every page load |
| `run_action()` helper | Used by `handover_status()` to call `f1_status.sh` |
| `web-dashboard/actions/f1_status.sh` | Provides topology + tunnel readiness verdicts consumed by the dashboard |

### Test straggler fixed

`scripts/dashboard/test-section-03-real-slices.sh` had `"Run V2X Slice"` in the
button-marker check loop. V2X was removed from the UI in a previous session;
the stale marker was causing the test to always fail that assertion.

```bash
# before
for marker in "Run eMBB Slice" "Run URLLC Slice" "Run mMTC Slice" "Run V2X Slice"

# after
for marker in "Run eMBB Slice" "Run URLLC Slice" "Run mMTC Slice"
```

### Validation suite results

```
python3 -m py_compile web-dashboard/*.py     → OK
ast.parse all *.py                           → py OK
node --check static/*.js                     → js OK
bash -n all tracked *.sh                     → sh OK
grep for dead symbols (handover.js,
  /api/handover/f1, f1_handover.sh,
  ho_a_to_b, ho_b_to_a)                     → 0 hits
/api/handover/status confirmed in:
  handover_api.py:54
  mixed_du_handover_api.py:433
f1_status.sh confirmed present:
  web-dashboard/actions/f1_status.sh
```

Net: **537 lines deleted, 3 inserted**.
