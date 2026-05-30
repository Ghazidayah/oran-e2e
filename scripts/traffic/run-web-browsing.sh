#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/oran-e2e-freeze}"
source "$REPO/scripts/ue/ue-common.sh"
UE_DEP="${UE_DEP:-oai-nr-ue}"

NS="${NS:-oran-ran}"
PORT="${PORT:-8090}"
BASE="${BASE:-$HOME/oran-proof/phase2-realistic-traffic}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
DIR="$BASE/$RUN_ID"
ROOT="$DIR/media-root"

mkdir -p "$ROOT/web"

echo "===== WEB BROWSING SCENARIO ====="
echo "RUN_ID=$RUN_ID"
echo "PROOF_DIR=$DIR"
echo "PORT=$PORT"

UE="$(ue_pod_for_deployment "$NS" "$UE_DEP")"
[ -n "$UE" ] || { echo "[FAIL] No running UE pod found"; exit 1; }

UE_IP="$(kubectl -n "$NS" exec "$UE" -- sh -c "ip -4 -o addr show oaitun_ue1 | awk '{print \$4}' | cut -d/ -f1")"
NODE_IP="$(kubectl get node -o wide --no-headers | awk '{print $6; exit}')"

echo "UE=$UE"
echo "UE_IP=$UE_IP"
echo "NODE_IP=$NODE_IP"

echo "===== CREATE WEB RESOURCES ====="
python3 - "$ROOT/web" <<'PY'
import sys, struct, hashlib, json
from pathlib import Path

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)

(root / "index.html").write_text("""<!doctype html>
<html><head><title>O-RAN Web Test</title><link rel="stylesheet" href="/web/style.css"></head>
<body><h1>O-RAN Web Browsing Scenario</h1><p>HTML + CSS + JS + images over oaitun_ue1.</p>
<img src="/web/image1.bmp"><img src="/web/image2.bmp"><script src="/web/app.js"></script></body></html>
""")
(root / "style.css").write_text("body{font-family:sans-serif;margin:40px} img{width:320px;margin:10px}")
(root / "app.js").write_text('console.log("O-RAN web scenario OK");')

def bmp(path, w, h, mode):
    row = (w * 3 + 3) & ~3
    pixels = bytearray()
    for y in range(h):
        line = bytearray()
        for x in range(w):
            line += bytes([(x*255)//w, (y*255)//h, 80 if mode == 1 else 180])
        line += b"\x00" * (row - w * 3)
        pixels = line + pixels
    size = 54 + len(pixels)
    header = b"BM" + struct.pack("<IHHI", size, 0, 0, 54)
    header += struct.pack("<IiiHHIIiiII", 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    path.write_bytes(header + pixels)

bmp(root / "image1.bmp", 640, 360, 1)
bmp(root / "image2.bmp", 640, 360, 2)

manifest = {}
for p in sorted(root.iterdir()):
    if p.is_file() and p.name != "manifest.json":
        manifest[p.name] = {"size": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
PY

URL_BASE="http://$NODE_IP:$PORT"

cat > "$DIR/urls.txt" <<EOF
$URL_BASE/web/index.html
$URL_BASE/web/style.css
$URL_BASE/web/app.js
$URL_BASE/web/image1.bmp
$URL_BASE/web/image2.bmp
EOF

echo "URL_BASE=$URL_BASE"

echo "===== START WEB SERVER ====="
pkill -f "python3 -m http.server $PORT" 2>/dev/null || true
nohup python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$ROOT" > "$DIR/web-server.log" 2>&1 &
echo $! > "$DIR/web-server.pid"
sleep 2
ss -ltnp | grep ":$PORT" | tee "$DIR/server-listen.txt"

echo "===== HOST HTTP CHECK ====="
python3 - "$DIR/urls.txt" <<'PY' | tee "$DIR/host-http-check.txt"
import sys, urllib.request
for url in open(sys.argv[1]):
    url = url.strip()
    r = urllib.request.urlopen(url, timeout=5)
    data = r.read()
    print(url, r.status, len(data))
PY

echo "===== UE ROUTE CHECK ====="
kubectl -n "$NS" exec "$UE" -- ip route get "$NODE_IP" | tee "$DIR/ue-route.txt"

echo "===== OAITUN BEFORE ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-before.txt"

echo "===== INSTALL UE WEB DOWNLOADER ====="
cat > /tmp/oran_web_download.py <<'PY'
import socket, sys, time, hashlib, json
from urllib.parse import urlparse

urls_file, src_ip = sys.argv[1:3]
urls = [x.strip() for x in open(urls_file) if x.strip()]

results = []
total_bytes = 0
ok_count = 0
start_all = time.time()

for url in urls:
    u = urlparse(url)
    host = u.hostname
    port = u.port or 80
    path = u.path or "/"
    t0 = time.time()
    s = socket.create_connection((host, port), timeout=20, source_address=(src_ip, 0))
    req = f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n".encode()
    s.sendall(req)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    header, body = buf.split(b"\r\n\r\n", 1)
    status = int(header.split()[1])
    data = bytearray(body)
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        data.extend(chunk)
    s.close()
    elapsed = time.time() - t0
    size = len(data)
    total_bytes += size
    if status == 200:
        ok_count += 1
    results.append({
        "url": url,
        "http_status": status,
        "bytes": size,
        "time_seconds": round(elapsed, 6),
        "sha256": hashlib.sha256(data).hexdigest()
    })

total_time = time.time() - start_all

out = {
    "scenario": "web_browsing",
    "resources_requested": len(urls),
    "resources_ok": ok_count,
    "total_bytes": total_bytes,
    "page_load_time_seconds": round(total_time, 6),
    "average_throughput_mbps": round(total_bytes * 8 / total_time / 1000000, 6),
    "resources": results,
    "verdict": "OK" if ok_count == len(urls) else "FAIL"
}
print(json.dumps(out, indent=2))
sys.exit(0 if out["verdict"] == "OK" else 2)
PY

kubectl -n "$NS" exec -i "$UE" -- sh -c 'cat > /tmp/oran_web_download.py' < /tmp/oran_web_download.py
kubectl -n "$NS" exec -i "$UE" -- sh -c 'cat > /tmp/urls.txt' < "$DIR/urls.txt"

echo "===== RUN WEB BROWSING THROUGH oaitun_ue1 ====="
kubectl -n "$NS" exec "$UE" -- python3 /tmp/oran_web_download.py /tmp/urls.txt "$UE_IP" | tee "$DIR/result.json"

echo "===== OAITUN AFTER ====="
kubectl -n "$NS" exec "$UE" -- ip -s link show oaitun_ue1 | tee "$DIR/oaitun-after.txt"

echo "===== SUMMARY ====="
python3 - "$DIR/result.json" "$DIR/summary.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
summary = f"""Scenario: web_browsing
Verdict: {data.get("verdict")}
Resources requested: {data.get("resources_requested")}
Resources OK: {data.get("resources_ok")}
Total bytes: {data.get("total_bytes")}
Page load time seconds: {data.get("page_load_time_seconds")}
Average throughput Mbps: {data.get("average_throughput_mbps")}
Result JSON: {sys.argv[1]}
"""
print(summary)
open(sys.argv[2], "w").write(summary)
PY

cat "$DIR/summary.txt"
echo "===== WEB BROWSING SCENARIO DONE ====="
