#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
PORT="${PORT:-5300}"
COUNT="${COUNT:-1000}"
SIZE="${SIZE:-1000}"
INTERVAL="${INTERVAL:-0.005}"
BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"

mkdir -p "$DIR"

echo "===== CUSTOM UDP TRAFFIC SCENARIO ====="
echo "RUN_ID=$RUN_ID"
echo "PROOF_DIR=$DIR"
echo "PORT=$PORT"
echo "COUNT=$COUNT"
echo "SIZE=$SIZE"
echo "INTERVAL=$INTERVAL"

echo "===== 1. DETECT UE / TUNNEL / NODE ====="
UE="$(kubectl -n "$NS" get pods --no-headers | awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}')"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod found"; exit 1; }

UE_IP="$(kubectl -n "$NS" exec "$UE" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1")"
NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"

[ -n "$UE_IP" ] || { echo "[FAIL] oaitun_ue1 has no IPv4"; exit 1; }

echo "UE=$UE"
echo "UE_IP=$UE_IP"
echo "NODE_IP=$NODE_IP"

echo "===== 2. ROUTE CHECK ====="
kubectl -n "$NS" exec "$UE" -- ip route get "$NODE_IP" | tee "$DIR/route.txt"

echo "===== 3. OAITUN BEFORE ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-before.txt"

echo "===== 4. CREATE HOST UDP RECEIVER ====="
cat > /tmp/oran_udp_receiver.py <<'PY'
import socket, time, json, sys, statistics

port = int(sys.argv[1])
expected = int(sys.argv[2])
expected_interval = float(sys.argv[3])
out = sys.argv[4]

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", port))
sock.settimeout(15)

received = 0
bytes_total = 0
first_src = None
timestamps = []
seqs = []

start = time.time()

while True:
    try:
        data, addr = sock.recvfrom(65535)
    except socket.timeout:
        break

    now = time.time()
    timestamps.append(now)
    received += 1
    bytes_total += len(data)

    if first_src is None:
        first_src = f"{addr[0]}:{addr[1]}"

    try:
        seq = int(data[:16].decode(errors="ignore").strip())
        seqs.append(seq)
    except Exception:
        pass

    if received >= expected:
        break

end = time.time()
sock.close()

duration = max(end - start, 0.000001)
lost = expected - received
loss_percent = (lost / expected) * 100 if expected else 0

deltas = []
if len(timestamps) >= 2:
    deltas = [timestamps[i] - timestamps[i-1] for i in range(1, len(timestamps))]

avg_interarrival_ms = None
max_interarrival_ms = None
jitter_ms = None

if deltas:
    avg_interarrival_ms = statistics.mean(deltas) * 1000
    max_interarrival_ms = max(deltas) * 1000
    jitter_ms = statistics.mean([abs(d - expected_interval) for d in deltas]) * 1000

result = {
    "scenario": "custom_udp_traffic",
    "listen_port": port,
    "expected_packets": expected,
    "received_packets": received,
    "lost_packets": lost,
    "loss_percent": round(loss_percent, 3),
    "bytes_received": bytes_total,
    "duration_seconds": round(duration, 6),
    "throughput_mbps": round((bytes_total * 8) / duration / 1000000, 6),
    "first_source_seen_by_server": first_src,
    "avg_interarrival_ms": round(avg_interarrival_ms, 6) if avg_interarrival_ms is not None else None,
    "max_interarrival_ms": round(max_interarrival_ms, 6) if max_interarrival_ms is not None else None,
    "jitter_ms_estimated": round(jitter_ms, 6) if jitter_ms is not None else None,
    "verdict": "OK" if received > 0 and loss_percent <= 10 else "FAIL"
}

open(out, "w").write(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
sys.exit(0 if result["verdict"] == "OK" else 2)
PY

echo "===== 5. START HOST UDP RECEIVER ====="
python3 /tmp/oran_udp_receiver.py "$PORT" "$COUNT" "$INTERVAL" "$DIR/result.json" > "$DIR/receiver-console.log" 2>&1 &
RECV_PID="$!"
echo "$RECV_PID" > "$DIR/receiver.pid"
sleep 2
echo "RECV_PID=$RECV_PID"

echo "===== 6. CREATE UE UDP SENDER ====="
cat > /tmp/oran_udp_sender.py <<'PY'
import socket, sys, time, json

dst_ip = sys.argv[1]
dst_port = int(sys.argv[2])
src_ip = sys.argv[3]
count = int(sys.argv[4])
size = int(sys.argv[5])
interval = float(sys.argv[6])

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((src_ip, 0))

start = time.time()

for i in range(count):
    prefix = f"{i:016d}".encode()
    payload = prefix + b"x" * max(0, size - len(prefix))
    sock.sendto(payload, (dst_ip, dst_port))
    time.sleep(interval)

end = time.time()
sock.close()

result = {
    "scenario": "custom_udp_sender",
    "dst_ip": dst_ip,
    "dst_port": dst_port,
    "src_ip_bound": src_ip,
    "sent_packets": count,
    "packet_size_bytes": size,
    "sent_bytes": count * size,
    "duration_seconds": round(end - start, 6),
    "target_interval_seconds": interval,
    "target_bitrate_mbps": round((count * size * 8) / (end - start) / 1000000, 6)
}

print(json.dumps(result, indent=2))
PY

kubectl -n "$NS" exec -i "$UE" -- sh -c 'cat > /tmp/oran_udp_sender.py' < /tmp/oran_udp_sender.py

echo "===== 7. RUN UDP SENDER FROM UE THROUGH oaitun_ue1 ====="
kubectl -n "$NS" exec "$UE" -- \
  python3 /tmp/oran_udp_sender.py "$NODE_IP" "$PORT" "$UE_IP" "$COUNT" "$SIZE" "$INTERVAL" \
  | tee "$DIR/sender-result.json"

echo "===== 8. READ RECEIVER RESULT ====="
sleep 3
cat "$DIR/receiver-console.log" | tee "$DIR/receiver-result.txt"

echo "===== 9. OAITUN AFTER ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-after.txt"

echo "===== 10. CREATE SUMMARY ====="
python3 - "$DIR/result.json" "$DIR/summary.txt" <<'PY'
import json, sys

result_path, summary_path = sys.argv[1], sys.argv[2]
data = json.load(open(result_path))

summary = f"""Scenario: custom_udp_traffic
Verdict: {data.get("verdict")}
Expected packets: {data.get("expected_packets")}
Received packets: {data.get("received_packets")}
Lost packets: {data.get("lost_packets")}
Packet loss percent: {data.get("loss_percent")}
Throughput Mbps: {data.get("throughput_mbps")}
Estimated jitter ms: {data.get("jitter_ms_estimated")}
Average interarrival ms: {data.get("avg_interarrival_ms")}
Max interarrival ms: {data.get("max_interarrival_ms")}
Bytes received: {data.get("bytes_received")}
First source seen by server: {data.get("first_source_seen_by_server")}
Result JSON: {result_path}
"""

print(summary)
open(summary_path, "w").write(summary)
PY

echo "===== SUMMARY ====="
cat "$DIR/summary.txt"

echo "===== CUSTOM UDP TRAFFIC SCENARIO DONE ====="
