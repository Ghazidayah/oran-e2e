(function () {
  function byId(id) { return document.getElementById(id); }
  function setText(id, val) {
    var el = byId(id);
    if (el) el.textContent = val == null ? "-" : String(val);
  }

  function setBusy(busy) {
    ["realFreqRefreshBtn", "realFreqApplyBtn", "realFreqRestoreBtn"].forEach(function (id) {
      var el = byId(id);
      if (el) el.disabled = !!busy;
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

  function selectedProfile() {
    var el = byId("realFreqSelect");
    return el ? el.value : "n78-current";
  }

  function renderResults(data) {
    var body = byId("realFreqResultsBody");
    if (!body) return;
    var rows = (data && data.rows) || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="7">No retune history yet.</td></tr>';
      return;
    }
    body.innerHTML = rows.map(function (r) {
      var isExp = r.profile === "n28-700";
      var verdict = r.verdict || "";
      var ok = verdict.indexOf("PASS") !== -1 || verdict.indexOf("OK") !== -1;
      var verdictColor = isExp ? "#ff9800" : (ok ? "#4caf50" : "#f44336");
      var profileLabel = isExp ? "⚠ " + (r.profile || "-") : (r.profile || "-");
      return (
        "<tr>" +
          "<td>" + profileLabel + "</td>" +
          "<td>" + (r.freq_mhz || "-") + "</td>" +
          "<td>" + (r.band || "-") + "</td>" +
          "<td>" + (r.ssb || "-") + "</td>" +
          "<td>" + (r.du_deploy || "-") + "</td>" +
          "<td style='color:" + verdictColor + ";font-weight:bold'>" + (r.verdict || "-") + "</td>" +
          "<td>" + (r.timestamp || "-") + "</td>" +
        "</tr>"
      );
    }).join("");
  }

  async function refreshStatus() {
    setBusy(true);
    setText("realFreqLog", "Fetching real carrier retune status...");
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
      setText("realFreqLog", data.log || "Status OK.");

      var results = await api("/api/real-frequency/results");
      renderResults(results);
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
    } finally {
      setBusy(false);
    }
  }

  async function applyRetune() {
    var profile = selectedProfile();
    setBusy(true);
    var msg = "Applying real carrier retune: " + profile + "\n\nThis restarts DU + UE pods — may take several minutes...";
    if (profile === "n28-700") {
      msg += "\n\n⚠ EXPERIMENTAL: n28 700 MHz FDD — cell boot and UE sync expected up to RACH Msg2.\n   Msg3 is blocked by OAI RFsim FDD limitation — no data tunnel will form.\n   Use Restore n78-current to return to baseline.";
    }
    setText("realFreqLog", msg);
    try {
      var data = await api("/api/real-frequency/apply", {
        method: "POST",
        body: JSON.stringify({ profile: profile })
      });
      setText("realFreqLog", (data.ok ? "[DONE] " : "[FAILED] ") + "profile=" + profile + "\n\n" + (data.log || ""));
      await refreshStatus();
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
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
      await refreshStatus();
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
    } finally {
      setBusy(false);
    }
  }

  // ── KPI comparison section ───────────────────────────────────────────────

  var KPI_PROFILES = [
    {value: "n78-3500",       label: "n78-3500",       mhz: "3499.68", band: "n78", duplex: "TDD / 30 kHz"},
    {value: "n78-cband-3780", label: "n78-cband-3780", mhz: "3779.04", band: "n78", duplex: "TDD / 30 kHz"},
    {value: "n41-2600",       label: "n41-2600",       mhz: "2593.35", band: "n41", duplex: "TDD / 30 kHz"},
    {value: "n28-700",        label: "n28-700",        mhz: "781.25",  band: "n28", duplex: "FDD / 15 kHz"},
  ];

  function setKpiBusy(busy) {
    ["kpiRunOneBtn", "kpiRunAllBtn"].forEach(function (id) {
      var el = byId(id);
      if (el) el.disabled = !!busy;
    });
  }

  function renderKpiTable(rows) {
    var body = byId("kpiTableBody");
    if (!body) return;
    var rowMap = {};
    (rows || []).forEach(function (r) { rowMap[r.profile] = r; });

    body.innerHTML = KPI_PROFILES.map(function (p) {
      var r = rowMap[p.value];
      var isLow = (p.value === "n28-700");
      var label = (isLow ? "⚠ " : "") + p.label;

      if (!r) {
        return (
          "<tr>" +
          "<td style='padding:8px;font-weight:bold'>" + label + "</td>" +
          "<td style='padding:8px'>" + p.band + "</td>" +
          "<td style='padding:8px'>" + p.mhz + "</td>" +
          "<td style='padding:8px'>" + p.duplex + "</td>" +
          "<td style='padding:8px;color:#555'>—</td>" +
          "<td style='padding:8px;color:#555'>—</td>" +
          "<td style='padding:8px;color:#555'>—</td>" +
          "<td style='padding:8px;color:#555'>—</td>" +
          "<td style='padding:8px;color:#555'>—</td>" +
          "<td style='padding:8px;color:#555'>—</td>" +
          "</tr>"
        );
      }

      var mbps = parseFloat(r.tcp_mbps) || 0;
      var mbpsColor = mbps > 30 ? "#4caf50" : mbps > 15 ? "#ff9800" : "#f44336";

      return (
        "<tr>" +
        "<td style='padding:8px;font-weight:bold'>" + label + "</td>" +
        "<td style='padding:8px'>" + p.band + "</td>" +
        "<td style='padding:8px'>" + p.mhz + "</td>" +
        "<td style='padding:8px'>" + p.duplex + "</td>" +
        "<td style='padding:8px;font-family:monospace;font-size:0.82em'>" + (r.netem || "—") + "</td>" +
        "<td style='padding:8px'>" + (r.ping_avg || "—") + "</td>" +
        "<td style='padding:8px'>" + (r.ping_loss || "—") + "</td>" +
        "<td style='padding:8px;font-weight:bold;color:" + mbpsColor + "'>" +
          (r.tcp_mbps && r.tcp_mbps !== "?" ? r.tcp_mbps + " Mbps" : "—") +
        "</td>" +
        "<td style='padding:8px'>" + (r.retransmits || "—") + "</td>" +
        "<td style='padding:8px;font-size:0.85em'>" + (r.timestamp || "—") + "</td>" +
        "</tr>"
      );
    }).join("");
  }

  async function runKpiTest(profile) {
    setKpiBusy(true);
    setText("realFreqLog", "Running KPI test: " + profile + "\napplying tc netem → ping 20× → iperf3 15 s → clear netem...");
    try {
      var data = await api("/api/real-frequency/kpi-test", {
        method: "POST",
        body: JSON.stringify({profile: profile}),
      });
      setText("realFreqLog", (data.ok ? "[DONE] " : "[FAILED] ") + profile + "\n\n" + (data.log || data.error || ""));
      var res = await api("/api/real-frequency/kpi-results");
      renderKpiTable(res.rows || []);
    } catch (e) {
      setText("realFreqLog", "ERROR: " + String(e));
    } finally {
      setKpiBusy(false);
    }
  }

  async function runAllKpis() {
    setKpiBusy(true);
    var profiles = KPI_PROFILES.map(function (p) { return p.value; });
    for (var i = 0; i < profiles.length; i++) {
      setText("realFreqLog", "Running KPI " + (i + 1) + " / " + profiles.length + ": " + profiles[i] + "...");
      try {
        var data = await api("/api/real-frequency/kpi-test", {
          method: "POST",
          body: JSON.stringify({profile: profiles[i]}),
        });
        var res = await api("/api/real-frequency/kpi-results");
        renderKpiTable(res.rows || []);
        setText("realFreqLog", (data.ok ? "[DONE] " : "[FAILED] ") + profiles[i] + "\n\n" + (data.log || data.error || ""));
      } catch (e) {
        setText("realFreqLog", "ERROR on " + profiles[i] + ": " + String(e));
      }
    }
    setKpiBusy(false);
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = byId("realFrequencyRoot");
    if (!root) return;

    var refreshBtn = byId("realFreqRefreshBtn");
    var applyBtn   = byId("realFreqApplyBtn");
    var restoreBtn = byId("realFreqRestoreBtn");

    if (refreshBtn) refreshBtn.addEventListener("click", refreshStatus);
    if (applyBtn)   applyBtn.addEventListener("click", applyRetune);
    if (restoreBtn) restoreBtn.addEventListener("click", restoreBaseline);

    refreshStatus();

    var kpiOneBtn = byId("kpiRunOneBtn");
    var kpiAllBtn = byId("kpiRunAllBtn");
    if (kpiOneBtn) kpiOneBtn.addEventListener("click", function () {
      var sel = byId("kpiProfileSelect");
      if (sel) runKpiTest(sel.value);
    });
    if (kpiAllBtn) kpiAllBtn.addEventListener("click", runAllKpis);

    api("/api/real-frequency/kpi-results").then(function (r) {
      renderKpiTable(r.rows || []);
    }).catch(function () {});
  });
})();
