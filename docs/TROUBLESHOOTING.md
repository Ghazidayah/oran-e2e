# Troubleshooting Guide

## Quick health check (read-only)

```bash
kubectl get nodes -o wide
kubectl -n oran-core get pods -o wide
kubectl -n oran-ran  get pods -o wide
kubectl -n oran-core exec deploy/open5gs-amf -- ss -lpn | grep -E '38412|7777'
kubectl -n oran-core exec deploy/open5gs-upf -- ss -lunp | grep -E '2152|8805'
for d in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
  p=$(kubectl -n oran-ran get pod -l app=$d -o jsonpath='{.items[0].metadata.name}')
  echo -n "$d: "; kubectl -n oran-ran exec "$p" -- sh -c 'ip -br a | grep oaitun || echo NO_TUNNEL'
done
```

---

## CU segfault (exit code 139)

**Symptom**: `oai-cu-cp` pod restarts unexpectedly; `kubectl describe pod` shows `exit code 139`;
`kubectl -n oran-ran get events` shows no OOMKill. All PDU sessions drop.

**Root cause**: Upstream OAI image `oai-gnb:2025.w45` segfaults intermittently under RFsim load
(~4 restarts per 23 h observed 2026-06-10/11). Not a memory exhaustion issue (no resource limit set).

**Recovery**:

1. Wait for the CU-CP pod to restart automatically (k3s restarts it).
2. Check if UEs self-healed:
   ```bash
   scripts/recover-ue-sessions.sh          # diagnose only, read-only
   ```
3. If any UE shows `STALE` or `NO_TUNNEL`:
   ```bash
   scripts/recover-ue-sessions.sh --fix    # restart only the unhealthy UEs
   ```

**Do NOT**: change the CU image version without re-validating the full E2E test suite.
**Do NOT**: blindly restart all UEs — only restart the ones that fail the data-plane check.

---

## UE tunnels not forming after a core/CU restart

**Symptom**: One or more UEs show `NO_TUNNEL` or a stale `oaitun_ue1` IP that no longer matches
the SMF assignment.

**Why it happens**: After AMF/SMF/UPF/MongoDB or CU restart, PDU sessions are torn down. UEs
usually reattach with new IPs, but the pod's tunnel interface can retain the old IP / dead GTP state
while still printing MAC stats in the logs.

**Recovery**:

```bash
scripts/recover-ue-sessions.sh            # show mismatch report
scripts/recover-ue-sessions.sh --fix      # restart only bad UEs
scripts/recover-ue-sessions.sh --fix --yes  # skip confirm prompt
```

The script:
1. Reads each UE's IMSI from its ConfigMap
2. Finds the SMF's most-recent IPv4 assignment for that IMSI in logs
3. Compares to the IP on `oaitun_ue1`
4. Pings the DN gateway `10.45.0.1` through the tunnel
5. Restarts only the UEs that mismatch or fail the ping

---

## CU not NGAP-associated with AMF on cold start

**Symptom**: Platform starts cleanly, but all UEs show `NO_TUNNEL` immediately. CU log contains:
```
[NGAP] No AMF is associated
```

**Why it happens**: The CU-CP pod can reach `Ready` before the NGAP SCTP session to the AMF is
established. DUs connect to the CU via F1 and UEs connect via RFsim, but without NGAP there is
no N2 path and no PDU sessions can be set up.

**Recovery** (automated on `scripts/platform-start.sh`):

`ensure_cu_ngap_associated()` in `scripts/platform-start.sh` detects this and restarts CU + DUs up
to 3 times. It uses two log samples 5 seconds apart to avoid acting on stale log lines.

Manual recovery:

```bash
kubectl -n oran-ran logs deploy/oai-cu-cp --tail=20 | grep -i "AMF\|ngap"
kubectl -n oran-ran rollout restart deploy/oai-cu-cp
kubectl -n oran-ran rollout status  deploy/oai-cu-cp --timeout=3m
kubectl -n oran-ran rollout restart deploy/oai-du0 deploy/oai-du1
```

Then run `scripts/recover-ue-sessions.sh --fix`.

**Environment override**: `ORAN_NGAP_GATE=0` disables the gate; `ORAN_NGAP_MAX_TRIES=N` sets retry count;
`ORAN_NGAP_SETTLE_SECONDS=N` sets the wait before each check (default 25s).

---

## UE registration rejected / no Allowed NSSAI

**Symptom**: UE sends Registration Request but AMF rejects or grants no usable slice. AMF log shows
no `Allowed NSSAI` or shows only SST=1 when a different slice was expected.

**Most likely cause 1: AMF ConfigMap is wrong or stale**

The AMF's real config source is ConfigMap `open5gs-oai-prep` (key `amf.yaml`) in namespace
`oran-core`, **not** `open5gs-amf`. After editing any ConfigMap, the AMF pod must be restarted —
subPath mounts do NOT hot-reload (CLAUDE.md Rule 8).

```bash
kubectl -n oran-core get cm open5gs-oai-prep -o jsonpath='{.data.amf\.yaml}' | grep -A5 s_nssai
kubectl -n oran-core rollout restart deploy/open5gs-amf
kubectl -n oran-core exec deploy/open5gs-amf -- grep -A5 s_nssai /etc/open5gs/amf.yaml
```

**Most likely cause 2: UE deployment args override ConfigMap**

The 2025.w45 nr-ue firmware sends no Requested NSSAI regardless of the ConfigMap `pdu_sessions`.
The subscriber MongoDB default_indicator drives Allowed NSSAI. Check with:

```bash
kubectl -n oran-ran get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}'
```

**Most likely cause 3: MongoDB subscriber has wrong slice**

```bash
MONGO=$(kubectl -n oran-core get pods --no-headers | awk '/mongodb/{print $1}')
kubectl -n oran-core exec "$MONGO" -- mongosh open5gs --eval \
  'db.subscribers.find({},{imsi:1,slice:1}).toArray()'
```

---

## Frequency / DU-switch recovery

**Symptom**: After a frequency retune or DU switch, UE1 has no tunnel, or is on the wrong DU.

**Frequency restore**:

```bash
bash scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh restore
```

This resets DU config and UE args to `n78-current` (SSB 621312, carrier 3319.68 MHz) and
waits for the tunnel to re-form.

**DU switch recovery**: If the mixed-DU handover left UE1 stranded:

```bash
bash scripts/handover/recover-mixed-du-state.sh
```

Or via the dashboard API: `POST /api/handover/mixed-du/recover`.

---

## ConfigMap edit has no effect on a running pod

CLAUDE.md Rule 8: subPath-mounted ConfigMaps do NOT hot-reload. The pod must be restarted AND
the new file verified inside the new pod:

```bash
kubectl -n oran-ran rollout restart deploy/oai-cu-cp
kubectl -n oran-ran exec deploy/oai-cu-cp -- grep snssaiList /etc/oai/gnb.conf
```

---

## `kubectl apply` rejected with "object has been modified"

CLAUDE.md Rule 4: Never apply a previously-saved manifest verbatim. Strip the runtime metadata
first, or use the `--dry-run=client` + pipe pattern:

```bash
kubectl -n oran-ran create configmap oai-cucp-config \
  --from-file=gnb.conf=./patched.conf \
  --dry-run=client -o yaml | kubectl apply -f -
```
