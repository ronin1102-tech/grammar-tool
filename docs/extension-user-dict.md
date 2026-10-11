# User dictionary — contract & test map (J9)

**Status:** build spec (battery-first) · completes v1 spec §3.3 (client-side dict) · 2026-10-11

## Architecture (locked)

- Storage: `chrome.storage.local` key `userDict` — `{ word: { addedAt } }`, words lowercased.
  Stays browser-local (sync would need the `storage` syncArea — parked; it still never leaves
  the machine unless Chrome sync is on, so local it is).
- **Filter lives in the SW** (single choke point): every engine response's matches pass
  through `filterMatches(matches, dict)` before reaching field-check callers AND before
  evidence is emitted. Rule: a match is filtered when its **lowercased matched text**
  equals a dictionary word **and** its rule category is in `filterCategories`
  (default `["TYPOS"]`) — a user-added word must never hide a grammar error.
- No new permissions. No new hosts. Manifest unchanged this round.
- Popup gains a dictionary section: list (word + remove ✕) and add input. Same page the
  status dot lives on — one surface, no settings jungle in v1.

## Contract

**background.js**
- `dictKey(w) = w.trim().toLowerCase()`
- `getDict()` / `setDict(d)` — chrome.storage.local, single key.
- `filterMatches(matches, dict)` — as ruled above; evidence emits BOTH counts:
  `{ engineMatches, shownMatches, filtered }` so the battery can see the delta.
- Messages: `dict-get` → `{dict}`, `dict-add {word}` → `{ok, dict}`, `dict-remove {word}` →
  `{ok, dict}` (all respond with the full dict; popup re-renders from responses).
- `field-check` response shape grows: `{ok, matches, engineMatches, filtered}` (matches =
  post-filter — callers unchanged).

**popup.js / popup.html**
- Dictionary list rendered from `dict-get`; add on Enter/button; remove per row.
- Battery driver (popup opened as a tab by the SW itself: `?battery=1`, driver reuses the
  PRODUCTION `field-check` path): adds `Sam`, probes, removes, probes. Probe sentence is
  `Tell sam and Xkalt about the mistkae.` — LT does NOT flag sentence-initial capitalized
  words (could be a proper noun; verified against 6.6), so the target word sits mid-sentence
  lowercase while the dict word stays capitalized: this exercises case normalization.
- Rig mechanics (both learned this round): command-line navigation to chrome-extension://
  URLs does not open the page — the SW opens the tab via chrome.tabs.create, triggered by
  a capture POST hello on 8082 (the rig's signature; silent in daily use). The hello lives
  in onInstalled: a fresh profile is a fresh INSTALL — Chrome never fires onStartup there.

## Test map (dict-battery.sh)

| # | Assertion | Evidence |
|---|---|---|
| U1 | engine flags all three probe words | `dict-probe` with engineMatches ≥ 3 (pre-dict baseline call) |
| U2 | adding `Sam` filters exactly its match | second probe: shown = engine − 1, `mistkae` still present |
| U3 | removing `Sam` restores the match | third probe: shown = engine, dictSize back to baseline |

Ride-along: no password capture regression this round (no new text paths; popup driver
sends only the probe sentence through the existing SW route).
