(function () {
  function byId(id) { return document.getElementById(id); }
  function setText(id, val) {
    var el = byId(id);
    if (el) el.textContent = val == null ? "-" : String(val);
  }

  function setBusy(busy) {
    ["realFreqRefreshBtn", "realFreqRestoreBtn"].forEach(function (id) {
      var el = byId(id);
      if (el) el.disabled = !!busy;
    });
    document.querySelectorAll("[data-freq-band-btn]").forEach(function (btn) {
      btn.disabled = !!busy;
    });
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
      body.innerHTML = '<tr><td colspan="9">No runs yet — click a band button above to start.</td></tr>';
      return;
    }
    body.innerHTML = rows.map(function (r) {
      var attachOk = (r.retune_verdict || r.verdict || "").indexOf("PASS") !== -1 ||
                     (r.retune_verdict || r.verdict || "").indexOf("OK") !== -1;
      var attachColor = attachOk ? "var(--ok)" : "var(--err)";
      var mbps = parseFloat(r.tcp_mbps) || 0;
      var mbpsColor = mbps > 10 ? "var(--ok)" : mbps > 5 ? "var(--warn)" : "var(--err)";
      var mbpsDisplay = (r.tcp_mbps && r.tcp_mbps !== "?") ? r.tcp_mbps + " Mbps" : "—";
      return (
        "<tr>" +
        "<td><strong>" + (r.band || r.profile || "-") + "</strong></td>" +
        "<td>" + (r.freq_mhz || "-") + "</td>" +
        "<td style='font-size:0.85em;font-family:monospace'>" + (r.ssb ? r.ssb + " / " + (r.pointa || "-") : "-") + "</td>" +
        "<td style='color:" + attachColor + ";font-weight:bold'>" + (r.retune_verdict || r.verdict || "-") + "</td>" +
        "<td style='font-size:0.85em'>" + (r.netem || "—") + "</td>" +
        "<td>" + (r.ping_avg || "—") + "</td>" +
        "<td>" + (r.ping_loss || "—") + "</td>" +
        "<td style='font-weight:bold;color:" + mbpsColor + "'>" + mbpsDisplay + "</td>" +
        "<td style='font-size:0.85em'>" + (r.timestamp || "-") + "</td>" +
        "</tr>"
      );
    }).join("");
  }

  async function refreshStatus(writeLog) {
    writeLog = (writeLog !== false);
    setBusy(true);
    if (writeLog) setText("realFreqLog", "Fetching real carrier retune status...");
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
      if (writeLog) setText("realFreqLog", data.log || "Status OK.");
    } catch (e) {
      if (writeLog) setText("realFreqLog", "ERROR: " + String(e));
    } finally {
      setBusy(false);
    }
  }

  async function restoreBaseline() {
    setBusy(true);
    setText("realFreqLog", "Restoring baseline n78-current...\n\nThis restarts DU + UE pods — may take several minutes...");
    try {
      var data = await api("/api/real-frequency/restore", { method: "POST", body: JSON.stringify({}) });
      setText("realFreqLog", (data.ok ? "[DONE] " : "[FAILED] ") + "restore n78-current\n\n" + (data.log || ""));
      await refreshStatus(false);
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
    } finally {
      setBusy(false);
    }
  }

  async function runBandFreq(profile, btn) {
    setBusy(true);
    setText("realFreqLog",
      "Running " + profile + ": REAL carrier retune (restarts DU0+UE1, ~2-3 min) then EMULATED netem KPI...");
    try {
      var data = await api("/api/real-frequency/run-band", {
        method: "POST",
        body: JSON.stringify({ profile: profile }),
      });
      setText("realFreqLog", (data.ok ? "[DONE] " : "[FAILED] ") + profile + "\n\n" + (data.log || ""));
      var res = await api("/api/real-frequency/kpi-results");
      renderBandResults(res.rows || []);
      await refreshStatus(false);
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

    var refreshBtn = byId("realFreqRefreshBtn");
    var restoreBtn = byId("realFreqRestoreBtn");

    if (refreshBtn) refreshBtn.addEventListener("click", refreshStatus);
    if (restoreBtn) restoreBtn.addEventListener("click", restoreBaseline);

    setText("realFreqLog", "Ready.");
    refreshStatus(false);

    api("/api/real-frequency/kpi-results").then(function (r) {
      renderBandResults(r.rows || []);
    }).catch(function () {});
  });
})();
