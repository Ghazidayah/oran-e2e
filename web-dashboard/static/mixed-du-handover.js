(() => {
  const PROFILES = [
    ["scheduler-auto",   "Scheduler Auto — adaptive AMC"],
    ["qpsk-robust",      "QPSK Robust — forced MCS 4 (Qm 2)"],
    ["qam16-balanced",   "16QAM Balanced — forced MCS 13 (Qm 4)"],
    ["qam64-throughput", "64QAM Throughput — forced MCS 28 (Qm 6)"],
  ];

  const style = document.createElement("style");
  style.textContent = `
    .radio-profile-section { margin-top: 18px; }
    .radio-profile-title { font-size: 17px; font-weight: 700; margin: 0 0 6px; }
    .radio-controls { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0 18px; align-items: center; }
    .radio-controls select { background: var(--panel-2); color: var(--text); border: 1px solid var(--line); border-radius: var(--radius); padding: 9px 10px; font-family: inherit; }
    .radio-controls button { background: transparent; color: var(--accent); border: 1px solid var(--accent); border-radius: var(--radius); padding: 7px 11px; font-weight: 600; font-size: 12px; cursor: pointer; font-family: inherit; transition: background 0.1s, color 0.1s; }
    .radio-controls button:hover:not(:disabled) { background: var(--accent); color: var(--bg); }
    .radio-controls button.secondary { color: var(--muted); border-color: var(--line); }
    .radio-controls button.secondary:hover:not(:disabled) { background: var(--panel-2); color: var(--text); border-color: var(--line); }
    .radio-table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: var(--radius); margin-top: 14px; }
    .radio-results { width: 100%; border-collapse: collapse; font-size: 13px; }
    .radio-results th, .radio-results td { border-bottom: 1px solid var(--line); padding: 10px; text-align: left; white-space: nowrap; }
    .radio-results th { color: var(--muted); background: var(--panel-2); }
    .radio-results tr.ref-row { opacity: .72; font-style: italic; }
    .radio-log { margin-top: 14px; min-height: 150px; max-height: 360px; overflow: auto; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 13px; border: 1px solid var(--line); border-radius: var(--radius); padding: 14px; background: var(--log-bg); color: var(--text); }
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
      <h2 class="radio-profile-title">Radio / Modulation Profile</h2>

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

  async function refreshStatus(writeLog = true) {
    if (writeLog) log("Refreshing modulation profile status...");
    try {
      const s = await api("/api/radio/status");
      setText("rp-active-profile", s.active_profile);
      setText("rp-max-mcs", s.max_mcs || "—");
      setText("rp-modulation", s.modulation || "—");
      setText("rp-active-du", s.active_du_deploy || "—");
      setText("rp-tunnel", s.tunnel_ready === "yes" ? "✅ READY" : "❌ NOT READY");
      const select = document.getElementById("rp-profile-select");
      if (select && PROFILES.some(([v]) => v === s.active_profile)) select.value = s.active_profile;
      if (writeLog) log(s.log || "");
    } catch (e) {
      if (writeLog) log("Status error: " + String(e));
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
      await refreshStatus(false);
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
      await refreshStatus(false);
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
      await refreshStatus(false);
      await refreshResults();
    } catch (e) {
      log(String(e));
    }
  });
})();
