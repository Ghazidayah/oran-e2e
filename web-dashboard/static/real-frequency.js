(function () {
  function byId(id) { return document.getElementById(id); }
  function setText(id, val) {
    var el = byId(id);
    if (el) el.textContent = val == null ? "-" : String(val);
  }

  var running = false;

  function setBusy(busy) {
    running = !!busy;
    var el = byId("realFreqRunBtn");
    if (el) el.disabled = running;
  }

  async function api(path, opts) {
    var res = await fetch(path, Object.assign({ headers: { "Content-Type": "application/json" } }, opts || {}));
    var text = await res.text();
    var data;
    try { data = text ? JSON.parse(text) : {}; }
    catch (e) { data = { ok: false, error: text || String(e) }; }
    if (!res.ok) throw new Error(data.error || data.message || text || ("HTTP " + res.status));
    return data;
  }

  function renderBandResults(rows) {
    var body = byId("freqBandResultsBody");
    if (!body) return;
    if (!rows || !rows.length) {
      body.innerHTML = '<tr><td colspan="11">No runs yet. Click Run to start.</td></tr>';
      return;
    }
    var F_REF = 2593.35;
    body.innerHTML = rows.map(function (r) {
      var attachOk = (r.retune_verdict || r.verdict || "").indexOf("PASS") !== -1 ||
                     (r.retune_verdict || r.verdict || "").indexOf("OK") !== -1;
      var attachColor = attachOk ? "var(--ok)" : "var(--err)";
      var mbps = parseFloat(r.tcp_mbps) || 0;
      var mbpsColor = mbps > 10 ? "var(--ok)" : mbps > 5 ? "var(--warn)" : "var(--err)";
      var mbpsDisplay = (r.tcp_mbps && r.tcp_mbps !== "?") ? r.tcp_mbps + " Mbps" : "-";

      var freqMhz = parseFloat(r.freq_mhz) || 0;
      var deltaPl = freqMhz > 0 ? 20 * Math.log10(freqMhz / F_REF) : 0;
      var K = Math.pow(10, -deltaPl / 10);
      var pct = Math.round(K * 100);
      var capMatch = (r.netem || "").match(/rate\s+(\d+(?:\.\d+)?)mbit/);
      var capMbit = capMatch ? capMatch[1] : "-";

      return (
        "<tr>" +
        "<td><strong>" + (r.band || r.profile || "-") + "</strong></td>" +
        "<td>" + (r.freq_mhz || "-") + "</td>" +
        "<td style='font-size:0.85em;font-family:monospace'>" + (r.ssb ? r.ssb + " / " + (r.pointa || "-") : "-") + "</td>" +
        "<td style='color:" + attachColor + ";font-weight:bold'>" + (r.retune_verdict || r.verdict || "-") + "</td>" +
        "<td>" + (freqMhz > 0 ? deltaPl.toFixed(2) : "-") + "</td>" +
        "<td>" + (freqMhz > 0 ? K.toFixed(2) : "-") + "</td>" +
        "<td>" + capMbit + "</td>" +
        "<td>" + (r.ping_avg || "-") + "</td>" +
        "<td>" + (r.ping_loss || "-") + "</td>" +
        "<td style='font-weight:bold;color:" + mbpsColor + "'>" + mbpsDisplay + "</td>" +
        "<td style='font-size:0.85em'>" + (r.timestamp || "-") + "</td>" +
        "</tr>"
      );
    }).join("");
  }

  var hasStatus = false;

  async function refreshStatus() {
    try {
      var data = await api("/api/real-frequency/status");
      var keys = data.carrier_keys || {};
      var lines = [
        "ok=" + data.ok,
        "active_profile=" + (data.active_profile || "-"),
        "du_deploy=" + (data.du_deploy || "-"),
        "du_cm=" + (data.du_cm || "-"),
        "tunnel_ready=" + (data.tunnel_ready || "-"),
        "",
        "===== Current DU carrier keys =====",
      ];
      Object.keys(keys).forEach(function (k) { lines.push("  " + k + " = " + keys[k]); });
      setText("realFreqSummary", lines.join("\n"));
      hasStatus = true;
      pollOk("freq-status");
    } catch (e) {
      pollFail("freq-status");
      if (!hasStatus) setText("realFreqSummary", "ERROR reading retune status:\n" + String(e));
    }
  }

  async function refreshResults() {
    try {
      var r = await api("/api/real-frequency/kpi-results");
      renderBandResults(r.rows || []);
      pollOk("freq-results");
    } catch (e) {
      pollFail("freq-results");
    }
  }

  async function runBandFreq(profile, btn) {
    setBusy(true);
    setText("realFreqLog",
      "Running " + profile + ": REAL carrier retune (restarts DU0+UE1, ~2-3 min), then EMULATED netem KPI where a band model exists...");
    try {
      var data = await api("/api/real-frequency/run-band", {
        method: "POST",
        body: JSON.stringify({ profile: profile }),
      });
      setText("realFreqLog", (data.ok ? "[DONE] " : "[FAILED] ") + profile + "\n\n" + (data.log || ""));
      await refreshResults();
      await refreshStatus();
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
    } finally {
      setBusy(false);
    }
  }

  window.runBandFreq = runBandFreq;

  document.addEventListener("DOMContentLoaded", function () {
    var root = byId("realFrequencyRoot");
    if (!root) return;

    var runBtn = byId("realFreqRunBtn");
    if (runBtn) runBtn.addEventListener("click", function () {
      var sel = byId("realFreqSelect");
      if (sel) runBandFreq(sel.value, runBtn);
    });

    setText("realFreqLog", "Ready.");
    refreshStatus();
    refreshResults();
    window.autoRefresh(refreshStatus, 30000, function () { return running; });
    window.autoRefresh(refreshResults, 30000, function () { return running; });
  });
})();
