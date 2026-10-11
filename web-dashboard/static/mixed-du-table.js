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

  function escapeText(v) {
    return String(v == null ? "" : v).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  function toggleHalf(ue, du, current, switchable) {
    var active = current === du;
    var disabled = active || !switchable ? " disabled" : "";
    return '<button type="button" class="du-toggle-btn' + (active ? " is-active" : "") + '"' +
      ' aria-pressed="' + active + '"' + disabled +
      ' data-ue="' + escapeText(ue) + '" data-target="' + du + '">' + du.toUpperCase() + "</button>";
  }

  function renderUeRows(ues) {
    var grid = byId("mixedDuUeGrid");
    if (!grid) return;

    if (!ues || !ues.length) {
      grid.innerHTML = '<p class="small">No UE status returned.</p>';
      return;
    }

    grid.innerHTML = ues.map(function (ue) {
      var name = ue.name || "-";
      var du = String(ue.du || "").toLowerCase();
      var switchable = !!ue.switchable;
      return (
        '<div class="du-card">' +
        '<div class="du-card-name">' + escapeText(name) + "</div>" +
        '<div class="du-toggle" role="group" aria-label="' + escapeText(name) + ' serving DU">' +
        toggleHalf(name, "du0", du, switchable) +
        toggleHalf(name, "du1", du, switchable) +
        "</div></div>"
      );
    }).join("");

    Array.prototype.forEach.call(grid.querySelectorAll("button[data-ue]"), function (btn) {
      btn.addEventListener("click", function () {
        switchDu(btn.getAttribute("data-ue"), btn.getAttribute("data-target"));
      });
    });
  }

  var hasData = false;

  async function refreshMixedDuStatus() {
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
      hasData = true;
      pollOk("du");
    } catch (e) {
      pollFail("du");
      if (!hasData) setText("mixedDuOutput", "ERROR refreshing status:\n" + String(e));
    }
  }

  var _handoverInFlight = false;

  // Single-flight: while one handover runs, the whole grid is greyed out and unclickable.
  function setSwitching(on) {
    var grid = byId("mixedDuUeGrid");
    if (grid) grid.classList.toggle("is-switching", on);
  }

  async function switchDu(ue, target) {
    if (_handoverInFlight) {
      setText("mixedDuActionLog", "A handover is already in progress, please wait for it to finish.");
      return;
    }
    _handoverInFlight = true;
    setSwitching(true);
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
      setSwitching(false);
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    if (!byId("mixedDuUeGrid")) return;
    refreshMixedDuStatus();
    window.autoRefresh(refreshMixedDuStatus, 15000, function () { return _handoverInFlight; });
  });
})();
