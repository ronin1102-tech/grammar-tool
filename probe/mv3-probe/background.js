// MV3 probe: service-worker fetch to the local LanguageTool engine (8081).
// Runs on install/startup. Result is written to chrome.storage.local (for the
// popup) AND POSTed to a local capture server on 8082 so the session driver
// can read the outcome from outside the browser.

async function probe(reason) {
  const t0 = Date.now();
  const result = { reason, at: new Date().toISOString() };
  try {
    const body = new URLSearchParams({
      text: "This is a test sentence with a obvious error in it.",
      language: "en-US"
    });
    const res = await fetch("http://localhost:8081/v2/check", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString()
    });
    const data = await res.json();
    result.ok = true;
    result.status = res.status;
    result.matches = data.matches ? data.matches.length : -1;
  } catch (e) {
    result.ok = false;
    result.error = String(e);
  }
  result.ms = Date.now() - t0;

  try { await chrome.storage.local.set({ lastProbe: result }); } catch (_) {}
  // Report home (localhost capture server) — also proves a second localhost
  // fetch path from the same service worker.
  try {
    await fetch("http://127.0.0.1:8082/capture", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(result)
    });
  } catch (_) {}
}

chrome.runtime.onInstalled.addListener(() => probe("onInstalled"));
chrome.runtime.onStartup.addListener(() => probe("onStartup"));

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "run-probe") {
    probe("popup:" + msg.note).then(() => sendResponse({ done: true }));
    return true;
  }
});
