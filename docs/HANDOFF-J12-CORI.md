# HANDOFF — J12 target-machine battery re-run (for Cori)

**From:** Claude (fix lane) · **To:** Cori (build/QA, evidence) · **Then:** Vesper close-out → Tracy accepts
**Date:** 2026-10-12 · **Branch:** `main`. The J12 fixes are one commit on top of `04b6de1`: `J12 fixes: Vesper QA round — 5 S2 + 13 S3`

**Read this first.** It replaces the conversation history. If you need detail on any
finding, it's in `docs/QA-J12-FIXES.md`. Don't re-derive anything else.

## Why you're needed

All 5 S2s and 13 S3s from Vesper's J12 review are fixed, and every battery is green, but
**only on Linux**: Playwright Chromium, a **fake** LT engine on 8081, and shims standing in
for `otool`/`xcode-select`. Each new assertion was also shown to fail on the original
code, so the tests do catch their bugs. What hasn't been proven is real Chrome 128 +
real LT 6.6 + real otool on the 2012 MBP. **That run is the job. Run and report only: no
code fixes, no pushes to main, no merge.**

## Setup (once)

**No GitHub access needed.** Tracy has already pulled `main` into the local repo.
Everything below is local git only, so don't fetch or pull.

```sh
cd ~/workspace/grammar-tool
git branch --show-current     # expect: main
git log --oneline -1          # expect subject: J12 fixes: Vesper QA round — 5 S2 + 13 S3
git status --short            # expect empty (no local edits under test)
```

If any check doesn't match, **stop and ask Tracy** to redo the checkout. Don't fix it
yourself.

Preconditions (all were already true on this machine after J11; confirm, don't redo):
- `engine/LanguageTool-6.6/` present (else `sh scripts/fetch-engine.sh`)
- `~/jdks/jdk-17.0.20.1+1` patched, and `~/jdks/temurin17-jdk.tar.gz` still cached (L1 extracts a fresh, **unpatched** copy from it)
- `vendor/lwa-extension.pem` present (dict-battery derives the extension ID from it)
- CommandLineTools installed: `xcode-select -p` prints a path (else L1 SKIPs by design)
- Nothing of yours on 8082/8083/8091. The batteries kill whatever listens on 8082/8083.
- **Reload the unpacked extension** in your daily Chrome profile afterwards if you use it. The batteries run their own fresh profiles, so they don't need this.

## Run (in this order, ~5 min total)

Save each output; `/tmp/lwa-capture.jsonl` and `/tmp/lwa-driver-report.json` get
overwritten by the next battery, so **copy them right after any battery that fails**.

```sh
mkdir -p /tmp/j12 && cd ~/workspace/grammar-tool
sh scripts/launcher-battery.sh 2>&1 | tee /tmp/j12/launcher.txt   # no Chrome; port 8091, never touches 8081
sh scripts/forms-battery.sh    2>&1 | tee /tmp/j12/forms.txt
sh scripts/overlay-battery.sh  2>&1 | tee /tmp/j12/overlay.txt
sh scripts/gmail-battery.sh    2>&1 | tee /tmp/j12/gmail.txt
sh scripts/dict-battery.sh     2>&1 | tee /tmp/j12/dict.txt
# after any FAIL:  mkdir -p /tmp/j12/<name>-fail && cp /tmp/lwa-capture.jsonl /tmp/lwa-driver-report.json /tmp/j12/<name>-fail/
```

## Expected (green = these exact lines)

| Battery | Expect | New this round (the J12 proof) |
|---|---|---|
| launcher | `LAUNCHER BATTERY: ALL GREEN`, L1–L4 PASS | all four (S2-5) |
| forms | T1–T8 PASS | T7 retype (S2-1), T8 cc-* textarea (S3-1); T5/T6 are back (J6 driver restored) |
| overlay | O1–O7 PASS | O6/O7 two fields at once (S2-2) |
| gmail | G1–G8 + privacy PASS | G7 minimize clears, G8 restore re-renders (S2-3) |
| dict | U1–U5 PASS | U4/U5 live page follows dict add/remove (S2-4) |

## Where a real-machine failure is most likely (check these first)

1. **O1 / O4: LT match ordering.** The assertions are unchanged from J7 (green then), but
   the fake engine only imitated LT. A FAIL here with `counts=` / `richAfter=` showing a
   different first match means ordering, not the fix.
2. **L1: real `otool` output.** The probe greps `otool -L lib/*.dylib` for
   `JavaRuntimeSupport`. If L1 fails with `preflight ok` (the battery deletes its extract
   on exit), re-extract by hand and include the output:
   `mkdir /tmp/j12/jdk && tar xzf ~/jdks/temurin17-jdk.tar.gz -C /tmp/j12/jdk && otool -L /tmp/j12/jdk/jdk-17.0.20.1+1/Contents/Home/lib/libawt.dylib`.
   If L2 fails (the *patched* JDK is reported unpatched), that's the important one: send
   `for f in ~/jdks/jdk-17.0.20.1+1/Contents/Home/lib/*.dylib; do otool -L "$f" | grep -l JavaRuntimeSupport && echo "$f"; done`.
3. **T5 (debounce exactly-one) on the slow chip.** It was fragile in J6 too. Before J12 every
   battery also got the popup dict driver (adding and removing words). That driver now opens
   only in dict-battery, so T5 should be *less* noisy than before. If it fails anyway, include
   `part5=/part1-4=` from the line.
4. **U4/U5 timing.** The popup waits ≤20 s for the fixture's first overlay, and ≤10 s after
   each add/remove. A cold engine on first run could miss the 20 s budget: re-run dict-battery
   **once** with the engine already warm. A second fail is real.
5. **G7/G8 timing.** These rely on ResizeObserver + one animation frame within 400 ms / 800 ms.
   The fixture tab is in the foreground, so this should hold. If not, include the
   `rectsBeforeMinimize/clearedAfterMinimize/afterRestore` numbers.

Rule from the brief still holds: "flake" is not a root cause. One re-run per battery max,
and only if the failure looks like a cold start (engine warmup, first Chrome launch).

## Quick manual smoke (optional, ~2 min, daily profile after reloading the extension)

- Type `Their was a obvious mistake.` in two different textareas on any page: **both** keep
  their underlines.
- Popup → add a flagged misspelled word to the dictionary → its underline disappears without typing.
- Launcher dialog wording: not needed. L1–L4 cover it headless.

## Report back (paste to Tracy, she routes it)

```
J12 target re-run — HEAD <sha> — <date>
launcher: <ALL GREEN | FAIL Lx: line>
forms:    <...>
overlay:  <...>
gmail:    <...>
dict:     <...>
re-runs used: <none | battery + reason>
attachments: /tmp/j12/*.txt (+ *-fail/ dirs)
```

All green → Vesper does the close-out pass on the branch head (start at `docs/QA-J12-FIXES.md`).
Any red → back to Claude with the failing line + its `-fail/` capture files.

## Still open, not yours

- **S3-12:** wording of the 8082 battery-entry paragraph in spec §3.3. Tracy approves.
- **Live-Gmail checklist** (`docs/extension-gmail.md`, now with minimize → restore). Tracy's, pre-declared.
- S3-2 (per-field abort) and S3-6 (2nd-compose id suffix) were verified by review only. No battery observes them, and that's documented.
