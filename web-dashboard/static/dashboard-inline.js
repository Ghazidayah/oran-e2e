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

// Scenario labels and remaining dashboard logic
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

