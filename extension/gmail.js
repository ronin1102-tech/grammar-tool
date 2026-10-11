// LWA Gmail module (J8) — identity + lifecycle for the compose surface.
// Contract: docs/extension-gmail.md
//  - Identity: textboxes inside [role=dialog] get evidence ids that carry the
//    surface ("gmail-compose:<label slug>"); generic fields fall through.
//  - Lifecycle: closing the compose dialog clears its overlay — no stale
//    underlines floating over the page after the box is gone.
// Loaded LAST (overlay.js, content.js, gmail.js).

(function () {
  function slug(s) {
    return String(s || "").trim().toLowerCase()
      .replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "") || "body";
  }

  window.__LWA_FIELD_ID = function (el) {
    try {
      if (!el || !el.closest || el.getAttribute("role") !== "textbox") return null;
      if (!el.closest('[role="dialog"]')) return null;
      return "gmail-compose:" + slug(el.getAttribute("aria-label"));
    } catch (_) { return null; }
  };

  // Dialog-close cleanup: any removed subtree that contained a labelled compose
  // textbox loses its overlay. (clearFor is a no-op unless it's the live one.)
  const OVERLAY = function () { return window.__LWA_OVERLAY; };
  new MutationObserver(function (muts) {
    muts.forEach(function (m) {
      Array.prototype.forEach.call(m.removedNodes, function (n) {
        if (n.nodeType !== 1 || !n.querySelectorAll) return;
        const scope = n.matches && n.matches('[role="dialog"]') ? n : n;
        const tbs = n.matches('[role="textbox"]')
          ? [n]
          : Array.prototype.slice.call(scope.querySelectorAll('[role="textbox"]'));
        tbs.forEach(function (tb) {
          const o = OVERLAY();
          if (o) o.clearFor(tb);
        });
      });
    });
  }).observe(document.documentElement || document, { childList: true, subtree: true });
})();
