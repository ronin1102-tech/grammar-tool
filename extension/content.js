// LWA content script — generic forms extractor (J6).
// Contract: docs/extension-content-script.md
// Architecture rule: NO cross-origin fetch here (content scripts inherit the
// page's CORS). Everything goes through the service worker.
// Secret guards: password / email / tel / number inputs and cc-* autocomplete
// fields are never read, never sent.

(function () {
  const DEBOUNCE_MS = 700;
  const MAX_CHARS = 10000;
  const TEXT_INPUTS = new Set(["text", "search", "url"]);

  let active = null; // the tracked editable element
  let timer = null;

  function isSecret(el) {
    if (el.tagName !== "INPUT") return false;
    const t = (el.getAttribute("type") || "text").toLowerCase();
    if (t === "password" || t === "email" || t === "tel" || t === "number") return true;
    const ac = (el.getAttribute("autocomplete") || "").toLowerCase();
    return ac.indexOf("cc-") === 0;
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
    if (el.id) return el.id;
    if (el.name) return el.name;
    const same = document.querySelectorAll(el.tagName);
    return el.tagName.toLowerCase() + "@" + Array.prototype.indexOf.call(same, el);
  }

  function check() {
    if (!active || !document.contains(active) || isSecret(active)) return;
    const text = (textOf(active) || "").slice(0, MAX_CHARS);
    if (!text.trim()) return;
    try {
      chrome.runtime.sendMessage(
        { type: "field-check", field: fieldId(active), tag: active.tagName.toLowerCase(), text: text },
        function () { void chrome.runtime.lastError; } // reply may never come; that's fine
      );
    } catch (_) { /* extension context gone (update/reload) */ }
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(check, DEBOUNCE_MS);
  }

  document.addEventListener("focusin", function (e) {
    if (!isEditable(e.target) || isSecret(e.target)) { active = null; return; }
    active = e.target;
  }, true);

  document.addEventListener("input", function () {
    if (active) schedule();
  }, true);
})();
