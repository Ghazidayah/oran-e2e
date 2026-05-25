#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-oran-ran}"
PORT="${PORT:-8091}"
SEGMENTS="${SEGMENTS:-8}"
SEGMENT_SIZE="${SEGMENT_SIZE:-524288}"
BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"
ROOT="$DIR/media-root"
HLS="$ROOT/hls"

mkdir -p "$HLS"

echo "===== STREAMING-LIKE HLS SCENARIO ====="
echo "RUN_ID=$RUN_ID"
echo "PROOF_DIR=$DIR"
echo "PORT=$PORT"
echo "SEGMENTS=$SEGMENTS"
echo "SEGMENT_SIZE=$SEGMENT_SIZE"

echo "===== 1. DETECT UE / TUNNEL / NODE ====="
UE="$(kubectl -n "$NS" get pods --no-headers | awk '/oai-nr-ue/ && $3=="Running"{print $1; exit}')"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod found"; exit 1; }

UE_IP="$(kubectl -n "$NS" exec "$UE" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1")"
NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"

[ -n "$UE_IP" ] || { echo "[FAIL] oaitun_ue1 has no IPv4"; exit 1; }

echo "UE=$UE"
echo "UE_IP=$UE_IP"
echo "NODE_IP=$NODE_IP"

echo "===== 2. CREATE HLS-LIKE PLAYLIST AND SEGMENTS ====="
python3 - "$HLS" "$SEGMENTS" "$SEGMENT_SIZE" <<'PY'
import sys, hashlib, json
from pathlib import Path

hls = Path(sys.argv[1])
segments = int(sys.argv[2])
segment_size = int(sys.argv[3])

manifest = {}
playlist = [
    "#EXTM3U",
    "#EXT-X-VERSION:3",
    "#EXT-X-TARGETDURATION:2",
    "#EXT-X-MEDIA-SEQUENCE:1"
]

for i in range(1, segments + 1):
    name = f"segment_{i:03d}.ts"
    path = hls / name

    # MPEG-TS-like payload: 188-byte packets starting with sync byte 0x47.
    packet = bytes([0x47]) + f"O-RAN-HLS-SEGMENT-{i:03d}-".encode()
    packet = packet.ljust(188, b"x")

    data = (packet * ((segment_size // len(packet)) + 1))[:segment_size]
    path.write_bytes(data)

    sha = hashlib.sha256(data).hexdigest()
    manifest[name] = {"size": len(data), "sha256": sha}

    playlist.append("#EXTINF:2.0,")
    playlist.append(name)

playlist.append("#EXT-X-ENDLIST")
(hls / "playlist.m3u8").write_text("\n".join(playlist) + "\n")
manifest["playlist.m3u8"] = {
    "size": (hls / "playlist.m3u8").stat().st_size,
    "sha256": hashlib.sha256((hls / "playlist.m3u8").read_bytes()).hexdigest()
}

(hls / "manifest.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
PY

URL_BASE="http://$NODE_IP:$PORT"
PLAYLIST_URL="$URL_BASE/hls/playlist.m3u8"

echo "PLAYLIST_URL=$PLAYLIST_URL"

echo "===== 3. START HLS MEDIA SERVER ====="
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
nohup python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$ROOT" > "$DIR/hls-server.log" 2>&1 &
echo $! > "$DIR/hls-server.pid"
sleep 2

ss -ltnp | grep ":$PORT" | tee "$DIR/server-listen.txt"

echo "===== 4. HOST HTTP CHECK ====="
python3 - "$PLAYLIST_URL" <<'PY' | tee "$DIR/host-http-check.txt"
import sys, urllib.request
url = sys.argv[1]
r = urllib.request.urlopen(url, timeout=5)
data = r.read()
print("playlist_status=", r.status)
print("playlist_bytes=", len(data))
print(data.decode(errors="replace"))
PY

echo "===== 5. UE ROUTE CHECK ====="
kubectl -n "$NS" exec "$UE" -- ip route get "$NODE_IP" | tee "$DIR/ue-route.txt"

echo "===== 6. OAITUN BEFORE ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-before.txt"

echo "===== 7. INSTALL UE STREAMING DOWNLOADER ====="
cat > /tmp/oran_streaming_like.py <<'PY'
import socket, sys, time, hashlib, json
from urllib.parse import urlparse, urljoin

playlist_url, src_ip = sys.argv[1:3]

def http_get(url, src_ip):
    u = urlparse(url)
    host = u.hostname
    port = u.port or 80
    path = u.path or "/"
    if u.query:
        path += "?" + u.query

    start = time.time()
    s = socket.create_connection((host, port), timeout=20, source_address=(src_ip, 0))
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"User-Agent: o-ran-streaming-like\r\n"
        f"Connection: close\r\n\r\n"
    ).encode()
    s.sendall(req)

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk

    if b"\r\n\r\n" not in buf:
        raise RuntimeError("No HTTP header received")

    header, body = buf.split(b"\r\n\r\n", 1)
    status = int(header.split()[1])

    data = bytearray(body)
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data.extend(chunk)

    s.close()
    elapsed = time.time() - start

    return {
        "url": url,
        "http_status": status,
        "bytes": len(data),
        "time_seconds": round(elapsed, 6),
        "sha256": hashlib.sha256(data).hexdigest(),
        "data": bytes(data)
    }

start_all = time.time()

playlist = http_get(playlist_url, src_ip)
playlist_text = playlist["data"].decode(errors="replace")

segment_names = []
for line in playlist_text.splitlines():
    line = line.strip()
    if line and not line.startswith("#"):
        segment_names.append(line)

segments = []
ok_segments = 0
total_segment_bytes = 0

for name in segment_names:
    url = urljoin(playlist_url, name)
    result = http_get(url, src_ip)
    result.pop("data", None)
    segments.append(result)
    total_segment_bytes += result["bytes"]
    if result["http_status"] == 200 and result["bytes"] > 0:
        ok_segments += 1

total_time = time.time() - start_all

segment_delays = [s["time_seconds"] for s in segments]
avg_delay = sum(segment_delays) / len(segment_delays) if segment_delays else None
max_delay = max(segment_delays) if segment_delays else None

out = {
    "scenario": "streaming_like_hls",
    "playlist_url": playlist_url,
    "bind_source_ip": src_ip,
    "playlist_http_status": playlist["http_status"],
    "playlist_bytes": playlist["bytes"],
    "segments_requested": len(segment_names),
    "segments_ok": ok_segments,
    "segment_success_rate_percent": round((ok_segments / len(segment_names)) * 100, 3) if segment_names else 0,
    "total_segment_bytes": total_segment_bytes,
    "total_time_seconds": round(total_time, 6),
    "average_segment_delay_seconds": round(avg_delay, 6) if avg_delay is not None else None,
    "max_segment_delay_seconds": round(max_delay, 6) if max_delay is not None else None,
    "average_throughput_mbps": round((total_segment_bytes * 8) / total_time / 1000000, 6) if total_time > 0 else None,
    "segments": segments,
    "verdict": "OK" if playlist["http_status"] == 200 and ok_segments == len(segment_names) and len(segment_names) > 0 else "FAIL"
}

print(json.dumps(out, indent=2))
sys.exit(0 if out["verdict"] == "OK" else 2)
PY

kubectl -n "$NS" exec -i "$UE" -- sh -c 'cat > /tmp/oran_streaming_like.py' < /tmp/oran_streaming_like.py

echo "===== 8. RUN STREAMING-LIKE DOWNLOAD THROUGH oaitun_ue1 ====="
kubectl -n "$NS" exec "$UE" -- \
  python3 /tmp/oran_streaming_like.py "$PLAYLIST_URL" "$UE_IP" \
  | tee "$DIR/result.json"

echo "===== 9. OAITUN AFTER ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-after.txt"

echo "===== 10. SUMMARY ====="
python3 - "$DIR/result.json" "$DIR/summary.txt" <<'PY'
import json, sys

data = json.load(open(sys.argv[1]))
summary = f"""Scenario: streaming_like_hls
Verdict: {data.get("verdict")}
Playlist HTTP status: {data.get("playlist_http_status")}
Segments requested: {data.get("segments_requested")}
Segments OK: {data.get("segments_ok")}
Segment success rate percent: {data.get("segment_success_rate_percent")}
Total segment bytes: {data.get("total_segment_bytes")}
Total time seconds: {data.get("total_time_seconds")}
Average segment delay seconds: {data.get("average_segment_delay_seconds")}
Max segment delay seconds: {data.get("max_segment_delay_seconds")}
Average throughput Mbps: {data.get("average_throughput_mbps")}
Result JSON: {sys.argv[1]}
"""
print(summary)
open(sys.argv[2], "w").write(summary)
PY

cat "$DIR/summary.txt"

echo "===== STREAMING-LIKE HLS SCENARIO DONE ====="
