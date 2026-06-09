(() => {
  const PROFILES = [
    ["scheduler-auto", "Scheduler Auto"],
    ["qpsk-robust", "QPSK Robust"],
    ["qam16-balanced", "16QAM Balanced"],
    ["qam64-throughput", "64QAM Throughput"],
    ["qam256-max", "256QAM Max"],
    ["qpsk-stress", "QPSK Stress / Calibration"]
  ];

  const style = document.createElement("style");
  style.textContent = `
    .radio-profile-section { margin-top: 18px; }
    .radio-profile-title { font-size: 20px; font-weight: 700; margin-bottom: 12px; }
    .radio-profile-subtitle { opacity: .88; margin-bottom: 18px; }
    .radio-card-grid { display: grid; grid-template-columns: repeat(5, minmax(130px, 1fr)); gap: 12px; margin-bottom: 14px; }
    .radio-card { border: 1px solid rgba(148,163,184,.25); border-radius: 10px; padding: 12px 14px; background: rgba(15,23,42,.55); }
    .radio-card .label { font-size: 12px; opacity: .75; margin-bottom: 6px; }
    .radio-card .value { font-size: 16px; font-weight: 700; word-break: break-word; }
    .radio-controls { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0 18px; align-items: center; }
    .radio-controls select { background: #0f172a; color: #e5e7eb; border: 1px solid rgba(148,163,184,.35); border-radius: 8px; padding: 9px 10px; }
    .radio-controls button { background: #2563eb; color: white; border: 0; border-radius: 8px; padding: 10px 14px; font-weight: 700; cursor: pointer; }
    .radio-controls button.secondary { background: #334155; }
    .radio-note { border: 1px solid rgba(251,191,36,.35); color: #fde68a; border-radius: 10px; padding: 10px 12px; margin: 12px 0; background: rgba(120,53,15,.22); }
    .radio-table-wrap { overflow-x: auto; border: 1px solid rgba(148,163,184,.20); border-radius: 10px; margin-top: 14px; }
    .radio-results { width: 100%; border-collapse: collapse; font-size: 13px; }
    .radio-results th, .radio-results td { border-bottom: 1px solid rgba(148,163,184,.16); padding: 10px; text-align: left; white-space: nowrap; }
    .radio-results th { color: #cbd5e1; background: rgba(15,23,42,.75); }
    .radio-log { margin-top: 14px; min-height: 150px; max-height: 360px; overflow: auto; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 13px; border: 1px solid rgba(148,163,184,.25); border-radius: 10px; padding: 14px; background: rgba(2,6,23,.72); }
    @media (max-width: 900px) { .radio-card-grid { grid-template-columns: repeat(2, minmax(130px, 1fr)); } }
  `;
  document.head.appendChild(style);

  function createRoot() {
    let root = document.querySelector(".handover-panel") ||
               document.querySelector("#mixed-du-handover-root") ||
               document.querySelector("#handover-root");

    if (!root) {
      root = document.createElement("section");
      root.className = "panel";
      (document.querySelector("main") || document.body).appendChild(root);
    }

    root.classList.add("radio-profile-section");
    root.innerHTML = `
      <div class="radio-profile-title">Radio / Modulation Profile Control</div>
      <div class="radio-profile-subtitle">
        DU-aware RFsim radio profile control for ue1. This replaces the old mixed-DU handover section.
      </div>

      <div class="radio-card-grid">
        <div class="radio-card"><div class="label">Active Profile</div><div class="value" id="rp-active-profile">loading</div></div>
        <div class="radio-card"><div class="label">Active DU</div><div class="value" id="rp-active-du">loading</div></div>
        <div class="radio-card"><div class="label">Slice</div><div class="value" id="rp-slice">loading</div></div>
        <div class="radio-card"><div class="label">UE Tunnel</div><div class="value" id="rp-tunnel">loading</div></div>
        <div class="radio-card"><div class="label">Last Verdict</div><div class="value" id="rp-verdict">not run yet</div></div>
      </div>

      <div class="radio-controls">
        <select id="rp-profile-select">
          ${PROFILES.map(([v, t]) => `<option value="${v}">${t}</option>`).join("")}
        </select>
        <button id="rp-refresh">Refresh Status</button>
        <button id="rp-apply">Apply Profile + Validate</button>
        <button id="rp-kpi">Run KPI Test</button>
        <button id="rp-baseline" class="secondary">Restore Scheduler Auto</button>
        <button id="rp-logs" class="secondary">Show Latest Logs</button>
      </div>

      <div class="radio-note">
        Honest limitation: these are RFsim AWGN / MCS-tendency profiles.
        Direct forced QPSK/16QAM/64QAM/256QAM was not proven.
        Final RFsim-only stress testing still showed MCS 0 / Qm 2 / SNR around 51 dB.
      </div>

      <h3>Radio Profile Results / Comparison</h3>
      <div class="radio-table-wrap">
        <table class="radio-results">
          <thead>
            <tr>
              <th>Profile</th><th>RFsim values</th><th>Ping avg</th><th>Image Mbps</th><th>TCP Mbps</th><th>Retransmits</th><th>MCS/SNR proof</th><th>Verdict</th>
            </tr>
          </thead>
          <tbody id="rp-results-body"><tr><td colspan="8">Loading results...</td></tr></tbody>
        </table>
      </div>

      <h3>Radio Profile Logs</h3>
      <pre class="radio-log" id="rp-log">Ready.</pre>
    `;
  }

  async function api(path, options = {}) {
    const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || JSON.stringify(data));
    return data;
  }

  function setText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = (text === undefined || text === null) ? "unknown" : text;
  }

  function log(text) { setText("rp-log", text || ""); }

  function selectedProfile() {
    var select = document.getElementById("rp-profile-select");
    return select ? select.value : "scheduler-auto";
  }

  function renderRows(rows) {
    const body = document.getElementById("rp-results-body");
    if (!body) return;
    if (!rows || !rows.length) {
      body.innerHTML = `<tr><td colspan="8">No results yet.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(r => `
      <tr>
        <td>${r.profile || "—"}</td>
        <td>${r.modulation || "—"}</td>
        <td>${r.ping_avg_ms || "—"}</td>
        <td>${r.image_mbps || "—"}</td>
        <td>${r.tcp_mbps || "—"}</td>
        <td>${r.retransmits || "—"}</td>
        <td>${r.mcs_snr || "—"}</td>
        <td>${r.verdict || "—"}</td>
      </tr>
    `).join("");
  }

  async function refreshStatus() {
    log("Refreshing radio profile status...");
    const s = await api("/api/radio/status");
    setText("rp-active-profile", s.active_profile);
    setText("rp-active-du", `${s.active_du_deploy || "unknown"} / ${s.serveraddr || "unknown"}`);
    setText("rp-slice", s.slice);
    setText("rp-tunnel", s.tunnel_ready === "yes" ? "READY" : "NOT READY");
    setText("rp-verdict", s.ok ? "STATUS OK" : "STATUS CHECK FAILED");
    const select = document.getElementById("rp-profile-select");
    if (select && PROFILES.some(([v]) => v === s.active_profile)) select.value = s.active_profile;
    log(s.log);
  }

  async function refreshResults() {
    const r = await api("/api/radio/results");
    renderRows([...(r.dynamic_rows || []), ...(r.reference_rows || [])]);
  }

  async function applyProfile(profile) {
    log(`Applying ${profile} and validating...`);
    setText("rp-verdict", "running");
    const r = await api("/api/radio/apply", {
      method: "POST",
      body: JSON.stringify({ profile })
    });
    setText("rp-verdict", r.ok ? "PASS" : "FAIL");
    log(r.log);
    await refreshStatus();
    await refreshResults();
  }

  async function runKpi(profile) {
    log(`Running KPI test for ${profile}. This can take several minutes...`);
    setText("rp-verdict", "KPI running");
    const r = await api("/api/radio/kpi-test", {
      method: "POST",
      body: JSON.stringify({ profile })
    });
    setText("rp-verdict", r.ok ? "KPI PASS" : "KPI FAIL");
    log(r.log);
    await refreshStatus();
    await refreshResults();
  }

  async function latestLogs() {
    const r = await api("/api/radio/logs");
    log(r.log);
  }

  document.addEventListener("DOMContentLoaded", async () => {
    createRoot();

    function bindClick(id, handler) {
      var el = document.getElementById(id);
      if (el) {
        el.addEventListener("click", handler);
      }
    }

    bindClick("rp-refresh", function () { refreshStatus().catch(function (e) { log(String(e)); }); });
    bindClick("rp-apply", function () { applyProfile(selectedProfile()).catch(function (e) { log(String(e)); }); });
    bindClick("rp-kpi", function () { runKpi(selectedProfile()).catch(function (e) { log(String(e)); }); });
    bindClick("rp-baseline", function () { applyProfile("scheduler-auto").catch(function (e) { log(String(e)); }); });
    bindClick("rp-logs", function () { latestLogs().catch(function (e) { log(String(e)); }); });

    try {
      await refreshStatus();
      await refreshResults();
    } catch (e) {
      log(String(e));
    }
  });
})();
