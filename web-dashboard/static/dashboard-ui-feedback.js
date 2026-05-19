// Shared dashboard button feedback.
(function () {
  function feedbackTarget(node) {
    if (!node || !node.closest) return null;
    return node.closest("button, a.button");
  }

  function pulse(target) {
    if (!target || target.disabled) return;
    target.classList.remove("ui-pressed");
    void target.offsetWidth;
    target.classList.add("ui-pressed");
    window.setTimeout(function () {
      target.classList.remove("ui-pressed");
    }, 650);
  }

  document.addEventListener("click", function (event) {
    const target = feedbackTarget(event.target);
    if (!target) return;
    pulse(target);
  }, true);
})();
