(function () {
  function byId(id) {
    return document.getElementById(id);
  }

  function setText(id, value) {
    var el = byId(id);
    if (el) el.textContent = value == null ? "-" : String(value);
  }

  function setBusy(isBusy) {
    var ids = ["frequencyRefreshBtn", "frequencyApplyBtn", "frequencyKpiBtn", "frequencyRestoreBtn"];
    ids.forEach(function (id) {
      var el = byId(id);
      if (el) el.disabled = !!isBusy;
    });
  }

  async function api(path, options) {
    var res = await fetch(path, Object.assign({
      headers: { "Content-Type": "application/json" }
    }, options || {}));

    var text = await res.text();
    var data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch (e) {
      data = { ok: false, error: text || String(e) };
    }

    if (!res.ok) {
      throw new Error(data.error || data.message || text || ("HTTP " + res.status));
    }
    return data;
  }

  function selectedProfile() {
    var el = byId("frequencyProfileSelect");
    return el ? el.value : "mid-band-3500";
  }

  function renderResults(data) {
    var body = byId("frequencyResultsBody");
    if (!body) return;

    var rows = (data && data.rows) || [];
    if (!rows.length) {
      body.innerHTML = '<tr><td colspan="8">No frequency KPI results yet.</td></tr>';
      return;
    }

    body.innerHTML = rows.map(function (r) {
      return (
        "<tr>" +
          "<td>" + (r.profile || "-") + "</td>" +
          "<td>" + (r.freq_mhz || "-") + "</td>" +
          "<td>" + (r.band_label || "-") + "</td>" +
          "<td>" + (r.rf_values || "-") + "</td>" +
          "<td>" + (r.tc_cmd || "-") + "</td>" +
          "<td>" + (r.ping_avg_ms || "-") + "</td>" +
          "<td>" + (r.image_mbps || "-") + "</td>" +
          "<td>" + (r.tcp_mbps || "-") + "</td>" +
        "</tr>"
      );
    }).join("");
  }

  async function loadFrequencyResults() {
    var data = await api("/api/frequency/results");
    renderResults(data);
  }

  async function refreshFrequencyStatus() {
    setBusy(true);
    setText("frequencyLog", "Refreshing frequency profile status...");
    try {
      var data = await api("/api/frequency/status");

      var summary = [
        "ok=" + data.ok,
        "active_profile=" + (data.active_profile || "-"),
        "freq_mhz=" + (data.freq_mhz || "-"),
        "band_label=" + (data.band_label || "-"),
        "serveraddr=" + (data.serveraddr || "-"),
        "rf_values=" + (data.rf_values || "-"),
        "qdisc=" + (data.qdisc || "-"),
        "tunnel_ready=" + (data.tunnel_ready || "-"),
        "",
        data.note || ""
      ].join("\n");

      setText("frequencySummary", summary);
      setText("frequencyLog", data.log || "Status OK.");

      var select = byId("frequencyProfileSelect");
      if (select && data.active_profile) select.value = data.active_profile;

      await loadFrequencyResults();
    } catch (e) {
      setText("frequencyLog", "ERROR refreshing frequency status:\n" + String(e));
    } finally {
      setBusy(false);
    }
  }

  async function applyFrequencyProfile() {
    var profile = selectedProfile();
    setBusy(true);
    setText("frequencyLog", "Applying frequency profile " + profile + "...");
    try {
      var data = await api("/api/frequency/apply", {
        method: "POST",
        body: JSON.stringify({ profile: profile })
      });

      setText("frequencyLog", "Apply result:\n\n" + JSON.stringify(data, null, 2));
      await refreshFrequencyStatus();
    } catch (e) {
      setText("frequencyLog", "ERROR applying frequency profile:\n" + String(e));
    } finally {
      setBusy(false);
    }
  }

  async function runFrequencyKpiTest() {
    var profile = selectedProfile();
    setBusy(true);
    setText("frequencyLog", "Running KPI test for frequency profile " + profile + "...");
    try {
      var data = await api("/api/frequency/kpi-test", {
        method: "POST",
        body: JSON.stringify({ profile: profile })
      });

      setText("frequencyLog", "KPI result:\n\n" + JSON.stringify(data, null, 2));
      await refreshFrequencyStatus();
    } catch (e) {
      setText("frequencyLog", "ERROR running frequency KPI test:\n" + String(e));
    } finally {
      setBusy(false);
    }
  }

  async function restoreFrequencyProfile() {
    setBusy(true);
    setText("frequencyLog", "Restoring mid-band-3500 baseline...");
    try {
      var data = await api("/api/frequency/restore", {
        method: "POST",
        body: JSON.stringify({})
      });

      setText("frequencyLog", "Restore result:\n\n" + JSON.stringify(data, null, 2));
      await refreshFrequencyStatus();
    } catch (e) {
      setText("frequencyLog", "ERROR restoring frequency baseline:\n" + String(e));
    } finally {
      setBusy(false);
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = byId("frequencyProfileRoot");
    if (!root) return;

    var refreshBtn = byId("frequencyRefreshBtn");
    var applyBtn = byId("frequencyApplyBtn");
    var kpiBtn = byId("frequencyKpiBtn");
    var restoreBtn = byId("frequencyRestoreBtn");

    if (refreshBtn) refreshBtn.addEventListener("click", refreshFrequencyStatus);
    if (applyBtn) applyBtn.addEventListener("click", applyFrequencyProfile);
    if (kpiBtn) kpiBtn.addEventListener("click", runFrequencyKpiTest);
    if (restoreBtn) restoreBtn.addEventListener("click", restoreFrequencyProfile);

    refreshFrequencyStatus();
  });
})();
