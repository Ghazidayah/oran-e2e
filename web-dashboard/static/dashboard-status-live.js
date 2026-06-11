function sanitizeTunnelState(text) {
  if (!text) return text;
  return text.replace(/(\boaitun_\w+\s+)UNKNOWN\b/g, "$1UP (tun)");
}
window.sanitizeTunnelState = sanitizeTunnelState;

function fmtLiveBytes(n) {
  n = Number(n) || 0;
  if (n >= 1073741824) return (n / 1073741824).toFixed(2) + " GB";
  if (n >= 1048576) return (n / 1048576).toFixed(1) + " MB";
  if (n >= 1024) return (n / 1024).toFixed(1) + " KB";
  return n + " B";
}

// Extracted from index.html script block 1
let rxHistory = [];

function fallbackValue(value, fallback) {
  return value === null || value === undefined ? fallback : value;
}

let txHistory = [];
let lastLiveMetricsSample = null;

function clsReady(value, total) {
  if (value === total && total > 0) return "ok";
  if (value > 0) return "warn";
  return "bad";
}

function podRows(items) {
  if (!items || items.length === 0) {
    return '<tr><td colspan="4">No data</td></tr>';
  }

  return items.map(p => `
    <tr>
      <td>${p.name || "-"}</td>
      <td class="${p.ready ? "ok" : "bad"}">${p.ready ? "READY" : "NOT READY"}</td>
      <td>${p.ip || "-"}</td>
      <td>${fallbackValue(p.restarts, "-")}</td>
    </tr>
  `).join("");
}

async function reloadStatus() {
  try {
    const res = await fetch("/api/status?t=" + Date.now());
    const data = await res.json();

    const c = data.counts || {};

    document.getElementById("coreMetric").textContent = `${fallbackValue(c.core_ready, 0)}/${fallbackValue(c.core_total, 0)}`;
    document.getElementById("coreMetric").className = "metric " + clsReady(fallbackValue(c.core_ready, 0), fallbackValue(c.core_total, 0));

    document.getElementById("ranMetric").textContent = `${fallbackValue(c.ran_ready, 0)}/${fallbackValue(c.ran_total, 0)}`;
    document.getElementById("ranMetric").className = "metric " + clsReady(fallbackValue(c.ran_ready, 0), fallbackValue(c.ran_total, 0));

    document.getElementById("monitoringMetric").textContent = `${fallbackValue(c.monitoring_ready, 0)}/${fallbackValue(c.monitoring_total, 0)}`;
    document.getElementById("monitoringMetric").className = "metric " + clsReady(fallbackValue(c.monitoring_ready, 0), fallbackValue(c.monitoring_total, 0));

    document.getElementById("ueMetric").textContent = c.active_ues ? `${c.active_ues} UE` : "0 UE";
    document.getElementById("ueMetric").className = c.active_ues > 0 ? "metric ok" : "metric warn";

    document.getElementById("ranTable").innerHTML = podRows(data.ran);
    document.getElementById("coreTable").innerHTML = podRows(data.core);

    if (data.links) {
      document.getElementById("grafanaLink").href = data.links.grafana;
      document.getElementById("prometheusLink").href = data.links.prometheus;
    }

    const out = document.getElementById("actionOutput");
    if (out && typeof out.textContent === "string" && out.textContent.startsWith("Status reload failed:")) {
      out.textContent = "Ready.";
    }

    const runsTable = document.getElementById("runsTable");
    if (data.recent_runs && runsTable) {
      runsTable.innerHTML = data.recent_runs.map(r => `
        <tr>
          <td>${r.time || "-"}</td>
          <td>${r.action || "-"}</td>
          <td>${r.status || "-"}</td>
          <td>${r.extra || "-"}</td>
        </tr>
      `).join("");
    }
  } catch (err) {
    console.warn("Status reload failed:", err);
  }
}

async function loadMetrics() {
  try {
    const countEl = document.getElementById("desiredUeCount");
    const count = countEl ? Number(countEl.value || 5) : 5;
    const res = await fetch(`/api/ues/live_metrics?count=${encodeURIComponent(count)}&t=${Date.now()}`);
    const m = await res.json();

    if (!m.ok) {
      throw new Error(m.error || "multi-UE metrics API returned ok=false");
    }

    const now = performance.now() / 1000;
    const previous = lastLiveMetricsSample;
    const elapsed = previous ? Math.max(0.25, now - previous.time) : 1;
    const previousByUe = previous ? previous.byUe : {};

    let totalRxMbps = 0;
    let totalTxMbps = 0;

    const rows = (m.ues || []).map((ue) => {
      const prev = previousByUe[ue.name] || null;
      const rxBytes = Number(ue.rx_bytes || 0);
      const txBytes = Number(ue.tx_bytes || 0);
      const rxMbps = prev ? Math.max(0, ((rxBytes - prev.rx_bytes) * 8) / (elapsed * 1000000)) : 0;
      const txMbps = prev ? Math.max(0, ((txBytes - prev.tx_bytes) * 8) / (elapsed * 1000000)) : 0;

      totalRxMbps += rxMbps;
      totalTxMbps += txMbps;

      return `
        <tr>
          <td><strong>${ue.name || "-"}</strong></td>
          <td>${ue.tunnel_ip || "-"}</td>
          <td class="ok">${rxMbps.toFixed(3)}</td>
          <td>${txMbps.toFixed(3)}</td>
          <td>${rxBytes} / ${txBytes}</td>
        </tr>
      `;
    }).join("");

    const byUe = {};
    (m.ues || []).forEach((ue) => {
      byUe[ue.name] = {
        rx_bytes: Number(ue.rx_bytes || 0),
        tx_bytes: Number(ue.tx_bytes || 0)
      };
    });
    lastLiveMetricsSample = { time: now, byUe };

    document.getElementById("rxMbps").textContent = `${totalRxMbps.toFixed(3)} Mbps`;
    document.getElementById("txMbps").textContent = `${totalTxMbps.toFixed(3)} Mbps`;
    document.getElementById("ueIpBox").textContent = `${m.active_count || 0}/${m.requested_count || count} UEs`;
    document.getElementById("bytesBox").textContent = `${fmtLiveBytes(m.total_rx_bytes)} / ${fmtLiveBytes(m.total_tx_bytes)}`;

    const tableBody = document.getElementById("liveMetricsTableBody");
    if (tableBody) {
      tableBody.innerHTML = rows || '<tr><td colspan="5">No attached UEs found for live metrics.</td></tr>';
    }

    rxHistory.push(totalRxMbps);
    txHistory.push(totalTxMbps);

    if (rxHistory.length > 60) rxHistory.shift();
    if (txHistory.length > 60) txHistory.shift();

    drawGraph();
  } catch (err) {
    console.log("multi-UE metrics error", err);
  }
}

function drawGraph() {
  const canvas = document.getElementById("trafficCanvas");
  const ctx = canvas.getContext("2d");
  const w = canvas.width;
  const h = canvas.height;

  ctx.clearRect(0, 0, w, h);
  ctx.fillStyle = "#020617";
  ctx.fillRect(0, 0, w, h);

  ctx.strokeStyle = "#1e293b";
  ctx.lineWidth = 1;
  for (let i = 0; i <= 5; i++) {
    const y = (h / 5) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }

  const all = rxHistory.concat(txHistory);
  const max = Math.max(0.1, ...all);

  function line(data, color) {
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    ctx.beginPath();

    data.forEach((v, i) => {
      const x = (w / 59) * i;
      const y = h - ((v / max) * (h - 20)) - 10;
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });

    ctx.stroke();
  }

  line(rxHistory, "#22c55e");
  line(txHistory, "#60a5fa");

  ctx.fillStyle = "#94a3b8";
  ctx.font = "14px Arial";
  ctx.fillText("RX Mbps", 18, 24);
  ctx.fillStyle = "#22c55e";
  ctx.fillRect(88, 14, 18, 4);

  ctx.fillStyle = "#94a3b8";
  ctx.fillText("TX Mbps", 130, 24);
  ctx.fillStyle = "#60a5fa";
  ctx.fillRect(200, 14, 18, 4);
}
