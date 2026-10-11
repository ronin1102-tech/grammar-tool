// LWA service worker — engine health, per spec §3.3.
// Status philosophy: green means a REAL check POST succeeded, not merely that
// the port answers (process-up is a lie about readiness — see engine warmup).

const ENGINE = "http://localhost:8081";
const MAX_CHARS = 10000;
let fieldAbort = null;

// Field checks (J6): latest-wins — a new check aborts the in-flight one.
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
    result.ok = true;
    result.matches = data.matches || [];
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
  // Automated-battery evidence channel: report the status to a local capture
  // server (127.0.0.1:8082) when one is listening. Harmless in daily use
  // (nothing listens on 8082 unless the test rig started it).
  try {
    await fetch("http://127.0.0.1:8082/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ kind: "engine-status", ok: result.ok, ms: result.ms })
    });
  } catch (_) {}
  return result;
}

chrome.runtime.onInstalled.addListener(() => { checkEngine(); });
chrome.runtime.onStartup.addListener(() => { checkEngine(); });

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "check") {
    checkEngine().then(sendResponse);
    return true; // async response
  }
  if (msg && msg.type === "field-check") {
    checkField(msg).then(sendResponse);
    return true;
  }
});
