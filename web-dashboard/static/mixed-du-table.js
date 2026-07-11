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

      setText("mixedDuOutput", lines.join("\n"));
      renderUeRows(data.ues || []);
    } catch (e) {
      setText("mixedDuOutput", "ERROR refreshing status:\n" + String(e));
    }
  }

  // Grey out / re-enable every UE switch button (single-flight: one handover at a time).
  function setSwitchButtonsDisabled(disabled) {
    var btns = document.querySelectorAll("#mixedDuTableBody button[data-ue]");
    Array.prototype.forEach.call(btns, function (b) {
      // Keep buttons that are disabled for their own reason (non-switchable UE) disabled.
      if (disabled) {
        if (!b.hasAttribute("disabled")) { b.setAttribute("disabled", "disabled"); b.dataset.tempDisabled = "1"; }
        b.style.opacity = "0.45";
      } else {
        if (b.dataset.tempDisabled === "1") { b.removeAttribute("disabled"); delete b.dataset.tempDisabled; }
        b.style.opacity = "";
      }
    });
  }

  var _handoverInFlight = false;

  async function switchDu(ue, target) {
    if (_handoverInFlight) {
      setText("mixedDuActionLog", "A handover is already in progress — please wait for it to finish.");
      return;
    }
    _handoverInFlight = true;
    setSwitchButtonsDisabled(true);
    setText("mixedDuActionLog", "Switching " + ue + " to " + target + " ... (other handovers disabled until this completes)");
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
      // 409 from the backend single-flight lock surfaces here as an error.
      var msg = String(e);
      if (msg.indexOf("in progress") !== -1 || msg.indexOf("HANDOVER_BUSY") !== -1) {
        setText("mixedDuActionLog", "Another handover is in progress; only one runs at a time. Try again once it finishes.");
      } else {
        setText("mixedDuActionLog", "ERROR switching " + ue + ":\n" + msg);
      }
    } finally {
      _handoverInFlight = false;
      setSwitchButtonsDisabled(false);
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
