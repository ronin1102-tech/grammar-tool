# Gmail compose module — contract & test map (J8)

**Status:** build spec (battery-first) · extends v1 spec §3.3 · 2026-10-11
**Feature:** first per-surface module. Gmail compose = `contenteditable` inside `[role=dialog]`;
the J6/J7 pipeline is event-driven and surface-agnostic, so this module adds identity,
lifecycle, and proof — not a new pipeline.

## Contract

**gmail.js** (loaded LAST: overlay.js, content.js, gmail.js):
- Registers `window.__LWA_FIELD_ID(el)` — a provider consulted by content.js's `fieldId()`
  at check time. Returns `"gmail-compose:<aria-label slug>"` for textboxes inside a
  `[role=dialog]` (e.g. `gmail-compose:message-body`), `null` otherwise (generic fallback).
  Evidence field ids therefore carry the surface — captures are self-describing.
- Compose-dialog lifecycle: a MutationObserver watches for dialog removal and calls
  `__LWA_OVERLAY.clearFor(textbox)` — closing a compose window can never leave stale
  underlines floating over the page.
- No new network paths. Overlay layer z-index (2147483646) already exceeds Gmail dialogs'.

**content.js** (one-line change): `fieldId()` tries `__LWA_FIELD_ID` first, then generic
id/name/tag@N fallback.

**In scope for v1:** modern Gmail (same-document compose, 2018+). Iframe-embedded compose
and top-frame-only restrictions are unchanged; cross-origin iframes remain out of scope.

## Test map (gmail-battery.sh, gmail fixture + driver v3)

Fixture mimics the compose dialog (fixed-position `[role=dialog]`, `role=textbox
[aria-label="Message Body"]`, multi-paragraph body with `<p>` + `<br>`).

| # | Assertion | Evidence |
|---|---|---|
| G1 | dialog-hosted multi-paragraph body checked; offsets correct across `<p>`/`<br>` boundaries | `field-check` for `gmail-compose:message-body`, textLength = textContent concatenation (87 for the 2-paragraph fixture — textContent semantics, not innerText's 103), matches ≥ 2 |
| G2 | overlay rects render inside the compose body's bounds | `overlay` capture rects within driver-reported field rect (±6px) |
| G3 | click applies matches[0]; auto re-check fires with corrected text | `apply` capture + later `field-check` sample startsWith corrected text |
| G4 | **undo proof** (J7's honest-untested item): `execCommand("undo")` restores the original wording — the correction sits on the page's native undo stack | driver report `undoRestores: true`, before/after text in report |
| G5 | field id carries the Gmail label | captures contain `gmail-compose:` prefix |
| G6 | compose dialog removed → overlay bridge cleared (lifecycle) | driver reads `data-lwa-rects` undefined after dialog removal |

Privacy re-assert rides along (password value never in captures) — same as every round.

**Driver sequencing note (run-1 lesson):** a driver's follow-up actions are concurrent
actors — undo fired its own input event and legitimately rescheduled the re-check the test
was waiting for. Order driver actions so each observed behavior completes its full event
lifecycle (apply → debounce → engine → evidence) before the next action.

**Honest untested in rig:** live Gmail DOM drift (fixture mirrors the documented shape,
not Google's live markup); undo on plain textareas (v1 claims undo-preservation for rich
fields only — G4 proves it where claimed).

## Live-Gmail pass (owner Tracy — login wall, ~3 minutes)

1. Start `LWA.app` (or `scripts/launcher.sh start`).
2. `chrome://extensions` → Developer mode → Load unpacked → `~/workspace/grammar-tool/extension`.
3. Open Gmail, click Compose, type: `Their was a obvious mistake and sent it yesterday.`
4. Expect underlines within ~1s of pausing. Click one → correction applies; `Cmd+Z` reverts
   it (the live-surface undo check).
5. Close the compose window → underlines vanish with it.
6. Report feel: underline lag, click precision, anything visually off. Any miss = new bug
   report, not a spec failure — the fixture mirrors documented DOM shape, not live markup.
