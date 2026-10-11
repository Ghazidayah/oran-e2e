// Shared polling helpers.
//
// autoRefresh(fn, ms, isBusy): run fn every `ms` while the tab is visible and nothing is in flight.
// pollOk(name) / pollFail(name): every poller reports its result here. A failed poll keeps the last
// data on screen; one banner shows the connection problem and disappears when all pollers succeed.
(function () {
  var failing = {};
  var lastOk = null;
  var banner = null;

  function render() {
    var names = Object.keys(failing);
    if (!names.length) {
      if (banner) banner.hidden = true;
      return;
    }
    if (!banner) {
      banner = document.createElement("div");
      banner.className = "conn-banner";
      banner.setAttribute("role", "status");
      var nav = document.querySelector("nav.topnav");
      if (nav) nav.after(banner); else document.body.prepend(banner);
    }
    banner.textContent = "Connection to the dashboard server lost. Showing the last data" +
      (lastOk ? " (last update " + lastOk.toLocaleTimeString() + ")" : "") + ". Retrying automatically.";
    banner.hidden = false;
  }

  window.pollOk = function (name) {
    lastOk = new Date();
    if (failing[name]) { delete failing[name]; }
    render();
  };

  window.pollFail = function (name) {
    failing[name] = true;
    render();
  };

  window.autoRefresh = function (fn, ms, isBusy) {
    setInterval(function () {
      if (document.hidden) return;
      if (isBusy && isBusy()) return;
      fn();
    }, ms);
  };
})();
