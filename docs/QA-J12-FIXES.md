# J12 — Fix-lane response (Claude)

**Input:** Vesper's J12 QA → Fix handoff (5 × S2, 13 × S3, 0 × S1) against `04b6de1`.
**Status:** every S2 fixed; every S3 fixed or written up (S3-12 wording is Tracy's call).
**Owed before acceptance:** a battery re-run on the target machine (2012 MBP, Catalina,
Chrome 128, real LT 6.6), then Vesper's close-out pass on the fixed tree.

## How this was verified (read before trusting the greens)

The fix lane ran on Linux, not the target machine. The batteries ran **unmodified in their
assertions**. Only the rig paths were swapped: Playwright's Chromium (`--headless=new`) in
place of macOS Chrome, and a **fake LT engine** on 8081 returning LT-shaped matches for the
fixture sentences. The launcher battery ran with `otool`/`xcode-select` shims and a
synthetic JDK tarball. So the extension logic and the battery wiring are proven here. The
real-engine, real-Chrome, real-otool behavior is **not** proven yet: that's the target re-run.

Each new assertion was also run against the **original** code (negative control) and
fails there:

| Assertion | Original code (`04b6de1`) | Fixed tree |
|---|---|---|
| T7 retype re-checks (S2-1) | FAIL: 1 capture, bridge empty after retype | PASS |
| T8 cc-* textarea (S3-1) | FAIL: field checked, `4242` captured | PASS |
| O6 both fields underlined (S2-2) | FAIL: public 0 bars drawn (bridge still claimed 1) | PASS |
| O7 apply in B leaves A intact (S2-2) | FAIL: public 0 bars before and after | PASS |
| G7 minimize clears (S2-3) | FAIL: bridge still set after hide | PASS |
| G8 restore re-renders | (new behavior) | PASS |
| U4/U5 live dict refresh (S2-4) | FAIL: live overlay stays 3 → 3 → 3 | PASS |
| L1–L4 launcher JDK UX (S2-5) | FAIL: all four (no probe; generic messages) | PASS |

## Target-machine re-run (Cori / Tracy)

```sh
sh scripts/forms-battery.sh     # T1–T8
sh scripts/overlay-battery.sh   # O1–O7
sh scripts/gmail-battery.sh     # G1–G8
sh scripts/dict-battery.sh      # U1–U5
sh scripts/launcher-battery.sh  # L1–L4 (new; spare port 8091, never touches 8081)
```

Real-engine items the fake engine can't settle:
- **O1/O4** depend on LT's match ordering (unchanged assertions; were green in J7).
- **L1** needs the cached `~/jdks/temurin17-jdk.tar.gz` (unpatched by construction) and
  CommandLineTools. Without CLT it SKIPs by design, and L3 covers the fallback path.
- **L3** asserts on the dyld wording `JavaRuntimeSupport`. Whether a real unpatched JDK dies
  at boot or only later is §1.2 territory. L1 is the primary path.

## Per finding

| # | Fix | Where | Verified by |
|---|---|---|---|
| S2-1 | Empty-text branch deletes `lastChecked` before clearing. Also: a failed or aborted check forgets its text, so the same text retries once the engine is back (same no-op-guard trap). | `content.js` | T7 |
| S2-2 | Per-field overlay state: `Map el → {field, matches, checkedText, rects, group}`, each field drawing into its own group. `clearFor`, hit-testing and re-render key off the map. | `overlay.js` | O6, O7 |
| S2-3 | Generic, in overlay: a `ResizeObserver` on each tracked field fires when it collapses to 0×0 (`display:none` on it or an ancestor). Hidden fields drop bars and bridge but keep state, so a restored compose gets its underlines back. Removal observer kept. | `overlay.js`, `gmail.js` | G7, G8 |
| S2-4 | SW broadcasts `dict-changed` to all tabs after add/remove (tab ids only, no new permission). content.js re-checks every field it has checked. A re-check, not a re-filter, so remove restores too. | `background.js`, `content.js` | U4, U5 |
| S2-5 | Launcher preflight: if JRS is absent from the OS and CLT is present, `otool -L` over `lib/*.dylib`. Unpatched → dialog naming `scripts/patch-jdk.sh <JDK home>`. Died-at-boot with a JRS dyld error → same dialog. Missing JDK → names fetch-engine.sh and patch-jdk.sh. New `LWA_PREFLIGHT_ONLY=1` test hook. | `launcher.sh` | L1–L4 |
| S3-1 | `cc-*` autocomplete guard applies to every element. | `content.js` | T8 |
| S3-2 | Per-field AbortControllers keyed `tab:frame:field`. Needed now anyway: a dict-change re-check of several fields would otherwise abort all but the last. | `background.js` | reviewed; not observable on localhost (same honest-untested note as J6) |
| S3-3 | Scroll/resize/size-change refresh is rAF-throttled. | `overlay.js` | all overlay batteries |
| S3-4 | Dead `current.layer` branch gone with the rewrite. | `overlay.js` | n/a |
| S3-5 | Tautological ternary removed. | `gmail.js` | G6 |
| S3-6 | 2nd+ compose dialog gets an index suffix (`…message-body-2`). | `gmail.js` | reviewed; G5 still green (single dialog) |
| S3-7 | Popup shows an error line when the SW doesn't answer an add/remove. | `popup.js/html` | reviewed |
| S3-8 | Popup note: dictionary hides spelling flags only. README checklist row reworded to match. | `popup.html`, `README.md` | reviewed |
| S3-9 | Smoke boot passes `--config engine/server.properties`. | `fetch-engine.sh` | `sh -n`; target run owed |
| S3-10 | `command -v python3` with the other prereqs. | `fetch-engine.sh` | `sh -n` |
| S3-11 | On start, a log over 1 MB moves to `engine.log.1` (one generation kept). | `launcher.sh` | local: 1.1 MB log rotated, fresh log started |
| S3-12 | Battery-entry paragraph added under §3.3 Manifest, **marked pending Tracy's wording approval**. | spec §3.3 | Tracy |
| S3-13 | Troubleshooting lists all three files that hardcode 8081. | `README.md` | n/a |

## Rig findings surfaced while fixing (not in Vesper's list)

1. **forms-battery had no driver since J7.** J7's overlay driver replaced J6's on the shared
   fixture page, so T5/T6 had nothing to observe. The J6 driver is restored as
   `?battery=forms`, and forms-battery.sh now opens that.
2. **T6 counted overlay captures.** Since J7, overlay evidence shares field ids
   (`field:"huge"`, no `textLength`). Assertions now read `field-check` captures only.
3. **Every battery got a popup dict driver.** Any capture server answered the SW's
   `battery-hello`, so the popup driver ran in every battery. Harmless before; with live
   dict refresh it would inject re-checks into other fixtures (e.g. T5's exactly-one).
   Now only dict-battery's capture server replies `dict`, and the SW opens the driver only
   on that reply.
4. **`fixture-server.js` had a hardcoded absolute path** (`/Users/.../tests/fixtures`).
   It now uses `__dirname`, which is identical on the target machine.
