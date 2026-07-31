#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/oran-e2e}"
source "$REPO/scripts/ue/ue-common.sh"
UE_DEP="${UE_DEP:-oai-nr-ue}"

NS="${NS:-oran-ran}"
PORT="${PORT:-8089}"
BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"
ROOT="$DIR/media-root"

mkdir -p "$ROOT/videos"

echo "===== VIDEO DOWNLOAD SCENARIO ====="
echo "RUN_ID=$RUN_ID"
echo "PROOF_DIR=$DIR"
echo "PORT=$PORT"

echo "===== 1. DETECT UE / TUNNEL / NODE ====="
UE="$(ue_pod_for_deployment "$NS" "$UE_DEP")"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod found"; exit 1; }

UE_IP="$(kubectl -n "$NS" exec "$UE" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1")"
NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"

[ -n "$UE_IP" ] || { echo "[FAIL] oaitun_ue1 has no IPv4"; exit 1; }

echo "UE=$UE"
echo "UE_IP=$UE_IP"
echo "NODE_IP=$NODE_IP"

echo "===== 2. CREATE SAMPLE VIDEO FILE ====="
VIDEO="$ROOT/videos/sample.mp4"

if command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg found: creating real MP4 test video"
  ffmpeg -y \
    -f lavfi -i testsrc=size=640x360:rate=25 \
    -f lavfi -i sine=frequency=1000:sample_rate=44100 \
    -t 10 \
    -c:v mpeg4 \
    -c:a aac \
    "$VIDEO" \
    > "$DIR/ffmpeg-create-video.log" 2>&1
  VIDEO_KIND="real_mp4_ffmpeg"
else
  echo "ffmpeg not found: creating MP4-sized binary video payload"
  python3 - "$VIDEO" <<'PY'
import sys, os, hashlib

path = sys.argv[1]
size_mb = 10
target = size_mb * 1024 * 1024

header = (
    b"\x00\x00\x00\x18ftypmp42"
    b"\x00\x00\x00\x00mp42isom"
    b"\x00\x00\x00\x08free"
)

pattern = b"O-RAN-5G-VIDEO-TEST-PAYLOAD-" * 1024

with open(path, "wb") as f:
    f.write(header)
    written = len(header)
    while written < target:
        chunk = pattern[: min(len(pattern), target - written)]
        f.write(chunk)
        written += len(chunk)

print("created", path)
print("bytes", os.path.getsize(path))
print("sha256", hashlib.sha256(open(path, "rb").read()).hexdigest())
PY
  VIDEO_KIND="mp4_named_test_payload"
fi

SHA="$(sha256sum "$VIDEO" | awk '{print $1}')"
SIZE="$(stat -c%s "$VIDEO")"
URL="http://$NODE_IP:$PORT/videos/sample.mp4"

echo "VIDEO_KIND=$VIDEO_KIND"
echo "VIDEO=$VIDEO"
echo "SIZE=$SIZE"
echo "SHA=$SHA"
echo "URL=$URL"

echo "===== 3. START MEDIA SERVER ====="
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
nohup python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$ROOT" > "$DIR/media-server.log" 2>&1 &
echo $! > "$DIR/media-server.pid"
sleep 2

ss -ltnp | grep ":$PORT" | tee "$DIR/server-listen.txt"

echo "===== 4. HOST HTTP CHECK ====="
python3 - <<PY | tee "$DIR/host-http-check.txt"
import urllib.request
url = "$URL"
r = urllib.request.urlopen(url, timeout=10)
data = r.read(1024)
print("host_http_status=", r.status)
print("host_first_bytes=", len(data))
PY

echo "===== 5. UE ROUTE CHECK ====="
kubectl -n "$NS" exec "$UE" -- ip route get "$NODE_IP" | tee "$DIR/ue-route.txt"

echo "===== 6. OAITUN BEFORE ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-before.txt"

echo "===== 7. INSTALL UE VIDEO DOWNLOADER ====="
cat > /tmp/oran_http_download.py <<'PY'
import socket, sys, time, hashlib, json
from urllib.parse import urlparse

url, out, src_ip, expected_sha = sys.argv[1:5]
u = urlparse(url)

host = u.hostname
port = u.port or 80
path = u.path or "/"

start = time.time()

sock = socket.create_connection((host, port), timeout=30, source_address=(src_ip, 0))
request = (
    f"GET {path} HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    f"User-Agent: o-ran-video-download\r\n"
    f"Connection: close\r\n\r\n"
).encode()

sock.sendall(request)

buf = b""
while b"\r\n\r\n" not in buf:
    chunk = sock.recv(4096)
    if not chunk:
        break
    buf += chunk

if b"\r\n\r\n" not in buf:
    raise RuntimeError("HTTP header not received")

header, body = buf.split(b"\r\n\r\n", 1)
status = int(header.split()[1])

sha = hashlib.sha256()
total = 0

with open(out, "wb") as f:
    if body:
        f.write(body)
        sha.update(body)
        total += len(body)

    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        f.write(chunk)
        sha.update(chunk)
        total += len(chunk)

sock.close()

elapsed = time.time() - start
digest = sha.hexdigest()

result = {
    "scenario": "video_download",
    "url": url,
    "bind_source_ip": src_ip,
    "output_file": out,
    "http_status": status,
    "downloaded_bytes": total,
    "time_seconds": round(elapsed, 6),
    "throughput_mbps": round((total * 8) / elapsed / 1000000, 6) if elapsed > 0 else None,
    "sha256": digest,
    "expected_sha256": expected_sha,
    "checksum_ok": digest == expected_sha,
    "verdict": "OK" if status == 200 and digest == expected_sha else "FAIL"
}

print(json.dumps(result, indent=2))
sys.exit(0 if result["verdict"] == "OK" else 2)
PY

kubectl -n "$NS" exec -i "$UE" -- sh -c 'cat > /tmp/oran_http_download.py' < /tmp/oran_http_download.py

echo "===== 8. RUN VIDEO DOWNLOAD THROUGH oaitun_ue1 ====="
kubectl -n "$NS" exec "$UE" -- \
  python3 /tmp/oran_http_download.py "$URL" /tmp/sample-video.mp4 "$UE_IP" "$SHA" \
  | tee "$DIR/result.json"

echo "===== 9. VERIFY FILE INSIDE UE ====="
kubectl -n "$NS" exec "$UE" -- ls -lh /tmp/sample-video.mp4 | tee "$DIR/ue-file.txt"
kubectl -n "$NS" exec "$UE" -- sha256sum /tmp/sample-video.mp4 | tee "$DIR/ue-sha256.txt"

echo "===== 10. OAITUN AFTER ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-after.txt"

echo "===== 11. SUMMARY ====="
python3 - "$DIR/result.json" "$DIR/summary.txt" "$VIDEO_KIND" "$SIZE" <<'PY'
import json, sys

result_path, summary_path, video_kind, expected_size = sys.argv[1:5]
data = json.load(open(result_path))

summary = f"""Scenario: video_download
Verdict: {data.get("verdict")}
Video kind: {video_kind}
HTTP status: {data.get("http_status")}
Expected size bytes: {expected_size}
Downloaded bytes: {data.get("downloaded_bytes")}
Transfer time seconds: {data.get("time_seconds")}
Throughput Mbps: {data.get("throughput_mbps")}
Checksum OK: {data.get("checksum_ok")}
URL: {data.get("url")}
Result JSON: {result_path}
"""

print(summary)
open(summary_path, "w").write(summary)
PY

cat "$DIR/summary.txt"

echo "===== VIDEO DOWNLOAD SCENARIO DONE ====="
