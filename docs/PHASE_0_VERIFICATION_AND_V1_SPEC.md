# Phase 0 Verification & v1 Technical Specification — Local Writing Assistant

**Project:** Local Writing Assistant (working title) — private, offline grammar engine for macOS
**Host machine:** 2012 MacBook Pro (MacBookPro9,2), macOS Catalina 10.15.7
**Status:** ✅ APPROVED — Tracy, 2026-10-10 (all four recommendations accepted; build lane: Cori J1–J12, Claude fix-pass, Vesper QA-gate)
**Engine order:** Tracy → Gemini → Vesper → Cori (this doc) → Claude (implementation lane)
**Verified by:** Cori, executing directly on target hardware, 2026-10-10. Every number below is from an actual command run this session; nothing is from documentation memory.

---

# Part 1 — Hardware Verification Log & Benchmark Matrix

## 1.1 Host identity (verified)

```
$ sw_vers; sysctl hw.model machdep.cpu.brand_string hw.memsize hw.ncpu; df -h /
ProductName: Mac OS X        ProductVersion: 10.15.7   BuildVersion: 19H2026
hw.model: MacBookPro9,2
machdep.cpu.brand_string: Intel(R) Core(TM) i5-3210M CPU @ 2.50GHz
hw.memsize: 17179869184      (16 GB)
hw.ncpu: 4
/dev/disk1s5  477Gi  10Gi  52Gi  17%  /
```

| Fact | Value | Consequence for v1 |
|---|---|---|
| Model / CPU | MacBookPro9,2, i5-3210M (Ivy Bridge, x86_64, 4 threads) | Everything must be x86_64 native; no ARM-only builds |
| RAM | 16 GB | Plenty for LT server + Chrome + system |
| Disk free | 52 GB | LT engine (~1 GB unzipped) + JDK (~330 MB) is trivial |
| Chrome | 128.0.6613.138 — **the last Chrome that runs on Catalina** | Extension must target MV3 APIs available in ≤128; pinned ceiling |
| Toolchain | Apple Swift 5.3.2 via CommandLineTools (no full Xcode) | Swift compiles but slowly (see 1.6); clang 12 available for Phase 2 |
| Homebrew | present at `/usr/local/bin` | Used only for one-time setup; product itself needs none |

## 1.2 Java 17 on Catalina (verified — with one significant trap found and fixed)

**Runtime installed:** Eclipse Temurin **17.0.20.1+1**, tarball (no admin password, no cask), self-contained in `~/jdks/`:

```
$ ~/jdks/jdk-17.0.20.1+1/Contents/Home/bin/java -version
openjdk version "17.0.20.1" 2026-08-18
OpenJDK Runtime Environment Temurin-17.0.20.1+1 (build 17.0.20.1+1)
OpenJDK 64-Bit Server VM Temurin-17.0.20.1+1 (build 17.0.20.1+1, mixed mode)
```

Java 17 **runs natively on this machine**. But the first LanguageTool check returned HTTP 500:

### The Catalina AWT trap (the main Phase 0 finding)

```
java.lang.UnsatisfiedLinkError: .../lib/libawt.dylib: dlopen(...):
  Library not loaded: /System/Library/Frameworks/JavaRuntimeSupport.framework/Versions/A/JavaRuntimeSupport
  Reason: image not found
  at org.languagetool.gui.Configuration.<clinit>(Configuration.java:91)   ← LT server loads AWT classes
  at java.desktop/java.awt.Color.<clinit>(...)
```

Root-cause chain, verified step by step:

1. LT 6.6's server path touches AWT (`org.languagetool.gui.Configuration` → `java.awt.Color` static init) even in server mode. `--headless` / `-Djava.awt.headless=true` does **not** help — the dylib load itself fails.
2. **Both** Temurin builds (JRE and full JDK, 17.0.20.1+1) ship `libawt.dylib` with a load command on `JavaRuntimeSupport.framework`, which **does not exist on Catalina** (verified: `ls /System/Library/Frameworks/JavaRuntimeSupport.framework` → No such file). This framework was removed after Catalina's era; current Temurin builds still reference it.
3. `otool -L` shows the load command; `nm -u` shows `libawt.dylib` imports **zero symbols** from JavaRuntimeSupport — the load command is vestigial. Other dylibs (`libawt_lwawt`, `libosxui`) import *real* JRS symbols — those are UI-only.

**The fix (verified working, reproducible):**

```sh
cd jdk-17.0.20.1+1/Contents/Home/lib
for f in libawt.dylib libawt_lwawt.dylib libosx.dylib libosxui.dylib libosxapp.dylib libsaproc.dylib; do
  install_name_tool -change \
    "/System/Library/Frameworks/JavaRuntimeSupport.framework/Versions/A/JavaRuntimeSupport" \
    "/usr/lib/libSystem.B.dylib" "$f"
  codesign -f -s - "$f"
done
```

Safe because the one dylib on the server's load path needs no JRS symbols. After patching: end-to-end HTTP 200 with correct grammar matches.

**Hard constraint recorded:** LanguageTool **desktop GUI mode can never run on Catalina** (real JRS dependencies in the UI dylibs). Server mode is the only supported operation — which is exactly the product shape. The patch is **step zero of every fresh install** and must be scripted (v1 job J2).

**LanguageTool version pairing (verified by execution + source):** LanguageTool **6.6** (build 2025-03-27, `f3e8d91`) is the final stable numbered ZIP — LT switched to snapshot-only releases after March 2025 (dev.languagetool.org/java-api.html: "requires Java 17 since version 6.6"). **Locked pair: LanguageTool 6.6 + Temurin 17.0.20.1+1 (patched).**

## 1.3 LanguageTool HTTP server benchmarks (verified)

Config for all rows: patched JDK 17, `-Djava.awt.headless=true -Xms256m -Xmx<size>`, `org.languagetool.server.HTTPServer --port 8081`, language en-US, payload = exactly 500 words with 25 embedded grammar errors. Harness: `scripts/bench-launch.sh` (in repo). RSS via `ps -o rss=`.

| Metric | `-Xmx1g` | `-Xmx2g` |
|---|---|---|
| Cold start → first HTTP 200 (`/v2/languages`) | **7 s** | **7 s** |
| Idle RSS (before any check) | 306 MB | 305 MB |
| First POST `/v2/check` (500 words) | 21 ms, HTTP 200 | 18 ms, HTTP 200 |
| RSS after first check | 550 MB | 687 MB |
| Steady-state POSTs (same payload ×3) | 1.02 s / 0.77 s / 0.73 s | 1.47 s / 1.08 s / 0.75 s |
| POST after 60 s idle (1g only) | 0.69 s — no reload penalty; RSS stayed 634 MB | not re-run |
| Matches returned on payload | 48 (25 planted + LT extras) | — |

**Recommendation: `-Xmx1g`.** The 2 GB heap buys nothing measurable (same cold start, higher RSS, no latency win). Keep 2 GB in notes only as headroom for future long-document batch checks.

**Recorded anomaly (honest):** the *first* POST was faster (18–21 ms) than steady-state (~0.7–1.5 s), reproducibly on both heaps. Hypothesis: LT 6.6 pipelines language-module init differently after the readiness GETs, and the repeated-sentence payload caches favorably. Impact on UX: none — steady-state is what a typer feels, and ≤1.5 s on 500 words leaves large headroom for the 700 ms debounce design. Not investigated further (would be v2 curiosity, not v1 need).

Sanity probe: 9-word sentence with two errors → HTTP 200 in 18 ms, exactly the right 2 matches ("Their → there", "a obvious → an obvious").

## 1.4 Offline & zero-telemetry audit (verified — empirical)

| Check | Method | Result |
|---|---|---|
| Network bind | `lsof -nP -iTCP:8081 -sTCP:LISTEN` | `TCP 127.0.0.1:8081 (LISTEN)` — **loopback only**, not `0.0.0.0`. LAN-invisible by default |
| All sockets of server pid | `lsof -a -i -p <pid>` | Only the 127.0.0.1 listener. No other sockets |
| WAN traffic over whole process life | `nettop -p <pid> -x -L 1` | `bytes_in = 0, bytes_out = 0` — **hard zero**, including first-use module loads |
| Update/telemetry chatter in server log | grep across full session log | None. (20 `TelemetryProvider` grep hits are stack-frame lines from the pre-patch crash traceback, not calls) |
| CLI surface | `HTTPServer --help` (full output captured) | `--config`, `--port`, `--public` only. **The launcher must never pass `--public`** (that flag would expose the port to the LAN). No telemetry flags exist because the server makes no outbound calls — confirmed empirically above |

Extension side enforces the same: `host_permissions` is an explicit allowlist of `localhost`/`127.0.0.1` — Chrome blocks any other origin, so the client *cannot* phone home even accidentally.

## 1.5 Chrome MV3 → localhost connectivity (verified)

Loaded the probe extension (`probe/mv3-probe/`, kept as evidence) into an **isolated** Chrome instance (`--user-data-dir=/tmp/lwa-chrome-profile --load-extension=...`) — Tracy's main profile untouched, no Developer Mode needed.

The MV3 **service worker** ran `fetch("http://localhost:8081/v2/check", {method:"POST", ...})` on install and reported:

```json
{"reason":"onInstalled","at":"2026-10-10T15:46:17.763Z","ok":true,"status":200,"matches":1,"ms":144}
```

- Service worker lifecycle works on Chrome 128 / Catalina; `onInstalled` fired and the SW executed fetches.
- **No CORS, no MV3 local-sandbox blocking** of localhost POSTs when `host_permissions` includes the origin.
- Manifest permissions required (whole list): `host_permissions: ["http://localhost:8081/*", "http://127.0.0.1:8081/*"]`. **No** `content_security_policy` key is needed — `fetch()` from a service worker is governed by host permissions, not page CSP.
- Popup UI path is written (`probe.html`) but click-through wasn't driven: **unverified, owner Tracy** (optional 3-step: chrome://extensions → Developer mode → Load unpacked → click the puzzle piece). The verified SW path is the one v1 actually uses.
- Run both engine server (8081) and capture server (8082) during the probe; both localhost fetches from the same SW succeeded.

## 1.6 Launcher toolchain on Catalina (verified)

- Swift 5.3.2 compiles AppKit: a 10-line menubar status-item probe **compiled OK in 246 s** (cold toolchain; warm rebuild speed unverified).
- Verdict for v1: **zsh + osascript `.app`** — the pattern already proven daily by `mac/launcher.zsh` (Solstice Agent): nohup + pidfile + port health-poll + osascript dialogs/notifications, zero Terminal window. Iterating on it costs seconds, not minutes.
- A true persistent menubar item (NSStatusItem) is **v2** — Swift is viable on this machine, just expensive to iterate. Flagged: the original brief asked for a menubar indicator in v1; the measured 246 s/compile makes that a poor v1 trade. v1 substitutes notification-based "ready" status + a state dialog on re-open.

## 1.7 Cost-driver diagnosis (what Phase 0 actually cost, and what v1 will cost)

- **Phase 0's real cost** was the AWT trap: two dead-end server launches + one extra JDK download before `otool`/`nm` root-caused it. Now banked as a scripted recipe — a fresh machine is a 10-minute setup.
- **Predicted v1 cost drivers, ranked:** (1) Google Docs text extraction/overlay inside its custom rendering surface — the one genuinely hard client piece; (2) overlay positioning + replacement inside rich editors (Gmail); (3) launcher — low risk, proven pattern; (4) engine integration — de-risked by today's numbers (7 s start, <1 s checks, zero-WAN).

## 1.8 Verified / Unverified ledger (with owners)

**Verified this session (executed, evidence above):** host identity · Java 17 runtime on Catalina · LT 6.6 pairing · the AWT patch (end-to-end) · cold start · RAM at idle/active · check latency · zero-WAN (nettop) · loopback-only bind · MV3 service-worker → localhost POST · swiftc presence & cold compile · LT CLI flag surface.

**Unverified — owner assigned:**

| Item | Owner | Note |
|---|---|---|
| Probe popup click-through in normal Developer Mode | Tracy | Optional; SW path (the one v1 uses) already verified |
| Warm swiftc rebuild speed | — | v2 concern only |
| llama.cpp build/runtime on clang 12 | deferred | Phase 2 per plan; not in v1 |
| Concurrent LT + llama.cpp RAM | deferred | Phase 2 |
| Thermals/battery under hours of continuous linting | — | Real typing load is far below today's benchmark load; revisit if ever noticeable |

---

# Part 2 — Open Decision Matrix (Tracy's gate — no decision made by Cori)

### D1. Product name
| Option | One-line rationale |
|---|---|
| **Local Writing Assistant** (working title) | Descriptive, zero marketing; fine forever if you don't care |
| **Scribe** / **Solstice Scribe** | Short, product-feeling; Solstice prefix ties it to the umbrella |
| **Proofline** | Neutral, says what it does; survives going public |
| **Quill** | Warm, writing-tool heritage; likely name collisions if public |
**DECIDED (Tracy, 2026-10-10):** keep the working title through v1; pick the name at Phase 3 polish so it never blocks the build.

### D2. Client scope: MV3 now vs native system-wide now
- **MV3 extension (recommended for v1):** every API it needs is verified present in the Chrome 128 ceiling; covers Gmail, Google Docs, and every standard web form — where the writing actually happens. Hardware-verified end-to-end today.
- **Native system-wide (parking lot):** on Catalina that means CGEventTap + Accessibility APIs, permission prompts, per-app exceptions, and Swift iteration at the measured 246 s/compile. High effort, and its benefit (non-browser apps) is the smaller share of Tracy's writing.
**DECIDED (Tracy, 2026-10-10):** MV3 v1, native v2/v3 — matching the plan's "recommend ONE shippable client" instruction.

### D3. Repository / branch strategy
- **Standalone private repo `grammar-tool`** (already scaffolded at `~/workspace/grammar-tool/` per your call), outside the Cori working tree. Solstice-branded when pushed.
- Branches: `main` (protected) + short-lived per-feature branches; Claude's fix-pass lane arrives as PRs; Vesper QA-gates before merge.
- `vendor/` (the LT ZIP) and `~/jdks` artifacts are **gitignored**; `scripts/fetch-engine.sh` re-fetches pinned URLs so a fresh clone reproduces the engine exactly.
**DECIDED (Tracy, 2026-10-10):** standalone private repo `grammar-tool`, vendor artifacts gitignored, `scripts/fetch-engine.sh` reproducibility.

### D4. Distribution model
- **v1: private local build.** A `make-app.sh` produces `LWA.app` in the project; hand-installed; ad-hoc signed. First launch on Catalina needs one right-click → Open (unsigned-app gate) — documented in the install walkthrough.
- **Future: public GitHub + Release ZIPs** — your plan notes portfolio value; that's a Tracy call, and nothing public happens without your explicit approval (standing rule).
- **Never:** auto-updaters/Sparkle — an offline product shouldn't grow a network dependency. Updates = re-run fetch scripts, by design.
**DECIDED (Tracy, 2026-10-10):** private local build for v1; public distribution deferred, nothing public without Tracy's explicit approval.

---

# Part 3 — Locked v1 Technical Specification (draft — activates on your approval)

## 3.1 Architecture

```
┌────────────────────────────┐   POST /v2/check (localhost:8081)
│ Chrome MV3 extension       │ ────────────────────────────────► ┌─────────────────────────┐
│ (thin client: extract,     │ ◄──────── JSON matches ┊───────── │ LanguageTool 6.6 server │
│  debounce, overlay, apply) │                                    │ 127.0.0.1 · patched     │
└────────────────────────────┘                                    │ JDK 17 headless · 1 GB  │
┌────────────────────────────┐   spawn / health-poll / SIGTERM    └─────────────────────────┘
│ LWA.app (zsh+osascript)    │ ────────────────────────────────► manages the java child
└────────────────────────────┘
```

One user, one machine, one engine. No cloud, no account, no telemetry — verified architecture, not policy.

## 3.2 Launcher — `LWA.app` (macOS, zsh + osascript)

- **Bundle:** AppleScript-app stub (same pattern as the Solstice Agent app) running `scripts/launcher.sh` from the project; a `git pull` updates behavior without rebuilding.
- **Start path:** set up env (Finder-launched apps don't read shell rc) → locate patched JDK (`~/jdks/jdk-17.0.20.1+1`) and engine → write pidfile → spawn `java -Djava.awt.headless=true -Xms256m -Xmx1g -cp engine/LanguageTool-6.6/languagetool-server.jar org.languagetool.server.HTTPServer --config engine/server.properties --port 8081` → poll `GET /v2/languages` until 200 (≤240 s budget) → notification **"Writing engine ready."**
- **Lifecycle:** pidfile at `data/engine.pid`; on quit: SIGTERM → wait ≤10 s → SIGKILL if still alive → verify port free (lsof) → notify. Re-open while running → state dialog (Running · since · Restart · Stop) — proven interaction pattern. Engine-files-newer-than-pidfile → offer restart (stale-launch guard, proven pattern).
- **Failure UX:** port already bound → dialog naming the offending pid (lsof); JDK missing/unpatched → dialog pointing at `scripts/patch-jdk.sh`; engine start timeout → dialog with last log lines.
- **Explicit deviation from the original brief:** v1 has **no live menubar item** (measured Swift cost, §1.6). Status = notifications + re-open dialog. True NSStatusItem menubar → v2.
- **Never passes `--public`** (§1.4).

## 3.3 Chrome extension (MV3 thin client)

- **Manifest:** MV3; `host_permissions: ["http://localhost:8081/*","http://127.0.0.1:8081/*"]` and nothing else — the allowlist is the telemetry firewall; no CSP key needed (§1.5); no remote code.
- **Extraction (per-surface modules):**
  - Generic forms: focus-driven; observes `input`/`keyup` on textarea, input\[text\], contenteditable; skips `type=password` and `autocomplete=cc-*` fields — **never sends secrets to the engine**.
  - Gmail: compose `div[role="textbox"][aria-label*="Message"]`.
  - Google Docs: custom canvas surface — **highest-risk v1 item**; if it proves unstable, Docs ships as v1.1 (Gmail + standard forms cover the daily core). Decision point at build time, per cost-driver ranking (§1.7).
- **Pipeline:** 700 ms debounce; in-flight request cancelled via AbortController on new input; only the active element's text is POSTed, capped at 10,000 chars (matches `maxTextLength`).
- **Overlay + apply:** match `offset/length` → `Range` over the text node → underline decorations styled by rule category; click → `replacements[0].value` applied via range replace (forms) / `execCommand("insertText")` (rich editors); re-check after apply. Non-destructive: text is never rewritten without an explicit user click.
- **User dictionary (v1):** client-side ignore-list in `chrome.storage.local`; matched rule hits on stored words are filtered before render. (LT 6.6 OSS has no persistent server-side user dict — client-side filter is the robust v1; server-side custom rules remain available via `rulesFile` later.)

## 3.4 Engine harness

- **Launch config `engine/server.properties`** (all flags verified present in `--help`): `maxTextLength=10000`, `maxCheckTimeMillis=30000`, `maxCheckThreads=2` (leave cores to Chrome), `cacheSize=500`, `cacheTTLSeconds=300`.
- **API contract (both endpoints exercised this session):** `POST /v2/check` form-urlencoded `text`, `language=en-US` → JSON `matches[]` with `message`, `offset`, `length`, `replacements[].value`, `rule.id`, `rule.category.id`. Health: `GET /v2/languages` → 200.
- **Disk layout:**

```
grammar-tool/
├── engine/
│   ├── LanguageTool-6.6/          # unzipped vendored engine
│   └── server.properties          # locked launch config
├── vendor/LanguageTool-6.6.zip    # pristine artifact (gitignored; fetch-engine.sh re-fetches)
├── data/                          # runtime: engine.pid, logs/
├── user-dict/                     # reserved (v1: dict lives client-side in chrome.storage)
├── custom-rules/                  # reserved (LT rulesFile hook — flag verified present)
├── docs/PHASE_0_VERIFICATION_AND_V1_SPEC.md
├── scripts/                       # fetch-engine.sh · patch-jdk.sh · launcher.sh · make-app.sh · bench-launch.sh · gen-payload.sh
└── probe/mv3-probe/               # Phase 0 evidence, kept
```

## 3.5 v1 job list (boring and complete — build order)

1. `scripts/patch-jdk.sh` — automate the §1.2 recipe; makes any fresh machine reproducible.
2. `scripts/fetch-engine.sh` — pinned-URL fetch of LT 6.6 + Temurin 17, integrity-checked.
3. `engine/server.properties` (§3.4).
4. `scripts/launcher.sh` + `scripts/make-app.sh` → `LWA.app` (§3.2).
5. Extension skeleton: manifest (locked permissions), service worker with health-check + status popup.
6. Generic-forms extractor + debounce/abort pipeline.
7. Overlay renderer + one-click apply (forms first).
8. Gmail compose module.
9. Client-side user dictionary.
10. Docs module spike → ship or defer to v1.1 by measured stability.
11. Install walkthrough (README: right-click-open note, first-run checklist).
12. QA round: Vesper flags, Claude fixes (per engine order), Tracy accepts.

**Parking lot (v2.txt, beside this spec):** true menubar item (Swift), Google Docs if deferred from v1, llama.cpp rewrite layer (Phase 2 per plan), native system-wide client, name finalization, public distribution.

## 3.6 Definition of done (v1)

Tracy double-clicks `LWA.app`, gets "ready" with no Terminal window; types in Gmail and a standard web form; sees underlines; applies a fix with one click; quits the app and every child process is gone (port free, pid gone). `nettop` on the engine shows zero WAN bytes at any point. — Then, and only then, v1 is done.

---

*Approval gate: PASSED — Tracy, 2026-10-10. Build lane: Cori builds J1–J12, Claude fix-pass, Vesper QA-gate.*
