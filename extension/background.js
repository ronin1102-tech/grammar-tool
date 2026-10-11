// LWA service worker — engine health, field checks, user dictionary.
// Status philosophy: green means a REAL check POST succeeded, not merely that
// the port answers (process-up is a lie about readiness — see engine warmup).

const ENGINE = "http://localhost:8081";
const MAX_CHARS = 10000;
let fieldAbort = null;

// ---- user dictionary (J9) ------------------------------------------------
// Words the user always accepts. Filter is CATEGORY-AWARE: a dictionary word
// only hides its TYPOS match — a grammar/punctuation error on the same text
// must still surface. Default categories in one place.
const DICT_KEY = "userDict";
const FILTER_CATEGORIES = ["TYPOS"];

function dictKey(w) { return String(w || "").trim().toLowerCase(); }

function getDict() {
  return chrome.storage.local.get(DICT_KEY).then(function (r) { return r[DICT_KEY] || {}; });
}
function setDict(d) {
  return chrome.storage.local.set({ userDict: d }).then(function () { return d; });
}

function filterMatches(matches, dict) {
  const list = matches || [];
  if (!dict || Object.keys(dict).length === 0) return list;
  return list.filter(function (m) {
    const cat = m.rule && m.rule.category && m.rule.category.id;
    if (FILTER_CATEGORIES.indexOf(cat) === -1) return true; // never hide non-TYPOS
    const txt = (m.context && typeof m.context.offset === "number")
      ? m.context.text.substr(m.context.offset, m.context.length)
      : (m.match || "");
    return !Object.prototype.hasOwnProperty.call(dict, dictKey(txt));
  });
}

// ---- field checks (J6): latest-wins abort --------------------------------
async function checkField(msg) {
  const text = String(msg.text || "").slice(0, MAX_CHARS);
  if (fieldAbort) fieldAbort.abort();
  fieldAbort = new AbortController();
  const result = { ok: false, matches: [] };
  try {
    const res = await fetch(ENGINE + "/v2/check", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ text, language: "en-US" }).toString(),
      signal: fieldAbort.signal
    });
    if (!res.ok) throw new Error("check HTTP " + res.status);
    const data = await res.json();
    const dict = await getDict();
    const shown = filterMatches(data.matches || [], dict);
    result.ok = true;
    result.matches = shown;
    result.engineMatches = (data.matches || []).length;
    result.filtered = result.engineMatches - shown.length;
  } catch (e) {
    result.error = String((e && e.message) || e);
  }
  // Battery evidence channel (test rig only; silent when nothing listens).
  try {
    await fetch("http://127.0.0.1:8082/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind: "field-check", field: msg.field, tag: msg.tag,
        textLength: text.length, matchesCount: result.matches.length,
        engineMatches: result.engineMatches, filtered: result.filtered,
        sample: text.slice(0, 120) // wide enough for burst discriminants
      })
    });
  } catch (_) {}
  return result;
}

async function checkEngine() {
  const t0 = Date.now();
  const result = { at: new Date().toISOString() };
  try {
    const health = await fetch(ENGINE + "/v2/languages");
    if (!health.ok) throw new Error("health HTTP " + health.status);
    const body = new URLSearchParams({ text: "This is a test.", language: "en-US" });
    const res = await fetch(ENGINE + "/v2/check", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString()
    });
    if (!res.ok) throw new Error("check HTTP " + res.status);
    const data = await res.json();
    result.ok = true;
    result.matches = Array.isArray(data.matches) ? data.matches.length : 0;
  } catch (e) {
    result.ok = false;
    result.error = String((e && e.message) || e);
  }
  result.ms = Date.now() - t0;
  try { await chrome.storage.local.set({ lastStatus: result }); } catch (_) {}
  // Battery evidence channel (test rig only; silent when nothing listens).
  try {
    await fetch("http://127.0.0.1:8082/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ kind: "engine-status", ok: result.ok, ms: result.ms })
    });
  } catch (_) {}
  return result;
}

chrome.runtime.onInstalled.addListener(() => {
  checkEngine();
  // Battery autostart: a capture server on 8082 is the rig's signature
  // (daily use has nothing on 8082 — this never fires outside tests).
  // NOTE: lives in onInstalled because the rig always uses a FRESH profile —
  // Chrome treats that as a first-time install (onInstalled), not a startup.
  // Learned the hard way: engine-status captured while battery-hello (then in
  // onStartup) never fired.
  fetch("http://127.0.0.1:8082/capture", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ kind: "battery-hello" })
  }).then(() => chrome.tabs.create({ url: chrome.runtime.getURL("popup.html?battery=1") }))
    .catch(() => {});
});
chrome.runtime.onStartup.addListener(() => { checkEngine(); });

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {  if (msg && msg.type === "check") {
    checkEngine().then(sendResponse);
    return true; // async response
  }
  if (msg && msg.type === "field-check") {
    checkField(msg).then(sendResponse);
    return true;
  }
  if (msg && msg.type === "battery-evidence") {
    fetch("http://127.0.0.1:8082/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(msg.data)
    }).then(() => sendResponse({ ok: true })).catch(() => sendResponse({ ok: false }));
    return true;
  }
  if (msg && msg.type === "dict-get") {
    getDict().then((d) => sendResponse({ ok: true, dict: d }));
    return true;
  }
  if (msg && msg.type === "dict-add") {
    const k = dictKey(msg.word);
    if (!k) { sendResponse({ ok: false, error: "empty word" }); return true; }
    getDict()
      .then((d) => { d[k] = { addedAt: new Date().toISOString() }; return setDict(d); })
      .then((d) => sendResponse({ ok: true, dict: d }));
    return true;
  }
  if (msg && msg.type === "dict-remove") {
    getDict()
      .then((d) => { delete d[dictKey(msg.word)]; return setDict(d); })
      .then((d) => sendResponse({ ok: true, dict: d }));
    return true;
  }
});
