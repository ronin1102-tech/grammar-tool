# Extension content script — contract & test map (J6)

**Status:** build spec (battery-first) · part of v1 spec §3.3 · 2026-10-11
**Feature:** generic-forms text extraction + debounce/abort pipeline (J6). Overlay/apply is J7.

## Architecture rule (locked)

Content scripts NEVER fetch cross-origin — they inherit the host page's CORS.
All engine traffic goes through the service worker (`chrome.runtime.sendMessage` →
`background.js`), which holds `host_permissions`. One network path, one place to guard.

## Contract

**content.js** (injected `<all_urls>`, `document_idle`, top frames):
- Tracks editables by their `input` events (target-driven — no focus tracking to miss). Per-field debounce timers: one field's pending re-check is never cancelled by typing in another (J7 battery finding). No-op guard: unchanged text is never re-sent.
- **Checkable allowlist** (everything else is invisible to the pipeline):
  `textarea`, `input[type=text|search|url]`, `contenteditable` blocks.
- **Secret guards — never read, never sent:** `input[type=password]`,
  `input[type=email|tel|number]`, any `autocomplete` starting with `cc-`.
- 700 ms debounce (collapses keystroke bursts into one check).
- Text cap 10 000 chars (mirrors `maxTextLength`).
- Sends `{type:"field-check", field, tag, text}`; keeps last result per field for J7.

**background.js** `field-check` handler:
- Enforces the 10 000-char cap server-side too (defense in depth).
- Latest-wins abort: a new check aborts the in-flight one (`AbortController`).
- Returns `{ok, matches[]}` (full match objects — J7 consumes them).
- Emits battery evidence `{kind:"field-check", field, textLength, matchesCount, sample(40)}`.

**Test channel:** SW POSTs evidence to `127.0.0.1:8082/capture` (test rig only; silent when absent).

## Test map

| # | Assertion | Expected evidence |
|---|---|---|
| T1 | password field is never checked | no capture entry for `#pw`; no `hunter2` anywhere |
| T2 | `autocomplete=cc-number` never checked | no capture entry for `#cc`; no `4111` anywhere |
| T3 | textarea checked, matches work | `#public` captured, `matchesCount ≥ 2` |
| T4 | contenteditable checked | `#rich` captured, `matchesCount ≥ 1` |
| T5 | debounce collapses a burst | `#public` receives 5 input events 120 ms apart → exactly ONE capture, full final text |
| T6 | 10 000-char cap | `#huge` (12 000 chars) → `textLength == 10000` |

**Honest untested edge:** true in-flight abort (request already sent, then aborted) needs a
slow engine to observe; on localhost the window is ~1 ms. AbortController is in place,
mechanism reviewed, behavior unverified — noted, not claimed.
