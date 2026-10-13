// autoRefresh(fn, ms, isBusy): run fn every `ms` while the tab is visible and nothing is in flight.
// A failed poll is handled by each caller, which keeps the last good data on screen.
window.autoRefresh = function (fn, ms, isBusy) {
  setInterval(function () {
    if (document.hidden) return;
    if (isBusy && isBusy()) return;
    fn();
  }, ms);
};
