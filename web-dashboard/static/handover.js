function handoverBadge(value, passText = "READY", failText = "NOT READY") {
  return value ? passText : failText;
}

function setHandoverText(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function setHandoverOutput(text) {
  const el = document.getElementById("handoverOutput");
  if (el) el.textContent = text || "No output.";
}

function setHandoverBusy(isBusy) {
  document.querySelectorAll("[data-handover-button]").forEach((button) => {
    button.disabled = isBusy;
    button.style.opacity = isBusy ? "0.55" : "";
  });
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

async function refreshHandoverStatus() {
  setHandoverBusy(true);
  setHandoverOutput("Checking F1 handover readiness...");

  try {
    const res = await fetch("/api/handover/status");
    const data = await res.json();

    setHandoverText("handoverMode", data.mode || "unknown");
    setHandoverText("handoverTopology", handoverBadge(data.topology_ready));
    setHandoverText("handoverTunnel", handoverBadge(data.ue_tunnel_ready));
    setHandoverText("handoverReady", handoverBadge(data.handover_ready, "YES", "NO"));

    setHandoverOutput(data.output || JSON.stringify(data, null, 2));
  } catch (err) {
    setHandoverOutput(`Failed to check handover status: ${err}`);
  } finally {
    setHandoverBusy(false);
  }
}

async function runF1Handover() {
  setHandoverBusy(true);
  setHandoverOutput("Running F1 handover. This can take around 45 seconds...");

  try {
    const res = await fetch("/api/handover/f1/run", { method: "POST" });
    const data = await res.json();

    setHandoverText("handoverLastResult", data.handover_success ? "SUCCESS" : "FAILED");
    renderHandoverChecks(data);
    setHandoverOutput(data.output || JSON.stringify(data, null, 2));

    await refreshHandoverStatus();
  } catch (err) {
    setHandoverText("handoverLastResult", "ERROR");
    setHandoverOutput(`Failed to run F1 handover: ${err}`);
  } finally {
    setHandoverBusy(false);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  refreshHandoverStatus();
});
