#!/usr/bin/env bash
# Fix "Registration reject [9]" / AUSF "HTTP response error [500]" after the core was
# (re)created: the SCP/NRF keeps a stale UDR/UDM endpoint ("No route to host" in the SCP log).
# Restarting udr -> udm -> ausf makes them re-register. MongoDB and the AMF are not touched.
#
#   tools/recover-core-auth.sh          # diagnose only
#   tools/recover-core-auth.sh --fix    # restart udr, udm, ausf, then the UEs that are not attached
set -u
CORE_NS="${CORE_NS:-oran-core}"
RAN_NS="${NS:-oran-ran}"

stale="$(kubectl -n "$CORE_NS" logs deploy/open5gs-scp --since=10m 2>/dev/null | grep -c 'No route to host')"
rej="$(kubectl -n "$CORE_NS" logs deploy/open5gs-amf --since=10m 2>/dev/null | grep -c 'Registration reject')"
echo "SCP 'No route to host' (10 min): $stale"
echo "AMF 'Registration reject' (10 min): $rej"

if [ "$stale" -eq 0 ] && [ "$rej" -eq 0 ]; then
  echo "VERDICT=CORE_AUTH_OK"
  exit 0
fi

if [ "${1:-}" != "--fix" ]; then
  echo "Core authentication looks broken. Re-run with --fix to restart udr, udm, ausf."
  echo "VERDICT=CORE_AUTH_RECOVERY_NEEDED"
  exit 0
fi

for nf in udr udm ausf; do
  kubectl -n "$CORE_NS" rollout restart "deploy/open5gs-$nf" >/dev/null
  kubectl -n "$CORE_NS" rollout status "deploy/open5gs-$nf" --timeout=120s || { echo "VERDICT=CORE_AUTH_RESTART_FAILED"; exit 1; }
done

echo "Restarting UEs..."
kubectl -n "$RAN_NS" rollout restart deploy/oai-nr-ue deploy/oai-nr-ue-2 deploy/oai-nr-ue-3 deploy/oai-nr-ue-4 deploy/oai-nr-ue-5 >/dev/null
echo "Wait ~90 s, then check: curl -s http://127.0.0.1:${ORAN_DASHBOARD_PORT:-18080}/api/handover/mixed-du/status | grep attached_count"
echo "VERDICT=CORE_AUTH_RESTARTED"
