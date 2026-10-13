// Dashboard actions, UE scenarios, traffic/slice runs and result tables.
// Shared helpers (fallbackValue, reloadStatus, loadMetrics) live in dashboard-status-live.js.

reloadStatus();
loadMetrics();

setInterval(reloadStatus, 10000);
setInterval(loadMetrics, 2000);

// ===== Run buttons: shared behaviour (OranUI.runWithButton, see common.js) =====
const runWithButton = OranUI.runWithButton;

function e2eButtons() {
  return Array.from(document.querySelectorAll("#section-e2e button"));
}

// Output box of the End-to-End section (also used by the Evidence Report).
function setLatestOutput(text) {
  const output = document.getElementById("actionOutput");
  if (!output) return;
  output.textContent = sanitizeTunnelState(text) || "(no output returned)";
  output.scrollTop = output.scrollHeight;
}

// POST /api/action/<name>; resolves to { ok, output }.
async function postAction(action) {
  const response = await fetch(`/api/action/${encodeURIComponent(action)}`, {
    method: "POST",
    cache: "no-store"
  });
  const raw = await response.text();
  let data;
  try {
    data = JSON.parse(raw);
  } catch (err) {
    data = { summary: { ok: response.ok, exit: response.ok ? 0 : 1 }, output: raw };
  }
  const summary = data.summary || {};
  const ok = response.ok && summary.ok !== false && Number(summary.exit || 0) === 0;
  return { ok, output: data.output || raw || "" };
}

// ===== Evidence Report button =====
const ACTION_LABELS = { report: "Lab report" };

async function runReport(action) {
  setLatestOutput(`Running ${ACTION_LABELS[action] || action}...\n\nWaiting for backend response.`);
  try {
    const result = await postAction(action);
    setLatestOutput(result.output);
    return result.ok;
  } catch (err) {
    setLatestOutput(`ERROR while running ${ACTION_LABELS[action] || action}:\n${err.message || err}`);
    return false;
  }
}

document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll("button[data-action]").forEach(function (button) {
    button.onclick = function () {
      runWithButton(button, [button], function () { return runReport(button.dataset.action); });
    };
  });
});

// ===== UE Check: serving DU check, attach + PDU session, connectivity =====
function extractValue(text, pattern) {
  const match = text.match(pattern);
  return match ? match[1] : "";
}

function formatScenarioSummary(data) {
  const lines = [];

  lines.push(`Scenario: ${data.label || data.scenario || "UE scenario"}`);
  lines.push(`Status: ${data.ok ? "SUCCESS" : "FAILED"}`);
  lines.push(`Requested UE count: ${fallbackValue(data.requested_count, "-")}`);
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

  return lines.join("\n");
}

// POST /api/ues/scenario/<name> for the selected UE count; resolves to { ok, output }.
async function postUeScenario(scenario, count) {
  const response = await fetch(`/api/ues/scenario/${scenario}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ count })
  });
  const data = await response.json();

  if (typeof renderMultiUeScenarioResult === "function") {
    renderMultiUeScenarioResult(data);
  }
  return { ok: response.ok && !!data.ok, output: formatScenarioSummary(data) };
}

async function runUeCheck(button) {
  const countEl = document.getElementById("desiredUeCount");
  const count = countEl ? Number(countEl.value || 1) : 1;

  return runWithButton(button, e2eButtons(), async () => {
    const steps = [
      { name: "Serving DU Check", run: () => postAction("ownership") },
      { name: "UE Attach + PDU Session", run: () => postUeScenario("attach_pdu", count) },
      { name: "UE Connectivity Test", run: () => postUeScenario("connectivity", count) }
    ];
    const log = [];
    let allOk = true;

    for (const [index, step] of steps.entries()) {
      setLatestOutput(log.concat(`[${index + 1}/${steps.length}] ${step.name} running...`).join("\n\n"));
      let result;
      try {
        result = await step.run();
      } catch (error) {
        result = { ok: false, output: `Error: ${error}` };
      }
      allOk = allOk && result.ok;
      log.push(`===== ${step.name}: ${result.ok ? "PASS" : "FAIL"} =====\n${result.output}`);
    }

    log.push(`UE Check: ${allOk ? "PASS" : "FAIL"}`);
    setLatestOutput(log.join("\n\n"));

    if (typeof refreshMultiUes === "function") {
      await refreshMultiUes();
    }
    return allOk;
  });
}

// ===== Realistic traffic scenarios (Run Image, Run TCP, ...) =====
async function runTrafficScenario(scenario, button) {
  return runWithButton(button, e2eButtons(), async () => {
    setLatestOutput("Starting realistic traffic scenario: " + scenario);

    try {
      const startRes = await fetch("/api/traffic/run/" + encodeURIComponent(scenario), {
        method: "POST"
      });
      const startData = await startRes.json();

      if (!startData.ok) {
        throw new Error(startData.error || "Failed to start scenario");
      }

      const jobId = startData.job_id;

      setLatestOutput(
        "Started: " + startData.label + "\n" +
        "Job ID: " + jobId + "\n" +
        "Waiting for result..."
      );

      for (let i = 0; i < 300; i++) {
        await new Promise((resolve) => setTimeout(resolve, 3000));

        const jobRes = await fetch("/api/traffic/jobs/" + encodeURIComponent(jobId));
        const jobData = await jobRes.json();

        if (!jobData.ok) {
          setLatestOutput("Job lookup failed:\n" + JSON.stringify(jobData, null, 2));
          continue;
        }

        const job = jobData.job || {};
        const status = job.status || "unknown";

        setLatestOutput(
          "Scenario: " + scenario + "\n" +
          "Job ID: " + jobId + "\n" +
          "Status: " + status + "\n" +
          "Exit: " + ((job.exit === null || job.exit === undefined) ? "-" : job.exit) + "\n" +
          "Proof: " + (job.job_dir || "-") + "\n\n" +
          "----- Output tail -----\n" +
          (jobData.output || "")
        );

        if (["ok", "failed", "timeout", "error"].includes(status)) {
          loadE2eKpiResults();
          return status === "ok";
        }
      }
    } catch (error) {
      setLatestOutput("Traffic scenario failed: " + error);
      return false;
    }
  });
}

function setSliceOutput(text) {
  const el = document.getElementById("sliceOutput");
  if (el) el.textContent = sanitizeTunnelState(text) || "";
}

async function runRealSliceTraffic(profile, button) {
  const group = Array.from(document.querySelectorAll("#slicePanel button"));
  return runWithButton(button, group, async () => {
    setSliceOutput(
      "Starting real S-NSSAI slice traffic: " + profile + "\n" +
      "This will switch UE1 slice, validate the tunnel, run traffic, then restore SST=1.\n" +
      "Please wait (may take several minutes)..."
    );

    try {
      const res = await fetch("/api/real-slice/" + encodeURIComponent(profile), { method: "POST" });
      const data = await res.json();
      const verdict = data.ok ? "PASS" : "FAIL (exit " + data.exit + ")";
      setSliceOutput(verdict + "\n\n" + (data.output || JSON.stringify(data, null, 2)));
      loadSliceResults();
      return !!data.ok;
    } catch (err) {
      setSliceOutput("Error: " + err);
      return false;
    }
  });
}

async function loadSliceResults() {
  try {
    const res = await fetch("/api/real-slice/results");
    const data = await res.json();
    renderSliceResults(data.rows || []);
  } catch (e) {
    // Echec d'une requete automatique: on garde les dernieres donnees affichees.
  }
}

function renderSliceResults(rows) {
  const body = document.getElementById("sliceResultsBody");
  if (!body) return;
  if (!rows.length) {
    body.innerHTML = '<tr><td colspan="7">No runs yet. Click a slice button above to start.</td></tr>';
    return;
  }
  body.innerHTML = rows.map(function(r) {
    const granted = (r.granted_sst && r.granted_sst !== "-")
      ? "SST:" + r.granted_sst + " SD:" + (r.sd || "0xffffff")
      : (r.granted_sst || "-");
    const v = r.verdict || "-";
    const vStyle = (v === "PASS" || v === "REAL_SLICE_SWITCH_OK")
      ? "color:#15803d;font-weight:bold"
      : (v.includes("FAIL") || v.includes("MISMATCH"))
      ? "color:#b91c1c;font-weight:bold"
      : "";
    const mbps = parseFloat(r.tcp_mbps) || 0;
    const mbpsStyle = mbps > 20 ? "color:#15803d;font-weight:bold"
                    : mbps > 8  ? "color:#b45309;font-weight:bold"
                    : mbps > 0  ? "color:#b91c1c;font-weight:bold" : "";
    return "<tr>" +
      "<td><strong>" + (r.label || r.profile) + "</strong><br><small style='opacity:.7'>SST=" + r.sst + " SD=" + (r.sd || "0xffffff") + "</small></td>" +
      "<td style='font-weight:bold'>" + granted + "</td>" +
      "<td>" + (r.tunnel_ip || "-") + "</td>" +
      "<td>" + (r.ping_avg_ms || "-") + "</td>" +
      "<td style='" + mbpsStyle + "'>" + (r.tcp_mbps || "-") + "</td>" +
      "<td style='" + vStyle + "'>" + v + "</td>" +
      "<td style='font-size:11px;opacity:.8'>" + (r.time || "").replace("T", " ").split(".")[0] + "</td>" +
      "</tr>";
  }).join("");
}

document.addEventListener("DOMContentLoaded", function() { loadSliceResults(); window.autoRefresh(loadSliceResults, 30000); });

// ===== E2E Scenario KPI Results table (PHASE2_KPI_RESULTS) =====
async function loadE2eKpiResults() {
  try {
    const res = await fetch("/api/e2e-kpi/results");
    const data = await res.json();
    renderE2eKpiResults(data.rows || []);
  } catch (e) {
    // Echec d'une requete automatique: on garde les dernieres donnees affichees.
  }
}

function renderE2eKpiResults(rows) {
  const body = document.getElementById("e2eKpiBody");
  if (!body) return;
  if (!rows.length) {
    body.innerHTML = '<tr><td colspan="6">No runs yet. Run a scenario above to populate this table.</td></tr>';
    return;
  }
  body.innerHTML = rows.map(function(r) {
    const v = (r.verdict || r.status || "?").toUpperCase();
    const ok = (v === "OK" && r.status === "ok");
    const vStyle = ok ? "color:#15803d;font-weight:bold" : "color:#b91c1c;font-weight:bold";
    const tput = (r.throughput_mbps === null || r.throughput_mbps === undefined) ? "-" : r.throughput_mbps.toFixed(2);
    const t = (r.time_s === null || r.time_s === undefined) ? "-" : r.time_s.toFixed(2);
    return "<tr>" +
      "<td>" + (r.label || r.scenario) + "</td>" +
      "<td style=\"" + vStyle + "\">" + v + "</td>" +
      "<td>" + tput + "</td>" +
      "<td>" + (r.integrity || "-") + "</td>" +
      "<td>" + t + "</td>" +
      "<td>" + (r.finished_at || "-") + "</td>" +
      "</tr>";
  }).join("");
}
document.addEventListener("DOMContentLoaded", function() { loadE2eKpiResults(); window.autoRefresh(loadE2eKpiResults, 30000); });
