#!/usr/bin/env bash
# =============================================================================
# gather-report-data.sh
# -----------------------------------------------------------------------------
# Collects EVERYTHING needed for the supervisor progress report into one bundle:
#   - parameters / configs (DU confs, UE configs, slice & modulation & frequency
#     definitions, IP plan, image versions)
#   - live platform state (pods, tunnels, NGAP/E1/F1, UE->DU distribution, SBI health)
#   - all KPI result JSONs (fresh, if you ran the acceptance suite just before)
#   - key logs (AMF, SMF, CU-CP, CU-UP, DU0, DU1, one UE)
#
# READ-ONLY: it changes nothing on the platform.
#
# RECOMMENDED ORDER (so KPIs are fresh & consistent):
#   1) bash tests/run-full-platform-acceptance.sh 2>&1 | tee ~/acceptance-for-report.log
#   2) bash gather-report-data.sh
#   3) upload the printed .tar.gz
# =============================================================================
set -u
REPO="${REPO:-$HOME/oran-e2e-freeze}"
CORE_NS="oran-core"; RAN_NS="oran-ran"
TS="$(date +%Y%m%d-%H%M%S)"
B="$HOME/report-data-$TS"
mkdir -p "$B"/{params,state,kpis,logs,versions}
cd "$REPO" || { echo "repo not found: $REPO"; exit 1; }

say(){ echo "[$1] $2"; }

# ---------------------------------------------------------------------------
say PART "1/5  PARAMETERS / CONFIGS"
# DU radio + slice config
cp manifests/ran/f1/du0.conf manifests/ran/f1/du1.conf "$B/params/" 2>/dev/null
# UE configmaps (serveraddr / DU targeting + S-NSSAI)
cp manifests/ran/mixed-du-live/*.yaml "$B/params/" 2>/dev/null
# capability parameter scripts (slice tc/netem, modulation MCS, frequency ARFCN, handover)
cp scripts/slicing/apply-slice-resource-profile.sh \
   scripts/slicing/run-real-slice-traffic.sh \
   scripts/radio/switch-ue-modulation-profile-du-aware.sh \
   scripts/frequency/switch-ue-actual-frequency-retune-du-aware.sh \
   scripts/handover/switch-ue-du-target.sh "$B/params/" 2>/dev/null
# IP plan / PLMN / project memory
cp OPERATING-RULES.md README.md "$B/params/" 2>/dev/null
# AMF + SMF + NSSF config (PLMN, S-NSSAI, slices)
kubectl -n "$CORE_NS" get cm -o name 2>/dev/null > "$B/params/core-configmaps-list.txt"
for nf in amf smf nssf; do
  kubectl -n "$CORE_NS" get cm "open5gs-$nf" -o yaml 2>/dev/null > "$B/params/core-$nf-configmap.yaml"
done
# subscriber list (IMSI / slices) from mongo, if reachable
MONGO=$(kubectl -n "$CORE_NS" get pod -l app.kubernetes.io/name=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$MONGO" ] && kubectl -n "$CORE_NS" exec "$MONGO" -- mongosh open5gs --quiet --eval \
  'db.subscribers.find({},{imsi:1,"slice.sst":1,"slice.sd":1,_id:0}).forEach(s=>printjson(s))' \
  > "$B/params/subscribers.txt" 2>/dev/null

# ---------------------------------------------------------------------------
say PART "2/5  LIVE PLATFORM STATE"
kubectl -n "$CORE_NS" get pods -o wide  > "$B/state/pods-core.txt"  2>&1
kubectl -n "$RAN_NS"  get pods -o wide  > "$B/state/pods-ran.txt"   2>&1
kubectl get nodes -o wide               > "$B/state/nodes.txt"      2>&1
# UE -> DU distribution + tunnels
{
  echo "== UE -> DU distribution + tunnels =="
  for u in oai-nr-ue oai-nr-ue-2 oai-nr-ue-3 oai-nr-ue-4 oai-nr-ue-5; do
    p=$(kubectl -n "$RAN_NS" get pod -l app=$u -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    srv=$(kubectl -n "$RAN_NS" get pod "$p" -o jsonpath='{.spec.containers[0].args}' 2>/dev/null | grep -oE 'oai-du[0-9]-rfsim')
    tun=$(kubectl -n "$RAN_NS" exec "$p" -- ip -br addr 2>/dev/null | awk '/oaitun/{print $3}')
    echo "$u  server=${srv:-?}  tunnel=${tun:-none}  pod=$p"
  done
} > "$B/state/ue-distribution.txt" 2>&1
# handover status (authoritative distribution + readiness)
curl -s http://127.0.0.1:18080/api/handover/mixed-du/status 2>/dev/null | python3 -m json.tool > "$B/state/handover-status.json" 2>/dev/null
# SBI health
{
  echo "reject9 (want 0):";   kubectl -n "$CORE_NS" logs deploy/open5gs-amf --since=30m 2>/dev/null | grep -ic "reject \[9\]"
  echo "scp no-route (want 0):"; kubectl -n "$CORE_NS" logs deploy/open5gs-scp --since=30m 2>/dev/null | grep -ic "no route"
  echo "amf NF registered count:"; kubectl -n "$CORE_NS" logs deploy/open5gs-amf 2>/dev/null | grep -c "NF registered"
} > "$B/state/sbi-health.txt" 2>&1
# NGAP / E1 / F1 markers
kubectl -n "$RAN_NS" logs deploy/oai-cu-cp --tail=800 2>/dev/null | grep -iE "NGAP|E1AP|CU-UP|F1 Setup|gNB-DU|associat" > "$B/state/ngap-e1-f1-markers.txt" 2>&1

# ---------------------------------------------------------------------------
say PART "3/5  KPI RESULT FILES (run the acceptance suite first for fresh values)"
cp web-dashboard/radio-profile-results.json \
   web-dashboard/real-slice-results.json \
   web-dashboard/real-frequency-results.json \
   web-dashboard/freq-kpi-results.json \
   web-dashboard/multi-ue-results.json "$B/kpis/" 2>/dev/null
# also grab the newest acceptance proof bundle if present
NEWEST_ACC=$(ls -dt "$HOME"/oran-proof/full-acceptance-* 2>/dev/null | head -1)
[ -n "$NEWEST_ACC" ] && cp -r "$NEWEST_ACC" "$B/kpis/acceptance-bundle" 2>/dev/null
# newest per-section proof dirs (the detailed logs)
for sec in baseline realistic real-slices radio multi-ue mixed-du final; do
  d=$(ls -dt "$HOME"/oran-proof/full-platform-functional-tests/section-*"$sec"* 2>/dev/null | head -1)
  [ -n "$d" ] && cp -r "$d" "$B/kpis/$(basename "$d")" 2>/dev/null
done

# ---------------------------------------------------------------------------
say PART "4/5  KEY LOGS"
for d in open5gs-amf open5gs-smf open5gs-upf; do
  kubectl -n "$CORE_NS" logs deploy/$d --tail=300 > "$B/logs/core-$d.log" 2>&1
done
for d in oai-cu-cp oai-cu-up oai-du0 oai-du1 oai-nr-ue; do
  kubectl -n "$RAN_NS" logs deploy/$d --tail=300 > "$B/logs/ran-$d.log" 2>&1
done

# ---------------------------------------------------------------------------
say PART "5/5  VERSIONS"
{
  echo "== k3s / node =="; kubectl version 2>/dev/null | head -6; kubectl get nodes -o wide 2>/dev/null
  echo; echo "== container images (RAN) =="; kubectl -n "$RAN_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null
  echo; echo "== container images (core) =="; kubectl -n "$CORE_NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null
  echo; echo "== git HEAD =="; git -C "$REPO" log --oneline -3 2>/dev/null
} > "$B/versions/versions.txt" 2>&1

# ---------------------------------------------------------------------------
TAR="$HOME/report-data-$TS.tar.gz"
tar -czf "$TAR" -C "$HOME" "report-data-$TS"
echo
echo "============================================================"
echo " DATA BUNDLE READY:"
ls -lh "$TAR"
echo " Upload that .tar.gz."
echo "============================================================"
