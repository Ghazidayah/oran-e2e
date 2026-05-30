#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/oran-e2e-freeze}"
source "$REPO/scripts/ue/ue-common.sh"
UE_DEP="${UE_DEP:-oai-nr-ue}"

NS="${NS:-oran-ran}"
PORT="${PORT:-8088}"
BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"
ROOT="$DIR/media-root"

mkdir -p "$ROOT/images"

echo "===== IMAGE DOWNLOAD SCENARIO ====="
echo "RUN_ID=$RUN_ID"
echo "PROOF_DIR=$DIR"

UE="$(ue_pod_for_deployment "$NS" "$UE_DEP")"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod"; exit 1; }

UE_IP="$(kubectl -n "$NS" exec "$UE" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1")"
NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"

echo "UE=$UE"
echo "UE_IP=$UE_IP"
echo "NODE_IP=$NODE_IP"

echo "===== CREATE REAL IMAGE FILE ====="
export IMG="$ROOT/images/test.bmp"
python3 - <<'PY'
import os, struct, hashlib
w, h = 640, 360
row = (w * 3 + 3) & ~3
pixels = bytearray()
for y in range(h):
    line = bytearray()
    for x in range(w):
        line += bytes([(x * 255)//w, (y * 255)//h, ((x+y) * 255)//(w+h)])
    line += b"\x00" * (row - w * 3)
    pixels = line + pixels
size = 54 + len(pixels)
header = b"BM" + struct.pack("<IHHI", size, 0, 0, 54)
header += struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
path = os.environ["IMG"]
with open(path, "wb") as f:
    f.write(header + pixels)
sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
print("IMAGE_PATH=" + path)
print("IMAGE_SIZE=" + str(os.path.getsize(path)))
print("IMAGE_SHA256=" + sha)
PY

SHA="$(sha256sum "$ROOT/images/test.bmp" | awk '{print $1}')"
SIZE="$(stat -c%s "$ROOT/images/test.bmp")"
URL="http://$NODE_IP:$PORT/images/test.bmp"

echo "SHA=$SHA"
echo "SIZE=$SIZE"
echo "URL=$URL"

echo "===== START MEDIA SERVER ====="
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
nohup python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$ROOT" > "$DIR/media-server.log" 2>&1 &
echo $! > "$DIR/media-server.pid"
sleep 2
ss -ltnp | grep ":$PORT"

echo "===== HOST HTTP CHECK ====="
python3 - <<PY | tee "$DIR/host-http-check.txt"
import urllib.request
r = urllib.request.urlopen("$URL", timeout=5)
data = r.read()
print("host_http_status=", r.status)
print("host_download_bytes=", len(data))
PY

echo "===== UE ROUTE CHECK ====="
kubectl -n "$NS" exec "$UE" -- ip route get "$NODE_IP" | tee "$DIR/ue-route.txt"

echo "===== OAITUN BEFORE ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-before.txt"

echo "===== INSTALL UE DOWNLOADER ====="
cat > /tmp/ue_http_download.py <<'PY'
import socket, sys, time, hashlib, json
from urllib.parse import urlparse

url, out, src_ip, expected = sys.argv[1:5]
u = urlparse(url)
host, port = u.hostname, u.port or 80
path = u.path or "/"

t0 = time.time()
s = socket.create_connection((host, port), timeout=20, source_address=(src_ip, 0))
s.sendall((f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n").encode())

buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)

head, body = buf.split(b"\r\n\r\n", 1)
status = int(head.split()[1])

sha = hashlib.sha256()
total = 0
with open(out, "wb") as f:
    f.write(body)
    sha.update(body)
    total += len(body)
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        f.write(chunk)
        sha.update(chunk)
        total += len(chunk)

s.close()
dt = time.time() - t0
digest = sha.hexdigest()

result = {
  "scenario": "image_download",
  "url": url,
  "bind_source_ip": src_ip,
  "http_status": status,
  "downloaded_bytes": total,
  "time_seconds": round(dt, 6),
  "throughput_mbps": round(total * 8 / dt / 1000000, 6),
  "sha256": digest,
  "expected_sha256": expected,
  "checksum_ok": digest == expected,
  "verdict": "OK" if status == 200 and digest == expected else "FAIL"
}
print(json.dumps(result, indent=2))
sys.exit(0 if result["verdict"] == "OK" else 2)
PY

kubectl -n "$NS" exec -i "$UE" -- sh -c 'cat > /tmp/ue_http_download.py' < /tmp/ue_http_download.py

echo "===== RUN DOWNLOAD THROUGH oaitun_ue1 ====="
kubectl -n "$NS" exec "$UE" -- python3 /tmp/ue_http_download.py "$URL" /tmp/test-image.bmp "$UE_IP" "$SHA" | tee "$DIR/result.json"

echo "===== VERIFY FILE IN UE ====="
kubectl -n "$NS" exec "$UE" -- ls -lh /tmp/test-image.bmp | tee "$DIR/ue-file.txt"
kubectl -n "$NS" exec "$UE" -- sha256sum /tmp/test-image.bmp | tee "$DIR/ue-sha256.txt"

echo "===== OAITUN AFTER ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-after.txt"

cat > "$DIR/summary.txt" <<EOF
Scenario: image_download
UE: $UE
UE tunnel IP: $UE_IP
Node IP: $NODE_IP
URL: $URL
Expected SHA256: $SHA
Expected size: $SIZE
Proof directory: $DIR
EOF

echo "===== SUMMARY ====="
cat "$DIR/summary.txt"

echo "===== DONE ====="
