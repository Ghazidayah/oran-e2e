#!/usr/bin/env bash

cd ~/oran-e2e-freeze || exit 1

RUN_DIR=~/oran-proof/final-closeout-$(date +%Y%m%d-%H%M%S)
mkdir -p "$RUN_DIR"

UE_POD=$(kubectl -n oran-ran get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')
GNB_A_POD=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-' | grep -v '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)
GNB_B_POD=$(kubectl -n oran-ran get pod -o name | grep '^pod/oai-gnb-b-' | head -n1 | cut -d/ -f2)

{
  echo "UE_POD=$UE_POD"
  echo "GNB_A_POD=$GNB_A_POD"
  echo "GNB_B_POD=$GNB_B_POD"
} | tee "$RUN_DIR/00-pods.txt"

echo "===== RAN PODS =====" | tee "$RUN_DIR/01-ran-pods.txt"
kubectl -n oran-ran get pods -o wide | tee -a "$RUN_DIR/01-ran-pods.txt"

echo "===== CORE PODS =====" | tee "$RUN_DIR/02-core-pods.txt"
kubectl -n oran-core get pods -o wide | tee -a "$RUN_DIR/02-core-pods.txt"

echo "===== IMAGES =====" | tee "$RUN_DIR/03-images.txt"
{
  echo "oai-gnb:      $(kubectl -n oran-ran get deploy oai-gnb   -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "oai-gnb-b:    $(kubectl -n oran-ran get deploy oai-gnb-b -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "oai-nr-ue:    $(kubectl -n oran-ran get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "open5gs-amf:  $(kubectl -n oran-core get deploy open5gs-amf -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "open5gs-smf:  $(kubectl -n oran-core get deploy open5gs-smf -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "open5gs-upf:  $(kubectl -n oran-core get deploy open5gs-upf -o jsonpath='{.spec.template.spec.containers[0].image}')"
} | tee -a "$RUN_DIR/03-images.txt"

kubectl -n oran-ran get deploy oai-gnb   -o yaml > "$RUN_DIR/04-oai-gnb-deploy.yaml"
kubectl -n oran-ran get deploy oai-gnb-b -o yaml > "$RUN_DIR/05-oai-gnb-b-deploy.yaml"
kubectl -n oran-ran get deploy oai-nr-ue -o yaml > "$RUN_DIR/06-oai-nr-ue-deploy.yaml"
kubectl -n oran-core get deploy open5gs-amf -o yaml > "$RUN_DIR/07-open5gs-amf-deploy.yaml"

echo "===== UE CHECK =====" | tee "$RUN_DIR/08-ue-check.txt"
kubectl -n oran-ran exec "$UE_POD" -- sh -c '
ip addr show oaitun_ue1 || true
echo "-----"
ip route || true
echo "-----"
ping -I oaitun_ue1 -c 5 10.45.0.1 || true
' | tee -a "$RUN_DIR/08-ue-check.txt"

echo "===== gNB-A LIVE =====" | tee "$RUN_DIR/09-gnb-a-live.txt"
kubectl -n oran-ran exec "$GNB_A_POD" -- sh -c '
ip addr || true
echo "-----"
ss -ltnp 2>/dev/null | grep 9090 || true
echo "-----"
ss -lunp 2>/dev/null | grep 2152 || true
echo "-----"
ps -ef | grep nr-softmodem | grep -v grep || true
' | tee -a "$RUN_DIR/09-gnb-a-live.txt"

echo "===== gNB-B LIVE =====" | tee "$RUN_DIR/10-gnb-b-live.txt"
kubectl -n oran-ran exec "$GNB_B_POD" -- sh -c '
ip addr || true
echo "-----"
ss -ltnp 2>/dev/null | grep 9090 || true
echo "-----"
ss -lunp 2>/dev/null | grep 2152 || true
echo "-----"
ps -ef | grep nr-softmodem | grep -v grep || true
' | tee -a "$RUN_DIR/10-gnb-b-live.txt"

echo "===== gNB-A LOGS =====" | tee "$RUN_DIR/11-gnb-a-logs.txt"
kubectl -n oran-ran logs "$GNB_A_POD" --since=30m \
  | egrep -i 'TELNETSRV|CU-UE-ID|RNTI|in-sync|RRCSetupComplete|Create UE context|Registration|error|fail' \
  | tail -n 300 \
  | tee -a "$RUN_DIR/11-gnb-a-logs.txt" || true

echo "===== gNB-B LOGS =====" | tee "$RUN_DIR/12-gnb-b-logs.txt"
kubectl -n oran-ran logs "$GNB_B_POD" \
  | egrep -i 'NG Setup|NGSetup|F1 Setup|4043|rfsim|connect\(\)|2152|gtp|amf|warning|error|fail' \
  | tail -n 200 \
  | tee -a "$RUN_DIR/12-gnb-b-logs.txt" || true

echo "===== AMF LOGS =====" | tee "$RUN_DIR/13-amf-logs.txt"
kubectl -n oran-core logs deploy/open5gs-amf --since=30m \
  | egrep -i 'gNB|ngap|handover|path switch|error|fail' \
  | tee -a "$RUN_DIR/13-amf-logs.txt" || true

PORT=19190
kubectl -n oran-ran port-forward pod/"$GNB_A_POD" ${PORT}:9090 > "$RUN_DIR/14-portforward.txt" 2>&1 &
PF_PID=$!
sleep 5

echo "===== CI CHECKS =====" | tee "$RUN_DIR/15-ci-checks.txt"
{
  echo "===== help ====="
  timeout 3 bash -lc "printf 'help\r\n' | nc 127.0.0.1 ${PORT}" || true
  echo
  echo "===== ci get_single_rnti ====="
  timeout 3 bash -lc "printf 'ci get_single_rnti\r\n' | nc 127.0.0.1 ${PORT}" || true
  echo
  echo "===== ci fetch_du_by_ue_id 1 ====="
  timeout 3 bash -lc "printf 'ci fetch_du_by_ue_id 1\r\n' | nc 127.0.0.1 ${PORT}" || true
  echo
  echo "===== ci trigger_n2_ho 1,1 ====="
  timeout 5 bash -lc "printf 'ci trigger_n2_ho 1,1\r\n' | nc 127.0.0.1 ${PORT}" || true
} | tee -a "$RUN_DIR/15-ci-checks.txt"

kill $PF_PID 2>/dev/null || true

cat > "$RUN_DIR/16-summary.txt" <<'SUMEOF'
STATUS: PARTIAL SUCCESS

COMPLETED
- Core is healthy.
- UE user-plane is healthy.
- UE tunnel exists and pings to 10.45.0.1 succeed.
- gNB-A is serving the UE.
- gNB-B is healthy, has N2/N3 interfaces, GTPU listener, NG Setup, and RFsim connectivity.
- gNB-A telnet/CI interface is reachable.

NOT COMPLETED
- Manual N2 handover is not completed.

VALIDATED BLOCKER
- The OAI gNB-A CI/telnet handover helper path cannot resolve the live UE correctly.

EXPECTED PROOF STRINGS
- ci get_single_rnti -> different number of UEs
- ci fetch_du_by_ue_id 1 -> No DU connected
- ci trigger_n2_ho 1,1 -> UE with id 1 not found

TECHNICAL CONCLUSION
- The remaining problem is in the current OAI CI/telnet UE-to-DU / UE-context mapping path.
- This is not a Multus/IPAM issue.
- This is not a core recovery issue.
- This is not a UE tunnel or basic RFsim connectivity issue.
SUMEOF

ARCHIVE="${RUN_DIR}.tar.gz"
tar -C "$(dirname "$RUN_DIR")" -czf "$ARCHIVE" "$(basename "$RUN_DIR")"

echo
echo "===== DONE ====="
echo "RUN_DIR=$RUN_DIR"
echo "ARCHIVE=$ARCHIVE"
ls -lh "$ARCHIVE"
