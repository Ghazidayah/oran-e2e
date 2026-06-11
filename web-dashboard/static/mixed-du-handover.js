(() => {
  const PROFILES = [
    ["scheduler-auto",   "Scheduler Auto — adaptive AMC"],
    ["qpsk-robust",      "QPSK Robust — forced MCS 4 (Qm 2)"],
    ["qam16-balanced",   "16QAM Balanced — forced MCS 13 (Qm 4)"],
    ["qam64-throughput", "64QAM Throughput — forced MCS 28 (Qm 6)"],
    ["qam256-max",       "256QAM Max — forced MCS 28 (UE-cap: 64QAM)"],
    ["qpsk-stress",      "QPSK Stress / Calibration — forced MCS 2"],
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
    .radio-note-ok { border: 1px solid rgba(34,197,94,.35); color: #bbf7d0; border-radius: 10px; padding: 10px 12px; margin: 12px 0; background: rgba(6,78,59,.22); }
    .radio-table-wrap { overflow-x: auto; border: 1px solid rgba(148,163,184,.20); border-radius: 10px; margin-top: 14px; }
    .radio-results { width: 100%; border-collapse: collapse; font-size: 13px; }
    .radio-results th, .radio-results td { border-bottom: 1px solid rgba(148,163,184,.16); padding: 10px; text-align: left; white-space: nowrap; }
    .radio-results th { color: #cbd5e1; background: rgba(15,23,42,.75); }
    .radio-results tr.ref-row { opacity: .72; font-style: italic; }
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
        Real forced-MCS profiles for UE1. Each profile caps the gNB scheduler's MCS via
        <code>--MACRLCs.[0].dl/ul_max_mcs</code> on the active DU (auto-detected from UE1 serveraddr —
        no ConfigMap surgery). Modulation order genuinely changes on air; verified in DU logs as Qm 2/4/6.
      </div>

      <div class="radio-card-grid">
        <div class="radio-card"><div class="label">Active Profile</div><div class="value" id="rp-active-profile">—</div></div>
        <div class="radio-card"><div class="label">Max MCS</div><div class="value" id="rp-max-mcs">—</div></div>
        <div class="radio-card"><div class="label">Modulation</div><div class="value" id="rp-modulation">—</div></div>
        <div class="radio-card"><div class="label">Active DU</div><div class="value" id="rp-active-du">—</div></div>
        <div class="radio-card"><div class="label">UE Tunnel</div><div class="value" id="rp-tunnel">—</div></div>
      </div>

      <div class="radio-note-ok">
        ✅ Real MCS forcing verified (2026-06-09): QPSK ~6.7 Mbps · 16QAM ~17.7 Mbps · 64QAM ~30 Mbps.
        Throughput scales with modulation order as theory predicts (Qm 2/4/6).
        256QAM is UE-capability-limited — OAI nr-ue (2025.w45) does not advertise pdsch-256QAM-FR1;
        qam256-max reaches 64QAM. See <code>docs/modulation-scenarios-validation.md</code>.
      </div>

      <div class="radio-controls">
        <select id="rp-profile-select">
          ${PROFILES.map(([v, t]) => `<option value="${v}">${t}</option>`).join("")}
        </select>
        <button id="rp-apply">Apply + Validate</button>
        <button id="rp-kpi">Run KPI Test</button>
        <button id="rp-baseline" class="secondary">Restore Scheduler Auto</button>
        <button id="rp-refresh" class="secondary">Refresh Status</button>
        <button id="rp-logs" class="secondary">Show Logs</button>
        <button id="rp-clear-logs" class="secondary">Clear Logs</button>
      </div>

      <h3>Modulation Profile KPI Results</h3>
      <p style="font-size:13px;opacity:.8">
        Italic rows = reference values from <code>docs/modulation-scenarios-validation.md</code>.
        Live runs (Apply / KPI Test) appear as regular rows.
      </p>
      <div class="radio-table-wrap">
        <table class="radio-results">
          <thead>
            <tr>
              <th>Profile</th><th>Max MCS</th><th>Modulation</th><th>Ping avg ms</th><th>TCP Mbps</th><th>Retransmits</th><th>Verdict</th>
            </tr>
          </thead>
          <tbody id="rp-results-body"><tr><td colspan="7">Loading results...</td></tr></tbody>
        </table>
      </div>

      <h3>Logs</h3>
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
    if (el) el.textContent = (text === undefined || text === null) ? "—" : text;
  }

  function log(text) { setText("rp-log", text || ""); }

  function selectedProfile() {
    const select = document.getElementById("rp-profile-select");
    return select ? select.value : "scheduler-auto";
  }

  function verdictStyle(verdict) {
    if (!verdict) return "";
    if (verdict.includes("PASS") || verdict.includes("VALIDATED")) return "color:#4caf50;font-weight:bold";
    if (verdict.includes("FAIL")) return "color:#f44336;font-weight:bold";
    if (verdict.includes("cap") || verdict.includes("⚠")) return "color:#ff9800;font-weight:bold";
    return "";
  }

  function renderRows(rows) {
    const body = document.getElementById("rp-results-body");
    if (!body) return;
    if (!rows || !rows.length) {
      body.innerHTML = `<tr><td colspan="7">No results yet — apply a profile or run a KPI test.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(r => {
      const isRef = !!r.source;
      const mbps = parseFloat(r.tcp_mbps) || 0;
      const mbpsStyle = mbps > 20 ? "color:#4caf50;font-weight:bold"
                      : mbps > 10 ? "color:#ff9800;font-weight:bold"
                      : mbps > 0  ? "color:#f44336;font-weight:bold"
                      : "";
      const verdict = r.verdict || "—";
      return `<tr${isRef ? ' class="ref-row"' : ""}>
        <td>${r.profile || "—"}</td>
        <td>${r.max_mcs || "—"}</td>
        <td>${r.modulation || "—"}</td>
        <td>${r.ping_avg_ms || "—"}</td>
        <td style="${mbpsStyle}">${r.tcp_mbps || "—"}</td>
        <td>${r.retransmits || "—"}</td>
        <td style="${verdictStyle(verdict)}">${verdict}</td>
      </tr>`;
    }).join("");
  }

  async function refreshStatus() {
    log("Refreshing modulation profile status...");
    try {
      const s = await api("/api/radio/status");
      setText("rp-active-profile", s.active_profile);
      setText("rp-max-mcs", s.max_mcs || "—");
      setText("rp-modulation", s.modulation || "—");
      setText("rp-active-du", s.active_du_deploy || "—");
      setText("rp-tunnel", s.tunnel_ready === "yes" ? "✅ READY" : "❌ NOT READY");
      const select = document.getElementById("rp-profile-select");
      if (select && PROFILES.some(([v]) => v === s.active_profile)) select.value = s.active_profile;
      log(s.log || "");
    } catch (e) {
      log("Status error: " + String(e));
    }
  }

  async function refreshResults() {
    try {
      const r = await api("/api/radio/results");
      renderRows([...(r.rows || []), ...(r.reference_rows || [])]);
    } catch (e) {
      // fail silently on initial load if API not ready
    }
  }

  async function applyProfile(profile) {
    log(`Applying ${profile} and validating...`);
    setText("rp-active-profile", "applying…");
    try {
      const r = await api("/api/radio/apply", {
        method: "POST",
        body: JSON.stringify({ profile })
      });
      log(r.log);
      await refreshStatus();
      await refreshResults();
    } catch (e) {
      log("Error: " + String(e));
    }
  }

  async function runKpi(profile) {
    log(`Running KPI test for ${profile}. This can take several minutes...`);
    try {
      const r = await api("/api/radio/kpi-test", {
        method: "POST",
        body: JSON.stringify({ profile })
      });
      log(r.log);
      await refreshStatus();
      await refreshResults();
    } catch (e) {
      log("Error: " + String(e));
    }
  }

  async function latestLogs() {
    const r = await api("/api/radio/logs");
    log(r.log);
  }

  document.addEventListener("DOMContentLoaded", async () => {
    createRoot();

    function bindClick(id, handler) {
      const el = document.getElementById(id);
      if (el) el.addEventListener("click", handler);
    }

    bindClick("rp-refresh",  () => refreshStatus().catch(e => log(String(e))));
    bindClick("rp-apply",    () => applyProfile(selectedProfile()).catch(e => log(String(e))));
    bindClick("rp-kpi",      () => runKpi(selectedProfile()).catch(e => log(String(e))));
    bindClick("rp-baseline", () => applyProfile("scheduler-auto").catch(e => log(String(e))));
    bindClick("rp-logs",     () => latestLogs().catch(e => log(String(e))));
    bindClick("rp-clear-logs", () => log("Ready."));

    try {
      await refreshStatus();
      await refreshResults();
    } catch (e) {
      log(String(e));
    }
  });
})();
