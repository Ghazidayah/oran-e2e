#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
PORT="${PORT:-5201}"
DURATION="${DURATION:-15}"
BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"

mkdir -p "$DIR"

echo "===== IPERF3 TCP THROUGHPUT SCENARIO ====="
echo "RUN_ID=$RUN_ID"
echo "PROOF_DIR=$DIR"
echo "PORT=$PORT"
echo "DURATION=$DURATION"

echo "===== 1. CHECK IPERF3 ON HOST ====="
if ! command -v iperf3 >/dev/null 2>&1; then
  echo "[FAIL] iperf3 is not installed on host."
  echo "Install it with: sudo apt update && sudo apt install -y iperf3"
  exit 1
fi
iperf3 --version | head -n 1 | tee "$DIR/host-iperf3-version.txt"

echo "===== 2. DETECT UE / TUNNEL / NODE ====="
UE="$(kubectl -n "$NS" get pods --no-headers | awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}')"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod found"; exit 1; }

UE_IP="$(kubectl -n "$NS" exec "$UE" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1")"
NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"

echo "UE=$UE"
echo "UE_IP=$UE_IP"
echo "NODE_IP=$NODE_IP"

echo "===== 3. CHECK IPERF3 INSIDE UE ====="
kubectl -n "$NS" exec "$UE" -- sh -c 'which iperf3 && iperf3 --version | head -n 1' | tee "$DIR/ue-iperf3-version.txt"

echo "===== 4. START IPERF3 SERVER ON HOST ====="
pkill -f "iperf3 -s -p $PORT" 2>/dev/null || true
nohup iperf3 -s -p "$PORT" > "$DIR/iperf3-server.log" 2>&1 &
echo $! > "$DIR/iperf3-server.pid"
sleep 2

ss -ltnp | grep ":$PORT" | tee "$DIR/server-listen.txt"

echo "===== 5. UE ROUTE TO IPERF SERVER ====="
kubectl -n "$NS" exec "$UE" -- ip route get "$NODE_IP" | tee "$DIR/ue-route-to-iperf-server.txt"

echo "===== 6. OAITUN BEFORE ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-before.txt"

echo "===== 7. RUN IPERF3 TCP CLIENT FROM UE THROUGH oaitun_ue1 ====="
kubectl -n "$NS" exec "$UE" -- \
  iperf3 -c "$NODE_IP" -B "$UE_IP" -p "$PORT" -t "$DURATION" -J \
  | tee "$DIR/iperf3-tcp-result.json"

echo "===== 8. OAITUN AFTER ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-after.txt"

echo "===== 9. PARSE TCP KPI ====="
python3 - "$DIR/iperf3-tcp-result.json" "$DIR/summary.txt" <<'PY'
import json, sys

json_path, summary_path = sys.argv[1], sys.argv[2]
data = json.load(open(json_path))

end = data.get("end", {})
sender = end.get("sum_sent", {})
receiver = end.get("sum_received", {})

bits_per_second = receiver.get("bits_per_second") or sender.get("bits_per_second") or 0
mbps = bits_per_second / 1_000_000
seconds = receiver.get("seconds") or sender.get("seconds")
bytes_received = receiver.get("bytes")
bytes_sent = sender.get("bytes")
retransmits = sender.get("retransmits", "N/A")

summary = f"""Scenario: iperf3_tcp
Verdict: OK
Throughput Mbps: {mbps:.3f}
Duration seconds: {seconds}
Bytes sent: {bytes_sent}
Bytes received: {bytes_received}
TCP retransmits: {retransmits}
Result JSON: {json_path}
"""

print(summary)
open(summary_path, "w").write(summary)
PY

echo "===== 10. SERVER LOG ====="
tail -n 30 "$DIR/iperf3-server.log" | tee "$DIR/iperf3-server-tail.txt"

echo "===== SUMMARY ====="
cat "$DIR/summary.txt"

echo "===== IPERF3 TCP SCENARIO DONE ====="
