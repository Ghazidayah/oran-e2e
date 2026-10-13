/* Helpers partages par les modules du dashboard (charge avant les autres scripts). */
(function (global) {
  function byId(id) {
    return document.getElementById(id);
  }

  function setText(id, value) {
    var el = byId(id);
    if (el) el.textContent = value == null ? "-" : String(value);
  }

  // fetch JSON: une reponse non JSON ou un statut HTTP d'erreur leve une Error lisible.
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

  function escapeHtml(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch];
    });
  }

  // Comportement commun des boutons de lancement (Run Video, UE Check, Apply, Run...):
  // le bouton affiche "Running..." et reste a sa largeur d'origine, le reste du groupe est
  // verrouille pendant la tache, puis "Done" ou "Failed" pendant 2,5 s avant restauration.
  // `task` retourne true (Done), false (Failed) ou undefined (libelle inchange).
  async function runWithButton(button, group, task) {
    var originalText = button.textContent;
    button.style.minWidth = button.offsetWidth + "px";
    button.disabled = true;
    button.textContent = "Running...";
    group.forEach(function (other) { if (other !== button) other.disabled = true; });

    try {
      var ok = await task();
      if (ok === true) button.textContent = "Done";
      else if (ok === false) button.textContent = "Failed";
    } catch (error) {
      console.error(error);
      button.textContent = "Failed";
    } finally {
      group.forEach(function (other) { if (other !== button) other.disabled = false; });
      setTimeout(function () {
        button.textContent = originalText;
        button.disabled = false;
        button.style.minWidth = "";
      }, 2500);
    }
  }

  global.OranUI = {
    byId: byId, setText: setText, jsonApi: jsonApi, escapeHtml: escapeHtml, runWithButton: runWithButton
  };
})(window);
