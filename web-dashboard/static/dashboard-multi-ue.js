// Multi-UE Control dashboard logic
let multiUeBusy = false;
let f1ModeActiveForMultiUe = false;
let desiredUeCountUserEdited = false;
  const ueScenarioSelections = {};
  const perUeScenarioOptions = [
    ["none", "None"],
    ["image", "Image Download"],
    ["video_download", "Video Download"],
    ["web", "Web Browsing"],
    ["streaming", "Streaming-like HLS"],
    ["tcp_download", "TCP Download KPI"],
    ["udp", "UDP Jitter / Loss"],
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
    document.querySelectorAll('[data-multi-ue-button="true"], [data-ue-scenario-select="true"], [data-multi-ue-mode-control="true"]').forEach((control) => {
      const keepRefreshEnabled = control.dataset.multiUeRefresh === "true";
      control.disabled = isBusy || control.dataset.locked === "true" || (f1ModeActiveForMultiUe && !keepRefreshEnabled);
      if (f1ModeActiveForMultiUe && !keepRefreshEnabled) {
        control.title = "Multi-UE control is disabled while F1 RFsim handover mode is active.";
      }
    });
  }

  // The button that started the current operation shows "Running..." (same wording as the other
  // launch buttons). Row buttons are re-rendered by every refresh, so the label is painted again
  // after each render.
  let runningOp = null;

  function paintRunning() {
    if (!runningOp) return;
    const button = document.querySelector(`[data-op="${runningOp}"]`);
    if (!button || button.dataset.originalText) return;
    button.dataset.originalText = button.textContent;
    button.style.minWidth = `${button.offsetWidth}px`;
    button.textContent = 'Running...';
  }

  function clearRunning() {
    runningOp = null;
    document.querySelectorAll('[data-op]').forEach((button) => {
      if (!button.dataset.originalText) return;
      button.textContent = button.dataset.originalText;
      button.style.minWidth = '';
      delete button.dataset.originalText;
    });
  }

  function beginOp(op) {
    runningOp = op;
    setMultiUeBusy(true);
    paintRunning();
  }

  function endOp() {
    clearRunning();
    setMultiUeBusy(false);
  }

  async function refreshF1ModeForMultiUe() {
    try {
      const response = await fetch('/api/handover/status');
      const data = await response.json();
      f1ModeActiveForMultiUe = false;
    } catch (error) {
      f1ModeActiveForMultiUe = false;
    }
    setMultiUeBusy(false);
    return f1ModeActiveForMultiUe;
  }

  function blockMultiUeIfF1Mode(action) {
    if (!f1ModeActiveForMultiUe) return false;
    setMultiUeOutput([
      "===== Multi-UE Control Blocked =====",
      `Action: ${action}`,
      "",
      "F1 RFsim handover mode is active.",
      "F1 handover uses a dedicated F1 UE and does not block Multi-UE controls.",
      "",
      "Use the F1 Handover Validation panel, or switch back to multi-UE baseline mode first.",
    ].join("\n"));
    setMultiUeBusy(false);
    return true;
  }

  function setMultiUeOutput(text) {
    const output = document.getElementById('multiUeOutput');
    if (output) output.textContent = text || '';
  }

  const escapeHtml = OranUI.escapeHtml;

  function scenarioMetric(output, regex) {
    const match = String(output || '').match(regex);
    return match ? match[1] : '';
  }

  function scenarioNameForRow(data, result) {
    return result.scenario || data.scenario || '-';
  }

  function scenarioLabelForRow(data, result) {
    return result.label || data.label || ueScenarioSelections[result.ue] || scenarioNameForRow(data, result);
  }

  function renderMultiUeScenarioResult(data, writeLogs = true) {
    const panel = document.getElementById('multiUeScenarioSummary');
    if (!panel) return;

    const results = Array.isArray(data.results) ? data.results : [];
    const scenarioTitle = data.mode === 'per_ue'
      ? 'Per-UE Independent Scenario Results'
      : `Multi-UE Scenario Results: ${data.label || data.scenario || 'scenario'}`;

    const rows = results.length
      ? results.map((result) => {
          const output = result.output || '';
          const duration = scenarioMetric(output, /duration_sec=([0-9]+)/);
          const mbps = scenarioMetric(output, /approx_total_mbps=([0-9.]+)/);
          return `
            <tr>
              <td><strong>${escapeHtml(result.ue || '-')}</strong></td>
              <td>${escapeHtml(scenarioNameForRow(data, result))}<br><small>${escapeHtml(scenarioLabelForRow(data, result))}</small></td>
              <td>${result.ok ? '<span class="multi-ue-badge multi-ue-attached">OK</span>' : '<span class="multi-ue-badge multi-ue-stopped">FAILED</span>'}</td>
              <td><code>${escapeHtml(result.tunnel_ip || '-')}</code></td>
              <td>${escapeHtml(fallbackValue(result.exit, '-'))}</td>
              <td>${duration ? `${escapeHtml(duration)}s` : '-'}</td>
              <td>${mbps ? `${escapeHtml(mbps)} Mbps` : '-'}</td>
            </tr>
          `;
        }).join('')
      : '<tr><td colspan="7">No scenario runs yet. Run scenarios to populate.</td></tr>';

    const rawBlocks = results.map((result) =>
      `===== ${result.ue || '-'} | ${scenarioNameForRow(data, result)} | ${result.ok ? 'OK' : 'FAILED'} =====\n${result.output || ''}`
    ).join('\n\n');

    const skippedCount = Array.isArray(data.skipped) ? data.skipped.length : 0;
    const skipped = skippedCount ? `<p class="warn">Skipped: ${escapeHtml(skippedCount)} UE(s)</p>` : '';

    const headerMeta = results.length ? `
      <div class="scenario-result-title">
        <h3>${escapeHtml(scenarioTitle)}</h3>
      </div>
      ${skipped}` : '';

    panel.innerHTML = `
      ${headerMeta}
      <table class="scenario-result-table">
        <thead>
          <tr>
            <th>UE</th>
            <th>Scenario</th>
            <th>Result</th>
            <th>Tunnel IP</th>
            <th>Exit</th>
            <th>Duration</th>
            <th>Approx Mbps</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
    `;

    if (writeLogs) setMultiUeOutput(rawBlocks || 'Ready.');
  }

  function fmtBytes(n) {
    n = Number(n) || 0;
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
    if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
    return n + ' B';
  }

  let hasMultiUeData = false;

  async function refreshMultiUes(isRetry = false) {
    try {
      const response = await fetch('/api/ues');
      const data = await response.json();

      const summary = document.getElementById('multiUeSummary');
      const tbody = document.getElementById('multiUeTableBody');

      if (!data.ok) {
        tbody.innerHTML = '<tr><td colspan="8">Failed to load UE status</td></tr>';
        return;
      }

      summary.textContent = f1ModeActiveForMultiUe ? 'Multi-UE disabled in F1 mode' : '';

      const desiredSelect = document.getElementById('desiredUeCount');
      if (
        desiredSelect &&
        data.attached_count >= 1 &&
        !desiredUeCountUserEdited &&
        document.activeElement !== desiredSelect
      ) {
        desiredSelect.value = String(data.attached_count);
      }

      tbody.innerHTML = data.ues.map((ue) => {
        const pod = ue.pod || '-';
        const tunnelIp = ue.tunnel_ip || '-';
        const bytes = `${fmtBytes(ue.rx_bytes)} / ${fmtBytes(ue.tx_bytes)}`;

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
                <button data-multi-ue-button="true" data-op="start:${ue.name}" data-locked="${ue.ready ? "true" : "false"}" ${startDisabled} onclick="startUe('${ue.name}')">Start</button>
                <button data-multi-ue-button="true" data-op="stop:${ue.name}" data-locked="${(ue.name === "ue1" || !ue.ready) ? "true" : "false"}" ${stopDisabled} title="${ue.name === "ue1" ? "UE1 is the baseline UE; stop is disabled in the UI." : "Scale this UE deployment to zero."}" onclick="stopUe('${ue.name}')">Stop</button>
                <button data-multi-ue-button="true" data-op="ping:${ue.name}" data-locked="${ue.attached ? "false" : "true"}" ${pingDisabled} title="Test this UE PDU tunnel." onclick="pingUe('${ue.name}')">Ping</button>
              </div>
            </td>
          </tr>
        `;
      }).join('');

      setMultiUeBusy(multiUeBusy);
      paintRunning();
      hasMultiUeData = true;

      // A previous transient failure may have left an error in the output box - clear it.
      const outEl = document.getElementById('multiUeOutput');
      if (outEl && outEl.textContent.startsWith('Failed to refresh UEs')) {
        setMultiUeOutput('Ready.');
      }
    } catch (error) {
      // Transient failures happen during dashboard restarts - retry once before alarming.
      if (!isRetry) {
        await new Promise((r) => setTimeout(r, 2000));
        return refreshMultiUes(true);
      }
      if (!hasMultiUeData) {
        setMultiUeOutput(`Failed to refresh UEs: ${error}, retried once. Is the dashboard up?`);
      }
    }
  }

  async function multiUePost(url, label, op) {
    if (multiUeBusy) return;
    await refreshF1ModeForMultiUe();
    if (blockMultiUeIfF1Mode(label)) return;

    beginOp(op);
    setMultiUeOutput(`${label}...`);

    try {
      const response = await fetch(url, { method: 'POST' });
      const data = await response.json();

      setMultiUeOutput(JSON.stringify(data, null, 2));
      await refreshMultiUes();
    } catch (error) {
      setMultiUeOutput(`${label} failed: ${error}`);
    } finally {
      endOp();
    }
  }

  async function startUe(ueName) {
    await multiUePost(`/api/ue/${ueName}/start`, `Starting ${ueName}`, `start:${ueName}`);
  }

  async function stopUe(ueName) {
    await multiUePost(`/api/ue/${ueName}/stop`, `Stopping ${ueName}`, `stop:${ueName}`);
  }

  async function pingUe(ueName) {
    await multiUePost(`/api/ue/${ueName}/ping`, `Pinging ${ueName}`, `ping:${ueName}`);
  }

  function selectedPerUeScenarioJobs() {
    return Array.from(document.querySelectorAll('[data-ue-scenario-select="true"]'))
      .map((select) => ({
        ue: select.dataset.ue,
        scenario: select.value
      }))
      .filter((job) => job.ue && job.scenario && job.scenario !== 'none');
  }

  async function runSelectedUeScenarios() {
    if (multiUeBusy) return;
    await refreshF1ModeForMultiUe();
    if (blockMultiUeIfF1Mode('run selected UE scenarios')) return;

    const jobs = selectedPerUeScenarioJobs();
    if (jobs.length === 0) {
      setMultiUeOutput('No per-UE scenarios selected. Choose at least one scenario other than None.');
      return;
    }

    beginOp('run-selected');
    setMultiUeOutput('Running independent per-UE eMBB realistic scenarios in parallel...\n' + jobs.map((job) => `${job.ue}: ${job.scenario}`).join('\n'));

    try {
      const response = await fetch('/api/ues/embb-scenarios', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jobs })
      });
      const data = await response.json();
      renderMultiUeScenarioResult(data);
      await refreshMultiUes();
    } catch (error) {
      setMultiUeOutput(`Per-UE scenarios failed: ${error}`);
    } finally {
      endOp();
    }
  }

  async function applyDesiredUes() {
    if (multiUeBusy) return;
    await refreshF1ModeForMultiUe();
    if (blockMultiUeIfF1Mode('apply desired UE count')) return;

    const count = Number(document.getElementById('desiredUeCount').value);
    desiredUeCountUserEdited = false;

    beginOp('apply');
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
      endOp();
    }
  }

  const desiredUeCountSelect = document.getElementById('desiredUeCount');
  if (desiredUeCountSelect) {
    desiredUeCountSelect.addEventListener('change', () => {
      desiredUeCountUserEdited = true;
    });
  }

  // Render empty-state table immediately so it is always visible, then load
  // the persisted last run so table + logs survive a hard page refresh.
  renderMultiUeScenarioResult({ results: [], ok: true });

  refreshF1ModeForMultiUe().then(refreshMultiUes);
  setInterval(async () => {
    if (multiUeBusy) return;
    await refreshF1ModeForMultiUe();
    await refreshMultiUes();
  }, 10000);

  fetch('/api/ues/embb-scenarios/last')
    .then((r) => r.json())
    .then((data) => { if (!data.empty) renderMultiUeScenarioResult(data, false); })
    .catch(() => {});

