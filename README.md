# Local Writing Assistant (working title)

Private, offline grammar checking for macOS. Your words never leave your machine —
that is a verified property of this build, not a policy (see *Offline & privacy* below).

Three pieces:
- **Engine** — LanguageTool 6.6 on a patched Temurin JDK 17, listening on 127.0.0.1:8081 only.
- **LWA.app** — double-clickable launcher that boots the engine, tells you when it's
  ready, and offers Stop/Restart on re-open.
- **Chrome extension** — MV3 thin client: extracts the text you're editing (forms,
  Gmail compose), checks it against the local engine, underlines findings, and applies
  a fix on one click. Never rewrites text without your click.

**Requirements:** macOS Catalina 10.15+ · Chrome 128 (the last Chrome that runs on
Catalina) · ~1.4 GB disk for the engine + JDK · no admin password (tarball JDK, no cask).

---

## Fresh install (one time)

### 1. Get the repo

    git clone https://github.com/ronin1102-tech/grammar-tool.git
    cd grammar-tool

The engine ZIP and JDK are **not** in the repo (gitignored) — the next step fetches
exact pinned copies and proves them by checksum.

### 2. Fetch the engine (one command, ~5 min)

    sh scripts/fetch-engine.sh

Downloads pinned LanguageTool 6.6 + Temurin 17.0.20.1+1, sha256-verifies both, extracts,
applies the Catalina JDK patch, then boots the server and runs one real grammar check
as a smoke test. Expected final lines (executed output from the target machine):

    OK: 0 dylib(s) patched, 0 JavaRuntimeSupport references remain in ~/jdks/jdk-17.0.20.1+1/Contents/Home/lib
    smoke: HTTP 200, 2 grammar matches on test sentence
    OK: engine ready at …/engine/LanguageTool-6.6 (JDK: ~/jdks/jdk-17.0.20.1+1/Contents/Home)

Re-running it is safe and cheap — already-verified artifacts are skipped
("ok (cached, checksum verified)"). Re-run it after `git pull` in case pins changed.

### 3. Build the launcher bundle

    sh scripts/make-app.sh

Produces `LWA.app` in the project root. Rebuild only if the project moves; a plain
`git pull` updates the launcher's behavior (the bundle just runs `scripts/launcher.sh`).

### 4. Start the engine

First launch on Catalina needs one right-click → **Open** on `LWA.app` (it's an
unsigned applet; the one-time Gatekeeper bypass). After that, double-click works.
You'll get a notification: **"Writing engine ready."** (budget is 240 s; ~7 s is
typical). While it runs, re-opening LWA.app offers Stop / Restart / OK.

Command-line equivalent: `sh scripts/launcher.sh start` (also `status`, `stop`, `restart`).

### 5. Load the extension (Developer Mode)

1. Open `chrome://extensions`, toggle **Developer mode** on (top right).
2. Click **Load unpacked** and select the `extension/` folder of this repo.
3. The extension appears as **Local Writing Assistant**. Its ID will be
   `hcnbhjnmgnbpnelbpjakhmegdpinhago` — that exact value, on every machine, because the
   signing key is pinned inside `extension/manifest.json` (`"key"` field). (Chrome
   displays IDs in a letters-only a-p alphabet; the same value in hex is
   `72d179dc6d1fd4b1f90a7c463f8d706e`.) If the first six letters aren't `hcnbhj`,
   something else got loaded.

### 6. First-run checklist (2 minutes, do all four)

**One gotcha:** pages that were already open before you loaded the extension don't
have it — content scripts attach when a page loads. Reload any open tab (⌘R) once
after loading, and after every extension reload.

| Check | Do | Expect |
|---|---|---|
| Engine link | Click the LWA toolbar icon | Green dot + "Engine ready · <a few hundred> ms" |
| Grammar loop | Open any page with a text box, type `This is a obvious test.` | Within ~1 s, "a obvious" underlined; click it → becomes "an obvious" |
| Gmail | Open a Gmail compose window, type the same sentence | Same underlines inside the compose body |
| Dictionary | LWA popup → "Always accept (dictionary)" → add your name | The engine stops flagging it from now on |

The debounce is 700 ms — stop typing for a moment and the underlines appear.

(Gmail row: battery-proven on the fixture — live-Gmail confirmation is the owner
checklist in `docs/extension-gmail.md`, still pending. Everything else above is
executed-this-session behavior.)
### 7. Everyday use

Start the engine when you sit down to write (double-click LWA.app), stop it when you're
done (re-open → Stop, or `sh scripts/launcher.sh stop`). The extension works only while
the engine is up; the popup says **"Engine down."** otherwise. Nothing degrades, nothing
queues — typing while the engine is off is just unchecked.

---

## Troubleshooting

- **"Port 8081 is already in use by pid NNN (not ours)."** — quit that process, or set
  `LWA_PORT` for the launcher. Note the extension is pinned to 8081 by its manifest
  allowlist, so moving the port means editing `extension/manifest.json` too.
- **"Engine did not become ready in 240s."** — look at the last lines of
  `data/engine.log`; the launcher dialog names that file too.
- **Popup shows "Engine down."** — the engine isn't running. Start LWA.app, then hit
  **Check now** in the popup.
- **Fresh clone has no `engine/` or `vendor/`** — by design. Run step 2.
- **macOS blocked LWA.app** — right-click → Open → Open (once).

## Offline & privacy (verified properties)

- The engine binds **127.0.0.1 only** — the launcher never passes `--public`, and a
  full-life network audit of the server process showed **zero bytes in/out** (spec §1.4).
- The extension's `host_permissions` allow only `localhost`/`127.0.0.1` — Chrome blocks
  every other origin, so the client *cannot* phone home even by accident.
- Secret fields never get checked: `type=password` and `autocomplete=cc-*` inputs are
  skipped before any text is sent.
- Only the text of the element you're editing is sent, capped at 10,000 characters.

## Updating

    git pull
    sh scripts/fetch-engine.sh   # idempotent; only fetches if pins changed
    # restart the engine when prompted (LWA.app offers Restart if engine files are newer)

---

*Every command in this file was executed on the target machine (2012 MBP,
Catalina 10.15.7, Chrome 128) during the J11 round, 2026-10-12. Extension loading was
proven via --load-extension (the batteries' mechanism); the manual chrome://extensions
flow is the standard equivalent. Surface behaviors are battery-proven (scripts/*-battery.sh);
live-Gmail remains the owner-flagged item. Verification log:
`docs/PHASE_0_VERIFICATION_AND_V1_SPEC.md`.
