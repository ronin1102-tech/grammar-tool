# Extension overlay & apply — contract & test map (J7)

**Status:** build spec (battery-first) · extends v1 spec §3.3 · 2026-10-11
**Feature:** non-destructive inline underlines + one-click replacement apply.

## Scope split (locked for v1)

| Surface | Technique | Status |
|---|---|---|
| `contenteditable` (Gmail-class) | native `Range` + CSS Custom Highlight API (`::highlight(lwa-matches)`, Chrome ≥105 ✓ 128) | J7 |
| `textarea` / `input[text]` | mirror-div measurement → fixed-position underlay bars (pointer-events:none) | J7 |
| Google Docs canvas | none | parked → J10 spike decides |

## Architecture rules (locked)

1. Engine traffic stays in the SW (J6 rule). Overlay evidence also routes through the SW
   (`battery-evidence` message → capture channel) — content scripts can't cross-origin fetch.
2. Page ↔ content-script state bridge is **DOM only**: field gets
   `data-lwa-rects='[[x,y,w,h,matchIndex]…]'` (isolated worlds share the DOM, not JS scope).
3. Apply is **non-destructive**: only on explicit click of an underlined match; applies
   `replacements[0]`; the resulting `input` event triggers the normal debounce → re-check.

## Contract

**overlay.js** (same content_scripts entry as content.js — shared isolated world):
- `window.__LWA_OVERLAY.render({el, field, text, matches})` — called by content.js with each
  field-check response. Renders underlines, stores that field's state, publishes
  `data-lwa-rects`, emits `{kind:"overlay", field, count, rects[]}` evidence.
- **State is per field** (J12 S2-2): a `Map` of `el → {field, matches, checkedText, rects}`,
  each field drawing into its own group in the shared layer. Underlines persist per field
  until THAT field changes; checking or applying in field B never touches field A.
  `clearFor(el)`, click hit-testing, and re-render all key off the map.
- Document-level click (capture): if the click lands in a stored match rect (±2–3px), apply:
  - plain fields: `setRangeText(rep, offset, offset+length)` (+ fallback string splice)
  - contenteditable: select the match Range → `execCommand("insertText", rep)` (undo-preserving)
  - both dispatch `input` → automatic re-check (and thus overlay refresh)
  - emits `{kind:"apply", field, from, to}` evidence
- Re-render on scroll/resize, rAF-throttled (J12 S3-3), and on tracked fields' size changes
  (`ResizeObserver`). A field that is hidden (0×0 — itself or an ancestor `display:none` —
  or `visibility:hidden`) drops its bars and bridge but keeps its state; when it shows
  again, the underlines come back (J12 S2-3).
- Known v1 limitation (accepted): match offsets can go stale if the user types between check
  and click; the fast re-check loop is the mitigation. Real Gmail-surface verification = J8.
- Readiness handshake: content side fires `lwaReady` on document once listeners are attached;
  test drivers wait for the event (never race document_idle with a timer).

**background.js**: adds `battery-evidence` pass-through to the capture channel. Nothing else.

## Test map (overlay-battery.sh, fixture v2 driver)

| # | Assertion | Evidence |
|---|---|---|
| O1 | overlays render on textarea: first render ≥2 matches, post-apply render = first − 1 (applied underline gone), rects inside field bounds | `overlay` captures + driver's `publicFieldRect` |
| O2 | dataset bridge live on both field types | driver reads `data-lwa-rects` non-empty |
| O3 | click at rect[0] on textarea applies `replacements[0]` and auto-re-checks | driver `publicAfter` startsWith "There was"; `apply` capture; later `field-check` sample startsWith "There was" |
| O4 | same on contenteditable ("exmaple" → "example") | driver `richAfter` contains "example"; `apply` capture |
| O5 | privacy guards still hold (regression): password value never appears | no `hunter2-secret`/field `pw` anywhere in captures |
| O6 | two fields underlined at once (J12 S2-2) | driver counts bars DRAWN over each field (leaf divs of `#lwa-overlay-layer`) — not just the bridge, which pre-J12 went stale |
| O7 | apply in one field leaves the other's underlines intact (J12 S2-2) | public's bridge byte-identical and bar count unchanged across the rich-field apply |

**Honest untested:** undo-stack preservation after `execCommand` apply (manual check in J8
Gmail pass); mirror fidelity under page zoom; overlay behavior in cross-origin iframes
(v1 is top-frame only).
