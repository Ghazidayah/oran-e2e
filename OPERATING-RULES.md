# OPERATING-RULES.md — O-RAN E2E Testbed

This repo is **not a normal codebase**. It is a set of scripts/configs/manifests wired to a
**live single-node 5G cluster** on host `oran-lab`. Commands here can take real UEs offline.
Read the Safety Rules before running anything.

---

## Platform

- Host `oran-lab`: Ubuntu 22.04.5, **k3s** single-node, Helm.
- Core: **Open5GS 5G SA** (namespace `oran-core`).
- RAN: **OpenAirInterface**, **F1 split** = CU + DU0 + DU1 (namespace `oran-ran`), **RFsim** (no radio HW).
- Monitoring: kube-prometheus-stack (namespace `monitoring`).
- Repo root: `~/oran-e2e`.

## Identity / addressing (do not change casually)

- PLMN **999/70**, DNN **oai**, 5 UEs IMSI `999700000000001`..`005`.
- AMF NGAP: `10.10.0.101:38412` (SCTP, N2).  UPF GTP-U: `10.20.0.101:2152` (N3).
- UE data tunnels: `oaitun_ue1` → `10.45.0.x`.
- F1 (DU0): `local_n_address 10.10.0.121` → CU `10.10.0.120`. RFsim service per DU: `oai-du0-rfsim` / `oai-du1-rfsim` on TCP 4043.
- gNB/DU deployments use `strategy: Recreate` because of fixed Multus IPs. UEs have no fixed IP (safe to `rollout restart`).

## Topology

- **UE1** = reference UE. Baseline home **DU0**. As of 2026-06-09 UE1 is **DU-switchable** (DU0↔DU1); it is no longer blocked.
- **UE2–UE5** live on **DU1**.
- UE→DU mapping is resolved dynamically from each UE's RFsim `serveraddr` via `ue_serveraddr_from_cm` in `scripts/ue/ue-common.sh`. Never hardcode a UE's DU.

## Frequency / band profiles

- Validated (TDD, 30 kHz, carrier-retune only): **n78 3500/3780 MHz**, **n41 2600 MHz**.
- `scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh` auto-detects the UE's current DU; override with `DU_DEPLOY=`.

## Conventions (keep these)

- Every validated phase gets **both** a git tag **and** a `docs/<phase>-validation.md`.
- **Validate before integrate**: prove a change live (or on a throwaway target) before wiring it into the dashboard / main scripts.
- Web dashboard: Flask on port **18080**, started with `./run-web-dashboard.sh`, stopped with `./stop-web-dashboard.sh`.
- Mixed-DU recovery + handover logic drive the dashboard API (`/api/handover/mixed-du/*`); `recover-mixed-du-state.sh` needs the dashboard running.

---

## SAFETY RULES (read before acting on the cluster)

1. **Read-only is free; mutation needs confirmation.** Auto-OK: `kubectl get/describe/logs`, `git status/log/diff/show`, file reads. **Always confirm first**: `kubectl delete/scale/patch/apply/rollout restart`, `helm upgrade`, anything that restarts core or RAN pods.
2. **A core (AMF/SMF/UPF/mongodb) or CU restart wipes all PDU sessions.** UEs re-register at NAS and OFTEN re-form their tunnels on their own with NEW IPs (observed 2026-06-10 after a CU restart: UE2-5 self-healed). But some can strand a stale `oaitun_ue1`. Do NOT blind-restart all UEs. Run `scripts/recover-ue-sessions.sh` (diagnose-first, read-only): it compares each pod's tunnel IP to the SMF's latest assignment and pings the DN gateway, restarting only the UEs that fail. Add `--fix` to act. (Outages: 2026-06-09 core, 2026-06-10 CU.)
3. **`sed` edits to .conf must be whitespace-agnostic.** The configs use long runs of spaces for alignment. Use `sed -E 's/(key[[:space:]]*=[[:space:]]*)OLD;/\1NEW;/'` and always `grep` to confirm the change landed before applying. A naive `sed` silently matched nothing twice on 2026-06-09.
4. **Never `kubectl apply` a previously-saved manifest verbatim** — it carries a stale `resourceVersion` and the API rejects it (`Conflict: object has been modified`). Either strip `resourceVersion/uid/creationTimestamp/managedFields/generation` + `status` first, or rebuild via `kubectl create cm ... --dry-run=client -o yaml | kubectl apply -f -`.
5. **DU0 n78 baseline lives in `manifests/ran/f1/du0.conf`** (band 78, SSB 621312, F1 10.10.0.121). If a backup is suspect, restore the DU0 configmap from this file, not from a `backups/` copy (the n28 validate script overwrote its own backup on repeated applies).
6. After any RF experiment on DU0/UE1, **restore to n78** and confirm UE1 ping 0% loss before stopping.
7. Honesty over optimism: report what the logs actually show; mark results "validated" only with end-to-end proof (tunnel + ping / session), not partial success.

8. **ConfigMap edits do NOT reach running pods** (subPath mounts). The CU ran a stale config for 14 days; the AMF likewise. After editing any ConfigMap, restart the consuming deployment AND verify the file inside the new pod (`kubectl exec ... grep`).
9. **The AMF's real config source is ConfigMap `open5gs-oai-prep` (key `amf.yaml`)** — NOT `open5gs-amf`, which is mounted but unused. Slice list lives there.
10. **UE deployment args override ConfigMap values** (e.g. `--rfsimulator.serveraddr`). When a UE misbehaves, check the deployment args, not just the ConfigMap.
11. **Slice switching = UE config (legacy nssai keys) + MongoDB default_indicator together.** The 2025.w45 nr-ue ignores `pdu_sessions = ({...})` and sends no Requested NSSAI, so Allowed NSSAI = subscriber default only. Use `scripts/slicing/switch-ue-slice.sh` (v2); success is the AMF-granted `S_NSSAI[SST:x]`, never just a tunnel.

## Known risks (2026-06-11)

- **The CU segfaults intermittently** (exit code 139, ~4 restarts/23h observed 2026-06-10/11,
  image oai-gnb:2025.w45). Not OOM (no memory limit set, no OOMKill events). Each crash tears
  down all PDU sessions; UE1 usually self-heals, UE2-5 sometimes strand stale tunnels.
  Mitigation: `scripts/recover-ue-sessions.sh --fix` (~30s). Root cause is upstream OAI;
  do NOT chase it by changing the image version without re-validating everything.

## Quick health check (read-only, safe)

```bash
kubectl get nodes -o wide
kubectl -n oran-core get pods -o wide
kubectl -n oran-ran  get pods -o wide
kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn | egrep '38412|7777'
kubectl -n oran-core exec deploy/open5gs-upf -- ss -lunp | egrep '2152|8805'
for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  p=$(kubectl -n oran-ran get pod -l app=$d -o jsonpath='{.items[0].metadata.name}')
  echo -n "$d: "; kubectl -n oran-ran exec "$p" -- sh -c 'ip -br a | grep oaitun || echo NO_TUNNEL'
done
```

## Open items (2026-06-09)

- Refresh stale `docs/validation/ue1-du-aware-handover-validation.md` (describes a state rolled back on 2026-06-02, re-enabled 2026-06-09).
- [DONE 2026-06-10] `scripts/recover-ue-sessions.sh` — diagnose-first recovery (rule 2), validated ALL_HEALTHY on live platform.
- Wire the working 3500/2600 profiles into the dashboard (original "add to dashboard" goal).
