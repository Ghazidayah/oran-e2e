// Remaining dashboard logic after status/live split
async function runAction(action) {
  const out = document.getElementById("actionOutput");
  out.textContent = "Running " + action + "...";

  try {
    let res = await fetch("/api/action/" + action, { method: "POST" });

    if (!res.ok) {
      res = await fetch("/api/run/" + action, { method: "POST" });
    }

    const data = await res.json();
    out.textContent = data.output || JSON.stringify(data, null, 2);
    reloadStatus();
  } catch (err) {
    out.textContent = "Action failed: " + err;
  }
}

reloadStatus();
loadMetrics();

setInterval(reloadStatus, 10000);
setInterval(loadMetrics, 2000);


// Extracted from index.html script block 2
(function () {
  const ACTION_LABELS = {
    ownership: "Serving gNB Check",
    e2e: "UE Attach + PDU Session",
    ping: "UE Connectivity Test",
    throughput: "UE Throughput KPI",
    stream: "UE Video-like Stream",
    light_traffic: "UE Stability Traffic",
    heavy_traffic: "UE Stress Traffic",
    stop_traffic: "Stop UE Traffic",
    report: "Lab report"
  };

  let activeAction = null;
  let timerHandle = null;
  let startedAt = null;

  function labelFor(action) {
    return ACTION_LABELS[action] || action;
  }

  function ensurePanel() {
    let panel = document.getElementById("action-feedback-panel");
    if (panel) return panel;

    panel = document.createElement("section");
    panel.id = "action-feedback-panel";
    panel.className = "idle";
    panel.innerHTML = `
      <div class="feedback-row">
        <div>
          <div class="feedback-title">Action status</div>
          <div id="action-feedback-detail" class="feedback-detail">
            No action running. Click a validation or traffic button to start.
          </div>
        </div>
        <div class="feedback-actions">
          <button class="feedback-report-button" type="button" data-action="report">Generate E2E Evidence Report</button>
          <span id="action-feedback-pill" class="feedback-pill">IDLE</span>
        </div>
      </div>
      <div class="feedback-progress">
        <div id="action-feedback-progress-bar" class="feedback-progress-bar"></div>
      </div>
    `;

    const header = document.querySelector("header");
    if (header && header.parentNode) {
      header.parentNode.insertBefore(panel, header.nextSibling);
    } else {
      document.body.insertBefore(panel, document.body.firstChild);
    }

    const reportButton = panel.querySelector('[data-action="report"]');
    if (reportButton) {
      reportButton.addEventListener("click", function (ev) {
        ev.preventDefault();
        runActionEnhanced("report", reportButton);
      });
    }

    return panel;
  }

  function setPanel(state, action, detail) {
    const panel = ensurePanel();
    const pill = document.getElementById("action-feedback-pill");
    const detailEl = document.getElementById("action-feedback-detail");
    const bar = document.getElementById("action-feedback-progress-bar");

    panel.className = state;

    if (pill) {
      if (state === "running") pill.textContent = "RUNNING";
      else if (state === "success") pill.textContent = "SUCCESS";
      else if (state === "failed") pill.textContent = "FAILED";
      else pill.textContent = "IDLE";
    }

    if (detailEl) {
      detailEl.textContent = detail || "No action running. Click a validation or traffic button to start.";
    }

    if (bar && state !== "running") {
      bar.style.width = state === "success" ? "100%" : "0%";
      bar.style.transform = "none";
    }
  }

  function getActionFromButton(button) {
    if (!button) return "";
    if (button.dataset && button.dataset.action) return button.dataset.action;

    const onclick = button.getAttribute("onclick") || "";
    const match = onclick.match(/runAction\(['"]([^'"]+)['"]\)/);
    if (match) return match[1];

    return "";
  }

  function actionButtons() {
    return Array.from(document.querySelectorAll("button, a.button, a")).filter(function (el) {
      const action = getActionFromButton(el);
      return !!action;
    });
  }

  function setButtonState(button, state) {
    if (!button) return;

    if (!button.dataset.originalText) {
      button.dataset.originalText = button.textContent.trim();
    }

    button.classList.remove("action-running", "action-success", "action-failed");

    if (state === "running") {
      button.disabled = true;
      button.classList.add("action-running");
      button.innerHTML = '<span class="button-spinner"></span>Running...';
      return;
    }

    if (state === "success") {
      button.disabled = true;
      button.classList.add("action-success");
      button.textContent = "Done ✓";
      return;
    }

    if (state === "failed") {
      button.disabled = true;
      button.classList.add("action-failed");
      button.textContent = "Failed ✗";
      return;
    }

    button.disabled = false;
    button.textContent = button.dataset.originalText || button.textContent;
  }

  function disableOtherButtons(activeButton) {
    actionButtons().forEach(function (btn) {
      if (btn !== activeButton) {
        btn.disabled = true;
        btn.style.opacity = "0.55";
      }
    });
  }

  function restoreButtons() {
    actionButtons().forEach(function (btn) {
      btn.disabled = false;
      btn.style.opacity = "";
      setButtonState(btn, "idle");
    });
  }

  function findOutputElement() {
    const ids = [
      "latest-output",
      "latestActionOutput",
      "action-output",
      "actionOutput",
      "output",
      "log-output",
      "latest-run-output"
    ];

    for (const id of ids) {
      const el = document.getElementById(id);
      if (el) return el;
    }

    const headings = Array.from(document.querySelectorAll("h1,h2,h3,h4,strong"));
    const latestHeading = headings.find(function (el) {
      return /latest action output/i.test(el.textContent || "");
    });

    if (latestHeading) {
      const container = latestHeading.closest("section, article, div");
      if (container) {
        const pre = container.querySelector("pre, code, textarea");
        if (pre) return pre;
      }
    }

    return document.querySelector("pre");
  }

  function setLatestOutput(text) {
    const output = findOutputElement();
    if (!output) return;

    output.textContent = text || "(no output returned)";
    output.scrollTop = output.scrollHeight;
  }

  async function refreshDashboard() {
    const candidates = ["loadStatus", "refreshStatus", "fetchStatus", "updateStatus", "loadDashboard"];
    for (const name of candidates) {
      if (typeof window[name] === "function") {
        try {
          await window[name]();
          return;
        } catch (err) {
          console.warn("Refresh function failed:", name, err);
        }
      }
    }

    try {
      await fetch("/api/status", { cache: "no-store" });
    } catch (err) {
      console.warn("Status refresh request failed:", err);
    }
  }

  function startTimer(action) {
    startedAt = Date.now();
    if (timerHandle) clearInterval(timerHandle);

    timerHandle = setInterval(function () {
      if (!startedAt) return;
      const seconds = Math.round((Date.now() - startedAt) / 1000);
      setPanel("running", action, `${labelFor(action)} is running... ${seconds}s elapsed`);
    }, 1000);
  }

  function stopTimer() {
    if (timerHandle) clearInterval(timerHandle);
    timerHandle = null;
    startedAt = null;
  }

  async function runActionEnhanced(action, button) {
    if (!action) return;

    if (activeAction) {
      setPanel("running", activeAction, `${labelFor(activeAction)} is already running. Wait for it to finish.`);
      return;
    }

    const activeButton = button || document.querySelector(`[data-action="${action}"]`) || document.querySelector(`[onclick*="${action}"]`);

    activeAction = action;
    setButtonState(activeButton, "running");
    disableOtherButtons(activeButton);
    setPanel("running", action, `${labelFor(action)} is running...`);
    setLatestOutput(`Running ${labelFor(action)}...\n\nWaiting for backend response.`);
    startTimer(action);

    try {
      const response = await fetch(`/api/action/${encodeURIComponent(action)}`, {
        method: "POST",
        cache: "no-store"
      });

      const raw = await response.text();
      let data = null;

      try {
        data = JSON.parse(raw);
      } catch (err) {
        data = {
          summary: { ok: response.ok, exit: response.ok ? 0 : 1 },
          output: raw
        };
      }

      const summary = data.summary || {};
      const ok = response.ok && summary.ok !== false && Number(summary.exit || 0) === 0;
      const output = data.output || raw || "";

      setLatestOutput(output);

      if (ok) {
        setButtonState(activeButton, "success");
        setPanel("success", action, `${labelFor(action)} completed successfully. Run: ${summary.run_dir || "n/a"}`);
      } else {
        setButtonState(activeButton, "failed");
        setPanel("failed", action, `${labelFor(action)} failed. Exit: ${fallbackValue(summary.exit, "unknown")}`);
      }

      await refreshDashboard();

      setTimeout(function () {
        restoreButtons();
        if (ok) {
          setPanel("idle", action, `${labelFor(action)} finished successfully. Ready for next action.`);
        }
      }, 2500);
    } catch (err) {
      setLatestOutput(`ERROR while running ${labelFor(action)}:\n${err.message || err}`);
      setButtonState(activeButton, "failed");
      setPanel("failed", action, `${labelFor(action)} failed before completion: ${err.message || err}`);

      setTimeout(function () {
        restoreButtons();
      }, 3000);
    } finally {
      stopTimer();
      activeAction = null;
    }
  }

  function installButtonHandlers() {
    ensurePanel();

    actionButtons().forEach(function (button) {
      const action = getActionFromButton(button);
      if (!action) return;

      button.dataset.action = action;

      if (button.dataset.feedbackInstalled === "1") return;
      button.dataset.feedbackInstalled = "1";

      button.onclick = function (ev) {
        ev.preventDefault();
        ev.stopPropagation();
        runActionEnhanced(action, button);
        return false;
      };
    });
  }

  window.runAction = function (action) {
    const button = window.event && window.event.currentTarget ? window.event.currentTarget : null;
    return runActionEnhanced(action, button);
  };

  document.addEventListener("DOMContentLoaded", installButtonHandlers);
  window.addEventListener("load", installButtonHandlers);
  setTimeout(installButtonHandlers, 1000);
})();


// Extracted from index.html script block 3
let multiUeBusy = false;
  const ueScenarioSelections = {};
  const perUeScenarioOptions = [
    ["none", "None"],
    ["attach_pdu", "Attach + PDU"],
    ["connectivity", "Connectivity"],
    ["light", "Light traffic"],
    ["throughput", "Throughput KPI"],
    ["heavy", "Heavy traffic"],
    ["video", "Video-like stream"],
    ["stop", "Stop traffic"]
  ];

  function setPerUeScenario(ueName, scenario) {
    ueScenarioSelections[ueName] = scenario || "none";
  }

  function scenarioSelectHtml(ue) {
    const selected = ueScenarioSelections[ue.name] || "none";
    return `
      <select class="ue-scenario-select" data-ue-scenario-select="true" data-locked="${ue.attached || ue.ready ? "false" : "true"}" data-ue="${ue.name}" onchange="setPerUeScenario('${ue.name}', this.value)" ${ue.attached || ue.ready ? "" : "disabled"}>
        ${perUeScenarioOptions.map(([value, label]) => `<option value="${value}" ${selected === value ? "selected" : ""}>${label}</option>`).join("")}
      </select>
    `;
  }

  function ueBadge(ue) {
    if (ue.attached) {
      return '<span class="multi-ue-badge multi-ue-attached">Attached</span>';
    }
    if (ue.ready) {
      return '<span class="multi-ue-badge multi-ue-running">Running</span>';
    }
    return '<span class="multi-ue-badge multi-ue-stopped">Stopped</span>';
  }

  function setMultiUeBusy(isBusy) {
    multiUeBusy = isBusy;
    document.querySelectorAll('[data-multi-ue-button="true"], [data-ue-scenario-select="true"]').forEach((control) => {
      control.disabled = isBusy || control.dataset.locked === "true";
    });
  }

  function setMultiUeOutput(text, keepScenarioSummary = false) {
    if (!keepScenarioSummary) {
      clearMultiUeScenarioSummary();
    }

    const output = document.getElementById('multiUeOutput');
    if (output) {
      output.textContent = text || '';
    }
  }

  function clearMultiUeScenarioSummary() {
    const panel = document.getElementById('multiUeScenarioSummary');
    if (!panel) return;
    panel.hidden = true;
    panel.innerHTML = '';
  }

  function escapeHtml(value) {
    return String(fallbackValue(value, ''))
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  function scenarioMetric(output, regex) {
    const match = String(output || '').match(regex);
    return match ? match[1] : '';
  }

  function scenarioPacketLoss(output) {
    const matches = String(output || '').match(/\d+(?:\.\d+)?% packet loss/g) || [];
    return matches.length ? matches.join(' / ') : '-';
  }

  function scenarioNameForRow(data, result) {
    return result.scenario || data.scenario || '-';
  }

  function scenarioLabelForRow(data, result) {
    return result.label || data.label || ueScenarioSelections[result.ue] || scenarioNameForRow(data, result);
  }

  function renderMultiUeScenarioResult(data) {
    const panel = document.getElementById('multiUeScenarioSummary');
    if (!panel) return;

    const results = Array.isArray(data.results) ? data.results : [];
    const statusClass = data.ok ? 'ok' : 'failed';
    const statusText = data.ok ? 'SUCCESS' : 'FAILED';
    const scenarioTitle = data.mode === 'per_ue'
      ? 'Per-UE Independent Scenario Results'
      : `Multi-UE Scenario Results: ${data.label || data.scenario || 'scenario'}`;

    const rows = results.map((result) => {
      const output = result.output || '';
      const duration = scenarioMetric(output, /duration_sec=([0-9]+)/);
      const rx = scenarioMetric(output, /rx_delta_bytes=([0-9]+)/);
      const tx = scenarioMetric(output, /tx_delta_bytes=([0-9]+)/);
      const mbps = scenarioMetric(output, /approx_total_mbps=([0-9.]+)/);
      return `
        <tr>
          <td><strong>${escapeHtml(result.ue || '-')}</strong></td>
          <td>${escapeHtml(scenarioNameForRow(data, result))}<br><small>${escapeHtml(scenarioLabelForRow(data, result))}</small></td>
          <td>${result.ok ? '<span class="multi-ue-badge multi-ue-attached">OK</span>' : '<span class="multi-ue-badge multi-ue-stopped">FAILED</span>'}</td>
          <td><code>${escapeHtml(result.tunnel_ip || '-')}</code></td>
          <td>${escapeHtml(fallbackValue(result.exit, '-'))}</td>
          <td>${escapeHtml(scenarioPacketLoss(output))}</td>
          <td>${duration ? `${escapeHtml(duration)}s` : '-'}</td>
          <td>${rx || tx ? `${escapeHtml(rx || '-')} / ${escapeHtml(tx || '-')} B` : '-'}</td>
          <td>${mbps ? `${escapeHtml(mbps)} Mbps` : '-'}</td>
        </tr>
      `;
    }).join('');

    const rawBlocks = results.map((result) => `
===== ${escapeHtml(result.ue || '-')} | ${escapeHtml(scenarioNameForRow(data, result))} | ${result.ok ? 'OK' : 'FAILED'} =====
${escapeHtml(result.output || '')}
`).join('\\n');

    const skipped = Array.isArray(data.skipped) && data.skipped.length
      ? `<span>Skipped: ${escapeHtml(data.skipped.length)}</span>`
      : '';

    panel.innerHTML = `
      <div class="scenario-result-title">
        <h3>${escapeHtml(scenarioTitle)}</h3>
        <span class="scenario-status ${statusClass}">${statusText}</span>
      </div>
      <div class="scenario-result-meta">
        <span>Mode: ${escapeHtml(data.mode || 'global')}</span>
        <span>Parallel: ${data.parallel ? 'yes' : 'no'}</span>
        <span>Selected UEs: ${escapeHtml((data.selected_ues || []).join(', ') || '-')}</span>
        <span>Selected count: ${escapeHtml(fallbackValue(data.selected_count, results.length))}</span>
        ${skipped}
      </div>
      <table class="scenario-result-table">
        <thead>
          <tr>
            <th>UE</th>
            <th>Scenario</th>
            <th>Result</th>
            <th>Tunnel IP</th>
            <th>Exit</th>
            <th>Packet loss</th>
            <th>Duration</th>
            <th>RX / TX delta</th>
            <th>Approx Mbps</th>
          </tr>
        </thead>
        <tbody>${rows || '<tr><td colspan="9">No per-UE results returned.</td></tr>'}</tbody>
      </table>
      <details class="scenario-raw-details">
        <summary>Show raw per-UE logs</summary>
        <pre class="scenario-raw-block">${rawBlocks || 'No raw logs available.'}</pre>
      </details>
    `;
    panel.hidden = false;
  }

  async function refreshMultiUes() {
    try {
      const response = await fetch('/api/ues');
      const data = await response.json();

      const summary = document.getElementById('multiUeSummary');
      const tbody = document.getElementById('multiUeTableBody');

      if (!data.ok) {
        summary.textContent = 'Failed to load UE status';
        tbody.innerHTML = '<tr><td colspan="8">Failed to load UE status</td></tr>';
        return;
      }

      summary.textContent = `${data.attached_count}/${data.max_ues} attached, ${data.running_count}/${data.max_ues} running`;

      const desiredSelect = document.getElementById('desiredUeCount');
      if (desiredSelect && data.attached_count >= 1) {
        desiredSelect.value = String(data.attached_count);
      }

      tbody.innerHTML = data.ues.map((ue) => {
        const pod = ue.pod || '-';
        const tunnelIp = ue.tunnel_ip || '-';
        const bytes = `${ue.rx_bytes || 0} / ${ue.tx_bytes || 0}`;

        const startDisabled = ue.ready ? 'disabled' : '';
        const stopDisabled = ue.name === 'ue1' ? 'disabled' : (!ue.ready ? 'disabled' : '');
        const pingDisabled = ue.attached ? '' : 'disabled';

        return `
          <tr>
            <td><strong>${ue.name}</strong></td>
            <td>${ue.imsi}</td>
            <td>${pod}</td>
            <td>${tunnelIp}</td>
            <td>${ueBadge(ue)}</td>
            <td>${scenarioSelectHtml(ue)}</td>
            <td>${bytes}</td>
            <td>
              <div class="multi-ue-actions">
                <button data-multi-ue-button="true" data-locked="${ue.ready ? "true" : "false"}" ${startDisabled} onclick="startUe('${ue.name}')">${ue.ready ? "Running" : "Start"}</button>
                <button data-multi-ue-button="true" data-locked="${(ue.name === "ue1" || !ue.ready) ? "true" : "false"}" ${stopDisabled} title="${ue.name === "ue1" ? "UE1 is the baseline UE; stop is disabled in the UI." : "Scale this UE deployment to zero."}" onclick="stopUe('${ue.name}')">Stop</button>
                <button data-multi-ue-button="true" data-locked="${ue.attached ? "false" : "true"}" ${pingDisabled} title="Test this UE PDU tunnel." onclick="pingUe('${ue.name}')">Ping</button>
              </div>
            </td>
          </tr>
        `;
      }).join('');
    } catch (error) {
      setMultiUeOutput(`Failed to refresh UEs: ${error}`);
    }
  }

  async function multiUePost(url, label) {
    if (multiUeBusy) return;

    setMultiUeBusy(true);
    setMultiUeOutput(`${label}...`);

    try {
      const response = await fetch(url, { method: 'POST' });
      const data = await response.json();

      setMultiUeOutput(JSON.stringify(data, null, 2));
      await refreshMultiUes();
    } catch (error) {
      setMultiUeOutput(`${label} failed: ${error}`);
    } finally {
      setMultiUeBusy(false);
    }
  }

  async function startUe(ueName) {
    await multiUePost(`/api/ue/${ueName}/start`, `Starting ${ueName}`);
  }

  async function stopUe(ueName) {
    await multiUePost(`/api/ue/${ueName}/stop`, `Stopping ${ueName}`);
  }

  async function pingUe(ueName) {
    await multiUePost(`/api/ue/${ueName}/ping`, `Pinging ${ueName}`);
  }

  function selectedPerUeScenarioJobs() {
    return Array.from(document.querySelectorAll('[data-ue-scenario-select="true"]'))
      .map((select) => ({
        ue: select.dataset.ue,
        scenario: select.value
      }))
      .filter((job) => job.ue && job.scenario && job.scenario !== 'none');
  }

  function extractScenarioValue(text, pattern) {
    const match = String(text || '').match(pattern);
    return match ? match[1] : '';
  }

  function formatPerUeScenarioSummary(data) {
    const lines = [];
    lines.push('Per-UE independent scenario matrix');
    lines.push(`Status: ${data.ok ? 'SUCCESS' : 'FAILED'}`);
    lines.push(`Parallel execution: ${data.parallel ? 'yes' : 'no'}`);
    lines.push(`Selected jobs: ${fallbackValue(data.selected_count, 0)}`);
    lines.push(`Selected UEs: ${(data.selected_ues || []).join(', ') || '-'}`);

    if (Array.isArray(data.skipped) && data.skipped.length > 0) {
      lines.push('');
      lines.push('Skipped:');
      data.skipped.forEach((item) => lines.push(`- ${item.ue || '-'}: ${item.reason || 'skipped'}`));
    }

    if (Array.isArray(data.errors) && data.errors.length > 0) {
      lines.push('');
      lines.push('Errors:');
      data.errors.forEach((err) => lines.push(`- ${err}`));
    }

    if (Array.isArray(data.results)) {
      lines.push('');
      lines.push('Per-UE results:');
      data.results.forEach((result) => {
        const output = result.output || '';
        const lossLines = output.match(/\d+(?:\.\d+)?% packet loss/g) || [];
        const mbps = extractScenarioValue(output, /approx_total_mbps=([0-9.]+)/);
        const rx = extractScenarioValue(output, /rx_delta_bytes=([0-9]+)/);
        const tx = extractScenarioValue(output, /tx_delta_bytes=([0-9]+)/);
        const duration = extractScenarioValue(output, /duration_sec=([0-9]+)/);

        lines.push(`- ${result.ue}: ${result.label || result.scenario || '-'} | ${result.ok ? 'OK' : 'FAILED'} | tunnel=${result.tunnel_ip || '-'} | exit=${result.exit}`);
        if (lossLines.length > 0) {
          lines.push(`  packet_loss: ${lossLines.join(' / ')}`);
        }
        if (duration || rx || tx || mbps) {
          lines.push(`  kpi: duration=${duration || '-'}s rx=${rx || '-'}B tx=${tx || '-'}B approx=${mbps || '-'} Mbps`);
        }
      });
    }

    if (!data.ok && data.error) {
      lines.push('');
      lines.push(`Error: ${data.error}`);
    }

    return lines.join('\n');
  }

  async function runSelectedUeScenarios() {
    if (multiUeBusy) return;

    const jobs = selectedPerUeScenarioJobs();
    if (jobs.length === 0) {
      setMultiUeOutput('No per-UE scenarios selected. Choose at least one scenario other than None.');
      return;
    }

    setMultiUeBusy(true);
    setMultiUeOutput('Running independent per-UE scenarios in parallel...\n' + jobs.map((job) => `${job.ue}: ${job.scenario}`).join('\n'));

    try {
      const response = await fetch('/api/ues/scenarios', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jobs })
      });
      const data = await response.json();
      renderMultiUeScenarioResult(data);
      setMultiUeOutput(formatPerUeScenarioSummary(data), true);
      await refreshMultiUes();
    } catch (error) {
      setMultiUeOutput(`Per-UE scenarios failed: ${error}`);
    } finally {
      setMultiUeBusy(false);
    }
  }

  async function applyDesiredUes() {
    if (multiUeBusy) return;

    const count = Number(document.getElementById('desiredUeCount').value);

    setMultiUeBusy(true);
    setMultiUeOutput(`Applying desired UE count: ${count}...`);

    try {
      const response = await fetch('/api/ues/desired', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ count })
      });

      const data = await response.json();
      setMultiUeOutput(JSON.stringify(data, null, 2));
      await refreshMultiUes();
    } catch (error) {
      setMultiUeOutput(`Apply desired UE count failed: ${error}`);
    } finally {
      setMultiUeBusy(false);
    }
  }

  refreshMultiUes();
  setInterval(refreshMultiUes, 10000);


// Extracted from index.html script block 4
const ueScenarioLabels = {
    attach_pdu: "UE Attach + PDU Session",
    connectivity: "UE Connectivity Test",
    stability: "UE Stability Traffic",
    throughput: "UE Throughput KPI",
    video: "UE Video-like Stream",
    stress: "UE Stress Traffic",
    stop: "Stop UE Traffic"
  };

  async function runUeScenario(scenario) {
    const countEl = document.getElementById('desiredUeCount');
    const count = countEl ? Number(countEl.value || 1) : 1;
    const label = ueScenarioLabels[scenario] || scenario;

    if (typeof setMultiUeOutput === 'function') {
      setMultiUeOutput(`${label} running on selected UE count: ${count}...\n`);
    }

    try {
      const response = await fetch(`/api/ues/scenario/${scenario}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ count })
      });

      const data = await response.json();

      if (typeof setMultiUeOutput === 'function') {
        renderMultiUeScenarioResult(data);
        setMultiUeOutput(formatScenarioSummary(data), true);
      }

      if (typeof refreshMultiUes === 'function') {
        await refreshMultiUes();
      }
    } catch (error) {
      if (typeof setMultiUeOutput === 'function') {
        setMultiUeOutput(`${label} failed: ${error}`);
      } else {
        alert(`${label} failed: ${error}`);
      }
    }
  }


// Extracted from index.html script block 5
const ueScenarioInteractiveLabels = {
    attach_pdu: "UE Attach + PDU Session",
    connectivity: "UE Connectivity Test",
    stability: "UE Stability Traffic",
    throughput: "UE Throughput KPI",
    video: "UE Video-like Stream",
    stress: "UE Stress Traffic",
    stop: "Stop UE Traffic"
  };

  function setUeButtonState(button, state, text) {
    if (!button) return;

    if (!button.dataset.originalText) {
      button.dataset.originalText = button.textContent.trim();
    }

    button.classList.remove("ue-btn-running", "ue-btn-success", "ue-btn-failed", "ue-btn-disabled");

    if (state === "running") {
      button.classList.add("ue-btn-running");
      button.disabled = true;
      button.textContent = text || "Running...";
      return;
    }

    if (state === "success") {
      button.classList.add("ue-btn-success");
      button.disabled = false;
      button.textContent = text || "Done ✓";
      setTimeout(() => restoreUeButton(button), 2200);
      return;
    }

    if (state === "failed") {
      button.classList.add("ue-btn-failed");
      button.disabled = false;
      button.textContent = text || "Failed ✗";
      setTimeout(() => restoreUeButton(button), 3000);
      return;
    }

    restoreUeButton(button);
  }

  function restoreUeButton(button) {
    if (!button) return;
    button.classList.remove("ue-btn-running", "ue-btn-success", "ue-btn-failed", "ue-btn-disabled");
    button.disabled = false;
    if (button.dataset.originalText) {
      button.textContent = button.dataset.originalText;
    }
  }

  function setScenarioButtonsDisabled(disabled, activeButton) {
    document.querySelectorAll('button[onclick*="runUeScenarioInteractive"], button[onclick*="runActionInteractive"]').forEach((button) => {
      if (button === activeButton) return;
      button.disabled = disabled;
      button.classList.toggle("ue-btn-disabled", disabled);
    });
  }

  function extractLine(text, pattern) {
    const match = text.match(pattern);
    return match ? match[0] : "";
  }

  function extractValue(text, pattern) {
    const match = text.match(pattern);
    return match ? match[1] : "";
  }

  function formatScenarioSummary(data) {
    const lines = [];

    lines.push(`Scenario: ${data.label || data.scenario || "UE scenario"}`);
    lines.push(`Status: ${data.ok ? "SUCCESS" : "FAILED"}`);
    lines.push(`Requested UE count: ${fallbackValue(data.requested_count, "-")}`);
    lines.push(`Selected UE count: ${fallbackValue(data.selected_count, "-")}`);
    lines.push(`Parallel execution: ${data.parallel ? "yes" : "no"}`);
    lines.push(`Selected UEs: ${(data.selected_ues || []).join(", ") || "-"}`);
    lines.push("");

    if (Array.isArray(data.results)) {
      lines.push("Per-UE results:");

      data.results.forEach((result) => {
        const output = result.output || "";
        const lossLines = output.match(/\d+(?:\.\d+)?% packet loss/g) || [];
        const mbps = extractValue(output, /approx_total_mbps=([0-9.]+)/);
        const rx = extractValue(output, /rx_delta_bytes=([0-9]+)/);
        const tx = extractValue(output, /tx_delta_bytes=([0-9]+)/);
        const duration = extractValue(output, /duration_sec=([0-9]+)/);

        lines.push(`- ${result.ue}: ${(result.scenario || data.scenario || "-")} / ${(result.label || data.label || "-")} | ${result.ok ? "OK" : "FAILED"} | tunnel=${result.tunnel_ip || "-"} | exit=${result.exit}`);
        if (lossLines.length > 0) {
          lines.push(`  packet_loss: ${lossLines.join(" / ")}`);
        }
        if (duration || rx || tx || mbps) {
          lines.push(`  kpi: duration=${duration || "-"}s rx=${rx || "-"}B tx=${tx || "-"}B approx=${mbps || "-"} Mbps`);
        }
      });
    }

    if (!data.ok && data.error) {
      lines.push("");
      lines.push(`Error: ${data.error}`);
    }

    lines.push("");
    lines.push("Full raw result is available from the API response if needed.");

    return lines.join("\n");
  }

  async function runUeScenarioInteractive(scenario, button) {
    const countEl = document.getElementById("desiredUeCount");
    const count = countEl ? Number(countEl.value || 1) : 1;
    const label = ueScenarioInteractiveLabels[scenario] || scenario;

    setScenarioButtonsDisabled(true, button);
    setUeButtonState(button, "running", "Running...");

    if (typeof setMultiUeOutput === "function") {
      setMultiUeOutput(`${label} running on selected UE count: ${count}...\n`);
    }

    try {
      const response = await fetch(`/api/ues/scenario/${scenario}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ count })
      });

      const data = await response.json();

      if (typeof setMultiUeOutput === "function") {
        renderMultiUeScenarioResult(data);
        setMultiUeOutput(formatScenarioSummary(data), true);
      }

      if (typeof refreshMultiUes === "function") {
        await refreshMultiUes();
      }

      if (!response.ok || !data.ok) {
        setUeButtonState(button, "failed", "Failed ✗");
      } else {
        setUeButtonState(button, "success", "Done ✓");
      }
    } catch (error) {
      if (typeof setMultiUeOutput === "function") {
        setMultiUeOutput(`${label} failed: ${error}`);
      }
      setUeButtonState(button, "failed", "Failed ✗");
    } finally {
      setScenarioButtonsDisabled(false, button);
    }
  }

  async function runActionInteractive(action, button) {
    const label = action || "action";

    setScenarioButtonsDisabled(true, button);
    setUeButtonState(button, "running", "Running...");

    try {
      if (typeof runAction !== "function") {
        throw new Error("runAction is not available");
      }

      await runAction(action);

      setUeButtonState(button, "success", "Done ✓");
    } catch (error) {
      if (typeof setMultiUeOutput === "function") {
        setMultiUeOutput(`${label} failed: ${error}`);
      }
      setUeButtonState(button, "failed", "Failed ✗");
    } finally {
      setScenarioButtonsDisabled(false, button);
    }
  }

