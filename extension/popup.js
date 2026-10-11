// Popup: renders engine status. document.title doubles as the automated
// battery's evidence channel (readable via the debug port's target list).
//
// Two check paths: the service worker (preferred), then — if the SW doesn't
// answer, e.g. it was killed by Chrome's idle lifecycle — a direct fetch from
// this extension page (host_permissions apply here too). The popup must never
// depend on the SW being alive.

const ENGINE = "http://localhost:8081";

function checkDirect() {
  const t0 = Date.now();
  const finish = (r) => {
    r.at = new Date().toISOString();
    try { chrome.storage.local.set({ lastStatus: r }); } catch (_) {}
    render(r);
  };
  fetch(ENGINE + "/v2/languages")
    .then((r) => { if (!r.ok) throw new Error("health HTTP " + r.status); })
    .then(() => fetch(ENGINE + "/v2/check", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ text: "This is a test.", language: "en-US" }).toString()
    }))
    .then(async (r) => {
      if (!r.ok) throw new Error("check HTTP " + r.status);
      const d = await r.json();
      finish({ ok: true, matches: (d.matches || []).length, ms: Date.now() - t0 });
    })
    .catch((e) => finish({ ok: false, error: String((e && e.message) || e), ms: Date.now() - t0 }));
}

function checkViaWorker() {
  let answered = false;
  try {
    chrome.runtime.sendMessage({ type: "check" }, (r) => {
      answered = true;
      if (chrome.runtime.lastError) { checkDirect(); return; }
      render(r);
    });
  } catch (_) { checkDirect(); return; }
  setTimeout(() => { if (!answered) checkDirect(); }, 800);
}

function render(r) {
  const dot = document.getElementById("dot");
  const line = document.getElementById("line");
  const hint = document.getElementById("hint");
  if (!r) { document.title = "LWA: no status"; return; }
  if (r.ok) {
    dot.className = "dot up";
    line.textContent = "Engine ready · " + r.ms + " ms";
    hint.textContent = "Your words never leave this machine.";
    document.title = "LWA: UP (" + r.ms + " ms)";
  } else {
    dot.className = "dot down";
    line.textContent = "Engine down.";
    hint.textContent = "Open LWA.app to start it.";
    document.title = "LWA: DOWN (" + r.error + ")";
  }
  document.getElementById("at").textContent = "checked " + new Date(r.at).toLocaleTimeString();
}

document.getElementById("recheck").onclick = () => {
  document.title = "LWA: checking…";
  checkViaWorker();
};

chrome.storage.local.get("lastStatus", ({ lastStatus }) => {
  if (lastStatus) render(lastStatus); // stale-until-fresh
});
checkViaWorker();
