# Cold-Start Bring-Up: Root Cause, Recovery, and Permanent Fix

**Scope.** This documents a 5GC (Open5GS) cold-start failure on the single-node k3s
platform and its fix. It is **independent of the O-RAN CU-CP/CU-UP (E1) split** — it is a
stock Open5GS-on-Kubernetes startup-ordering weakness that the E1 work happened to expose
(the monolithic CU's slower startup had previously masked the timing). The E1 split itself
is validated and unaffected.

---

## 1. Symptom

After a `platform-stop` / `platform-start` cycle, UEs fail to attach. Pods cycle through
`CrashLoopBackOff`, no `oaitun_ue1` tunnel forms, and the AMF logs, for every IMSI:

```
[amf] WARNING: [suci-0-999-70-0000-0-0-000000000X] Registration reject [9]
```

5GMM cause **#9 = "UE identity cannot be derived by the network."** The UE radio layer is
healthy throughout (`UE synchronized!`, PBCH decoded, RRC connected) — the failure is on
the core/control side, not the air interface.

---

## 2. Root cause

A single theme, biting at three different hops: **when a core NF changes pod IP while a
peer is already connected to it, the peer never re-establishes the connection.** On a
single node where everything boots at once, this strands endpoints.

| Hop | What was observed | Consequence |
|-----|-------------------|-------------|
| AUSF / SCP → UDM | `Failed to connect to 10.42.0.226 port 7777: No route to host` (a UDM IP from an earlier pod) | AUSF gets HTTP 500 → AMF cannot resolve identity → `reject [9]` |
| AMF startup ordering | AMF boots before NRF holds AUSF/UDM profiles | first registrations rejected before discovery settles |
| CU-CP → AMF | `Received NGAP_DEREGISTERED_GNB_IND` then `No AMF is associated to the gNB` | UE reaches CU-CP (RRC OK) but registration has no AMF to go to |

Confirmed **not** the cause (ruled out by evidence): subscriber data (6 subscribers present,
UE1 has valid K/OPc), MongoDB (up and queryable), the home-network SUCI keys (`hnet/*.key`
all present), and UDM↔Mongo connectivity.

The decisive evidence was the SCP repeatedly logging `No route to host` to a UDM IP that
**no longer existed and was never in the current NRF** — i.e. a stale endpoint cached from a
pod destroyed earlier in the session. Restarting individual NFs did **not** clear it (and in
fact created fresh churn); only a clean, ordered bring-up from zero did.

---

## 3. Proven manual recovery (the safety net)

This sequence recovered the platform to 5/5 UEs attached, reproducibly. Use it any time the
platform is in the stale-endpoint state (e.g. before a live demo if a cold start misbehaves).

```bash
# (1) Clean slate — scale the whole core to zero and let it fully terminate.
kubectl -n oran-core scale deploy --all --replicas=0
sleep 30
kubectl -n oran-core get pods            # confirm terminated

# (2) Bring the core up in DEPENDENCY ORDER (no restarts).
kubectl -n oran-core scale deploy open5gs-mongodb open5gs-nrf open5gs-scp --replicas=1
sleep 25
kubectl -n oran-core scale deploy \
  open5gs-udr open5gs-udm open5gs-ausf open5gs-bsf open5gs-nssf \
  open5gs-pcf open5gs-upf open5gs-sepp open5gs-webui --replicas=1
sleep 25
kubectl -n oran-core scale deploy open5gs-amf open5gs-smf --replicas=1   # AMF/SMF LAST
sleep 20

# (3) Verify the core is clean (both should be 0).
kubectl -n oran-core logs deploy/open5gs-scp --tail=40 | grep -c "No route"      # want 0
kubectl -n oran-core logs deploy/open5gs-amf --since=3m | grep -c "reject \[9\]"  # want 0

# (4) Re-associate the RAN to the now-stable AMF, then bring up UEs.
kubectl -n oran-ran rollout restart deploy/oai-cu-cp
kubectl -n oran-ran rollout status  deploy/oai-cu-cp --timeout=120s
sleep 10
kubectl -n oran-ran rollout restart deploy/oai-du0 deploy/oai-du1
sleep 20
for u in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  kubectl -n oran-ran rollout restart deploy/$u
done
sleep 120

# (5) Confirm tunnels.
for u in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  p=$(kubectl -n oran-ran get pod -l app=$u -o jsonpath='{.items[0].metadata.name}')
  echo -n "$u: "; kubectl -n oran-ran exec "$p" -- ip -br addr | awk '/oaitun/{print $3}'
done
```

Expected: `No route` = 0, `reject [9]` = 0, and five `10.45.0.x` tunnels.

---

## 4. Permanent fix (in `platform-start.sh`)

The fix is **ordering**: the AMF and SMF must not be the ones waiting on discovery. After
restoring the saved replica counts (`~/.oran-lab/platform-replicas.tsv`) and waiting for the
key workloads, the script runs three ordered stages — `ensure_core_amf_ready`,
`ensure_cu_plane_healthy`, `reconcile_ue_sessions` — in that sequence.

**Stage 1 — `ensure_core_amf_ready()`** (gated by `ORAN_CORE_GATE`, default `1`):

1. Waits for the NF directory, data and auth NFs to report a Ready replica, each up to 180s:
   `open5gs-mongodb`, `open5gs-nrf`, `open5gs-scp`, `open5gs-udr`, `open5gs-udm`,
   `open5gs-ausf`, `open5gs-upf`.
2. Pauses `ORAN_CORE_REGISTER_SETTLE` seconds (default 25) so those NFs register their
   profiles into the NRF.
3. Restarts `open5gs-amf` + `open5gs-smf` **last**, so they boot into a populated NRF and
   discover AUSF/UDM/UPF on the first attempt.
4. Confirms positively: counts `NF registered` lines in the AMF log and reports how many NF
   profiles it discovered. If none appear yet, it warns and leaves the retry to stage 3.

**Stage 2 — `ensure_cu_plane_healthy()`** (gated by `ORAN_CU_GATE`, default `1`): applies
`manifests/ran/e1/e1-split.yaml`, then scales CU-CP before CU-UP (correct E1 order), settles
`ORAN_CU_SETTLE_SECONDS` (default 25) and verifies both NGAP (no `No AMF is associated` in the
CU-CP log, ideally `gNB-N2 accepted` in the AMF log) and E1 association. On failure it
re-pairs by restarting CU-CP then CU-UP, up to `ORAN_CU_MAX_TRIES` attempts (default 3). Once
healthy it rollout-restarts DU0 and DU1 so F1-C re-associates.

**Stage 3 — `reconcile_ue_sessions()`** (gated by `ORAN_RECONCILE_UES`, default `1`): sleeps
`ORAN_UE_SETTLE_SECONDS` (default 45) to let restored UEs self-attach, then delegates to
`scripts/recover-ue-sessions.sh --fix --yes`, which restarts only the UEs still without a
working tunnel, and re-runs it to confirm `VERDICT=ALL_HEALTHY`.

Opt-outs (each stage independently): `ORAN_CORE_GATE=0`, `ORAN_CU_GATE=0`,
`ORAN_RECONCILE_UES=0` — e.g. `ORAN_CORE_GATE=0 bash scripts/platform-start.sh` skips the core
ordering stage and prints `[SKIP] ORAN_CORE_GATE=0`.

Tunables: `ORAN_CORE_REGISTER_SETTLE` (default 25s) — raise if the NRF needs longer to
populate on a slow/cold cache; `ORAN_CU_SETTLE_SECONDS` (25s), `ORAN_CU_MAX_TRIES` (3),
`ORAN_UE_SETTLE_SECONDS` (45s).

Note: `platform-start.sh` restores replicas from the state file — it does **not** scale
everything to zero first. The scale-to-zero clean slate in section 3 remains a manual
procedure, to be used when the platform is already in the stale-endpoint state.

---

## 5. How to verify a clean cold start

```bash
bash scripts/platform-stop.sh
bash scripts/platform-start.sh      # let it finish — do NOT Ctrl-C
sleep 180
echo "reject9:";          kubectl -n oran-core logs deploy/open5gs-amf --since=6m | grep -ic "reject \[9\]"
echo "scp route errors:"; kubectl -n oran-core logs deploy/open5gs-scp --since=6m | grep -ic "no route"
for u in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  p=$(kubectl -n oran-ran get pod -l app=$u -o jsonpath='{.items[0].metadata.name}')
  echo -n "$u: "; kubectl -n oran-ran exec "$p" -- ip -br addr | awk '/oaitun/{print $3}'
done
```

Pass criteria: `reject9: 0`, `scp route errors: 0`, five `10.45.0.x` tunnels, no manual
intervention.

---

## 6. Defense framing (honest)

- The CU-CP/CU-UP (E1) split is validated across all six capability areas; this cold-start
  issue does not affect those results.
- The issue is a known operational characteristic of a disaggregated SBA core on a single
  node: **service discovery must converge before dependents connect, and endpoints must not
  change identity underneath live associations.** The fix — ordered, dependency-aware
  bring-up — is the same principle real deployments rely on (readiness gating / startup
  ordering). It is a legitimate platform-engineering finding, not a defect in the architecture.
