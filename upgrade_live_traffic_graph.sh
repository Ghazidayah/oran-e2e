#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/oran-e2e-freeze/web-dashboard"
APP_FILE="$APP_DIR/app.py"
HTML_FILE="$APP_DIR/templates/index.html"

python3 - <<'PY'
from pathlib import Path

app_file = Path.home() / "oran-e2e-freeze/web-dashboard/app.py"
html_file = Path.home() / "oran-e2e-freeze/web-dashboard/templates/index.html"

app = app_file.read_text()

backend_code = r'''

LAST_NET_SAMPLE = {
    "t": None,
    "rx": None,
    "tx": None
}

def read_ue_net_counters():
    ue = find_ue_pod()
    if not ue:
        return {
            "ok": False,
            "error": "No UE pod found",
            "ue": "",
            "rx_bytes": 0,
            "tx_bytes": 0,
            "t": time.time()
        }

    script = """
if [ -d /sys/class/net/oaitun_ue1 ]; then
  date +%s
  cat /sys/class/net/oaitun_ue1/statistics/rx_bytes
  cat /sys/class/net/oaitun_ue1/statistics/tx_bytes
  ip -o -4 addr show oaitun_ue1 2>/dev/null | awk '{print $4}' || true
else
  echo "0"
  echo "0"
  echo "0"
fi
"""
    r = exec_in_ue(script, timeout=12)
    lines = [x.strip() for x in r["output"].splitlines() if x.strip()]

    try:
        ts = float(lines[0])
        rx = int(lines[1])
        tx = int(lines[2])
        ip = lines[3] if len(lines) > 3 else ""
        return {
            "ok": True,
            "ue": ue,
            "t": ts,
            "rx_bytes": rx,
            "tx_bytes": tx,
            "ip": ip,
            "raw": r["output"]
        }
    except Exception:
        return {
            "ok": False,
            "error": "Could not parse UE tunnel counters",
            "ue": ue,
            "rx_bytes": 0,
            "tx_bytes": 0,
            "t": time.time(),
            "raw": r["output"]
        }

@app.route("/api/live_metrics")
def api_live_metrics():
    global LAST_NET_SAMPLE

    current = read_ue_net_counters()

    rx_mbps = 0.0
    tx_mbps = 0.0

    if current.get("ok") and LAST_NET_SAMPLE["t"] is not None:
        dt = max(current["t"] - LAST_NET_SAMPLE["t"], 0.001)
        drx = max(current["rx_bytes"] - LAST_NET_SAMPLE["rx"], 0)
        dtx = max(current["tx_bytes"] - LAST_NET_SAMPLE["tx"], 0)

        rx_mbps = (drx * 8.0) / dt / 1000000.0
        tx_mbps = (dtx * 8.0) / dt / 1000000.0

    if current.get("ok"):
        LAST_NET_SAMPLE = {
            "t": current["t"],
            "rx": current["rx_bytes"],
            "tx": current["tx_bytes"]
        }

    return jsonify({
        "time": datetime.now().isoformat(timespec="seconds"),
        "ok": current.get("ok", False),
        "ue": current.get("ue", ""),
        "ip": current.get("ip", ""),
        "rx_bytes": current.get("rx_bytes", 0),
        "tx_bytes": current.get("tx_bytes", 0),
        "rx_mbps": round(rx_mbps, 3),
        "tx_mbps": round(tx_mbps, 3),
        "error": current.get("error", "")
    })

@app.route("/metrics")
def prometheus_metrics():
    current = read_ue_net_counters()
    rx = current.get("rx_bytes", 0)
    tx = current.get("tx_bytes", 0)
    ok = 1 if current.get("ok") else 0

    body = f"""# HELP oran_ue_tunnel_up UE tunnel oaitun_ue1 status
# TYPE oran_ue_tunnel_up gauge
oran_ue_tunnel_up {ok}
# HELP oran_ue_rx_bytes UE tunnel received bytes
# TYPE oran_ue_rx_bytes counter
oran_ue_rx_bytes {rx}
# HELP oran_ue_tx_bytes UE tunnel transmitted bytes
# TYPE oran_ue_tx_bytes counter
oran_ue_tx_bytes {tx}
"""
    return body, 200, {"Content-Type": "text/plain; version=0.0.4"}
'''

if "def api_live_metrics" not in app:
    marker = '@app.route("/api/runs")'
    if marker not in app:
        raise SystemExit("Could not find insertion point in app.py")
    app = app.replace(marker, backend_code + "\n" + marker)
    app_file.write_text(app)
    print("Added backend live metrics API.")
else:
    print("Backend live metrics API already exists.")

html = html_file.read_text()

css_code = r'''
    .livebox {
      display: grid;
      grid-template-columns: 1fr 260px;
      gap: 16px;
      align-items: stretch;
    }
    .chartWrap {
      background: #06101d;
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 14px;
      min-height: 310px;
    }
    canvas {
      width: 100%;
      height: 260px;
      display: block;
    }
    .liveStats {
      display: grid;
      gap: 12px;
    }
    .statMini {
      background: #0b1626;
      border: 1px solid var(--line);
      border-radius: 14px;
      padding: 14px;
    }
    .statMini strong {
      display: block;
      font-size: 24px;
      margin-top: 8px;
    }
'''

if ".livebox" not in html:
    html = html.replace("    @media (max-width: 1100px) {", css_code + "\n    @media (max-width: 1100px) {")

graph_section = r'''
  <div class="section card">
    <h2>Real-Time UE Data Transfer</h2>
    <div class="small" style="margin-bottom: 12px;">
      Live traffic measured from the UE tunnel interface <strong>oaitun_ue1</strong>. Start light/heavy traffic or run throughput/video-like tests to see the graph move.
    </div>

    <div class="livebox">
      <div class="chartWrap">
        <canvas id="trafficChart" width="900" height="260"></canvas>
      </div>

      <div class="liveStats">
        <div class="statMini">
          <span class="small">Download RX</span>
          <strong class="ok" id="rxNow">0.000 Mbps</strong>
        </div>
        <div class="statMini">
          <span class="small">Upload TX</span>
          <strong class="blue" id="txNow">0.000 Mbps</strong>
        </div>
        <div class="statMini">
          <span class="small">UE tunnel IP</span>
          <strong id="liveIp">-</strong>
        </div>
        <div class="statMini">
          <span class="small">Total RX / TX</span>
          <strong id="totalBytes">-</strong>
        </div>
      </div>
    </div>
  </div>
'''

if "Real-Time UE Data Transfer" not in html:
    marker = '''  <div class="section grid2">
    <div class="card">
      <h2>Latest Action Output</h2>'''
    if marker not in html:
        raise SystemExit("Could not find insertion point in index.html")
    html = html.replace(marker, graph_section + "\n" + marker)

js_code = r'''
let trafficLabels = [];
let rxSeries = [];
let txSeries = [];

function humanBytes(v) {
  if (v > 1024 * 1024 * 1024) return (v / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  if (v > 1024 * 1024) return (v / (1024 * 1024)).toFixed(2) + ' MB';
  if (v > 1024) return (v / 1024).toFixed(2) + ' KB';
  return v + ' B';
}

function drawTrafficChart() {
  const canvas = document.getElementById('trafficChart');
  if (!canvas) return;

  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;

  ctx.clearRect(0, 0, w, h);

  ctx.fillStyle = '#06101d';
  ctx.fillRect(0, 0, w, h);

  const padL = 48;
  const padR = 18;
  const padT = 18;
  const padB = 36;
  const plotW = w - padL - padR;
  const plotH = h - padT - padB;

  const all = rxSeries.concat(txSeries);
  const maxVal = Math.max(1, ...all) * 1.25;

  ctx.strokeStyle = '#1e3552';
  ctx.lineWidth = 1;
  ctx.font = '12px Arial';
  ctx.fillStyle = '#90a4bd';

  for (let i = 0; i <= 4; i++) {
    const y = padT + (plotH / 4) * i;
    ctx.beginPath();
    ctx.moveTo(padL, y);
    ctx.lineTo(w - padR, y);
    ctx.stroke();

    const val = maxVal - (maxVal / 4) * i;
    ctx.fillText(val.toFixed(1), 8, y + 4);
  }

  function mapX(i) {
    if (rxSeries.length <= 1) return padL;
    return padL + (i / (rxSeries.length - 1)) * plotW;
  }

  function mapY(v) {
    return padT + plotH - (v / maxVal) * plotH;
  }

  function line(series, color) {
    if (series.length < 2) return;

    ctx.beginPath();
    ctx.lineWidth = 3;
    ctx.strokeStyle = color;

    series.forEach((v, i) => {
      const x = mapX(i);
      const y = mapY(v);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });

    ctx.stroke();
  }

  line(rxSeries, '#49e58c');
  line(txSeries, '#57a7ff');

  ctx.fillStyle = '#49e58c';
  ctx.fillRect(padL, h - 18, 10, 10);
  ctx.fillStyle = '#dbeafe';
  ctx.fillText('Download RX Mbps', padL + 16, h - 9);

  ctx.fillStyle = '#57a7ff';
  ctx.fillRect(padL + 160, h - 18, 10, 10);
  ctx.fillStyle = '#dbeafe';
  ctx.fillText('Upload TX Mbps', padL + 176, h - 9);

  ctx.fillStyle = '#90a4bd';
  ctx.fillText('Mbps', 8, 16);
}

async function updateLiveTraffic() {
  try {
    const r = await fetch('/api/live_metrics');
    const m = await r.json();

    const label = new Date().toLocaleTimeString();
    trafficLabels.push(label);
    rxSeries.push(Number(m.rx_mbps || 0));
    txSeries.push(Number(m.tx_mbps || 0));

    while (rxSeries.length > 60) {
      trafficLabels.shift();
      rxSeries.shift();
      txSeries.shift();
    }

    document.getElementById('rxNow').textContent = Number(m.rx_mbps || 0).toFixed(3) + ' Mbps';
    document.getElementById('txNow').textContent = Number(m.tx_mbps || 0).toFixed(3) + ' Mbps';
    document.getElementById('liveIp').textContent = m.ip || '-';
    document.getElementById('totalBytes').textContent =
      humanBytes(m.rx_bytes || 0) + ' / ' + humanBytes(m.tx_bytes || 0);

    drawTrafficChart();
  } catch (e) {
    console.log('live traffic update failed', e);
  }
}
'''

if "updateLiveTraffic" not in html:
    html = html.replace("refreshStatus();", js_code + "\nrefreshStatus();\nupdateLiveTraffic();\nsetInterval(updateLiveTraffic, 5000);")

html_file.write_text(html)
print("Added real-time traffic graph to platform.")
PY

echo "Live traffic graph upgrade complete."
echo "Restart the platform:"
echo "./stop-web-dashboard.sh"
echo "./run-web-dashboard.sh"
