// Popup: engine status + user dictionary.
// document.title doubles as the battery's evidence channel (debug port list).
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

// ---- dictionary (J9) -------------------------------------------------------
function send(msg) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendMessage(msg, (r) => {
        if (chrome.runtime.lastError) return resolve(null);
        resolve(r);
      });
    } catch (_) { resolve(null); }
  });
}

// A null reply means the service worker never answered — say so instead of
// silently doing nothing (QA J12 S3-7).
function dictResult(r) {
  const err = document.getElementById("dict-err");
  err.textContent = r ? "" : "Couldn't reach the extension — try again, or reload it in chrome://extensions.";
  return !!(r && r.ok);
}

function renderDict(dict) {
  const ul = document.getElementById("dictlist");
  ul.textContent = "";
  const words = Object.keys(dict || {}).sort();
  words.forEach((w) => {
    const li = document.createElement("li");
    const span = document.createElement("span");
    span.className = "w"; span.textContent = w;
    const x = document.createElement("button");
    x.className = "x"; x.textContent = "✕"; x.title = "remove";
    x.onclick = async () => { const r = await send({ type: "dict-remove", word: w }); if (dictResult(r)) renderDict(r.dict); };
    li.appendChild(span); li.appendChild(x);
    ul.appendChild(li);
  });
  if (!words.length) {
    const li = document.createElement("li");
    li.style.color = "#999";
    li.textContent = "(empty)";
    ul.appendChild(li);
  }
}

async function addWord() {
  const input = document.getElementById("dict-word");
  const w = input.value;
  if (!w.trim()) return;
  const r = await send({ type: "dict-add", word: w });
  if (dictResult(r)) { input.value = ""; renderDict(r.dict); }
}
document.getElementById("dict-add").onclick = addWord;
document.getElementById("dict-word").addEventListener("keydown", (e) => { if (e.key === "Enter") addWord(); });

send({ type: "dict-get" }).then((r) => { if (r && r.ok) renderDict(r.dict); });

// ---- battery driver (J9): drives the PRODUCTION dict+check paths -----------
// Rig opens this page as a tab with ?battery=1. The probe sentence's rule
// identity was verified against LT 6.6 on 2026-10-11: Sam/Xkalt/mistkae are
// all TYPOS / MORFOLOGIK_RULE_EN_US.
if (location.search.indexOf("battery=1") !== -1) {
  const capture = (data) => fetch("http://127.0.0.1:8082/capture", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(data)
  }).catch(() => {});
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  (async () => {
    const report = async (data) => { await capture(Object.assign({ kind: "dict-probe" }, data)); };
    try {
      const probeText = "Tell sam and Xkalt about the mistkae.";
      // Mid-sentence lowercase 'sam' — LT does NOT flag sentence-initial
      // capitalized words (could be a proper noun; verified against 6.6).
      // Dict word stays capitalized "Sam": exercises the case-normalization
      // contract (dict keys lowercased, context text lowercased before compare).
      const probe = async () => {
        // Production path: the SW's field-check (fetch + dict filter + evidence).
        return send({ type: "field-check", field: "dict-probe", tag: "popup", text: probeText });
      };

      await sleep(800); // SW wake
      const base = await probe();
      await report({ phase: "baseline", engineMatches: base.engineMatches, shownMatches: base.matches.length });

      await send({ type: "dict-add", word: "Sam" });
      const withSam = await probe();
      await report({ phase: "with-sam", engineMatches: withSam.engineMatches, shownMatches: withSam.matches.length });

      await send({ type: "dict-remove", word: "Sam" });
      const afterRemove = await probe();
      await report({ phase: "after-remove", engineMatches: afterRemove.engineMatches, shownMatches: afterRemove.matches.length });

      // Live overlay (J12 S2-4): a real page's underlines must follow dict
      // changes with zero typing. The fixture types once; we watch its overlay
      // evidence (content-script messages reach extension pages too), then
      // add and remove "Sam" and wait for the overlay to follow each time.
      const overlayCounts = [];
      const waiters = [];
      chrome.runtime.onMessage.addListener((m) => {
        const d = m && m.type === "battery-evidence" && m.data;
        if (!d || d.kind !== "overlay" || d.field !== "live") return;
        overlayCounts.push(d.count);
        waiters.slice().forEach((w) => w(d.count));
      });
      const overlayCount = (pred, ms) => new Promise((resolve) => {
        if (overlayCounts.length && pred(overlayCounts[overlayCounts.length - 1])) return resolve(true);
        const w = (n) => { if (pred(n)) { done(true); } };
        const done = (ok) => { waiters.splice(waiters.indexOf(w), 1); clearTimeout(t); resolve(ok); };
        const t = setTimeout(() => done(false), ms);
        waiters.push(w);
      });
      chrome.tabs.create({ url: "http://127.0.0.1:8083/dict?battery=1", active: true });
      const sawBase = await overlayCount((n) => n >= 3, 20000);
      const liveBase = overlayCounts[overlayCounts.length - 1];
      await send({ type: "dict-add", word: "Sam" });
      const sawAdd = await overlayCount((n) => n === liveBase - 1, 10000);
      await report({ phase: "live-added", sawBase, liveBase, sawAdd, counts: overlayCounts.slice() });
      await send({ type: "dict-remove", word: "Sam" });
      const sawRemove = await overlayCount((n) => n === liveBase, 10000);
      await report({ phase: "live-removed", sawRemove, counts: overlayCounts.slice() });
    } catch (e) {
      await report({ phase: "driverError", error: String(e && e.stack || e) });
    }
    await capture({ kind: "dict-done" });
  })();
}
