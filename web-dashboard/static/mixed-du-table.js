(function () {
  function byId(id) {
    return document.getElementById(id);
  }

  function setText(id, value) {
    var el = byId(id);
    if (el) el.textContent = value == null ? "-" : String(value);
  }

  async function jsonApi(path, options) {
    var res = await fetch(path, Object.assign({
      headers: { "Content-Type": "application/json" }
    }, options || {}));

    var text = await res.text();
    var data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch (e) {
      data = { ok: false, error: text || String(e) };
    }

    if (!res.ok) {
      throw new Error(data.error || data.message || text || ("HTTP " + res.status));
    }
    return data;
  }

  function renderUeRows(ues) {
    var body = byId("mixedDuTableBody");
    if (!body) return;

    if (!ues || !ues.length) {
      body.innerHTML = '<tr><td colspan="6">No UE status returned.</td></tr>';
      return;
    }

    body.innerHTML = ues.map(function (ue) {
      var name = ue.name || "-";
      var role = ue.protected ? "protected" : (ue.switchable ? "switchable" : "-");
      var du = ue.du || "-";
      var tunnel = ue.tunnel_ip || "-";
      var pod = ue.pod || "-";

      var disabled = ue.switchable ? "" : "disabled";
      var actions =
        '<button class="small-btn" ' + disabled + ' data-ue="' + name + '" data-target="du0">→ DU0</button> ' +
        '<button class="small-btn" ' + disabled + ' data-ue="' + name + '" data-target="du1">→ DU1</button>';

      return (
        "<tr>" +
        "<td>" + name + "</td>" +
        "<td>" + role + "</td>" +
        "<td>" + du + "</td>" +
        "<td>" + tunnel + "</td>" +
        "<td>" + pod + "</td>" +
        "<td>" + actions + "</td>" +
        "</tr>"
      );
    }).join("");

    Array.prototype.forEach.call(body.querySelectorAll("button[data-ue]"), function (btn) {
      btn.addEventListener("click", function () {
        switchDu(btn.getAttribute("data-ue"), btn.getAttribute("data-target"));
      });
    });
  }

  async function refreshMixedDuStatus() {
    setText("mixedDuOutput", "Refreshing Mixed-DU status...");
    try {
      var data = await jsonApi("/api/handover/mixed-du/status");

      var lines = [
        "mode=" + (data.mode || "-"),
        "DU0 ready=" + data.du0_ready,
        "DU1 ready=" + data.du1_ready,
        "attached=" + (data.attached_count || 0) + "/" + (data.expected_count || "-"),
        "topology ready=" + data.topology_ready,
        "handover ready=" + data.handover_ready
      ];

      if (data.note) lines.push("note=" + data.note);

      setText("mixedDuOutput", lines.join("\n"));
      renderUeRows(data.ues || []);
    } catch (e) {
      setText("mixedDuOutput", "ERROR refreshing status:\n" + String(e));
    }
  }

  async function switchDu(ue, target) {
    setText("mixedDuActionLog", "Switching " + ue + " to " + target + "...");
    try {
      var data = await jsonApi("/api/handover/mixed-du/switch", {
        method: "POST",
        body: JSON.stringify({ ue: ue, target: target })
      });

      setText(
        "mixedDuActionLog",
        "Switch result for " + ue + " -> " + target + "\n\n" +
        JSON.stringify(data, null, 2)
      );

      await refreshMixedDuStatus();
    } catch (e) {
      setText("mixedDuActionLog", "ERROR switching " + ue + ":\n" + String(e));
    }
  }

  async function runMixedDuValidation() {
    setText("mixedDuActionLog", "Running Mixed-DU validation...");
    try {
      var data = await jsonApi("/api/handover/mixed-du/run", {
        method: "POST",
        body: JSON.stringify({})
      });

      setText(
        "mixedDuActionLog",
        "Mixed-DU validation result:\n\n" + JSON.stringify(data, null, 2)
      );

      await refreshMixedDuStatus();
    } catch (e) {
      setText("mixedDuActionLog", "ERROR running validation:\n" + String(e));
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    var refreshBtn = byId("mixedDuRefreshBtn");
    var runBtn = byId("mixedDuRunBtn");

    if (refreshBtn) refreshBtn.addEventListener("click", refreshMixedDuStatus);
    if (runBtn) runBtn.addEventListener("click", runMixedDuValidation);

    if (byId("mixedDuTableBody")) {
      refreshMixedDuStatus();
    }
  });
})();
