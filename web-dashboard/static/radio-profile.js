(() => {
  const PROFILES = [
    ["scheduler-auto",   "Scheduler Auto (adaptive AMC)"],
    ["qpsk-robust",      "QPSK Robust (forced MCS 4, Qm 2)"],
    ["qam16-balanced",   "16QAM Balanced (forced MCS 13, Qm 4)"],
    ["qam64-throughput", "64QAM Throughput (forced MCS 28, Qm 6)"],
  ];

  const style = document.createElement("style");
  style.textContent = `
    .radio-profile-section { margin-top: 18px; }
    .radio-profile-title { font-size: 19px; font-weight: 700; margin: 0 0 6px; }
    .radio-controls { display: flex; flex-wrap: wrap; gap: 10px; margin: 12px 0 18px; align-items: center; }
    .radio-controls button { background: transparent; color: var(--accent); border: 1px solid var(--accent); border-radius: var(--radius); padding: 9px 16px; font-weight: 600; font-size: 14px; min-height: 38px; cursor: pointer; font-family: inherit; transition: background 0.1s, color 0.1s; }
    .radio-controls button:hover:not(:disabled) { background: var(--accent); color: var(--bg); }
    .radio-table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: var(--radius); margin-top: 14px; }
    .radio-results { width: 100%; border-collapse: collapse; font-size: 15px; }
    .radio-results th, .radio-results td { border-bottom: 1px solid var(--line); padding: 10px; text-align: left; white-space: nowrap; }
    .radio-results th { color: var(--muted); background: var(--panel-2); }
    .radio-results tr.ref-row { opacity: .72; font-style: italic; }
    .radio-log { margin-top: 14px; min-height: 48px; max-height: 420px; overflow: auto; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 14px; border: 1px solid var(--line); border-radius: var(--radius); padding: 14px; background: var(--log-bg); color: var(--text); }
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
        <button id="rp-apply-kpi">Apply + KPI Test</button>
      </div>

      <h3>Modulation Profile KPI Results</h3>
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

      <h3 class="mt-18">Logs</h3>
      <pre class="radio-log" id="rp-log">Ready.</pre>
    `;
  }

  const api = OranUI.jsonApi;
  const setText = OranUI.setText;

  function log(text) { setText("rp-log", text || ""); }

  function selectedProfile() {
    const select = document.getElementById("rp-profile-select");
    return select ? select.value : "scheduler-auto";
  }

  function verdictStyle(verdict) {
    if (!verdict) return "";
    if (verdict.includes("PASS") || verdict.includes("VALIDATED")) return "color:#15803d;font-weight:bold";
    if (verdict.includes("FAIL")) return "color:#b91c1c;font-weight:bold";
    if (verdict.includes("cap")) return "color:#b45309;font-weight:bold";
    return "";
  }

  function renderRows(rows) {
    const body = document.getElementById("rp-results-body");
    if (!body) return;
    if (!rows || !rows.length) {
      body.innerHTML = `<tr><td colspan="7">No results yet. Apply a profile or run a KPI test.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(r => {
      const isRef = !!r.source;
      const verdict = r.verdict || "-";
      return `<tr${isRef ? ' class="ref-row"' : ""}>
        <td>${r.profile || "-"}</td>
        <td>${r.max_mcs || "-"}</td>
        <td>${r.modulation || "-"}</td>
        <td>${r.ping_avg_ms || "-"}</td>
        <td>${r.tcp_mbps || "-"}</td>
        <td>${r.retransmits || "-"}</td>
        <td style="${verdictStyle(verdict)}">${verdict}</td>
      </tr>`;
    }).join("");
  }

  async function refreshResults() {
    try {
      const r = await api("/api/radio/results");
      renderRows([...(r.rows || []), ...(r.reference_rows || [])]);
    } catch (e) {
      // Echec d'une requete automatique: on garde les dernieres donnees affichees.
    }
  }

  let busy = false;

  async function applyProfile(profile) {
    busy = true;
    log(`Applying ${profile} and validating...`);
    try {
      const r = await api("/api/radio/apply", {
        method: "POST",
        body: JSON.stringify({ profile })
      });
      log(r.log);
      await refreshResults();
      return r;
    } catch (e) {
      log("Error: " + String(e));
      return null;
    } finally {
      busy = false;
    }
  }

  async function runKpi(profile) {
    busy = true;
    log(`Running KPI test for ${profile}. This can take several minutes...`);
    try {
      const r = await api("/api/radio/kpi-test", {
        method: "POST",
        body: JSON.stringify({ profile })
      });
      log(r.log);
      await refreshResults();
      return r;
    } catch (e) {
      log("Error: " + String(e));
      return null;
    } finally {
      busy = false;
    }
  }

  document.addEventListener("DOMContentLoaded", async () => {
    createRoot();

    function bindClick(id, handler) {
      const el = document.getElementById(id);
      if (el) el.addEventListener("click", handler);
    }

    const applyBtn = document.getElementById("rp-apply-kpi");
    bindClick("rp-apply-kpi", () => OranUI.runWithButton(applyBtn, [applyBtn], async () => {
      const profile = selectedProfile();
      // Only proceed to the KPI test if the apply request itself did not fail.
      const applied = await applyProfile(profile);
      if (!applied) return false;
      const kpi = await runKpi(profile);
      return !!kpi && applied.ok !== false && kpi.ok !== false;
    }));

    await refreshResults();
    window.autoRefresh(refreshResults, 30000, () => busy);
  });
})();
