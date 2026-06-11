// Multi-UE Control dashboard logic
let multiUeBusy = false;
let f1ModeActiveForMultiUe = false;
let desiredUeCountUserEdited = false;
  const ueScenarioSelections = {};
  const perUeScenarioOptions = [
    ["none", "None"],
    ["attach_pdu", "Attach + PDU"],
    ["connectivity", "Connectivity"],
    ["image", "Image Download eMBB"],
    ["video_download", "Video Download eMBB"],
    ["web", "Web Browsing eMBB"],
    ["streaming", "Streaming-like HLS eMBB"],
    ["tcp_download", "TCP Download KPI eMBB"],
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
    document.querySelectorAll('[data-multi-ue-button="true"], [data-ue-scenario-select="true"], [data-multi-ue-mode-control="true"]').forEach((control) => {
      const keepRefreshEnabled = control.dataset.multiUeRefresh === "true";
      control.disabled = isBusy || control.dataset.locked === "true" || (f1ModeActiveForMultiUe && !keepRefreshEnabled);
      if (f1ModeActiveForMultiUe && !keepRefreshEnabled) {
        control.title = "Multi-UE control is disabled while F1 RFsim handover mode is active.";
      }
    });
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

  function fmtBytes(n) {
    n = Number(n) || 0;
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
    if (n >= 1024) return (n / 1024).toFixed(1) + ' KB';
    return n + ' B';
  }

  async function refreshMultiUes(isRetry = false) {
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

      const updatedAt = new Date().toLocaleTimeString();
      summary.textContent = f1ModeActiveForMultiUe
        ? `${data.attached_count}/${data.max_ues} attached, ${data.running_count}/${data.max_ues} running - Multi-UE disabled in F1 mode — updated ${updatedAt}`
        : `${data.attached_count}/${data.max_ues} attached, ${data.running_count}/${data.max_ues} running — updated ${updatedAt}`;

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
                <button data-multi-ue-button="true" data-locked="${ue.ready ? "true" : "false"}" ${startDisabled} onclick="startUe('${ue.name}')">${ue.ready ? "Running" : "Start"}</button>
                <button data-multi-ue-button="true" data-locked="${(ue.name === "ue1" || !ue.ready) ? "true" : "false"}" ${stopDisabled} title="${ue.name === "ue1" ? "UE1 is the baseline UE; stop is disabled in the UI." : "Scale this UE deployment to zero."}" onclick="stopUe('${ue.name}')">Stop</button>
                <button data-multi-ue-button="true" data-locked="${ue.attached ? "false" : "true"}" ${pingDisabled} title="Test this UE PDU tunnel." onclick="pingUe('${ue.name}')">Ping</button>
              </div>
            </td>
          </tr>
        `;
      }).join('');

      setMultiUeBusy(false);

      // A previous transient failure may have left an error in the output box — clear it.
      const outEl = document.getElementById('multiUeOutput');
      if (outEl && outEl.textContent.startsWith('Failed to refresh UEs')) {
        setMultiUeOutput('Ready.');
      }
    } catch (error) {
      // Transient failures happen during dashboard restarts — retry once before alarming.
      if (!isRetry) {
        await new Promise((r) => setTimeout(r, 2000));
        return refreshMultiUes(true);
      }
      setMultiUeOutput(`Failed to refresh UEs: ${error} — retried once; is the dashboard up?`);
    }
  }

  async function multiUePost(url, label) {
    if (multiUeBusy) return;
    await refreshF1ModeForMultiUe();
    if (blockMultiUeIfF1Mode(label)) return;

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
    await refreshF1ModeForMultiUe();
    if (blockMultiUeIfF1Mode('run selected UE scenarios')) return;

    const jobs = selectedPerUeScenarioJobs();
    if (jobs.length === 0) {
      setMultiUeOutput('No per-UE scenarios selected. Choose at least one scenario other than None.');
      return;
    }

    setMultiUeBusy(true);
    setMultiUeOutput('Running independent per-UE eMBB realistic scenarios in parallel...\n' + jobs.map((job) => `${job.ue}: ${job.scenario}`).join('\n'));

    try {
      const response = await fetch('/api/ues/embb-scenarios', {
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
    await refreshF1ModeForMultiUe();
    if (blockMultiUeIfF1Mode('apply desired UE count')) return;

    const count = Number(document.getElementById('desiredUeCount').value);
    desiredUeCountUserEdited = false;

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

  const desiredUeCountSelect = document.getElementById('desiredUeCount');
  if (desiredUeCountSelect) {
    desiredUeCountSelect.addEventListener('change', () => {
      desiredUeCountUserEdited = true;
    });
  }

  refreshF1ModeForMultiUe().then(refreshMultiUes);
  setInterval(async () => {
    await refreshF1ModeForMultiUe();
    await refreshMultiUes();
  }, 10000);


// Extracted from index.html script block 4
