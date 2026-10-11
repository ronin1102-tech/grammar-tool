// LWA overlay — underlines + one-click apply (J7).
// Contract: docs/extension-overlay.md
//  - plain fields: mirror-div measurement → fixed underlay bars
//  - contenteditable: Range + CSS Custom Highlight API fallback-free variant
//    (we draw our own bars from getClientRects — same math both ways)
//  - page bridge: el.dataset.lwaRects (isolated worlds share DOM, not JS)
//  - apply: click → hit-test stored rects → replacements[0] at match offset
//    (staleness guard: text must still contain the original matched substring)

(function () {
  if (window.__LWA_OVERLAY) return; // singleton

  const LAYER_Z = "2147483646";
  const COLOR = { misspelling: "#d64541", grammar: "#e67e22", default: "#8e44ad" };
  const TOLERANCE = 3; // px hit-test slack

  let layer = null;
  let current = null; // { el, field, matches, checkedText, rects: [{x,y,w,h,mi}] }

  function cat(m) {
    const id = (m.rule && m.rule.category && m.rule.category.id) || "";
    if (id === "TYPOS") return "misspelling";
    if (id === "GRAMMAR") return "grammar";
    return "default";
  }

  function sendEvidence(data) {
    try {
      chrome.runtime.sendMessage({ type: "battery-evidence", data: data }, function () {
        void chrome.runtime.lastError;
      });
    } catch (_) {}
  }

  function ensureLayer() {
    if (layer && document.contains(layer)) return layer;
    layer = document.createElement("div");
    layer.id = "lwa-overlay-layer";
    layer.style.cssText =
      "position:fixed;inset:0;pointer-events:none;z-index:" + LAYER_Z + ";";
    (document.body || document.documentElement).appendChild(layer);
    return layer;
  }

  function clearLayer() {
    if (layer) layer.textContent = "";
  }

  function styleFor(m) {
    const c = COLOR[cat(m)] || COLOR.default;
    return "position:absolute;pointer-events:none;" +
      "border-bottom:2px solid " + c + ";" +
      "background:" + c + "18;border-radius:2px;";
  }

  // ---- measurement: plain fields (mirror div) -----------------------------
  function textStyle(el, s) {
    const cs = getComputedStyle(el);
    const props = ["fontFamily", "fontSize", "fontWeight", "fontStyle", "letterSpacing",
      "lineHeight", "textTransform", "wordSpacing", "tabSize"];
    props.forEach(function (p) { s[p] = cs[p]; });
    return s;
  }

  function measurePlain(el, text, matches) {
    const rect = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    const padL = parseFloat(cs.paddingLeft) || 0;
    const padR = parseFloat(cs.paddingRight) || 0;
    const padT = parseFloat(cs.paddingTop) || 0;
    const single = el.tagName === "INPUT";

    const mirror = document.createElement("div");
    textStyle(el, mirror.style);
    mirror.style.cssText += "position:absolute;visibility:hidden;white-space:" +
      (single ? "pre" : "pre-wrap") + ";word-wrap:break-word;box-sizing:content-box;" +
      "border:0;padding:0;margin:0;top:0;left:0;";
    mirror.style.width = Math.max(0, rect.width - padL - padR) + "px";
    const html = [];
    const marks = [];
    matches.forEach(function (m, mi) {
      const a = m.offset, b = m.offset + m.length;
      marks.push({ mi: mi, at: a, edge: "s" }, { mi: mi, at: b, edge: "e" });
    });
    marks.sort(function (p, q) { return p.at - q.at; });
    let pos = 0;
    marks.forEach(function (mk) {
      if (mk.at > pos) html.push(esc(text.slice(pos, mk.at)));
      html.push("<span data-mi='" + mk.mi + "' data-edge='" + mk.edge + "'></span>");
      pos = mk.at;
    });
    html.push(esc(text.slice(pos)));
    mirror.innerHTML = html.join("");
    document.body.appendChild(mirror);

    const lh = parseFloat(getComputedStyle(el).lineHeight) || parseFloat(getComputedStyle(el).fontSize) * 1.2;
    const out = [];
    marks.forEach(function (mk) {
      const node = mirror.querySelector("span[data-mi='" + mk.mi + "'][data-edge='" + mk.edge + "']");
      if (single) {
        out.push({ mi: mk.mi, edge: mk.edge, x: node.offsetLeft, y: 0 });
      } else {
        out.push({ mi: mk.mi, edge: mk.edge, x: node.offsetLeft, y: node.offsetTop });
      }
    });
    document.body.removeChild(mirror);

    // group marker pairs → one rect per match segment
    const rects = [];
    for (let i = 0; i < out.length; i += 2) {
      const s = out[i], e = out[i + 1];
      const x = rect.left + padL + s.x - el.scrollLeft;
      const w = Math.max(4, e.x - s.x);
      const yTop = single
        ? rect.top + (rect.height - lh) / 2
        : rect.top + padT + Math.min(s.y, e.y) - el.scrollTop;
      const yBot = single ? yTop + lh : rect.top + padT + Math.max(s.y, e.y) + lh - el.scrollTop;
      rects.push({ x: x, y: yTop, w: w, h: yBot - yTop, mi: s.mi });
    }
    return rects;
  }

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // ---- measurement: contenteditable (Ranges) ------------------------------
  function rangeForOffset(root, target) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let n, off = 0;
    while ((n = walker.nextNode())) {
      const len = n.nodeValue.length;
      if (target <= off + len) return [n, target - off];
      off += len;
    }
    return null;
  }

  function measureRich(el, text, matches) {
    const rects = [];
    matches.forEach(function (m, mi) {
      const a = rangeForOffset(el, m.offset);
      const b = rangeForOffset(el, m.offset + m.length);
      if (!a || !b) return;
      try {
        const r = document.createRange();
        r.setStart(a[0], a[1]);
        r.setEnd(b[0], b[1]);
        const list = r.getClientRects();
        for (let k = 0; k < list.length; k++) {
          const q = list[k];
          rects.push({ x: q.left, y: q.top, w: q.width, h: q.height, mi: mi });
        }
      } catch (_) {}
    });
    return rects;
  }

  // ---- render / clear ------------------------------------------------------
  function render(req) {
    const el = req.el;
    if (!el || !document.contains(el)) return;
    if (current && current.layer && current.layer.parentNode) current.layer.parentNode.removeChild(current.layer);
    clearLayer();
    current = null;
    delete el.dataset.lwaRects;
    if (!req.matches || !req.matches.length) {
      sendEvidence({ kind: "overlay", field: req.field, count: 0, rects: [] });
      return;
    }
    const text = req.text;
    const rects = el.tagName === "TEXTAREA" || el.tagName === "INPUT"
      ? measurePlain(el, text, req.matches)
      : measureRich(el, text, req.matches);
    const L = ensureLayer();
    rects.forEach(function (r) {
      const bar = document.createElement("div");
      bar.style.cssText = styleFor(req.matches[r.mi]) +
        "left:" + r.x + "px;top:" + r.y + "px;width:" + r.w + "px;height:" + Math.max(4, r.h) + "px;";
      L.appendChild(bar);
    });
    current = { el: el, field: req.field, matches: req.matches, checkedText: text, rects: rects };
    try {
      el.dataset.lwaRects = JSON.stringify(rects.map(function (r) {
        return [Math.round(r.x), Math.round(r.y), Math.round(r.w), Math.round(r.h), r.mi];
      }));
    } catch (_) {}
    sendEvidence({
      kind: "overlay", field: req.field, count: rects.length,
      rects: rects.map(function (r) { return [Math.round(r.x), Math.round(r.y), Math.round(r.w), Math.round(r.h)]; })
    });
  }

  // ---- apply ---------------------------------------------------------------
  function findMi(x, y) {
    if (!current) return -1;
    for (let i = 0; i < current.rects.length; i++) {
      const r = current.rects[i];
      if (x >= r.x - TOLERANCE && x <= r.x + r.w + TOLERANCE &&
          y >= r.y - TOLERANCE && y <= r.y + r.h + TOLERANCE) return r.mi;
    }
    return -1;
  }

  function originalSubstring(m) {
    const c = m.context;
    if (c && typeof c.offset === "number" && typeof c.text === "string") {
      return c.text.substr(c.offset, c.length);
    }
    return null;
  }

  function locate(text, m) {
    // exact offsets first; on staleness, search the original substring nearby
    const orig = originalSubstring(m);
    if (text === current.checkedText) return { start: m.offset, end: m.offset + m.length };
    if (orig) {
      const from = Math.max(0, m.offset - 200);
      const idx = text.indexOf(orig, from);
      if (idx !== -1 && idx <= m.offset + 200) return { start: idx, end: idx + orig.length };
    }
    return null;
  }

  function applyAt(x, y) {
    const mi = findMi(x, y);
    if (mi < 0) return false;
    const m = current.matches[mi];
    const rep = m.replacements && m.replacements[0] && m.replacements[0].value;
    if (!rep) return false;
    const el = current.el;
    const text = el.tagName === "TEXTAREA" || el.tagName === "INPUT" ? el.value : el.textContent;
    const loc = locate(text || "", m);
    if (!loc) return false;
    const from = (text || "").substr(loc.start, loc.end - loc.start);

    if (el.tagName === "TEXTAREA" || el.tagName === "INPUT") {
      el.focus();
      if (el.setRangeText) el.setRangeText(rep, loc.start, loc.end, "end");
      else el.value = el.value.slice(0, loc.start) + rep + el.value.slice(loc.end);
      el.dispatchEvent(new Event("input", { bubbles: true })); // triggers re-check
    } else {
      const a = rangeForOffset(el, loc.start);
      const b = rangeForOffset(el, loc.end);
      if (!a || !b) return false;
      const r = document.createRange();
      r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]);
      const sel = window.getSelection();
      sel.removeAllRanges(); sel.addRange(r);
      document.execCommand("insertText", false, rep); // fires input natively
    }
    sendEvidence({ kind: "apply", field: current.field, from: from.slice(0, 60), to: rep.slice(0, 60) });
    clearFor(el);
    return true;
  }

  function clearFor(el) {
    if (current && current.el === el) {
      clearLayer();
      delete el.dataset.lwaRects;
      current = null;
    }
  }

  // ---- events --------------------------------------------------------------
  document.addEventListener("click", function (e) {
    if (!current) return;
    applyAt(e.clientX, e.clientY);
  }, true);

  function rerenderOnScroll() {
    if (!current || !current.matches || !current.matches.length) return;
    const el = current.el;
    if (!document.contains(el)) return;
    const text = el.tagName === "TEXTAREA" || el.tagName === "INPUT" ? el.value : el.textContent;
    const rects = el.tagName === "TEXTAREA" || el.tagName === "INPUT"
      ? measurePlain(el, text || "", current.matches)
      : measureRich(el, text || "", current.matches);
    current.rects = rects;
    clearLayer();
    const L = ensureLayer();
    rects.forEach(function (r) {
      const bar = document.createElement("div");
      bar.style.cssText = styleFor(current.matches[r.mi]) +
        "left:" + r.x + "px;top:" + r.y + "px;width:" + r.w + "px;height:" + Math.max(4, r.h) + "px;";
      L.appendChild(bar);
    });
    try {
      el.dataset.lwaRects = JSON.stringify(rects.map(function (r) {
        return [Math.round(r.x), Math.round(r.y), Math.round(r.w), Math.round(r.h), r.mi];
      }));
    } catch (_) {}
  }
  document.addEventListener("scroll", rerenderOnScroll, true);
  window.addEventListener("resize", rerenderOnScroll);

  window.__LWA_OVERLAY = { render: render, clearFor: clearFor, applyAt: applyAt };
  // NOTE: the lwaReady handshake is dispatched by content.js (loaded AFTER this
  // file) — readiness must mean "capture pipeline attached", not "overlay API
  // exists". Announcing from here raced drivers into a deaf page.
})();
