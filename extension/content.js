// LWA content script — generic forms extractor (J6, per-field rework in J7).
// Contract: docs/extension-content-script.md
// Architecture rule: NO cross-origin fetch here (content scripts inherit the
// page's CORS). Everything goes through the service worker.
// Secret guards: password / email / tel / number inputs and cc-* autocomplete
// fields are never read, never sent.

(function () {
  const DEBOUNCE_MS = 700;
  const MAX_CHARS = 10000;
  const TEXT_INPUTS = new Set(["text", "search", "url"]);

  // Per-field state — NOT one shared timer. A shared timer let a keystroke in
  // field B cancel field A's pending re-check (found by the J7 battery: apply
  // in A, then any input anywhere, and A's corrections never re-checked).
  const timers = new Map();    // element -> timeout id
  const lastChecked = new Map(); // element -> text at last check (no-op guard)

  function isSecret(el) {
    // cc-* autocomplete guards ANY element, not just <input> (QA J12 S3-1).
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (ac.indexOf("cc-") === 0) return true;
    if (el.tagName !== "INPUT") return false;
    const t = (el.getAttribute("type") || "text").toLowerCase();
    return t === "password" || t === "email" || t === "tel" || t === "number";
  }

  function isEditable(el) {
    if (!el || !el.tagName) return false;
    if (el.tagName === "TEXTAREA") return true;
    if (el.tagName === "INPUT") {
      const t = (el.getAttribute("type") || "text").toLowerCase();
      return TEXT_INPUTS.has(t);
    }
    return !!el.isContentEditable;
  }

  function textOf(el) {
    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") return el.value || "";
    return el.textContent || "";
  }

  function fieldId(el) {
    try {
      if (window.__LWA_FIELD_ID) {
        const provided = window.__LWA_FIELD_ID(el); // surface modules first (J8)
        if (provided) return provided;
      }
    } catch (_) {}
    if (el.id) return el.id;
    if (el.name) return el.name;
    const same = document.querySelectorAll(el.tagName);
    return el.tagName.toLowerCase() + "@" + Array.prototype.indexOf.call(same, el);
  }

  function checkEl(el) {
    timers.delete(el);
    if (!el || !document.contains(el) || isSecret(el)) return;
    const text = (textOf(el) || "").slice(0, MAX_CHARS);
    if (!text.trim()) {
      // Clearing a field resets its check state: retyping the identical text
      // must re-check, not hit the no-op guard (QA J12 S2-1).
      lastChecked.delete(el);
      if (window.__LWA_OVERLAY) window.__LWA_OVERLAY.clearFor(el);
      return;
    }
    if (lastChecked.get(el) === text) return; // nothing changed since last check
    lastChecked.set(el, text);
    try {
      chrome.runtime.sendMessage(
        { type: "field-check", field: fieldId(el), tag: el.tagName.toLowerCase(), text: text },
        function (resp) {
          void chrome.runtime.lastError; // reply may never come; that's fine
          if (!resp || !resp.ok) {
            // Failed/aborted check: forget it, so the same text can be checked
            // again (engine down now, up later) instead of no-op'ing forever.
            if (lastChecked.get(el) === text) lastChecked.delete(el);
            return;
          }
          if (!document.contains(el)) return;
          if (window.__LWA_OVERLAY) {
            window.__LWA_OVERLAY.render({ el: el, field: fieldId(el), text: text, matches: resp.matches });
          }
        }
      );
    } catch (_) { /* extension context gone (update/reload) */ }
  }

  function scheduleFor(el) {
    clearTimeout(timers.get(el));
    timers.set(el, setTimeout(function () { checkEl(el); }, DEBOUNCE_MS));
  }

  // Dictionary changed (SW broadcast, QA J12 S2-4): re-check every field we've
  // checked, so added words lose their underline — and removed words regain
  // it — with zero typing.
  try {
    chrome.runtime.onMessage.addListener(function (msg) {
      if (!msg || msg.type !== "dict-changed") return;
      lastChecked.forEach(function (_text, el) {
        lastChecked.delete(el);
        if (document.contains(el)) scheduleFor(el);
      });
    });
  } catch (_) { /* extension context gone */ }

  document.addEventListener("input", function (e) {
    // Input events carry their own target — no focus tracking to miss.
    // (Autofocus-before-injection and focus-stealing pages therefore can't
    // blind us; there is no `active` to lose.)
    const el = e.target;
    if (isEditable(el) && !isSecret(el)) scheduleFor(el);
  }, true);

  // Readiness handshake: fired LAST (this file loads after overlay.js), so it
  // means "capture pipeline fully attached". Test drivers wait for this event.
  document.dispatchEvent(new CustomEvent("lwaReady"));
})();
