function handoverBadge(value, passText = "READY", failText = "NOT READY") {
  return value ? passText : failText;
}

function setHandoverText(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function setHandoverOutput(text) {
  const el = document.getElementById("handoverOutput");
  if (el) el.textContent = text || "Ready.";
}

let handoverReadyForRun = false;

function setHandoverBusy(isBusy) {
  document.querySelectorAll("[data-handover-button]").forEach((button) => {
    const isRunButton = button.id === "runF1HandoverButton";
    button.disabled = isBusy;
    button.style.opacity = isBusy ? "0.55" : "";
    if (isRunButton) {
      button.title = handoverReadyForRun
        ? "Run validated F1 handover."
        : "Click to check readiness. The dashboard will block the run if F1 mode is not ready.";
    }
  });
}

function updateHandoverCards(data) {
  handoverReadyForRun = Boolean(data.handover_ready);

  setHandoverText("handoverMode", data.mode || "unknown");
  setHandoverText("handoverTopology", handoverBadge(data.topology_ready));
  setHandoverText("handoverTunnel", handoverBadge(data.ue_tunnel_ready));
  setHandoverText("handoverReady", handoverBadge(data.handover_ready, "YES", "NO"));

  setHandoverBusy(false);
}

function renderHandoverChecks(data) {
  const panel = document.getElementById("handoverChecks");
  if (!panel) return;

  const checks = [
    ["Trigger accepted", data.trigger_ok],
    ["CU handover complete", data.cu_complete],
    ["RRCReconfigurationComplete", data.rrc_complete],
    ["Target DU CFRA", data.du_cfra],
    ["Post-handover ping", data.post_ping_ok],
  ];

  panel.innerHTML = checks.map(([label, ok]) => `
    <div class="handover-check ${ok ? "pass" : "fail"}">
      ${ok ? "PASS" : "FAIL"} - ${label}
    </div>
  `).join("");
}

function extractFirstMatch(text, regex, fallback = "not found") {
  const match = text.match(regex);
  return match ? match[1] : fallback;
}

function buildCompactHandoverSummary(data) {
  const output = data.output || "";

  const runDir = extractFirstMatch(output, /RUN_DIR=([^\n]+)/);
  const rntiChange = extractFirstMatch(output, /update RNTI from ([0-9a-fA-F]+ to [0-9a-fA-F]+)/);
  const target = extractFirstMatch(output, /towards DU ([0-9]+).*PCI ([0-9]+)/, "not found");
  const ping = output.includes("0% packet loss") ? "0% packet loss" : "not confirmed";

  return [
    "===== F1 Handover Result =====",
    `Result: ${data.handover_success ? "SUCCESS" : "FAILED"}`,
    `RNTI change: ${rntiChange}`,
    `Target DU / PCI: ${target}`,
    `Post-handover ping: ${ping}`,
    "",
    "Checks:",
    `- Trigger accepted: ${data.trigger_ok ? "PASS" : "FAIL"}`,
    `- CU handover complete: ${data.cu_complete ? "PASS" : "FAIL"}`,
    `- RRCReconfigurationComplete: ${data.rrc_complete ? "PASS" : "FAIL"}`,
    `- Target DU CFRA: ${data.du_cfra ? "PASS" : "FAIL"}`,
    `- Post-handover ping: ${data.post_ping_ok ? "PASS" : "FAIL"}`,
    "",
    `Evidence directory: ${runDir}`,
  ].join("\n");
}

async function refreshHandoverStatus(showOutput = true) {
  setHandoverBusy(true);
  if (showOutput) {
    setHandoverOutput("Checking F1 handover readiness...");
  }

  try {
    const res = await fetch("/api/handover/status");
    const data = await res.json();

    updateHandoverCards(data);

    if (showOutput) {
      const compact = [
        "===== F1 Handover Readiness =====",
        `Mode: ${data.mode || "unknown"}`,
        `F1 topology: ${data.topology_ready ? "READY" : "NOT READY"}`,
        `UE tunnel: ${data.ue_tunnel_ready ? "READY" : "NOT READY"}`,
        `Handover ready: ${data.handover_ready ? "YES" : "NO"}`,
      ].join("\n");

      setHandoverOutput(compact);
    }
  } catch (err) {
    if (showOutput) {
      setHandoverOutput(`Failed to check handover status: ${err}`);
    }
  } finally {
    setHandoverBusy(false);
  }
}

async function runF1Handover() {
  setHandoverBusy(true);
  setHandoverText("handoverLastResult", "checking...");
  setHandoverOutput("Checking F1 handover readiness before running...");

  try {
    const statusRes = await fetch("/api/handover/status");
    const statusData = await statusRes.json();

    updateHandoverCards(statusData);

    if (!statusData.handover_ready) {
      const panel = document.getElementById("handoverChecks");
      if (panel) panel.innerHTML = "";

      setHandoverText("handoverLastResult", "blocked");
      setHandoverOutput([
        "===== F1 Handover Blocked =====",
        "F1 handover was not started because readiness checks did not pass.",
        "",
        `Mode: ${statusData.mode || "unknown"}`,
        `F1 topology: ${statusData.topology_ready ? "READY" : "NOT READY"}`,
        `UE tunnel: ${statusData.ue_tunnel_ready ? "READY" : "NOT READY"}`,
        `Handover ready: ${statusData.handover_ready ? "YES" : "NO"}`,
        "",
        "Review F1 topology and UE tunnel status before running again.",
      ].join("\n"));
      return;
    }

    setHandoverText("handoverLastResult", "running...");
    setHandoverOutput("Running F1 handover. This can take around 45 seconds...");

    const res = await fetch("/api/handover/f1/run", { method: "POST" });
    const data = await res.json();

    setHandoverText("handoverLastResult", data.handover_success ? "SUCCESS" : "FAILED");
    renderHandoverChecks(data);
    setHandoverOutput(buildCompactHandoverSummary(data));

    await refreshHandoverStatus(false);
  } catch (err) {
    setHandoverText("handoverLastResult", "ERROR");
    setHandoverOutput(`Failed to run F1 handover: ${err}`);
  } finally {
    setHandoverBusy(false);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  refreshHandoverStatus(true);
});
