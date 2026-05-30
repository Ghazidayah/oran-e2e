(function () {
  function el(tag, attrs, text) {
    const node = document.createElement(tag);
    attrs = attrs || {};
    Object.keys(attrs).forEach((key) => {
      if (key === "class") node.className = attrs[key];
      else node.setAttribute(key, attrs[key]);
    });
    if (text !== undefined) node.textContent = text;
    return node;
  }

  async function api(path, options) {
    const res = await fetch(path, options || {});
    return await res.json();
  }

  function ueRow(ue) {
    const tr = el("tr");
    tr.appendChild(el("td", {}, ue.name || ""));
    tr.appendChild(el("td", {}, ue.protected ? "protected" : "switchable"));
    tr.appendChild(el("td", {}, ue.du || "unknown"));
    tr.appendChild(el("td", {}, ue.tunnel_ip || "-"));
    tr.appendChild(el("td", {}, ue.pod || "-"));

    const actions = el("td");
    if (ue.protected) {
      actions.appendChild(el("span", {}, "blocked"));
    } else {
      ["du0", "du1"].forEach((target) => {
        const b = el("button", {
          type: "button",
          "data-ue": ue.name,
          "data-target": target,
          class: "mixed-du-switch-btn"
        }, "→ " + target.toUpperCase());
        b.style.marginRight = "6px";
        actions.appendChild(b);
      });
    }
    tr.appendChild(actions);
    return tr;
  }

  function ensurePanel() {
    let panel = document.getElementById("mixed-du-handover-panel");
    if (panel) return panel;

    panel = el("section", { id: "mixed-du-handover-panel", class: "card" });
    panel.style.marginTop = "20px";
    panel.style.padding = "16px";
    panel.style.border = "1px solid #444";
    panel.style.borderRadius = "10px";

    panel.innerHTML = `
      <h2>Multi-UE DU Continuity / Handover</h2>
      <p>
        ue1 is DU-aware. DU switching is available for ue1, ue2, ue3, ue4, and ue5. Phase 3/4 slice scripts preserve the current DU target.
      </p>
      <div style="margin: 10px 0;">
        <button id="mixed-du-refresh" type="button">Refresh DU Status</button>
        <button id="mixed-du-run" type="button">Run Mixed-DU Validation</button>
      </div>
      <pre id="mixed-du-summary" style="white-space: pre-wrap;"></pre>
      <table id="mixed-du-table" style="width:100%; border-collapse: collapse;">
        <thead>
          <tr>
            <th>UE</th>
            <th>Role</th>
            <th>DU</th>
            <th>Tunnel</th>
            <th>Pod</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody></tbody>
      </table>
      <pre id="mixed-du-output" style="white-space: pre-wrap; margin-top: 12px;"></pre>
    `;

    const main =
      document.querySelector("main") ||
      document.querySelector(".container") ||
      document.body;

    main.appendChild(panel);
    return panel;
  }

  function renderStatus(data) {
    const panel = ensurePanel();
    const summary = panel.querySelector("#mixed-du-summary");
    const tbody = panel.querySelector("#mixed-du-table tbody");

    summary.textContent =
      "mode=" + data.mode + "\n" +
      "DU0 ready=" + data.du0_ready + "\n" +
      "DU1 ready=" + data.du1_ready + "\n" +
      "attached=" + data.attached_count + "/" + data.expected_count + "\n" +
      "ue1 DU-aware ready=" + data.ue1_protected_ok + "\n" +
      "handover ready=" + data.handover_ready;

    tbody.innerHTML = "";
    (data.ues || []).forEach((ue) => tbody.appendChild(ueRow(ue)));
  }

  async function refresh() {
    const output = document.getElementById("mixed-du-output");
    try {
      const data = await api("/api/handover/mixed-du/status");
      renderStatus(data);
      if (output) output.textContent = "";
    } catch (err) {
      if (output) output.textContent = "Refresh failed: " + err;
    }
  }

  async function switchUE(ue, target) {
    const output = document.getElementById("mixed-du-output");
    output.textContent = "Switching " + ue + " to " + target + "...";

    try {
      const data = await api("/api/handover/mixed-du/switch", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ue: ue, target: target })
      });

      output.textContent =
        "ok=" + data.ok + "\n" +
        "verdict=" + data.verdict + "\n\n" +
        (data.script_output || "");

      if (data.status) renderStatus(data.status);
      else await refresh();
    } catch (err) {
      output.textContent = "Switch failed: " + err;
    }
  }

  async function runValidation() {
    const output = document.getElementById("mixed-du-output");
    output.textContent = "Running mixed-DU validation...";

    try {
      const data = await api("/api/handover/mixed-du/run", { method: "POST" });
      output.textContent =
        "ok=" + data.ok + "\n" +
        "handover_success=" + data.handover_success + "\n" +
        "mode=" + data.mode + "\n\n" +
        JSON.stringify(data.matrix || data, null, 2);

      if (data.status) renderStatus(data.status);
    } catch (err) {
      output.textContent = "Validation failed: " + err;
    }
  }

  function patchOldLabels() {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);

    nodes.forEach((node) => {
      node.nodeValue = node.nodeValue
        .replace(/F1 Handover Validation/g, "Multi-UE DU Continuity / Handover")
        .replace(/F1 Handover/g, "Mixed-DU Handover")
        .replace(/F1 topology/g, "Mixed-DU topology")
        .replace(/F1 Topology/g, "Mixed-DU Topology")
        .replace(/oai-nr-ue-f1/g, "ue2-ue5");
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    ensurePanel();
    patchOldLabels();

    document.addEventListener("click", function (ev) {
      const target = ev.target;

      if (target && target.id === "mixed-du-refresh") {
        refresh();
      }

      if (target && target.id === "mixed-du-run") {
        runValidation();
      }

      if (target && target.classList && target.classList.contains("mixed-du-switch-btn")) {
        switchUE(target.getAttribute("data-ue"), target.getAttribute("data-target"));
      }
    });

    refresh();
  });
})();
