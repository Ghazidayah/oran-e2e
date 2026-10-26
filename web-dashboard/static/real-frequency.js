(function () {
  var byId = OranUI.byId;
  var setText = OranUI.setText;
  var api = OranUI.jsonApi;

  var running = false;

  var currentSnrRef = 20;

  // Shannon model, same formulas as real_frequency_api.py.
  function bandK(freqMhz, snrRef) {
    var dpl = 20 * Math.log10(freqMhz / 2593.35);
    var snrT = snrRef - dpl;
    var k = Math.log(1 + Math.pow(10, snrT / 10)) / Math.log(1 + Math.pow(10, snrRef / 10));
    return { dpl: dpl, snr: snrT, k: k };
  }

  function renderBandResults(rows) {
    var body = byId("freqBandResultsBody");
    if (!body) return;
    if (!rows || !rows.length) {
      body.innerHTML = '<tr><td colspan="11">No runs yet. Click Run to start.</td></tr>';
      return;
    }
    body.innerHTML = rows.map(function (r) {
      var attachOk = (r.retune_verdict || r.verdict || "").indexOf("PASS") !== -1 ||
                     (r.retune_verdict || r.verdict || "").indexOf("OK") !== -1;
      var attachColor = attachOk ? "var(--ok)" : "var(--err)";
      var mbpsDisplay = (r.tcp_mbps && r.tcp_mbps !== "?") ? r.tcp_mbps + " Mbps" : "-";

      var freqMhz = parseFloat(r.freq_mhz) || 0;
      var m = freqMhz > 0 ? bandK(freqMhz, r.snr_ref_db || currentSnrRef) : { dpl: 0, snr: null, k: 0 };
      var deltaPl = m.dpl;
      var K = m.k;
      var snrText = (freqMhz > 0 && m.snr !== null) ? m.snr.toFixed(2) : "-";
      var capMatch = (r.netem || "").match(/rate\s+(\d+(?:\.\d+)?)(mbit|kbit)/i);
      var capMbit = "-";
      if (capMatch) {
        var capVal = parseFloat(capMatch[1]);
        if (capMatch[2].toLowerCase() === "kbit") capVal = capVal / 1000;
        capMbit = String(Math.round(capVal * 100) / 100);
      }

      return (
        "<tr>" +
        "<td><strong>" + (r.band || r.profile || "-") + "</strong></td>" +
        "<td>" + (r.freq_mhz || "-") + "</td>" +
        "<td style='font-size:0.85em;font-family:monospace'>" + (r.ssb ? r.ssb + " / " + (r.pointa || "-") : "-") + "</td>" +
        "<td style='color:" + attachColor + ";font-weight:bold'>" + (r.retune_verdict || r.verdict || "-") + "</td>" +
        "<td>" + (freqMhz > 0 ? deltaPl.toFixed(2) : "-") + "</td>" +
        "<td>" + snrText + "</td>" +
        "<td>" + (freqMhz > 0 ? K.toFixed(2) : "-") + "</td>" +
        "<td>" + capMbit + "</td>" +
        "<td>" + (r.ping_avg || "-") + "</td>" +
        "<td style='color:#000'>" + mbpsDisplay + "</td>" +
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
        "active_profile=" + (data.active_profile || "-"),
        "du_deploy=" + (data.du_deploy || "-"),
        "tunnel_ready=" + (data.tunnel_ready || "-"),
        "",
        "===== Current DU carrier keys =====",
      ];
      Object.keys(keys).forEach(function (k) { lines.push("  " + k + " = " + keys[k]); });
      setText("realFreqSummary", lines.join("\n"));
      hasStatus = true;
    } catch (e) {
      if (!hasStatus) setText("realFreqSummary", "ERROR reading retune status:\n" + String(e));
    }
  }

  async function refreshResults() {
    try {
      var r = await api("/api/real-frequency/kpi-results");
      if (r.snr_ref_db) currentSnrRef = r.snr_ref_db;
      renderBandResults(r.rows || []);
    } catch (e) {
      // Echec d'une requete automatique: on garde les dernieres donnees affichees.
    }
  }

  async function runBandFreq(profile) {
    running = true;
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
      return !!data.ok;
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
      return false;
    } finally {
      running = false;
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = byId("realFrequencyRoot");
    if (!root) return;

    var runBtn = byId("realFreqRunBtn");
    if (runBtn) runBtn.addEventListener("click", function () {
      var sel = byId("realFreqSelect");
      if (sel) OranUI.runWithButton(runBtn, [runBtn], function () { return runBandFreq(sel.value); });
    });

    setText("realFreqLog", "Ready.");
    refreshStatus();
    refreshResults();
    window.autoRefresh(refreshStatus, 30000, function () { return running; });
    window.autoRefresh(refreshResults, 30000, function () { return running; });
  });
})();
