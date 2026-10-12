// LWA Gmail module (J8) — identity + lifecycle for the compose surface.
// Contract: docs/extension-gmail.md
//  - Identity: textboxes inside [role=dialog] get evidence ids that carry the
//    surface ("gmail-compose:<label slug>"); generic fields fall through.
//  - Lifecycle: closing the compose dialog clears its overlay — no stale
//    underlines floating over the page after the box is gone. Minimize (dialog
//    stays in the DOM, body hidden) is handled generically by overlay.js:
//    hidden fields drop their bars via ResizeObserver.
// Loaded LAST (overlay.js, content.js, gmail.js).

(function () {
  function slug(s) {
    return String(s || "").trim().toLowerCase()
      .replace(/\s+/g, "-").replace(/[^a-z0-9-]/g, "") || "body";
  }

  window.__LWA_FIELD_ID = function (el) {
    try {
      if (!el || !el.closest || el.getAttribute("role") !== "textbox") return null;
      const dlg = el.closest('[role="dialog"]');
      if (!dlg) return null;
      // Two open composes would both slug to the same id; suffix the 2nd+
      // dialog so evidence stays distinguishable (QA J12 S3-6).
      const n = Array.prototype.indexOf.call(document.querySelectorAll('[role="dialog"]'), dlg);
      return "gmail-compose:" + slug(el.getAttribute("aria-label")) + (n > 0 ? "-" + (n + 1) : "");
    } catch (_) { return null; }
  };

  // Dialog-close cleanup: any removed subtree that contained a labelled compose
  // textbox loses its overlay. (clearFor is a no-op for fields without one.)
  const OVERLAY = function () { return window.__LWA_OVERLAY; };
  new MutationObserver(function (muts) {
    muts.forEach(function (m) {
      Array.prototype.forEach.call(m.removedNodes, function (n) {
        if (n.nodeType !== 1 || !n.querySelectorAll) return;
        const tbs = n.matches('[role="textbox"]')
          ? [n]
          : Array.prototype.slice.call(n.querySelectorAll('[role="textbox"]'));
        tbs.forEach(function (tb) {
          const o = OVERLAY();
          if (o) o.clearFor(tb);
        });
      });
    });
  }).observe(document.documentElement || document, { childList: true, subtree: true });
})();
